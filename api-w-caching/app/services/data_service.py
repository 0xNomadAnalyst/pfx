from __future__ import annotations

import json
import logging
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import UTC, datetime
from typing import Any

from app.services.cache_config import API_CACHE_CONFIG
from app.services.pages.dex_liquidity import DexLiquidityPageService
from app.services.pages.dex_swaps import DexSwapsPageService
from app.services.pages.exponent import ExponentPageService
from app.services.pages.global_ecosystem import GlobalEcosystemPageService
from app.services.pages.health import HealthPageService
from app.services.pages.kamino import KaminoPageService
from app.services.pages.risk_analysis import RiskAnalysisPageService
from app.services.shared.cache_store import QueryCache
from app.services.sql_adapter import SqlAdapter

logger = logging.getLogger(__name__)
_HOTSPOT_WIDGET_KEYS = {
    "global-ecosystem/ge-activity-vol-usx",
    "global-ecosystem/ge-tvl-share-usx",
}


class _DexesCompositeService:
    """Routes widget requests to liquidity or swaps sub-service."""

    def __init__(self, liquidity, swaps):
        self._liquidity = liquidity
        self._swaps = swaps
        self.default_protocol = liquidity.default_protocol
        self.default_pair = liquidity.default_pair

    def get_widget_payload(self, widget_id: str, params: dict[str, Any]) -> dict[str, Any]:
        if hasattr(self._swaps, "_handlers") and widget_id in self._swaps._handlers:
            return self._swaps.get_widget_payload(widget_id, params)
        return self._liquidity.get_widget_payload(widget_id, params)

    def list_widgets(self) -> list[str]:
        return self._liquidity.list_widgets() + self._swaps.list_widgets()


class DataService:
    """Coordinator for page-specific data services."""

    def __init__(self, sql_adapter: SqlAdapter):
        self.sql = sql_adapter
        cache = QueryCache(
            ttl_seconds=float(API_CACHE_CONFIG.get("API_CACHE_TTL_SECONDS", 30)),
            max_entries=int(API_CACHE_CONFIG.get("API_CACHE_MAX_ENTRIES", 256)),
            swr_workers=int(API_CACHE_CONFIG.get("API_CACHE_SWR_WORKERS", 4)),
            jitter_pct=float(API_CACHE_CONFIG.get("API_CACHE_TTL_JITTER_PCT", 10)),
        )
        self._query_cache = cache
        liquidity = DexLiquidityPageService(sql_adapter, cache)
        swaps = DexSwapsPageService(sql_adapter, cache)
        kamino = KaminoPageService(sql_adapter, cache)
        exponent = ExponentPageService(sql_adapter, cache)
        health = HealthPageService(sql_adapter, cache)
        global_eco = GlobalEcosystemPageService(sql_adapter, cache)

        from app.services import pipeline_config
        onyc_creds = pipeline_config.PIPELINES.get("onyc")
        if onyc_creds:
            onyc_sql = SqlAdapter.from_credentials(onyc_creds)
        else:
            logger.warning("ONyc pipeline credentials not found; risk page will use default adapter")
            onyc_sql = sql_adapter
        risk = RiskAnalysisPageService(onyc_sql, cache)
        self._pages = {
            "playbook-liquidity": liquidity,
            "dex-liquidity": liquidity,
            "dex-swaps": swaps,
            "dexes": _DexesCompositeService(liquidity, swaps),
            "kamino": kamino,
            "exponent": exponent,
            "health": health,
            "global-ecosystem": global_eco,
            "risk-analysis": risk,
        }
        self._default_page = "playbook-liquidity"
        self._log_slow_widgets = os.getenv("API_LOG_SLOW_WIDGETS", "0") == "1"
        self._slow_widget_threshold_ms = float(os.getenv("API_SLOW_WIDGET_THRESHOLD_MS", "150"))
        self._health_status_cache_ttl_seconds = float(os.getenv("HEALTH_STATUS_TTL_SECONDS", "15"))
        self._health_status_cache_ttl_green_seconds = float(
            os.getenv("HEALTH_STATUS_TTL_GREEN_SECONDS", str(self._health_status_cache_ttl_seconds))
        )
        self._health_status_cache_ttl_red_seconds = float(
            os.getenv("HEALTH_STATUS_TTL_RED_SECONDS", "4")
        )
        self._health_status_lock = threading.Lock()
        self._health_status_cached: bool | None = None
        self._health_status_expires_at = 0.0
        self._telemetry_enabled = os.getenv("API_TELEMETRY_ENABLED", "0") == "1"
        self._telemetry_lock = threading.Lock()
        self._telemetry: dict[str, Any] = {
            "requests_total": 0,
            "requests_success": 0,
            "requests_error": 0,
            "requests_by_page": {},
            "errors_by_page": {},
            "requests_by_widget": {},
            "status_family_counts": {},
            "latency_by_page": {},
            "latency_by_widget": {},
            "nav_trace_counts": {},
            "status_family_by_widget": {},
        }
        self._validate_dbsql_contract()

    def _validate_dbsql_contract(self) -> None:
        """Best-effort startup check for required DBSQL compatibility surfaces."""
        enabled = os.getenv("DBSQL_CONTRACT_CHECK_ENABLED", "1") == "1"
        if not enabled:
            return
        strict = os.getenv("DBSQL_CONTRACT_CHECK_STRICT", "0") == "1"
        required = [
            "dexes.get_view_dex_last(text,text,interval,boolean)",
            "dexes.get_view_dex_timeseries(text,text,text,integer,boolean)",
            "dexes.get_view_tick_dist_simple(text,text,interval,boolean)",
            "dexes.get_view_dex_ohlcv(text,text,text,integer,boolean)",
            "dexes.get_view_liquidity_depth_table(text,text,boolean)",
            "dexes.get_view_dex_table_ranked_events(text,text,text,text,text,integer,text,boolean)",
            "dexes.get_view_sell_swaps_distribution(text,text,text,text,integer,boolean)",
            "dexes.get_view_sell_pressure_t0_distribution(text,text,text,text,integer,text,boolean)",
        ]
        missing: list[str] = []
        for signature in required:
            try:
                rows = self.sql.fetch_rows("SELECT to_regprocedure(%s) AS proc", (signature,))
            except Exception as exc:
                msg = f"DBSQL contract check query failed for {signature}: {exc}"
                if strict:
                    raise RuntimeError(msg) from exc
                logger.warning(msg)
                return
            if not rows or rows[0].get("proc") is None:
                missing.append(signature)
        if not missing:
            return
        message = f"DBSQL compatibility contract missing required functions: {', '.join(missing)}"
        if strict:
            raise RuntimeError(message)
        logger.warning(message)

    def flush_caches(self) -> None:
        """Drop all cached query results (e.g. after a pipeline switch)."""
        if hasattr(self, "_query_cache"):
            self._query_cache.clear()
        for svc in set(self._pages.values()):
            if hasattr(svc, "_cache"):
                with svc._cache_lock:
                    svc._cache.clear()
            if hasattr(svc, "cache") and svc.cache is not None and hasattr(svc.cache, "clear"):
                svc.cache.clear()
        self._health_status_cached = None
        self._health_status_expires_at = 0.0

    def close(self) -> None:
        if hasattr(self, "_query_cache") and hasattr(self._query_cache, "close"):
            self._query_cache.close()
        self.sql.close()

    def get_cache_stats(self) -> dict[str, Any]:
        if hasattr(self, "_query_cache") and hasattr(self._query_cache, "stats"):
            return self._query_cache.stats()
        return {}

    def get_telemetry_snapshot(self) -> dict[str, Any]:
        with self._telemetry_lock:
            request_stats = json.loads(json.dumps(self._telemetry))
        request_stats["latency_by_page"] = self._latency_rollup(request_stats.get("latency_by_page", {}))
        request_stats["latency_by_widget"] = self._latency_rollup(request_stats.get("latency_by_widget", {}))
        sql_snapshot = self.sql.get_telemetry_snapshot() if hasattr(self.sql, "get_telemetry_snapshot") else {}
        refresh_interval_seconds = float(API_CACHE_CONFIG.get("DASH_REFRESH_INTERVAL_SECONDS", API_CACHE_CONFIG.get("API_CACHE_TTL_SECONDS", 30)))
        return {
            "enabled": self._telemetry_enabled,
            "refresh_interval_seconds": refresh_interval_seconds,
            "request_stats": request_stats,
            "cache_stats": self.get_cache_stats(),
            "sql_pool_pressure": sql_snapshot,
            "hotspot_summary": self._build_hotspot_summary(
                request_stats,
                sql_snapshot,
            ),
        }

    def reset_telemetry(self) -> dict[str, Any]:
        with self._telemetry_lock:
            self._telemetry = {
                "requests_total": 0,
                "requests_success": 0,
                "requests_error": 0,
                "requests_by_page": {},
                "errors_by_page": {},
                "requests_by_widget": {},
                "status_family_counts": {},
                "latency_by_page": {},
                "latency_by_widget": {},
                "nav_trace_counts": {},
                "status_family_by_widget": {},
            }
        if hasattr(self.sql, "reset_telemetry"):
            self.sql.reset_telemetry()
        return self.get_telemetry_snapshot()

    def warmup(self) -> None:
        """Prime expensive caches to reduce first-user cold latency."""
        enabled = os.getenv("API_PREWARM_ENABLED", "1") == "1"
        if not enabled:
            return
        started = time.perf_counter()
        max_seconds = float(os.getenv("API_PREWARM_MAX_SECONDS", "30"))
        windows = [
            item.strip()
            for item in os.getenv("API_PREWARM_WINDOWS", "1h,24h,7d").split(",")
            if item.strip()
        ]
        if not windows:
            windows = ["24h"]

        warmup_jobs: list[tuple[str, str, dict[str, Any]]] = []
        row_sizes = [
            int(item.strip())
            for item in os.getenv("API_PREWARM_ROWS", "20,120").split(",")
            if item.strip()
        ]
        if not row_sizes:
            row_sizes = [20]

        base_params = {
            "protocol": "raydium",
            "pair": "USX-USDC",
            "page": 1,
        }
        exponent_jobs: list[tuple[str, str, dict[str, Any]]] = []
        health_jobs: list[tuple[str, str, dict[str, Any]]] = []
        global_jobs: list[tuple[str, str, dict[str, Any]]] = []

        # Prime Kamino shared rows and heavy table/chart queries.
        warmup_jobs.extend(
            [
                ("kamino", "kamino-market-assets", dict(base_params)),
                ("kamino", "kamino-config-table", dict(base_params)),
                ("kamino", "kamino-rate-curve", dict(base_params)),
                ("kamino", "kamino-stress-debt", dict(base_params)),
                ("kamino", "kamino-loan-size-dist", dict(base_params)),
                ("kamino", "kpi-utilization-by-reserve", dict(base_params)),
            ]
        )
        for rows in row_sizes:
            params = dict(base_params)
            params["rows"] = rows
            warmup_jobs.append(("kamino", "kamino-obligation-watchlist", params))
        for window in windows:
            params = dict(base_params)
            params["last_window"] = window
            warmup_jobs.append(("kamino", "kamino-utilization-timeseries", params))
            warmup_jobs.append(("kamino", "kamino-ltv-hf-timeseries", params))
            warmup_jobs.append(("kamino", "kamino-liability-flows", params))
            warmup_jobs.append(("kamino", "kamino-liquidations", params))

        if os.getenv("API_PREWARM_DEX_ENABLED", "1") == "1":
            dex_windows = [
                item.strip()
                for item in os.getenv("API_PREWARM_DEX_WINDOWS", "24h").split(",")
                if item.strip()
            ]
            for window in dex_windows:
                params = dict(base_params)
                params["last_window"] = window

                # Dex liquidity heavy/shared data paths.
                warmup_jobs.append(("dex-liquidity", "kpi-tvl", params))
                warmup_jobs.append(("dex-liquidity", "ranked-lp-events", params))
                warmup_jobs.append(("dex-liquidity", "liquidity-depth-table", params))
                warmup_jobs.append(("dex-liquidity", "liquidity-distribution", params))
                warmup_jobs.append(("dex-liquidity", "usdc-lp-flows", params))
                warmup_jobs.append(("dex-liquidity", "trade-impact-toggle", {**params, "impact_mode": "size"}))

                # Dex swaps heavy/shared data paths.
                warmup_jobs.append(("dex-swaps", "kpi-swap-volume-24h", params))
                warmup_jobs.append(("dex-swaps", "kpi-swap-count-24h", params))
                warmup_jobs.append(("dex-swaps", "swaps-ranked-events", params))
                warmup_jobs.append(("dex-swaps", "swaps-ohlcv", params))
                warmup_jobs.append(("dex-swaps", "swaps-flows-toggle", {**params, "flow_mode": "usx"}))
                warmup_jobs.append(("dex-swaps", "swaps-flows-toggle", {**params, "flow_mode": "usdc"}))

                warmup_jobs.append(("dex-swaps", "swaps-distribution-toggle", {**params, "distribution_mode": "sell-order"}))
                warmup_jobs.append(("dex-swaps", "swaps-spread-volatility", params))
                warmup_jobs.append(("dex-swaps", "swaps-price-impacts", params))

        if os.getenv("API_PREWARM_EXPONENT_ENABLED", "1") == "1":
            exponent_windows = [
                item.strip()
                for item in os.getenv("API_PREWARM_EXPONENT_WINDOWS", "24h").split(",")
                if item.strip()
            ]
            mkt1 = os.getenv("API_PREWARM_EXPONENT_MKT1", "").strip()
            mkt2 = os.getenv("API_PREWARM_EXPONENT_MKT2", "").strip()
            for window in exponent_windows:
                params = dict(base_params)
                params["last_window"] = window
                params["mkt1"] = mkt1
                params["mkt2"] = mkt2

                # Exponent shared rows and heavy timeseries path.
                exponent_jobs.append(("exponent", "exponent-market-meta", params))
                exponent_jobs.append(("exponent", "exponent-pie-tvl", params))
                exponent_jobs.append(("exponent", "kpi-base-token-yield", params))
                exponent_jobs.append(("exponent", "exponent-pt-swap-flows-mkt1", params))
                exponent_jobs.append(("exponent", "exponent-pt-swap-flows-mkt2", params))
                exponent_jobs.append(("exponent", "exponent-market-assets", params))

        if os.getenv("API_PREWARM_EXPONENT_FIRST", "1") == "1":
            warmup_jobs = exponent_jobs + warmup_jobs
        else:
            warmup_jobs.extend(exponent_jobs)

        if os.getenv("API_PREWARM_HEALTH_ENABLED", "1") == "1":
            health_windows = [
                item.strip()
                for item in os.getenv("API_PREWARM_HEALTH_WINDOWS", "24h,7d").split(",")
                if item.strip()
            ]
            include_heavy_health = os.getenv("API_PREWARM_HEALTH_INCLUDE_HEAVY", "0") == "1"
            base_health_params = {
                **base_params,
                "health_schema": os.getenv("API_PREWARM_HEALTH_SCHEMA", "dexes"),
                "health_attribute": os.getenv("API_PREWARM_HEALTH_ATTRIBUTE", "Write Rate"),
                "health_base_schema": os.getenv("API_PREWARM_HEALTH_BASE_SCHEMA", "dexes"),
            }

            # Fast table paths.
            health_jobs.extend(
                [
                    ("health", "health-queue-table", dict(base_health_params)),
                    ("health", "health-trigger-table", dict(base_health_params)),
                    ("health", "health-base-table", dict(base_health_params)),
                ]
            )
            if include_heavy_health:
                health_jobs.extend(
                    [
                        ("health", "health-master", dict(base_health_params)),
                        ("health", "health-cagg-table", dict(base_health_params)),
                    ]
                )

            # Window-sensitive chart paths.
            for window in health_windows:
                params = dict(base_health_params)
                params["last_window"] = window
                health_jobs.append(("health", "health-queue-chart", params))
                health_jobs.append(("health", "health-base-chart-events", params))
                health_jobs.append(("health", "health-base-chart-accounts", params))

        if os.getenv("API_PREWARM_HEALTH_FIRST", "0") == "1":
            warmup_jobs = health_jobs + warmup_jobs
        else:
            warmup_jobs.extend(health_jobs)

        if os.getenv("API_PREWARM_GLOBAL_ENABLED", "1") == "1":
            global_windows = [
                item.strip()
                for item in os.getenv("API_PREWARM_GLOBAL_WINDOWS", "24h,7d").split(",")
                if item.strip()
            ]
            # Shared last-row cache path.
            global_jobs.append(("global-ecosystem", "ge-issuance-bar", dict(base_params)))
            include_heavy_global_ts = os.getenv("API_PREWARM_GLOBAL_INCLUDE_HEAVY_TS", "0") == "1"
            for window in global_windows:
                params = dict(base_params)
                params["last_window"] = window
                # Prime interval and yield caches by default. The shared
                # global timeseries function can take tens of seconds on cold
                # start, so only prewarm it when explicitly enabled.
                if include_heavy_global_ts:
                    global_jobs.append(("global-ecosystem", "ge-issuance-time", params))
                global_jobs.append(("global-ecosystem", "ge-activity-pct-usx", params))
                global_jobs.append(("global-ecosystem", "ge-yield-generation", params))
                if os.getenv("API_PREWARM_GLOBAL_HOTSPOTS_ENABLED", "1") == "1":
                    global_jobs.append(("global-ecosystem", "ge-activity-vol-usx", params))
                    global_jobs.append(("global-ecosystem", "ge-tvl-share-usx", params))

        if os.getenv("API_PREWARM_GLOBAL_FIRST", "0") == "1":
            warmup_jobs = global_jobs + warmup_jobs
        else:
            warmup_jobs.extend(global_jobs)

        failures = 0
        completed = 0
        for page, widget_id, params in warmup_jobs:
            if max_seconds > 0 and (time.perf_counter() - started) >= max_seconds:
                logger.info(
                    "Warmup budget reached after %s jobs in %.2fs (limit %.2fs)",
                    completed,
                    time.perf_counter() - started,
                    max_seconds,
                )
                break
            try:
                self.get_widget_data(page=page, widget_id=widget_id, params=params)
                completed += 1
            except Exception as exc:  # pragma: no cover - startup best effort
                failures += 1
                logger.warning("Warmup failed for %s/%s: %s", page, widget_id, exc)
        logger.info("Warmup complete: %s/%s jobs, %s failures", completed, len(warmup_jobs), failures)

    def list_widgets(self, page: str | None = None) -> list[str]:
        page_key = page or self._default_page
        page_service = self._pages.get(page_key)
        if page_service is None:
            raise ValueError(f"Unsupported page: {page_key}")
        return page_service.list_widgets()

    def get_health_master_status(self) -> list[dict[str, Any]]:
        health_svc = self._pages["health"]
        return health_svc.fetch_master_rows()  # type: ignore[union-attr]

    def get_health_indicator_status(
        self,
        *,
        non_blocking: bool = False,
        allow_stale_on_lock_contention: bool = False,
    ) -> bool | None:
        now = time.time()
        if now < self._health_status_expires_at:
            return self._health_status_cached

        acquired = self._health_status_lock.acquire(blocking=not non_blocking)
        if not acquired:
            if allow_stale_on_lock_contention:
                return self._health_status_cached
            return None

        try:
            now = time.time()
            if now < self._health_status_expires_at:
                return self._health_status_cached

            health_svc = self._pages["health"]
            status = health_svc.fetch_master_is_green()  # type: ignore[union-attr]
            if status is None and self._health_status_cached is not None:
                # Hold last known good status briefly when DB is degraded.
                self._health_status_expires_at = now + min(5.0, self._health_status_cache_ttl_seconds)
                return self._health_status_cached

            self._health_status_cached = status
            ttl_seconds = self._health_status_cache_ttl_seconds
            if status is True:
                ttl_seconds = self._health_status_cache_ttl_green_seconds
            elif status is False:
                ttl_seconds = self._health_status_cache_ttl_red_seconds
            self._health_status_expires_at = now + max(1.0, ttl_seconds)
            return status
        finally:
            self._health_status_lock.release()

    def get_meta(self) -> dict[str, Any]:
        liquidity = self._pages["playbook-liquidity"]
        return liquidity.get_meta()  # type: ignore[no-any-return]

    def get_widget_data(
        self,
        page: str,
        widget_id: str,
        params: dict[str, Any],
        trace_ctx: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        started = time.perf_counter()
        page_service = self._pages.get(page)
        if page_service is None:
            raise ValueError(f"Unsupported page: {page}")

        protocol = str(params.get("protocol", page_service.default_protocol))
        pair = str(params.get("pair", page_service.default_pair))
        generated_at = datetime.now(UTC)
        trace = trace_ctx or {}
        nav_trace_id = str(trace.get("nav_trace_id", ""))
        request_id = str(trace.get("request_id", ""))
        if hasattr(self.sql, "set_request_context"):
            self.sql.set_request_context(
                page=page,
                widget=widget_id,
                nav_trace_id=nav_trace_id,
                request_id=request_id,
            )
        self._record_widget_request_started(page, widget_id, nav_trace_id=nav_trace_id)
        status_code = 200
        try:
            payload = page_service.get_widget_payload(widget_id, params)
            response = {
                "metadata": {
                    "protocol": protocol,
                    "pair": pair,
                    "generated_at": generated_at,
                    "watermark": None,
                },
                "data": payload,
                "status": "success",
            }
            return response
        except Exception:
            status_code = 500
            raise
        finally:
            elapsed_ms = (time.perf_counter() - started) * 1000.0
            self._record_widget_request_finished(
                page,
                widget_id,
                elapsed_ms=elapsed_ms,
                status_code=status_code,
            )
            if hasattr(self.sql, "clear_request_context"):
                self.sql.clear_request_context()
            if self._log_slow_widgets:
                if elapsed_ms >= self._slow_widget_threshold_ms:
                    logger.warning("Slow widget %.2fms page=%s widget=%s", elapsed_ms, page, widget_id)

    @staticmethod
    def _build_cache_key(widget_id: str, params: dict[str, Any]) -> str:
        sig = "&".join(f"{k}={params[k]}" for k in sorted(params.keys()))
        return f"{widget_id}::{sig}"

    def _record_widget_request_started(self, page: str, widget_id: str, *, nav_trace_id: str = "") -> None:
        if not self._telemetry_enabled:
            return
        with self._telemetry_lock:
            self._telemetry["requests_total"] = int(self._telemetry["requests_total"]) + 1
            page_counts = self._telemetry["requests_by_page"]
            page_counts[page] = int(page_counts.get(page, 0)) + 1
            widget_key = f"{page}/{widget_id}"
            widget_counts = self._telemetry["requests_by_widget"]
            widget_counts[widget_key] = int(widget_counts.get(widget_key, 0)) + 1
            if nav_trace_id:
                trace_counts = self._telemetry["nav_trace_counts"]
                trace_counts[nav_trace_id] = int(trace_counts.get(nav_trace_id, 0)) + 1

    def _record_widget_request_finished(
        self,
        page: str,
        widget_id: str,
        *,
        elapsed_ms: float,
        status_code: int,
    ) -> None:
        if not self._telemetry_enabled:
            return
        widget_key = f"{page}/{widget_id}"
        family = f"{max(0, int(status_code)) // 100}xx"
        with self._telemetry_lock:
            if 200 <= int(status_code) < 300:
                self._telemetry["requests_success"] = int(self._telemetry["requests_success"]) + 1
            else:
                self._telemetry["requests_error"] = int(self._telemetry["requests_error"]) + 1
                error_counts = self._telemetry["errors_by_page"]
                error_counts[page] = int(error_counts.get(page, 0)) + 1
            status_counts = self._telemetry["status_family_counts"]
            status_counts[family] = int(status_counts.get(family, 0)) + 1
            status_by_widget = self._telemetry["status_family_by_widget"]
            per_widget = status_by_widget.get(widget_key)
            if not isinstance(per_widget, dict):
                per_widget = {}
            per_widget[family] = int(per_widget.get(family, 0)) + 1
            status_by_widget[widget_key] = per_widget
            page_latency = self._telemetry["latency_by_page"]
            widget_latency = self._telemetry["latency_by_widget"]
            page_entry = self._update_latency_entry(page_latency.get(page), elapsed_ms)
            widget_entry = self._update_latency_entry(widget_latency.get(widget_key), elapsed_ms)
            page_latency[page] = page_entry
            widget_latency[widget_key] = widget_entry

    @staticmethod
    def _update_latency_entry(entry: dict[str, Any] | None, elapsed_ms: float) -> dict[str, Any]:
        if not isinstance(entry, dict):
            entry = {"count": 0, "total_ms": 0.0, "max_ms": 0.0, "samples": []}
        safe_ms = max(0.0, float(elapsed_ms))
        entry["count"] = int(entry.get("count", 0)) + 1
        entry["total_ms"] = float(entry.get("total_ms", 0.0)) + safe_ms
        entry["max_ms"] = max(float(entry.get("max_ms", 0.0)), safe_ms)
        samples = list(entry.get("samples", []))
        samples.append(safe_ms)
        if len(samples) > 400:
            samples = samples[-400:]
        entry["samples"] = samples
        return entry

    @staticmethod
    def _latency_rollup(raw: dict[str, Any]) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for key, value in (raw or {}).items():
            if not isinstance(value, dict):
                continue
            count = int(value.get("count", 0) or 0)
            total_ms = float(value.get("total_ms", 0.0) or 0.0)
            samples = [float(v) for v in value.get("samples", [])]
            out[key] = {
                "count": count,
                "avg_ms": round(total_ms / count, 3) if count > 0 else 0.0,
                "max_ms": round(float(value.get("max_ms", 0.0) or 0.0), 3),
                "p50_ms": DataService._percentile(samples, 50),
                "p95_ms": DataService._percentile(samples, 95),
                "p99_ms": DataService._percentile(samples, 99),
            }
        return out

    @staticmethod
    def _percentile(values: list[float], pct: float) -> float:
        if not values:
            return 0.0
        if len(values) == 1:
            return round(float(values[0]), 3)
        ordered = sorted(values)
        rank = (len(ordered) - 1) * max(0.0, min(100.0, float(pct))) / 100.0
        lo = int(rank)
        hi = min(lo + 1, len(ordered) - 1)
        frac = rank - lo
        return round((ordered[lo] * (1.0 - frac)) + (ordered[hi] * frac), 3)

    @staticmethod
    def _build_hotspot_summary(request_stats: dict[str, Any], sql_snapshot: dict[str, Any]) -> dict[str, Any]:
        latency = request_stats.get("latency_by_widget", {})
        status_by_widget = request_stats.get("status_family_by_widget", {})
        fingerprints = sql_snapshot.get("query_fingerprint_stats", {})
        pool_wait_avg = float(sql_snapshot.get("pool_checkout_wait_avg_ms", 0.0) or 0.0)
        pool_wait_max = float(sql_snapshot.get("pool_checkout_wait_max_ms", 0.0) or 0.0)
        result: dict[str, Any] = {
            "widgets": {},
            "pool_wait_avg_ms": round(pool_wait_avg, 3),
            "pool_wait_max_ms": round(pool_wait_max, 3),
        }
        for key in sorted(_HOTSPOT_WIDGET_KEYS):
            lat = latency.get(key, {}) if isinstance(latency, dict) else {}
            statuses = status_by_widget.get(key, {}) if isinstance(status_by_widget, dict) else {}
            fp_entries: list[dict[str, Any]] = []
            if isinstance(fingerprints, dict):
                for fp_key, fp in fingerprints.items():
                    if not isinstance(fp, dict):
                        continue
                    if str(fp.get("page", "")) != "global-ecosystem":
                        continue
                    if str(fp.get("widget", "")) != key.split("/", 1)[1]:
                        continue
                    fp_entries.append(
                        {
                            "fingerprint_key": fp_key,
                            "count": int(fp.get("count", 0) or 0),
                            "error_count": int(fp.get("error_count", 0) or 0),
                            "avg_ms": float(fp.get("avg_ms", 0.0) or 0.0),
                            "p95_ms": float(fp.get("p95_ms", 0.0) or 0.0),
                            "p99_ms": float(fp.get("p99_ms", 0.0) or 0.0),
                            "max_ms": float(fp.get("max_ms", 0.0) or 0.0),
                            "query_preview": str(fp.get("query_preview", "")),
                            "slow_samples_ms": list(fp.get("slow_samples_ms", [])),
                        }
                    )
            fp_entries.sort(key=lambda item: (item["p95_ms"], item["count"]), reverse=True)
            result["widgets"][key] = {
                "latency": lat if isinstance(lat, dict) else {},
                "status_families": statuses if isinstance(statuses, dict) else {},
                "top_sql_fingerprints": fp_entries[:5],
            }
        return result

    def warmup_targets(
        self,
        *,
        targets: list[dict[str, Any]],
        base_params: dict[str, Any] | None = None,
        budget_seconds: float = 30.0,
        max_jobs: int = 20,
        concurrency: int = 3,
        include_payloads: bool = False,
        max_payload_bytes: int = 2_000_000,
        max_payload_count: int = 20,
    ) -> dict[str, Any]:
        started = time.perf_counter()
        common_params = dict(base_params or {})
        dedup: set[str] = set()
        queue: list[tuple[str, str, dict[str, Any]]] = []

        for target in targets:
            page_id = str(target.get("page_id") or target.get("page") or "").strip()
            widget_id = str(target.get("widget_id") or "").strip()
            if not page_id or not widget_id:
                continue
            merged_params = dict(common_params)
            override_params = target.get("params")
            if isinstance(override_params, dict):
                merged_params.update(override_params)
            signature = "|".join(
                [
                    page_id,
                    widget_id,
                    "&".join(
                        f"{key}={merged_params[key]}"
                        for key in sorted(merged_params.keys())
                    ),
                ]
            )
            if signature in dedup:
                continue
            dedup.add(signature)
            queue.append((page_id, widget_id, merged_params))

        queue = queue[: max(1, int(max_jobs))]
        attempted = 0
        completed = 0
        failed = 0
        skipped = 0
        budget = max(1.0, float(budget_seconds))
        worker_count = max(1, int(concurrency))

        payloads_lock = threading.Lock()
        payloads_list: list[dict[str, Any]] = []
        payloads_bytes = 0

        def _run_job(job: tuple[str, str, dict[str, Any]]) -> bool:
            nonlocal payloads_bytes
            if time.perf_counter() - started >= budget:
                return False
            page_id, widget_id, params = job
            result = self.get_widget_data(page=page_id, widget_id=widget_id, params=params)
            if include_payloads:
                with payloads_lock:
                    if len(payloads_list) >= max_payload_count:
                        return True
                    try:
                        entry_size = len(json.dumps(result, default=str))
                    except Exception:
                        return True
                    if payloads_bytes + entry_size <= max_payload_bytes:
                        payloads_list.append({
                            "cache_key": self._build_cache_key(widget_id, params),
                            "page_id": page_id,
                            "widget_id": widget_id,
                            "response": result,
                        })
                        payloads_bytes += entry_size
            return True

        futures = []
        with ThreadPoolExecutor(max_workers=worker_count) as executor:
            for job in queue:
                if (time.perf_counter() - started) >= budget:
                    skipped += 1
                    continue
                attempted += 1
                futures.append(executor.submit(_run_job, job))

            deadline = started + budget
            for future in as_completed(futures):
                if time.perf_counter() > deadline:
                    skipped += 1
                    continue
                try:
                    ok = future.result()
                    if ok:
                        completed += 1
                    else:
                        skipped += 1
                except Exception as exc:
                    failed += 1
                    logger.warning("Warmup job failed: %s", exc)

            for future in futures:
                if not future.done():
                    future.cancel()
                    skipped += 1

        elapsed = time.perf_counter() - started
        logger.info(
            "Targeted warmup complete: attempted=%s completed=%s failed=%s skipped=%s elapsed=%.2fs budget=%.2fs",
            attempted,
            completed,
            failed,
            skipped,
            elapsed,
            budget,
        )
        result: dict[str, Any] = {
            "stats": {
                "attempted": attempted,
                "completed": completed,
                "failed": failed,
                "skipped": skipped,
                "elapsed_seconds": round(elapsed, 3),
                "budget_seconds": budget,
            },
        }
        if include_payloads:
            result["payloads"] = payloads_list
        return result
