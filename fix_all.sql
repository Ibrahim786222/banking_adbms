-- FILE: fix_all.sql
-- Run this ONE file to fix everything
-- It drops old procedures and recreates as functions

-- STEP 1: DROP EVERYTHING
DROP PROCEDURE IF EXISTS transfer_funds(INTEGER, INTEGER, DECIMAL);
DROP PROCEDURE IF EXISTS transfer_funds(INTEGER, INTEGER, NUMERIC);
DROP PROCEDURE IF EXISTS deposit_funds(INTEGER, DECIMAL);
DROP PROCEDURE IF EXISTS deposit_funds(INTEGER, NUMERIC);
DROP PROCEDURE IF EXISTS withdraw_funds(INTEGER, DECIMAL);
DROP PROCEDURE IF EXISTS withdraw_funds(INTEGER, NUMERIC);
DROP PROCEDURE IF EXISTS aries_recovery();
DROP PROCEDURE IF EXISTS create_checkpoint();
DROP FUNCTION  IF EXISTS transfer_funds(INTEGER, INTEGER, DECIMAL);
DROP FUNCTION  IF EXISTS transfer_funds(INTEGER, INTEGER, NUMERIC);
DROP FUNCTION  IF EXISTS deposit_funds(INTEGER, DECIMAL);
DROP FUNCTION  IF EXISTS deposit_funds(INTEGER, NUMERIC);
DROP FUNCTION  IF EXISTS withdraw_funds(INTEGER, DECIMAL);
DROP FUNCTION  IF EXISTS withdraw_funds(INTEGER, NUMERIC);
DROP FUNCTION  IF EXISTS aries_recovery();
DROP FUNCTION  IF EXISTS create_checkpoint();
DROP FUNCTION  IF EXISTS wal_write(VARCHAR, VARCHAR, VARCHAR, INTEGER, TEXT, TEXT);

-- STEP 2: WAL HELPER
CREATE OR REPLACE FUNCTION wal_write(
    p_txid VARCHAR, p_op VARCHAR,
    p_table VARCHAR DEFAULT NULL, p_record_id INTEGER DEFAULT NULL,
    p_old_val TEXT DEFAULT NULL, p_new_val TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO recovery_log(transaction_id, operation, table_name, record_id, old_value, new_value)
    VALUES (p_txid, p_op, p_table, p_record_id, p_old_val, p_new_val);
END;
$$ LANGUAGE plpgsql;

-- STEP 3: TRANSFER FUNCTION
CREATE OR REPLACE FUNCTION transfer_funds(
    p_from_account INTEGER,
    p_to_account   INTEGER,
    p_amount       NUMERIC
) RETURNS TABLE(status TEXT, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_bal  NUMERIC;
    v_txid VARCHAR(50) := 'TRF_' || to_char(NOW(),'YYYYMMDDHH24MISS') || floor(random()*999)::TEXT;
BEGIN
    PERFORM wal_write(v_txid,'BEGIN');
    IF p_amount <= 0 THEN
        RETURN QUERY SELECT 'FAILED'::TEXT, 'Amount must be greater than zero'::TEXT; RETURN;
    END IF;
    SELECT balance INTO v_bal FROM accounts WHERE account_id = p_from_account FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM wal_write(v_txid,'ABORT'); RETURN QUERY SELECT 'FAILED'::TEXT, 'Source account not found'::TEXT; RETURN;
    END IF;
    IF v_bal < p_amount THEN
        PERFORM wal_write(v_txid,'ABORT'); RETURN QUERY SELECT 'FAILED'::TEXT, ('Insufficient balance. Available: Rs.' || v_bal)::TEXT; RETURN;
    END IF;
    PERFORM 1 FROM accounts WHERE account_id = p_to_account FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM wal_write(v_txid,'ABORT'); RETURN QUERY SELECT 'FAILED'::TEXT, 'Destination account not found'::TEXT; RETURN;
    END IF;
    PERFORM wal_write(v_txid,'UPDATE','accounts',p_from_account, v_bal::TEXT, (v_bal-p_amount)::TEXT);
    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_from_account;
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_to_account;
    INSERT INTO transaction_log(transaction_id,from_account_id,to_account_id,amount,transaction_type,status,description)
    VALUES(v_txid,p_from_account,p_to_account,p_amount,'TRANSFER','SUCCESS','Fund transfer');
    PERFORM wal_write(v_txid,'COMMIT');
    RETURN QUERY SELECT 'SUCCESS'::TEXT, ('Transfer successful! Tx: ' || v_txid)::TEXT;
EXCEPTION WHEN OTHERS THEN
    PERFORM wal_write(v_txid,'ABORT','accounts',p_from_account,NULL,SQLERRM);
    RETURN QUERY SELECT 'FAILED'::TEXT, ('Error: ' || SQLERRM)::TEXT;
END; $$;

-- STEP 4: DEPOSIT FUNCTION
CREATE OR REPLACE FUNCTION deposit_funds(
    p_account_id INTEGER,
    p_amount     NUMERIC
) RETURNS TABLE(status TEXT, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_bal  NUMERIC;
    v_txid VARCHAR(50) := 'DEP_' || to_char(NOW(),'YYYYMMDDHH24MISS') || floor(random()*999)::TEXT;
BEGIN
    PERFORM wal_write(v_txid,'BEGIN');
    IF p_amount <= 0 THEN
        RETURN QUERY SELECT 'FAILED'::TEXT, 'Amount must be greater than zero'::TEXT; RETURN;
    END IF;
    SELECT balance INTO v_bal FROM accounts WHERE account_id = p_account_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM wal_write(v_txid,'ABORT'); RETURN QUERY SELECT 'FAILED'::TEXT, 'Account not found'::TEXT; RETURN;
    END IF;
    PERFORM wal_write(v_txid,'UPDATE','accounts',p_account_id, v_bal::TEXT, (v_bal+p_amount)::TEXT);
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_account_id;
    INSERT INTO transaction_log(transaction_id,from_account_id,to_account_id,amount,transaction_type,status,description)
    VALUES(v_txid,NULL,p_account_id,p_amount,'DEPOSIT','SUCCESS','Cash deposit');
    PERFORM wal_write(v_txid,'COMMIT');
    RETURN QUERY SELECT 'SUCCESS'::TEXT, ('Deposited Rs.' || p_amount || ' successfully! Tx: ' || v_txid)::TEXT;
EXCEPTION WHEN OTHERS THEN
    PERFORM wal_write(v_txid,'ABORT','accounts',p_account_id,NULL,SQLERRM);
    RETURN QUERY SELECT 'FAILED'::TEXT, ('Error: ' || SQLERRM)::TEXT;
END; $$;

-- STEP 5: WITHDRAW FUNCTION
CREATE OR REPLACE FUNCTION withdraw_funds(
    p_account_id INTEGER,
    p_amount     NUMERIC
) RETURNS TABLE(status TEXT, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_bal  NUMERIC;
    v_txid VARCHAR(50) := 'WDR_' || to_char(NOW(),'YYYYMMDDHH24MISS') || floor(random()*999)::TEXT;
BEGIN
    PERFORM wal_write(v_txid,'BEGIN');
    IF p_amount <= 0 THEN
        RETURN QUERY SELECT 'FAILED'::TEXT, 'Amount must be greater than zero'::TEXT; RETURN;
    END IF;
    SELECT balance INTO v_bal FROM accounts WHERE account_id = p_account_id FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM wal_write(v_txid,'ABORT'); RETURN QUERY SELECT 'FAILED'::TEXT, 'Account not found'::TEXT; RETURN;
    END IF;
    IF v_bal < p_amount THEN
        PERFORM wal_write(v_txid,'ABORT'); RETURN QUERY SELECT 'FAILED'::TEXT, ('Insufficient balance. Available: Rs.' || v_bal)::TEXT; RETURN;
    END IF;
    PERFORM wal_write(v_txid,'UPDATE','accounts',p_account_id, v_bal::TEXT, (v_bal-p_amount)::TEXT);
    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_account_id;
    INSERT INTO transaction_log(transaction_id,from_account_id,to_account_id,amount,transaction_type,status,description)
    VALUES(v_txid,p_account_id,NULL,p_amount,'WITHDRAW','SUCCESS','Cash withdrawal');
    PERFORM wal_write(v_txid,'COMMIT');
    RETURN QUERY SELECT 'SUCCESS'::TEXT, ('Withdrawn Rs.' || p_amount || ' successfully! Tx: ' || v_txid)::TEXT;
EXCEPTION WHEN OTHERS THEN
    PERFORM wal_write(v_txid,'ABORT','accounts',p_account_id,NULL,SQLERRM);
    RETURN QUERY SELECT 'FAILED'::TEXT, ('Error: ' || SQLERRM)::TEXT;
END; $$;

-- STEP 6: ARIES RECOVERY FUNCTION
CREATE OR REPLACE FUNCTION aries_recovery()
RETURNS TABLE(report TEXT) LANGUAGE plpgsql AS $$
DECLARE
    r RECORD; v_report TEXT := ''; v_winners TEXT[] := '{}'; v_losers TEXT[] := '{}';
BEGIN
    v_report := '=== ARIES RECOVERY ===' || chr(10) || 'Time: ' || NOW()::TEXT || chr(10) || chr(10);
    v_report := v_report || '-- PHASE 1: ANALYSIS --' || chr(10);
    FOR r IN SELECT DISTINCT transaction_id, bool_or(operation='COMMIT') AS committed
             FROM recovery_log WHERE is_checkpointed = FALSE GROUP BY transaction_id
    LOOP
        IF r.committed THEN
            v_winners := array_append(v_winners, r.transaction_id);
            v_report  := v_report || '  WINNER: ' || r.transaction_id || chr(10);
        ELSE
            v_losers  := array_append(v_losers, r.transaction_id);
            v_report  := v_report || '  LOSER:  ' || r.transaction_id || chr(10);
        END IF;
    END LOOP;
    v_report := v_report || chr(10) || '-- PHASE 2: REDO --' || chr(10);
    FOR r IN SELECT * FROM recovery_log WHERE transaction_id=ANY(v_winners) AND operation='UPDATE' ORDER BY lsn ASC
    LOOP
        v_report := v_report || '  REDO: ' || r.table_name || ' rec=' || r.record_id || ' ' || COALESCE(r.old_value,'?') || '->' || COALESCE(r.new_value,'?') || chr(10);
    END LOOP;
    v_report := v_report || chr(10) || '-- PHASE 3: UNDO --' || chr(10);
    FOR r IN SELECT * FROM recovery_log WHERE transaction_id=ANY(v_losers) AND operation='UPDATE' ORDER BY lsn DESC
    LOOP
        v_report := v_report || '  UNDO: ' || r.table_name || ' rec=' || r.record_id || ' ' || COALESCE(r.new_value,'?') || '->' || COALESCE(r.old_value,'?') || chr(10);
    END LOOP;
    UPDATE recovery_log SET is_checkpointed = TRUE WHERE is_checkpointed = FALSE;
    v_report := v_report || chr(10) || '=== RECOVERY COMPLETE ===';
    RETURN QUERY SELECT v_report;
END; $$;

-- STEP 7: CHECKPOINT FUNCTION
CREATE OR REPLACE FUNCTION create_checkpoint()
RETURNS TABLE(message TEXT) LANGUAGE plpgsql AS $$
DECLARE v_count INTEGER;
BEGIN
    UPDATE recovery_log SET is_checkpointed = TRUE WHERE is_checkpointed = FALSE;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    INSERT INTO recovery_log(transaction_id, operation) VALUES('SYSTEM','CHECKPOINT');
    RETURN QUERY SELECT ('Checkpoint created. ' || v_count || ' entries marked stable.')::TEXT;
END; $$;

-- Verify
SELECT routine_name, routine_type FROM information_schema.routines
WHERE routine_schema = 'public'
ORDER BY routine_name;