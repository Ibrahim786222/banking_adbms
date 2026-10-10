-- ============================================================
-- FILE: banking_schema.sql
-- Run this FIRST before any other SQL file
-- ============================================================

DROP TABLE IF EXISTS recovery_log CASCADE;
DROP TABLE IF EXISTS audit_log CASCADE;
DROP TABLE IF EXISTS transaction_log CASCADE;
DROP TABLE IF EXISTS accounts CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

-- ─────────────────────────────────────────
-- TABLE 1: Customers
-- ─────────────────────────────────────────
CREATE TABLE customers (
    customer_id   SERIAL PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    email         VARCHAR(100) UNIQUE,
    phone         VARCHAR(15),
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ─────────────────────────────────────────
-- TABLE 2: Accounts
-- ─────────────────────────────────────────
CREATE TABLE accounts (
    account_id     SERIAL PRIMARY KEY,
    customer_id    INTEGER REFERENCES customers(customer_id) ON DELETE CASCADE,
    account_number VARCHAR(20) UNIQUE NOT NULL,
    account_type   VARCHAR(20) CHECK (account_type IN ('Savings', 'Current')),
    balance        DECIMAL(15,2) DEFAULT 0.00 CHECK (balance >= 0),
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ─────────────────────────────────────────
-- TABLE 3: Transaction Log
-- ─────────────────────────────────────────
CREATE TABLE transaction_log (
    log_id           SERIAL PRIMARY KEY,
    transaction_id   VARCHAR(50) UNIQUE,
    from_account_id  INTEGER REFERENCES accounts(account_id),
    to_account_id    INTEGER REFERENCES accounts(account_id),
    amount           DECIMAL(15,2),
    transaction_type VARCHAR(20),   -- TRANSFER / DEPOSIT / WITHDRAW
    status           VARCHAR(20),   -- SUCCESS / FAILED
    log_timestamp    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description      TEXT
);

-- ─────────────────────────────────────────
-- TABLE 4: Audit Log  (Trigger-based)
-- ─────────────────────────────────────────
CREATE TABLE audit_log (
    audit_id    SERIAL PRIMARY KEY,
    account_id  INTEGER REFERENCES accounts(account_id),
    old_balance DECIMAL(15,2),
    new_balance DECIMAL(15,2),
    changed_by  TEXT DEFAULT current_user,
    change_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ─────────────────────────────────────────
-- TABLE 5: Recovery Log  (ARIES / WAL simulation)
-- ─────────────────────────────────────────
-- LSN  = Log Sequence Number (monotonically increasing)
-- This simulates Write-Ahead Logging used by real DBMS engines
CREATE TABLE recovery_log (
    lsn              SERIAL PRIMARY KEY,           -- Log Sequence Number
    transaction_id   VARCHAR(50),
    operation        VARCHAR(20),                  -- BEGIN / UPDATE / COMMIT / ABORT / CHECKPOINT
    table_name       VARCHAR(50),
    record_id        INTEGER,
    old_value        TEXT,
    new_value        TEXT,
    log_time         TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_checkpointed  BOOLEAN DEFAULT FALSE
);

-- ─────────────────────────────────────────
-- Indexes for Query Optimization
-- ─────────────────────────────────────────
CREATE INDEX idx_accounts_customer   ON accounts(customer_id);
CREATE INDEX idx_accounts_number     ON accounts(account_number);
CREATE INDEX idx_txlog_time          ON transaction_log(log_timestamp DESC);
CREATE INDEX idx_txlog_type          ON transaction_log(transaction_type);
CREATE INDEX idx_audit_account       ON audit_log(account_id);
CREATE INDEX idx_recovery_txid       ON recovery_log(transaction_id);
CREATE INDEX idx_recovery_checkpoint ON recovery_log(is_checkpointed);
