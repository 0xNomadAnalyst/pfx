from __future__ import annotations

import logging
import os
import threading
import time
from datetime import UTC, datetime
from typing import Any

from app.services.pages.dex_liquidity import DexLiquidityPageService
from app.services.pages.dex_swaps import DexSwapsPageService
from app.services.pages.exponent import ExponentPageService
from app.services.pages.health import HealthPageService
from app.services.pages.kamino import KaminoPageService
from app.services.shared.cache_store import QueryCache
from app.services.sql_adapter import SqlAdapter

logger = logging.getLogger(__name__)


class DataService:
    """Coordinator for page-specific data services."""

    def __init__(self, sql_adapter: SqlAdapter):
        self.sql = sql_adapter
        cache = QueryCache(
            ttl_seconds=float(os.getenv("API_CACHE_TTL_SECONDS", "30")),
            max_entries=int(os.getenv("API_CACHE_MAX_ENTRIES", "256")),
        )
        liquidity = DexLiquidityPageService(sql_adapter, cache)
        swaps = DexSwapsPageService(sql_adapter, cache)
        kamino = KaminoPageService(sql_adapter, cache)
        exponent = ExponentPageService(sql_adapter, cache)
        health = HealthPageService(sql_adapter, cache)
        self._pages = {
            "playbook-liquidity": liquidity,
            "dex-liquidity": liquidity,
            "dex-swaps": swaps,
            "kamino": kamino,
            "exponent": exponent,
            "health": health,
        }
        self._default_page = "playbook-liquidity"
        self._log_slow_widgets = os.getenv("API_LOG_SLOW_WIDGETS", "0") == "1"
        self._slow_widget_threshold_ms = float(os.getenv("API_SLOW_WIDGET_THRESHOLD_MS", "150"))
        self._health_status_cache_ttl_seconds = float(os.getenv("HEALTH_STATUS_TTL_SECONDS", "15"))
        self._health_status_lock = threading.Lock()
        self._health_status_cached: bool | None = None
        self._health_status_expires_at = 0.0

    def close(self) -> None:
        self.sql.close()

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

    def get_health_indicator_status(self) -> bool | None:
        now = time.time()
        if now < self._health_status_expires_at:
            return self._health_status_cached

        with self._health_status_lock:
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
            self._health_status_expires_at = now + self._health_status_cache_ttl_seconds
            return status

    def get_meta(self) -> dict[str, Any]:
        liquidity = self._pages["playbook-liquidity"]
        return liquidity.get_meta()  # type: ignore[no-any-return]

    def get_widget_data(self, page: str, widget_id: str, params: dict[str, Any]) -> dict[str, Any]:
        started = time.perf_counter()
        page_service = self._pages.get(page)
        if page_service is None:
            raise ValueError(f"Unsupported page: {page}")

        protocol = str(params.get("protocol", page_service.default_protocol))
        pair = str(params.get("pair", page_service.default_pair))
        generated_at = datetime.now(UTC)
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
        if self._log_slow_widgets:
            elapsed_ms = (time.perf_counter() - started) * 1000.0
            if elapsed_ms >= self._slow_widget_threshold_ms:
                logger.warning("Slow widget %.2fms page=%s widget=%s", elapsed_ms, page, widget_id)
        return response
