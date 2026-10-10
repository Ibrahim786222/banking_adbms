"""
FILE: app.py
Flask web application for Banking ADBMS Mini Project

ROOT CAUSE FIX:
  psycopg2 CALL with OUT params is unreliable in PostgreSQL 18.
  Solution: converted all procedures to FUNCTIONS with RETURNS TABLE.
  Now called via:  SELECT * FROM function_name(args)
  This is 100% reliable across all psycopg2 + PostgreSQL versions.
"""

from flask import Flask, render_template, request, redirect, url_for, flash
import os
import psycopg2

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", "dev-only-change-me")

# ══════════════════════════════════════════════
#  UPDATE PASSWORD IF DIFFERENT
# ══════════════════════════════════════════════
DB_CONFIG = {
    'dbname': os.environ.get('DB_NAME', 'banking_adbms'),
    'user': os.environ.get('DB_USER', 'postgres'),
    'password': os.environ.get('DB_PASSWORD', ''),
    'host': os.environ.get('DB_HOST', 'localhost'),
    'port': int(os.environ.get('DB_PORT', '5432')),
}

def get_db_connection():
    return psycopg2.connect(**DB_CONFIG)


# ─────────────────────────────────────────────
# DASHBOARD
# ─────────────────────────────────────────────
@app.route('/')
def dashboard():
    conn = get_db_connection()
    cur  = conn.cursor()

    cur.execute("""
        SELECT a.account_id, a.account_number, c.name, a.account_type, a.balance
        FROM accounts a
        JOIN customers c ON a.customer_id = c.customer_id
        ORDER BY a.account_id
    """)
    accounts = cur.fetchall()

    cur.execute("""
        SELECT transaction_id,
               COALESCE(from_account_id::TEXT, '-'),
               COALESCE(to_account_id::TEXT,   '-'),
               amount, transaction_type, status, log_timestamp
        FROM transaction_log
        ORDER BY log_timestamp DESC LIMIT 10
    """)
    transactions = cur.fetchall()

    cur.execute("""
        SELECT al.audit_id, al.account_id, a.account_number,
               al.old_balance, al.new_balance, al.changed_by, al.change_time
        FROM audit_log al
        JOIN accounts a ON al.account_id = a.account_id
        ORDER BY al.change_time DESC LIMIT 10
    """)
    audit_entries = cur.fetchall()

    cur.execute("""
        SELECT lsn, transaction_id, operation, table_name,
               record_id, old_value, new_value, log_time, is_checkpointed
        FROM recovery_log
        ORDER BY lsn DESC LIMIT 10
    """)
    wal_entries = cur.fetchall()

    cur.close()
    conn.close()

    return render_template('dashboard.html',
                           accounts=accounts,
                           transactions=transactions,
                           audit_entries=audit_entries,
                           wal_entries=wal_entries)


# ─────────────────────────────────────────────
# FUND TRANSFER
# ─────────────────────────────────────────────
@app.route('/transfer', methods=['POST'])
def transfer():
    conn = None
    try:
        from_acc = int(request.form['from_account'])
        to_acc   = int(request.form['to_account'])
        amount   = float(request.form['amount'])

        conn = get_db_connection()
        cur  = conn.cursor()

        # ✅ SELECT * FROM function() — works perfectly with psycopg2
        cur.execute("SELECT * FROM transfer_funds(%s, %s, %s)",
                    (from_acc, to_acc, amount))
        result = cur.fetchone()   # (status, message)
        conn.commit()

        if result and result[0] == 'SUCCESS':
            flash(f"✅ {result[1]}", "success")
        else:
            flash(f"❌ {result[1] if result else 'Unknown error'}", "danger")

    except Exception as e:
        if conn: conn.rollback()
        flash(f"❌ Error: {str(e)}", "danger")
    finally:
        if conn: conn.close()

    return redirect(url_for('dashboard'))


# ─────────────────────────────────────────────
# DEPOSIT
# ─────────────────────────────────────────────
@app.route('/deposit', methods=['POST'])
def deposit():
    conn = None
    try:
        account_id = int(request.form['account_id'])
        amount     = float(request.form['amount'])

        conn = get_db_connection()
        cur  = conn.cursor()

        cur.execute("SELECT * FROM deposit_funds(%s, %s)", (account_id, amount))
        result = cur.fetchone()
        conn.commit()

        if result and result[0] == 'SUCCESS':
            flash(f"✅ {result[1]}", "success")
        else:
            flash(f"❌ {result[1] if result else 'Unknown error'}", "danger")

    except Exception as e:
        if conn: conn.rollback()
        flash(f"❌ Error: {str(e)}", "danger")
    finally:
        if conn: conn.close()

    return redirect(url_for('dashboard'))


# ─────────────────────────────────────────────
# WITHDRAW
# ─────────────────────────────────────────────
@app.route('/withdraw', methods=['POST'])
def withdraw():
    conn = None
    try:
        account_id = int(request.form['account_id'])
        amount     = float(request.form['amount'])

        conn = get_db_connection()
        cur  = conn.cursor()

        cur.execute("SELECT * FROM withdraw_funds(%s, %s)", (account_id, amount))
        result = cur.fetchone()
        conn.commit()

        if result and result[0] == 'SUCCESS':
            flash(f"✅ {result[1]}", "success")
        else:
            flash(f"❌ {result[1] if result else 'Unknown error'}", "danger")

    except Exception as e:
        if conn: conn.rollback()
        flash(f"❌ Error: {str(e)}", "danger")
    finally:
        if conn: conn.close()

    return redirect(url_for('dashboard'))


# ─────────────────────────────────────────────
# ARIES RECOVERY
# ─────────────────────────────────────────────
@app.route('/recovery', methods=['POST'])
def recovery():
    conn = None
    try:
        conn = get_db_connection()
        cur  = conn.cursor()

        cur.execute("SELECT * FROM aries_recovery()")
        result = cur.fetchone()
        conn.commit()

        flash(f"🔄 ARIES Recovery Report:\n{result[0]}", "info")

    except Exception as e:
        if conn: conn.rollback()
        flash(f"❌ Recovery Error: {str(e)}", "danger")
    finally:
        if conn: conn.close()

    return redirect(url_for('dashboard'))


# ─────────────────────────────────────────────
# CHECKPOINT
# ─────────────────────────────────────────────
@app.route('/checkpoint', methods=['POST'])
def checkpoint():
    conn = None
    try:
        conn = get_db_connection()
        cur  = conn.cursor()

        cur.execute("SELECT * FROM create_checkpoint()")
        result = cur.fetchone()
        conn.commit()

        flash(f"✅ {result[0]}", "success")

    except Exception as e:
        if conn: conn.rollback()
        flash(f"❌ Checkpoint Error: {str(e)}", "danger")
    finally:
        if conn: conn.close()

    return redirect(url_for('dashboard'))


if __name__ == '__main__':
    app.run(debug=os.environ.get('FLASK_DEBUG', 'false').lower() == 'true')
