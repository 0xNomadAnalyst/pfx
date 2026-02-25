import os
from decimal import Decimal
from typing import Any

import psycopg2
import psycopg2.extras
from psycopg2.pool import ThreadedConnectionPool


class SqlAdapter:
    """Small SQL execution adapter independent from FastAPI."""

    def __init__(self) -> None:
        self._pool: ThreadedConnectionPool | None = None

    def _dsn(self) -> str:
        sslmode = os.getenv("DB_SSLMODE", "require")
        allowed_sslmodes = {"disable", "allow", "prefer", "require", "verify-ca", "verify-full"}
        if sslmode not in allowed_sslmodes:
            sslmode = "require"
        connect_timeout = int(os.getenv("DB_CONNECT_TIMEOUT_SECONDS", "5"))
        statement_timeout_ms = int(os.getenv("DB_STATEMENT_TIMEOUT_MS", "15000"))
        return (
            f"host={os.environ['DB_HOST']} "
            f"port={os.environ['DB_PORT']} "
            f"dbname={os.environ['DB_NAME']} "
            f"user={os.environ['DB_USER']} "
            f"password={os.environ['DB_PASSWORD']} "
            f"sslmode={sslmode} "
            f"connect_timeout={connect_timeout} "
            f"options='-c statement_timeout={statement_timeout_ms}'"
        )

    def _get_pool(self) -> ThreadedConnectionPool:
        if self._pool is None:
            minconn = int(os.getenv("DB_POOL_MIN", "1"))
            maxconn = int(os.getenv("DB_POOL_MAX", "8"))
            self._pool = ThreadedConnectionPool(minconn=minconn, maxconn=maxconn, dsn=self._dsn())
        return self._pool

    def fetch_rows(self, query: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        pool = self._get_pool()
        conn = pool.getconn()
        try:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute(query, params)
                return [self._normalize_row(row) for row in cur.fetchall()]
        finally:
            if not conn.closed:
                conn.rollback()
                pool.putconn(conn)
            else:
                pool.putconn(conn, close=True)

    def close(self) -> None:
        if self._pool is not None:
            self._pool.closeall()
            self._pool = None

    @staticmethod
    def _normalize_row(row: dict[str, Any]) -> dict[str, Any]:
        normalized: dict[str, Any] = {}
        for key, value in row.items():
            if isinstance(value, Decimal):
                normalized[key] = float(value)
            elif isinstance(value, list):
                normalized[key] = [float(item) if isinstance(item, Decimal) else item for item in value]
            else:
                normalized[key] = value
        return normalized
