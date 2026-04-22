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

    Reuses the same env contract as `db-sql/deploy.py`: DB_HOST, DB_PORT,
    DB_NAME, DB_USER, DB_PASSWORD, optional PGSSLMODE (default 'require').
    """
    _load_env()
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
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
