import os
import threading
import time
import logging
from decimal import Decimal
from typing import Any

import psycopg2
import psycopg2.extras
from psycopg2.pool import ThreadedConnectionPool

logger = logging.getLogger(__name__)


class SqlAdapter:
    """Small SQL execution adapter independent from FastAPI."""

    def __init__(self) -> None:
        self._pool: ThreadedConnectionPool | None = None
        self._pool_lock = threading.Lock()

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
            with self._pool_lock:
                if self._pool is None:
                    minconn = int(os.getenv("DB_POOL_MIN", "1"))
                    maxconn = int(os.getenv("DB_POOL_MAX", "8"))
                    if maxconn < minconn:
                        maxconn = minconn
                    self._pool = ThreadedConnectionPool(minconn=minconn, maxconn=maxconn, dsn=self._dsn())
                    if os.getenv("DB_POOL_PREWARM", "1") == "1":
                        self._prewarm_pool(self._pool)
        return self._pool

    @staticmethod
    def _prewarm_pool(pool: ThreadedConnectionPool) -> None:
        conn = pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        finally:
            if not conn.closed:
                conn.rollback()
                pool.putconn(conn)
            else:
                pool.putconn(conn, close=True)

    def fetch_rows(
        self,
        query: str,
        params: tuple[Any, ...] = (),
        statement_timeout_ms: int | None = None,
    ) -> list[dict[str, Any]]:
        started = time.perf_counter()
        pool = self._get_pool()
        conn = pool.getconn()
        try:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                if statement_timeout_ms is not None:
                    cur.execute(f"SET LOCAL statement_timeout = {int(statement_timeout_ms)}")
                cur.execute(query, params)
                rows = [self._normalize_row(row) for row in cur.fetchall()]
                self._log_slow_query(started, query, len(rows), statement_timeout_ms)
                return rows
        finally:
            if not conn.closed:
                conn.rollback()
                pool.putconn(conn)
            else:
                pool.putconn(conn, close=True)

    def _log_slow_query(
        self,
        started: float,
        query: str,
        row_count: int,
        statement_timeout_ms: int | None,
    ) -> None:
        if os.getenv("DB_LOG_SLOW_QUERIES", "0") != "1":
            return
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        threshold_ms = float(os.getenv("DB_SLOW_QUERY_THRESHOLD_MS", "200"))
        if elapsed_ms < threshold_ms:
            return
        compact_query = " ".join(query.split())
        query_preview = compact_query[:180]
        logger.warning(
            "Slow SQL query %.2fms rows=%s timeout_ms=%s sql=%s",
            elapsed_ms,
            row_count,
            statement_timeout_ms,
            query_preview,
        )

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
