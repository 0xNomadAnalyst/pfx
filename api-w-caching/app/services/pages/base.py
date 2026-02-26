from __future__ import annotations

from typing import Any, Callable

from app.services.shared.cache_store import QueryCache
from app.services.sql_adapter import SqlAdapter


class BasePageService:
    page_id: str = ""
    default_protocol: str = "raydium"
    default_pair: str = "USX-USDC"

    def __init__(self, sql_adapter: SqlAdapter, cache: QueryCache):
        self.sql = sql_adapter
        self.cache = cache
        self._handlers: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {}

    def list_widgets(self) -> list[str]:
        return sorted(self._handlers.keys())

    def get_widget_payload(self, widget_id: str, params: dict[str, Any]) -> dict[str, Any]:
        handler = self._handlers.get(widget_id)
        if handler is None:
            raise ValueError(f"Unsupported widget: {widget_id}")
        return handler(params)

    def _cached(self, key: str, loader: Callable[[], Any], ttl_seconds: float | None = None) -> Any:
        return self.cache.cached(key, loader, ttl_seconds=ttl_seconds)
