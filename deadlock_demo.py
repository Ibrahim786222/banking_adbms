"""
FILE: scripts/deadlock_demo.py
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PURPOSE : Deliberately creates a DEADLOCK between two
          transactions to demonstrate PostgreSQL's built-in
          deadlock detection and how the system resolves it.

SCENARIO:
    Transaction A: locks ACC1 → tries to lock ACC2
    Transaction B: locks ACC2 → tries to lock ACC1
    → Classic circular wait → PostgreSQL detects & kills one

HOW TO RUN:
    python scripts/deadlock_demo.py

Observe which transaction is aborted (the "victim")
and which one succeeds.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"""


import os
import psycopg2
import threading
import time

DB_CONFIG = {
    'dbname': os.environ.get('DB_NAME', 'banking_adbms'),
    'user': os.environ.get('DB_USER', 'postgres'),
    'password': os.environ.get('DB_PASSWORD', ''),
    'host': os.environ.get('DB_HOST', 'localhost'),
    'port': int(os.environ.get('DB_PORT', '5432')),
}

barrier = threading.Barrier(2)   # synchronize both threads
log = []
log_lock = threading.Lock()

def txn_a():
    """
    Transaction A:
      Step 1: Lock account 1
      Step 2: Wait for Txn B to lock account 2
      Step 3: Try to lock account 2 → DEADLOCK
    """
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = False
    cur = conn.cursor()
    try:
        with log_lock: log.append("TXN-A: BEGIN")

        # Step 1: Lock account 1
        cur.execute("SELECT balance FROM accounts WHERE account_id = 1 FOR UPDATE")
        with log_lock: log.append("TXN-A: Locked account 1 ✅")

        # Wait for Txn B to also lock account 2
        barrier.wait()
        time.sleep(0.2)

        # Step 2: Try to lock account 2 (Txn B already holds it → deadlock)
        with log_lock: log.append("TXN-A: Trying to lock account 2…")
        cur.execute("SELECT balance FROM accounts WHERE account_id = 2 FOR UPDATE")
        with log_lock: log.append("TXN-A: Locked account 2 ✅ — doing transfer…")

        cur.execute("UPDATE accounts SET balance = balance - 1000 WHERE account_id = 1")
        cur.execute("UPDATE accounts SET balance = balance + 1000 WHERE account_id = 2")
        conn.commit()
        with log_lock: log.append("TXN-A: COMMITTED ✅")

    except psycopg2.errors.DeadlockDetected:
        conn.rollback()
        with log_lock: log.append("TXN-A: ❌ DEADLOCK DETECTED — rolled back (victim)")
    except Exception as e:
        conn.rollback()
        with log_lock: log.append(f"TXN-A: ❌ ERROR: {e}")
    finally:
        conn.close()


def txn_b():
    """
    Transaction B:
      Step 1: Lock account 2
      Step 2: Wait for Txn A to lock account 1
      Step 3: Try to lock account 1 → DEADLOCK
    """
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = False
    cur = conn.cursor()
    try:
        with log_lock: log.append("TXN-B: BEGIN")

        # Step 1: Lock account 2
        cur.execute("SELECT balance FROM accounts WHERE account_id = 2 FOR UPDATE")
        with log_lock: log.append("TXN-B: Locked account 2 ✅")

        # Wait for Txn A to also lock account 1
        barrier.wait()
        time.sleep(0.2)

        # Step 2: Try to lock account 1 (Txn A already holds it → deadlock)
        with log_lock: log.append("TXN-B: Trying to lock account 1…")
        cur.execute("SELECT balance FROM accounts WHERE account_id = 1 FOR UPDATE")
        with log_lock: log.append("TXN-B: Locked account 1 ✅ — doing transfer…")

        cur.execute("UPDATE accounts SET balance = balance - 2000 WHERE account_id = 2")
        cur.execute("UPDATE accounts SET balance = balance + 2000 WHERE account_id = 1")
        conn.commit()
        with log_lock: log.append("TXN-B: COMMITTED ✅")

    except psycopg2.errors.DeadlockDetected:
        conn.rollback()
        with log_lock: log.append("TXN-B: ❌ DEADLOCK DETECTED — rolled back (victim)")
    except Exception as e:
        conn.rollback()
        with log_lock: log.append(f"TXN-B: ❌ ERROR: {e}")
    finally:
        conn.close()


if __name__ == '__main__':
    print("=" * 55)
    print("  DEADLOCK DEMONSTRATION")
    print("  TXN-A: ACC1 → ACC2  |  TXN-B: ACC2 → ACC1")
    print("  Expected: One commits, one is rolled back")
    print("=" * 55 + "\n")

    t1 = threading.Thread(target=txn_a)
    t2 = threading.Thread(target=txn_b)

    t1.start()
    t2.start()
    t1.join()
    t2.join()

    print("Timeline:")
    for entry in log:
        print(f"  {entry}")

    print("\n" + "─" * 55)
    print("  KEY POINT: PostgreSQL's deadlock detector woke up,")
    print("  chose one transaction as the VICTIM and aborted it.")
    print("  The other transaction completed successfully.")
    print("  This is automatic — no manual intervention needed.")
    print("─" * 55)
    print()
    print("  PREVENTION STRATEGY: Always lock accounts in the")
    print("  same ORDER (lower ID first) to avoid circular waits.")
    print("  See: transfer_funds() — locks MIN(id) before MAX(id)")
    print("=" * 55)
