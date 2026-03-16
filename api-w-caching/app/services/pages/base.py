from __future__ import annotations

import os
from collections import OrderedDict
import logging
import threading
import time
from typing import Any, Callable

logger = logging.getLogger(__name__)


class BasePageService:
    page_id = ""
    default_protocol = "raydium"
    default_pair = "USX-USDC"

    def __init__(self, sql: Any | None = None, cache: Any | None = None):
        # Keep compatibility with both service stacks:
        # - legacy stack passes (SqlAdapter, QueryCache)
        # - standalone stack passes no args and uses SQLClient
        if sql is None:
            from app.services.sql import SQLClient

            self.sql = SQLClient()
        else:
            self.sql = sql
        self.cache = cache
        self._handlers: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {}
        self._cache: OrderedDict[str, tuple[float, float, Any]] = OrderedDict()
        self._cache_lock = threading.Lock()
        self._refreshing: set[str] = set()
        self._cache_max_entries = int(os.getenv("API_CACHE_MAX_ENTRIES", "256"))
        self._default_swr_seconds = float(os.getenv("API_CACHE_SWR_SECONDS", "15"))

    def _trim_cache_locked(self) -> None:
        while len(self._cache) > self._cache_max_entries:
            self._cache.popitem(last=False)

    def _cached(
        self,
        key: str,
        fn: Callable[[], Any],
        ttl_seconds: float = 30.0,
        *,
        swr_seconds: float | None = None,
    ) -> Any:
        swr = self._default_swr_seconds if swr_seconds is None else max(swr_seconds, 0.0)
        if self.cache is not None and hasattr(self.cache, "cached_swr"):
            return self.cache.cached_swr(key, fn, ttl_seconds=ttl_seconds, swr_seconds=swr)
        if self.cache is not None and hasattr(self.cache, "cached"):
            return self.cache.cached(key, fn, ttl_seconds=ttl_seconds)
        now = time.time()
        with self._cache_lock:
            cached = self._cache.get(key)
            if cached:
                expires_at, stale_expires_at, value = cached
                if expires_at > now:
                    self._cache.move_to_end(key)
                    return value
                if swr > 0 and stale_expires_at > now:
                    self._cache.move_to_end(key)
                    if key not in self._refreshing:
                        self._refreshing.add(key)
                        threading.Thread(
                            target=self._refresh_cached_key,
                            args=(key, fn, ttl_seconds, swr),
                            daemon=True,
                        ).start()
                    return value
                if stale_expires_at <= now:
                    self._cache.pop(key, None)
        value = fn()
        with self._cache_lock:
            expires_at = now + ttl_seconds
            self._cache[key] = (expires_at, expires_at + swr, value)
            self._cache.move_to_end(key)
            self._trim_cache_locked()
        return value

    def _refresh_cached_key(
        self,
        key: str,
        fn: Callable[[], Any],
        ttl_seconds: float,
        swr_seconds: float,
    ) -> None:
        try:
            value = fn()
            now = time.time()
            with self._cache_lock:
                expires_at = now + ttl_seconds
                self._cache[key] = (expires_at, expires_at + swr_seconds, value)
                self._cache.move_to_end(key)
                self._trim_cache_locked()
        except Exception as exc:
            logger.debug("SWR refresh failed for %s/%s: %s", self.page_id, key, exc)
        finally:
            with self._cache_lock:
                self._refreshing.discard(key)

    @staticmethod
    def _should_invert(params: dict[str, Any], protocol: str) -> bool:
        from app.services import pipeline_config

        pipeline = str(params.get("_pipeline") or pipeline_config.get_current()).lower()
        if pipeline != "onyc":
            return False
        pb = str(params.get("price_basis", "default")).lower()
        if pb == "invert-both":
            return True
        proto = protocol.lower()
        if pb == "invert-orca" and proto == "orca":
            return True
        if pb == "invert-ray" and proto in ("raydium", "ray"):
            return True
        return False

    def get_meta(self) -> dict[str, Any]:
        return {}

    def list_widgets(self) -> list[str]:
        return list(self._handlers.keys())

    def get_widget_payload(self, widget_id: str, params: dict[str, Any]) -> dict[str, Any]:
        handler = self._handlers.get(widget_id)
        if handler is None:
            raise KeyError(f"Unsupported widget id '{widget_id}' for page '{self.page_id}'")
        return handler(params)
