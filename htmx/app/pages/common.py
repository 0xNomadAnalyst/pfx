from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import urlencode


@dataclass(frozen=True)
class WidgetConfig:
    id: str
    title: str
    kind: str
    refresh_interval_seconds: int
    css_class: str
    expandable: bool = True


@dataclass(frozen=True)
class PageConfig:
    slug: str
    label: str
    api_page_id: str
    widgets: list[WidgetConfig]
    default_protocol: str = "raydium"
    default_pair: str = "USX-USDC"
    show_protocol_pair_filters: bool = False
    widget_filter_env_var: str = ""


def build_widget_endpoint(api_base_url: str, api_page_id: str, widget_id: str) -> str:
    query = urlencode(
        {
            "lookback": "1 day",
            "interval": "5 minutes",
            "rows": 120,
            "tick_delta_time": "1 hour",
        }
    )
    return f"{api_base_url}/api/v1/{api_page_id}/{widget_id}?{query}"
