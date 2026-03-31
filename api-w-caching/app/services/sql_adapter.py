import os
import threading
import time
import logging
import hashlib
import re
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
        self._local = threading.local()
        self._telemetry_enabled = os.getenv("API_TELEMETRY_ENABLED", "0") == "1"
        self._telemetry_lock = threading.Lock()
        self._telemetry: dict[str, Any] = {
            "pool_checkout_count": 0,
            "pool_checkout_wait_total_ms": 0.0,
            "pool_checkout_wait_max_ms": 0.0,
            "pool_in_use_last": 0,
            "pool_idle_last": 0,
            "pool_in_use_max": 0,
            "pool_wait_over_25ms": 0,
            "query_count": 0,
            "query_error_count": 0,
            "query_duration_total_ms": 0.0,
            "query_duration_max_ms": 0.0,
            "last_query_row_count": 0,
            "query_fingerprint_stats": {},
        }

    def _dsn(self) -> str:
        if hasattr(self, "_fixed_dsn"):
            return self._fixed_dsn
        sslmode = os.getenv("DB_SSLMODE") or os.getenv("PGSSLMODE") or "require"
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
    def from_credentials(cls, creds: dict[str, str]) -> "SqlAdapter":
        """Create an adapter with a fixed DSN from an explicit credentials dict,
        immune to pipeline-switcher changes in os.environ.

        Expected keys: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD.
        Optional: DB_SSLMODE (defaults to 'require').
        """
        inst = cls.__new__(cls)
        inst._pool = None
        inst._pool_lock = threading.Lock()
        inst._local = threading.local()
        inst._telemetry_enabled = os.getenv("API_TELEMETRY_ENABLED", "0") == "1"
        inst._telemetry_lock = threading.Lock()
        inst._telemetry = {
            "pool_checkout_count": 0,
            "pool_checkout_wait_total_ms": 0.0,
            "pool_checkout_wait_max_ms": 0.0,
            "pool_in_use_last": 0,
            "pool_idle_last": 0,
            "pool_in_use_max": 0,
            "pool_wait_over_25ms": 0,
            "query_count": 0,
            "query_error_count": 0,
            "query_duration_total_ms": 0.0,
            "query_duration_max_ms": 0.0,
            "last_query_row_count": 0,
            "query_fingerprint_stats": {},
        }
        sslmode = creds.get("DB_SSLMODE") or creds.get("PGSSLMODE") or "require"
        allowed = {"disable", "allow", "prefer", "require", "verify-ca", "verify-full"}
        if sslmode not in allowed:
            sslmode = "require"
        ct = int(os.getenv("DB_CONNECT_TIMEOUT_SECONDS", "5"))
        st = int(os.getenv("DB_STATEMENT_TIMEOUT_MS", "15000"))
        inst._fixed_dsn = (
            f"host={creds['DB_HOST']} "
            f"port={creds['DB_PORT']} "
            f"dbname={creds['DB_NAME']} "
            f"user={creds['DB_USER']} "
            f"password={creds['DB_PASSWORD']} "
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

    def set_request_context(
        self,
        *,
        page: str = "",
        widget: str = "",
        nav_trace_id: str = "",
        request_id: str = "",
    ) -> None:
        self._local.request_context = {
            "page": page,
            "widget": widget,
            "nav_trace_id": nav_trace_id,
            "request_id": request_id,
        }

    def clear_request_context(self) -> None:
        self._local.request_context = {}

    def _current_request_context(self) -> dict[str, str]:
        context = getattr(self._local, "request_context", {})
        if isinstance(context, dict):
            return {
                "page": str(context.get("page", "")),
                "widget": str(context.get("widget", "")),
                "nav_trace_id": str(context.get("nav_trace_id", "")),
                "request_id": str(context.get("request_id", "")),
            }
        return {"page": "", "widget": "", "nav_trace_id": "", "request_id": ""}

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
        checkout_started = time.perf_counter()
        conn = pool.getconn()
        checkout_wait_ms = (time.perf_counter() - checkout_started) * 1000.0
        self._record_pool_checkout(pool, checkout_wait_ms)
        try:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                if statement_timeout_ms is not None:
                    cur.execute(f"SET LOCAL statement_timeout = {int(statement_timeout_ms)}")
                cur.execute(query, params)
                rows = [self._normalize_row(row) for row in cur.fetchall()]
                self._log_slow_query(started, query, len(rows), statement_timeout_ms)
                self._record_query_result(
                    time.perf_counter() - started,
                    len(rows),
                    error=False,
                    query=query,
                )
                return rows
        except Exception:
            self._record_query_result(
                time.perf_counter() - started,
                0,
                error=True,
                query=query,
            )
            raise
        finally:
            if not conn.closed:
                conn.rollback()
                pool.putconn(conn)
            else:
                pool.putconn(conn, close=True)
            self._record_pool_snapshot(pool)

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

    def get_telemetry_snapshot(self) -> dict[str, Any]:
        with self._telemetry_lock:
            snapshot = dict(self._telemetry)
            fingerprint_stats = dict(self._telemetry.get("query_fingerprint_stats", {}))
        checkout_count = int(snapshot.get("pool_checkout_count", 0) or 0)
        query_count = int(snapshot.get("query_count", 0) or 0)
        snapshot["pool_checkout_wait_avg_ms"] = round(
            float(snapshot.get("pool_checkout_wait_total_ms", 0.0) or 0.0) / checkout_count,
            3,
        ) if checkout_count > 0 else 0.0
        snapshot["query_duration_avg_ms"] = round(
            float(snapshot.get("query_duration_total_ms", 0.0) or 0.0) / query_count,
            3,
        ) if query_count > 0 else 0.0
        fingerprint_rollup: dict[str, Any] = {}
        for fp_key, entry in fingerprint_stats.items():
            count = int(entry.get("count", 0) or 0)
            total_ms = float(entry.get("total_ms", 0.0) or 0.0)
            p95 = self._percentile(entry.get("samples", []), 95)
            p99 = self._percentile(entry.get("samples", []), 99)
            fingerprint_rollup[fp_key] = {
                "count": count,
                "error_count": int(entry.get("error_count", 0) or 0),
                "avg_ms": round(total_ms / count, 3) if count > 0 else 0.0,
                "max_ms": round(float(entry.get("max_ms", 0.0) or 0.0), 3),
                "p95_ms": p95,
                "p99_ms": p99,
                "page": str(entry.get("page", "")),
                "widget": str(entry.get("widget", "")),
                "query_preview": str(entry.get("query_preview", "")),
                "slow_samples_ms": list(entry.get("slow_samples_ms", [])),
            }
        snapshot["query_fingerprint_stats"] = fingerprint_rollup
        return snapshot

    def reset_telemetry(self) -> None:
        with self._telemetry_lock:
            self._telemetry.update({
                "pool_checkout_count": 0,
                "pool_checkout_wait_total_ms": 0.0,
                "pool_checkout_wait_max_ms": 0.0,
                "pool_in_use_last": 0,
                "pool_idle_last": 0,
                "pool_in_use_max": 0,
                "pool_wait_over_25ms": 0,
                "query_count": 0,
                "query_error_count": 0,
                "query_duration_total_ms": 0.0,
                "query_duration_max_ms": 0.0,
                "last_query_row_count": 0,
                "query_fingerprint_stats": {},
            })

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

    def _record_pool_checkout(self, pool: ThreadedConnectionPool, checkout_wait_ms: float) -> None:
        if not self._telemetry_enabled:
            return
        with self._telemetry_lock:
            self._telemetry["pool_checkout_count"] = int(self._telemetry["pool_checkout_count"]) + 1
            self._telemetry["pool_checkout_wait_total_ms"] = float(self._telemetry["pool_checkout_wait_total_ms"]) + checkout_wait_ms
            self._telemetry["pool_checkout_wait_max_ms"] = max(float(self._telemetry["pool_checkout_wait_max_ms"]), checkout_wait_ms)
            if checkout_wait_ms >= 25.0:
                self._telemetry["pool_wait_over_25ms"] = int(self._telemetry["pool_wait_over_25ms"]) + 1
        self._record_pool_snapshot(pool)

    def _record_pool_snapshot(self, pool: ThreadedConnectionPool) -> None:
        if not self._telemetry_enabled:
            return
        try:
            in_use = len(getattr(pool, "_used", {}) or {})
            idle = len(getattr(pool, "_pool", []) or [])
        except Exception:
            return
        with self._telemetry_lock:
            self._telemetry["pool_in_use_last"] = in_use
            self._telemetry["pool_idle_last"] = idle
            self._telemetry["pool_in_use_max"] = max(int(self._telemetry["pool_in_use_max"]), in_use)

    def _record_query_result(self, elapsed_s: float, row_count: int, *, error: bool, query: str) -> None:
        if not self._telemetry_enabled:
            return
        elapsed_ms = max(0.0, elapsed_s * 1000.0)
        context = self._current_request_context()
        fingerprint = self._query_fingerprint(query)
        fp_key = f"{context.get('page', '')}/{context.get('widget', '')}/{fingerprint}"
        with self._telemetry_lock:
            self._telemetry["query_count"] = int(self._telemetry["query_count"]) + 1
            if error:
                self._telemetry["query_error_count"] = int(self._telemetry["query_error_count"]) + 1
            self._telemetry["query_duration_total_ms"] = float(self._telemetry["query_duration_total_ms"]) + elapsed_ms
            self._telemetry["query_duration_max_ms"] = max(float(self._telemetry["query_duration_max_ms"]), elapsed_ms)
            self._telemetry["last_query_row_count"] = max(0, int(row_count))
            fp_stats = self._telemetry.setdefault("query_fingerprint_stats", {})
            entry = fp_stats.get(fp_key)
            if not isinstance(entry, dict):
                entry = {
                    "count": 0,
                    "error_count": 0,
                    "total_ms": 0.0,
                    "max_ms": 0.0,
                    "samples": [],
                    "slow_samples_ms": [],
                    "page": context.get("page", ""),
                    "widget": context.get("widget", ""),
                    "query_preview": " ".join(query.split())[:220],
                }
            entry["count"] = int(entry.get("count", 0)) + 1
            if error:
                entry["error_count"] = int(entry.get("error_count", 0)) + 1
            entry["total_ms"] = float(entry.get("total_ms", 0.0)) + elapsed_ms
            entry["max_ms"] = max(float(entry.get("max_ms", 0.0)), elapsed_ms)
            samples = list(entry.get("samples", []))
            samples.append(elapsed_ms)
            if len(samples) > 300:
                samples = samples[-300:]
            entry["samples"] = samples
            slow_samples = sorted([float(v) for v in entry.get("slow_samples_ms", [])] + [elapsed_ms], reverse=True)
            entry["slow_samples_ms"] = [round(v, 3) for v in slow_samples[:5]]
            fp_stats[fp_key] = entry

    @staticmethod
    def _query_fingerprint(query: str) -> str:
        compact = " ".join(query.split())
        compact = re.sub(r"\b\d+(\.\d+)?\b", "?", compact)
        compact = re.sub(r"'[^']*'", "'?'", compact)
        compact = re.sub(r'"[^"]*"', '"?"', compact)
        digest = hashlib.md5(compact.encode("utf-8")).hexdigest()
        return digest[:16]

    @staticmethod
    def _percentile(values: list[float], pct: float) -> float:
        if not values:
            return 0.0
        if len(values) == 1:
            return round(float(values[0]), 3)
        ordered = sorted(float(v) for v in values)
        rank = (len(ordered) - 1) * max(0.0, min(100.0, float(pct))) / 100.0
        lo = int(rank)
        hi = min(lo + 1, len(ordered) - 1)
        frac = rank - lo
        value = ordered[lo] * (1.0 - frac) + ordered[hi] * frac
        return round(value, 3)
