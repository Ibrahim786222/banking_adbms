-- ============================================================
-- FILE: procedures_triggers.sql
-- Run this THIRD (after sample_data.sql)
-- ============================================================
--DROP PROCEDURE IF EXISTS transfer_funds(INTEGER, INTEGER, DECIMAL);
--DROP PROCEDURE IF EXISTS deposit_funds(INTEGER, DECIMAL);
--DROP PROCEDURE IF EXISTS withdraw_funds(INTEGER, DECIMAL);
--DROP PROCEDURE IF EXISTS aries_recovery();
--DROP PROCEDURE IF EXISTS create_checkpoint();
-- ════════════════════════════════════════════════════════════
-- SECTION 1: AUDIT TRIGGER  (Active Database)
-- Fires automatically on every balance change
-- ════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION audit_balance_change()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_log (account_id, old_balance, new_balance, changed_by)
    VALUES (NEW.account_id, OLD.balance, NEW.balance, current_user);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_balance ON accounts;
CREATE TRIGGER trg_audit_balance
AFTER UPDATE OF balance ON accounts
FOR EACH ROW
EXECUTE FUNCTION audit_balance_change();


-- ════════════════════════════════════════════════════════════
-- SECTION 2: WAL / ARIES HELPER
-- Writes a WAL entry before any data change (Write-Ahead Log)
-- ════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION wal_write(
    p_txid      VARCHAR,
    p_op        VARCHAR,
    p_table     VARCHAR  DEFAULT NULL,
    p_record_id INTEGER  DEFAULT NULL,
    p_old_val   TEXT     DEFAULT NULL,
    p_new_val   TEXT     DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO recovery_log
        (transaction_id, operation, table_name, record_id, old_value, new_value)
    VALUES
        (p_txid, p_op, p_table, p_record_id, p_old_val, p_new_val);
END;
$$ LANGUAGE plpgsql;


-- ════════════════════════════════════════════════════════════
-- SECTION 3: FUND TRANSFER  (fixed callproc → CALL bug)
-- Uses Pessimistic Concurrency Control (SELECT … FOR UPDATE)
-- Demonstrates 2-Phase Locking (2PL)
-- ════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE transfer_funds(
    p_from_account INTEGER,
    p_to_account   INTEGER,
    p_amount       DECIMAL(15,2),
    OUT p_status   TEXT,
    OUT p_message  TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_from_balance DECIMAL(15,2);
    v_tx_id        VARCHAR(50) := 'TX_TRF_' || to_char(NOW(), 'YYYYMMDDHH24MISS') || '_' || floor(random()*1000)::TEXT;
BEGIN
    -- WAL: LOG BEGIN
    PERFORM wal_write(v_tx_id, 'BEGIN');

    -- Validate amount
    IF p_amount <= 0 THEN
        p_status  := 'FAILED';
        p_message := 'Amount must be greater than zero';
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_from_account, NULL, 'Invalid amount');
        RETURN;
    END IF;

    -- Lock source account row (2PL – Growing Phase)
    SELECT balance INTO v_from_balance
    FROM accounts
    WHERE account_id = p_from_account
    FOR UPDATE;

    IF NOT FOUND THEN
        p_status  := 'FAILED';
        p_message := 'Source account not found';
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_from_account, NULL, 'Not found');
        RETURN;
    END IF;

    IF v_from_balance < p_amount THEN
        p_status  := 'FAILED';
        p_message := 'Insufficient balance. Available: ₹' || v_from_balance;
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_from_account, v_from_balance::TEXT, 'Insufficient');
        RETURN;
    END IF;

    -- Lock destination account row (2PL – Growing Phase continues)
    PERFORM 1 FROM accounts WHERE account_id = p_to_account FOR UPDATE;
    IF NOT FOUND THEN
        p_status  := 'FAILED';
        p_message := 'Destination account not found';
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_to_account, NULL, 'Not found');
        RETURN;
    END IF;

    -- WAL: LOG before UPDATE (Write-Ahead: log BEFORE data change)
    PERFORM wal_write(v_tx_id, 'UPDATE', 'accounts', p_from_account,
                      v_from_balance::TEXT, (v_from_balance - p_amount)::TEXT);

    -- Perform Transfer (2PL – Shrinking Phase / locks released at commit)
    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_from_account;
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_to_account;

    -- Log the transaction
    INSERT INTO transaction_log
        (transaction_id, from_account_id, to_account_id, amount, transaction_type, status, description)
    VALUES
        (v_tx_id, p_from_account, p_to_account, p_amount, 'TRANSFER', 'SUCCESS', 'Fund transfer successful');

    -- WAL: LOG COMMIT
    PERFORM wal_write(v_tx_id, 'COMMIT');

    p_status  := 'SUCCESS';
    p_message := 'Transfer successful! Transaction ID: ' || v_tx_id;

EXCEPTION
    WHEN OTHERS THEN
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_from_account, NULL, SQLERRM);
        INSERT INTO transaction_log
            (transaction_id, from_account_id, to_account_id, amount, transaction_type, status, description)
        VALUES
            (v_tx_id, p_from_account, p_to_account, p_amount, 'TRANSFER', 'FAILED', SQLERRM);
        p_status  := 'FAILED';
        p_message := 'Error: ' || SQLERRM;
END;
$$;


-- ════════════════════════════════════════════════════════════
-- SECTION 4: DEPOSIT
-- ════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE deposit_funds(
    p_account_id INTEGER,
    p_amount     DECIMAL(15,2),
    OUT p_status  TEXT,
    OUT p_message TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_balance DECIMAL(15,2);
    v_tx_id       VARCHAR(50) := 'TX_DEP_' || to_char(NOW(), 'YYYYMMDDHH24MISS') || '_' || floor(random()*1000)::TEXT;
BEGIN
    PERFORM wal_write(v_tx_id, 'BEGIN');

    IF p_amount <= 0 THEN
        p_status  := 'FAILED';
        p_message := 'Deposit amount must be greater than zero';
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_account_id, NULL, 'Invalid amount');
        RETURN;
    END IF;

    SELECT balance INTO v_old_balance
    FROM accounts
    WHERE account_id = p_account_id
    FOR UPDATE;

    IF NOT FOUND THEN
        p_status  := 'FAILED';
        p_message := 'Account not found';
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_account_id, NULL, 'Not found');
        RETURN;
    END IF;

    -- WAL before update
    PERFORM wal_write(v_tx_id, 'UPDATE', 'accounts', p_account_id,
                      v_old_balance::TEXT, (v_old_balance + p_amount)::TEXT);

    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_account_id;

    INSERT INTO transaction_log
        (transaction_id, from_account_id, to_account_id, amount, transaction_type, status, description)
    VALUES
        (v_tx_id, NULL, p_account_id, p_amount, 'DEPOSIT', 'SUCCESS', 'Cash deposit');

    PERFORM wal_write(v_tx_id, 'COMMIT');

    p_status  := 'SUCCESS';
    p_message := 'Deposited ₹' || p_amount || ' successfully! Tx: ' || v_tx_id;

EXCEPTION
    WHEN OTHERS THEN
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_account_id, NULL, SQLERRM);
        p_status  := 'FAILED';
        p_message := 'Error: ' || SQLERRM;
END;
$$;


-- ════════════════════════════════════════════════════════════
-- SECTION 5: WITHDRAW
-- ════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE withdraw_funds(
    p_account_id INTEGER,
    p_amount     DECIMAL(15,2),
    OUT p_status  TEXT,
    OUT p_message TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_balance DECIMAL(15,2);
    v_tx_id       VARCHAR(50) := 'TX_WDR_' || to_char(NOW(), 'YYYYMMDDHH24MISS') || '_' || floor(random()*1000)::TEXT;
BEGIN
    PERFORM wal_write(v_tx_id, 'BEGIN');

    IF p_amount <= 0 THEN
        p_status  := 'FAILED';
        p_message := 'Withdrawal amount must be greater than zero';
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_account_id, NULL, 'Invalid amount');
        RETURN;
    END IF;

    SELECT balance INTO v_old_balance
    FROM accounts
    WHERE account_id = p_account_id
    FOR UPDATE;

    IF NOT FOUND THEN
        p_status  := 'FAILED';
        p_message := 'Account not found';
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_account_id, NULL, 'Not found');
        RETURN;
    END IF;

    IF v_old_balance < p_amount THEN
        p_status  := 'FAILED';
        p_message := 'Insufficient balance. Available: ₹' || v_old_balance;
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_account_id, v_old_balance::TEXT, 'Insufficient');
        RETURN;
    END IF;

    -- WAL before update
    PERFORM wal_write(v_tx_id, 'UPDATE', 'accounts', p_account_id,
                      v_old_balance::TEXT, (v_old_balance - p_amount)::TEXT);

    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_account_id;

    INSERT INTO transaction_log
        (transaction_id, from_account_id, to_account_id, amount, transaction_type, status, description)
    VALUES
        (v_tx_id, p_account_id, NULL, p_amount, 'WITHDRAW', 'SUCCESS', 'Cash withdrawal');

    PERFORM wal_write(v_tx_id, 'COMMIT');

    p_status  := 'SUCCESS';
    p_message := 'Withdrawn ₹' || p_amount || ' successfully! Tx: ' || v_tx_id;

EXCEPTION
    WHEN OTHERS THEN
        PERFORM wal_write(v_tx_id, 'ABORT', 'accounts', p_account_id, NULL, SQLERRM);
        p_status  := 'FAILED';
        p_message := 'Error: ' || SQLERRM;
END;
$$;


-- ════════════════════════════════════════════════════════════
-- SECTION 6: ARIES RECOVERY SIMULATION
-- Simulates crash recovery using WAL (Write-Ahead Log)
-- Steps: Analysis → Redo → Undo  (classic ARIES algorithm)
-- ════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE aries_recovery(OUT p_report TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    r              RECORD;
    v_report       TEXT := '';
    v_winners      TEXT[] := '{}';   -- committed transactions
    v_losers       TEXT[] := '{}';   -- uncommitted (need UNDO)
BEGIN
    v_report := '=== ARIES RECOVERY SIMULATION ===' || chr(10);
    v_report := v_report || 'Timestamp: ' || NOW()::TEXT || chr(10) || chr(10);

    -- ── PHASE 1: ANALYSIS ──────────────────────────────────
    -- Scan WAL from last checkpoint to find winner/loser transactions
    v_report := v_report || '--- PHASE 1: ANALYSIS ---' || chr(10);

    FOR r IN
        SELECT DISTINCT transaction_id,
               bool_or(operation = 'COMMIT') AS committed
        FROM recovery_log
        WHERE is_checkpointed = FALSE
        GROUP BY transaction_id
    LOOP
        IF r.committed THEN
            v_winners := array_append(v_winners, r.transaction_id);
            v_report  := v_report || '  WINNER (committed): ' || r.transaction_id || chr(10);
        ELSE
            v_losers  := array_append(v_losers, r.transaction_id);
            v_report  := v_report || '  LOSER  (aborted):   ' || r.transaction_id || chr(10);
        END IF;
    END LOOP;

    v_report := v_report || chr(10);

    -- ── PHASE 2: REDO ──────────────────────────────────────
    -- Redo all committed transactions (reapply changes)
    v_report := v_report || '--- PHASE 2: REDO ---' || chr(10);

    FOR r IN
        SELECT * FROM recovery_log
        WHERE transaction_id = ANY(v_winners)
          AND operation = 'UPDATE'
        ORDER BY lsn ASC
    LOOP
        v_report := v_report
            || '  REDO on ' || r.table_name
            || ' record=' || r.record_id
            || '  ' || COALESCE(r.old_value,'NULL')
            || ' → ' || COALESCE(r.new_value,'NULL')
            || chr(10);
        -- (In a real system we would re-apply the UPDATE here)
    END LOOP;

    v_report := v_report || chr(10);

    -- ── PHASE 3: UNDO ──────────────────────────────────────
    -- Undo all loser transactions (reverse changes, newest-first)
    v_report := v_report || '--- PHASE 3: UNDO ---' || chr(10);

    FOR r IN
        SELECT * FROM recovery_log
        WHERE transaction_id = ANY(v_losers)
          AND operation = 'UPDATE'
        ORDER BY lsn DESC   -- reverse order for UNDO
    LOOP
        v_report := v_report
            || '  UNDO on ' || r.table_name
            || ' record=' || r.record_id
            || '  reverting ' || COALESCE(r.new_value,'NULL')
            || ' → ' || COALESCE(r.old_value,'NULL')
            || chr(10);
        -- (In a real system we would re-apply the reverse UPDATE here)
    END LOOP;

    -- Mark all processed logs as checkpointed
    UPDATE recovery_log SET is_checkpointed = TRUE
    WHERE is_checkpointed = FALSE;

    v_report := v_report || chr(10) || '=== RECOVERY COMPLETE ===' || chr(10);
    p_report := v_report;
END;
$$;


-- ════════════════════════════════════════════════════════════
-- SECTION 7: CHECKPOINT  (ARIES helper)
-- Marks current WAL position as stable
-- ════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE create_checkpoint(OUT p_message TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    UPDATE recovery_log SET is_checkpointed = TRUE WHERE is_checkpointed = FALSE;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    INSERT INTO recovery_log (transaction_id, operation)
    VALUES ('SYSTEM', 'CHECKPOINT');

    p_message := 'Checkpoint created. ' || v_count || ' log entries marked stable.';
END;
$$;
