from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Any

from app.services.pages.dex_liquidity import DexLiquidityPageService
from app.services.pages.dex_swaps import DexSwapsPageService
from app.services.pages.kamino import KaminoPageService
from app.services.shared.cache_store import QueryCache
from app.services.sql_adapter import SqlAdapter


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
        self._pages = {
            "playbook-liquidity": liquidity,
            "dex-liquidity": liquidity,
            "dex-swaps": swaps,
            "kamino": kamino,
        }
        self._default_page = "playbook-liquidity"

    def close(self) -> None:
        self.sql.close()

    def list_widgets(self, page: str | None = None) -> list[str]:
        page_key = page or self._default_page
        page_service = self._pages.get(page_key)
        if page_service is None:
            raise ValueError(f"Unsupported page: {page_key}")
        return page_service.list_widgets()

    def get_meta(self) -> dict[str, Any]:
        liquidity = self._pages["playbook-liquidity"]
        return liquidity.get_meta()  # type: ignore[no-any-return]

    def get_widget_data(self, page: str, widget_id: str, params: dict[str, Any]) -> dict[str, Any]:
        page_service = self._pages.get(page)
        if page_service is None:
            raise ValueError(f"Unsupported page: {page}")

        protocol = str(params.get("protocol", page_service.default_protocol))
        pair = str(params.get("pair", page_service.default_pair))
        generated_at = datetime.now(UTC)
        payload = page_service.get_widget_payload(widget_id, params)
        return {
            "metadata": {
                "protocol": protocol,
                "pair": pair,
                "generated_at": generated_at,
                "watermark": None,
            },
            "data": payload,
            "status": "success",
        }
