from __future__ import annotations

import logging
import os
import time
from pathlib import Path
from typing import Any

from dotenv import find_dotenv, load_dotenv

logger = logging.getLogger(__name__)

try:
    import psycopg  # type: ignore
    from psycopg.rows import dict_row  # type: ignore

    _DB_DRIVER = "psycopg"
except Exception:  # pragma: no cover - fallback path by environment
    psycopg = None  # type: ignore
    dict_row = None  # type: ignore
    try:
        import psycopg2  # type: ignore
        from psycopg2.extras import RealDictCursor  # type: ignore

        _DB_DRIVER = "psycopg2"
    except Exception as exc:  # pragma: no cover
        raise RuntimeError("No supported Postgres driver installed. Install psycopg or psycopg2.") from exc


def _load_env() -> None:
    env_candidates = [
        Path.cwd() / ".env",
        Path.cwd() / ".env.prod.core",
        Path(__file__).resolve().parents[3] / ".env",
        Path(__file__).resolve().parents[3] / ".env.prod.core",
    ]
    for env_file in env_candidates:
        if env_file.exists():
            load_dotenv(env_file, override=False)
            return
    discovered = find_dotenv(usecwd=True)
    if discovered:
        load_dotenv(discovered, override=False)


class SQLClient:
    def __init__(
        self,
        connect_timeout_seconds: int = 10,
        max_retries: int = 3,
        retry_backoff_seconds: float = 1.5,
    ):
        _load_env()
        self.connect_timeout_seconds = connect_timeout_seconds
        self.max_retries = max_retries
        self.retry_backoff_seconds = retry_backoff_seconds
        self._conn: Any | None = None

    def _connect(self) -> Any:
        if self._conn and not self._conn.closed:
            return self._conn
        if _DB_DRIVER == "psycopg":
            self._conn = psycopg.connect(  # type: ignore[attr-defined]
                host=os.getenv("DB_HOST", ""),
                port=int(os.getenv("DB_PORT", "5432")),
                dbname=os.getenv("DB_NAME", ""),
                user=os.getenv("DB_USER", ""),
                password=os.getenv("DB_PASSWORD", ""),
                connect_timeout=self.connect_timeout_seconds,
                sslmode=os.getenv("DB_SSLMODE", "require"),
                row_factory=dict_row,
                autocommit=True,
            )
        else:
            self._conn = psycopg2.connect(  # type: ignore[name-defined]
                host=os.getenv("DB_HOST", ""),
                port=int(os.getenv("DB_PORT", "5432")),
                dbname=os.getenv("DB_NAME", ""),
                user=os.getenv("DB_USER", ""),
                password=os.getenv("DB_PASSWORD", ""),
                connect_timeout=self.connect_timeout_seconds,
                sslmode=os.getenv("DB_SSLMODE", "require"),
                keepalives=1,
                keepalives_idle=30,
                keepalives_interval=10,
                keepalives_count=5,
                cursor_factory=RealDictCursor,  # type: ignore[name-defined]
            )
            self._conn.autocommit = True
        return self._conn

    def reconnect(self) -> Any:
        try:
            if self._conn and not self._conn.closed:
                self._conn.close()
        except Exception:
            pass
        self._conn = None
        return self._connect()

    def check_connection(self) -> bool:
        try:
            conn = self._connect()
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
            return True
        except Exception:
            return False

    def fetch_rows(self, query: str, params: tuple[Any, ...] | None = None) -> list[dict[str, Any]]:
        last_error: Exception | None = None
        for attempt in range(self.max_retries + 1):
            try:
                conn = self._connect()
                with conn.cursor() as cur:
                    cur.execute(query, params or ())
                    rows = cur.fetchall()
                return [dict(row) for row in rows]
            except Exception as exc:
                last_error = exc
                logger.warning("SQL fetch failed attempt %s/%s: %s", attempt + 1, self.max_retries + 1, exc)
                if attempt >= self.max_retries:
                    break
                sleep_seconds = self.retry_backoff_seconds**attempt
                time.sleep(sleep_seconds)
                self.reconnect()
        if last_error:
            raise last_error
        return []
