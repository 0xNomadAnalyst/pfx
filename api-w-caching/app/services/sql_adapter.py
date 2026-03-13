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
        if hasattr(self, "_fixed_dsn"):
            return self._fixed_dsn
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

    @classmethod
    def from_env_file(cls, env_path: str) -> "SqlAdapter":
        """Create an adapter with a fixed DSN derived from an env file,
        immune to pipeline-switcher changes in os.environ."""
        from pathlib import Path
        inst = cls.__new__(cls)
        inst._pool = None
        inst._pool_lock = threading.Lock()
        env = {}
        p = Path(env_path)
        if p.exists():
            for line in p.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip()
        sslmode = env.get("PGSSLMODE", env.get("DB_SSLMODE", "require"))
        allowed = {"disable", "allow", "prefer", "require", "verify-ca", "verify-full"}
        if sslmode not in allowed:
            sslmode = "require"
        ct = int(os.getenv("DB_CONNECT_TIMEOUT_SECONDS", "5"))
        st = int(os.getenv("DB_STATEMENT_TIMEOUT_MS", "15000"))
        inst._fixed_dsn = (
            f"host={env['DB_HOST']} "
            f"port={env['DB_PORT']} "
            f"dbname={env['DB_NAME']} "
            f"user={env['DB_USER']} "
            f"password={env['DB_PASSWORD']} "
            f"sslmode={sslmode} "
            f"connect_timeout={ct} "
            f"options='-c statement_timeout={st}'"
        )
        return inst

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

    def reset_pool(self) -> None:
        """Close the current pool so the next query reconnects with fresh env vars."""
        with self._pool_lock:
            if self._pool is not None:
                try:
                    self._pool.closeall()
                except Exception:
                    pass
                self._pool = None

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
