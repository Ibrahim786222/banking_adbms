# Banking ADBMS Mini Project

A PostgreSQL + Flask academic mini-project demonstrating account operations, transaction logging, balance auditing, concurrency, deadlock behavior, and a simplified ARIES-style recovery simulation.

## Stack
- Python 3.10+
- Flask
- PostgreSQL
- psycopg2

## Project structure
```text
banking_adbms/
├── app.py
├── banking_schema.sql
├── sample_data.sql
├── procedures_triggers.sql
├── fix_all.sql
├── requirements.txt
├── .env.example
├── templates/dashboard.html
└── scripts/
    ├── concurrency_test.py
    └── deadlock_demo.py
```

## 1. Create the database
Create a PostgreSQL database named `banking_adbms` in pgAdmin or run `CREATE DATABASE banking_adbms;` from `psql`.

## 2. Initialize the database
Run from this project directory:
```powershell
psql -U postgres -d banking_adbms -f banking_schema.sql
psql -U postgres -d banking_adbms -f sample_data.sql
psql -U postgres -d banking_adbms -f procedures_triggers.sql
psql -U postgres -d banking_adbms -f fix_all.sql
```
`banking_schema.sql` drops and recreates project tables. Do not run it against a database whose data you need to preserve. `fix_all.sql` replaces routines with functions expected by the Flask app. Use only a disposable/local demo database.

## 3. Install dependencies
```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

## 4. Configure PostgreSQL credentials
Set these environment variables in PowerShell; never commit real credentials:
```powershell
$env:DB_NAME = "banking_adbms"
$env:DB_USER = "postgres"
$env:DB_PASSWORD = "your_local_postgres_password"
$env:DB_HOST = "localhost"
$env:DB_PORT = "5432"
$env:FLASK_SECRET_KEY = "replace-with-a-long-random-secret"
```

## 5. Run the application
```powershell
python app.py
```
Open http://127.0.0.1:5000.

## 6. Optional concurrency/deadlock demos
After setting the same DB environment variables, run these only against a local/test database because they execute transactions and may change demo data:
```powershell
python scripts/concurrency_test.py
python scripts/deadlock_demo.py
```

## Concepts demonstrated
- Relational schema, constraints, and indexes
- Stored routines and triggers
- Transaction logging and balance auditing
- Row locks using `SELECT ... FOR UPDATE`
- Concurrent transaction testing and PostgreSQL deadlock detection
- Educational WAL/ARIES-style recovery simulation

> Academic note: `recovery_log` and the recovery routine simulate recovery concepts at the application level. They are not PostgreSQL's internal WAL or a production ARIES implementation.

## Security and limitations
- Educational demo only; not suitable for real banking or production deployment.
- Use fictional data only.
- `.env`, passwords, local databases, and secrets should never be committed.
- Before deployment, add authentication, CSRF protection, stronger validation/error handling, and a production WSGI server.
