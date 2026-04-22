"""Database connection helpers for the hackathon app.

Creds are loaded from `../.env.pfx.core` (the shared pfx core env file).
psycopg3 is used throughout. Keep connections short-lived: every route
opens and closes its own connection.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import psycopg
from dotenv import load_dotenv


APP_DIR = Path(__file__).resolve().parent
ENV_PATH = APP_DIR.parent.parent / ".env.pfx.core"


def _load_env() -> None:
    if ENV_PATH.exists():
        load_dotenv(ENV_PATH, override=False)


def connect() -> psycopg.Connection:
    """Return a new psycopg connection to the ONyc database.

    Resolution order (first match wins):

    1. ``DATABASE_URL`` — Railway / Heroku style (linked Postgres injects this).
    2. ``DB_HOST``, ``DB_PORT``, ``DB_NAME``, ``DB_USER``, ``DB_PASSWORD`` —
       same contract as ``db-sql/deploy.py``.
    3. ``PGHOST``, ``PGPORT``, ``PGDATABASE``, ``PGUSER``, ``PGPASSWORD`` —
       libpq-style names some platforms expose.

    Optional ``PGSSLMODE`` (default ``require``) applies only to the discrete-host
    path; URLs should carry SSL in the connection string.
    """
    _load_env()

    database_url = os.getenv("DATABASE_URL")
    if database_url:
        # SQLAlchemy/Heroku historically used postgres://; psycopg expects postgresql://
        if database_url.startswith("postgres://"):
            database_url = "postgresql://" + database_url[len("postgres://") :]
        return psycopg.connect(database_url, application_name="hackathon-brief")

    host = os.getenv("DB_HOST") or os.getenv("PGHOST")
    port = os.getenv("DB_PORT") or os.getenv("PGPORT") or "5432"
    dbname = os.getenv("DB_NAME") or os.getenv("PGDATABASE")
    user = os.getenv("DB_USER") or os.getenv("PGUSER")
    password = os.getenv("DB_PASSWORD") or os.getenv("PGPASSWORD")

    if not host:
        msg = (
            "Database env missing: set DATABASE_URL, or DB_HOST with DB_NAME/DB_USER/DB_PASSWORD, "
            "or PGHOST with PGDATABASE/PGUSER/PGPASSWORD. See pfx/taq-hackathon/.env.railway."
        )
        raise RuntimeError(msg)
    if not all((dbname, user, password)):
        raise RuntimeError(
            "Database env incomplete: need DB_NAME (or PGDATABASE), DB_USER (or PGUSER), "
            "DB_PASSWORD (or PGPASSWORD) when using host-based connection."
        )

    return psycopg.connect(
        host=host,
        port=port,
        dbname=dbname,
        user=user,
        password=password,
        sslmode=os.getenv("PGSSLMODE", "require"),
        application_name="hackathon-brief",
    )


def fetch_one(sql: str, params: tuple[Any, ...] = ()) -> Any:
    with connect() as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()


def fetch_all(sql: str, params: tuple[Any, ...] = ()) -> list[Any]:
    with connect() as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()
