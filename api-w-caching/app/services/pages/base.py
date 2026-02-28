from __future__ import annotations

import threading
import time
from typing import Any, Callable

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
        self._cache: dict[str, tuple[float, Any]] = {}
        self._cache_lock = threading.Lock()

    def _cached(self, key: str, fn: Callable[[], Any], ttl_seconds: float = 30.0) -> Any:
        if self.cache is not None and hasattr(self.cache, "cached"):
            return self.cache.cached(key, fn, ttl_seconds=ttl_seconds)
        now = time.time()
        with self._cache_lock:
            cached = self._cache.get(key)
            if cached and cached[0] > now:
                return cached[1]
        value = fn()
        with self._cache_lock:
            self._cache[key] = (now + ttl_seconds, value)
        return value

    def get_meta(self) -> dict[str, Any]:
        return {}

    def list_widgets(self) -> list[str]:
        return list(self._handlers.keys())

    def get_widget_payload(self, widget_id: str, params: dict[str, Any]) -> dict[str, Any]:
        handler = self._handlers.get(widget_id)
        if handler is None:
            raise KeyError(f"Unsupported widget id '{widget_id}' for page '{self.page_id}'")
        return handler(params)
