from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class WidgetConfig:
    id: str
    title: str
    kind: str
    css_class: str
    refresh_interval_seconds: int = 30
    expandable: bool = True


@dataclass(frozen=True)
class PageConfig:
    slug: str
    label: str
    api_page_id: str
    widgets: list[WidgetConfig]
    show_protocol_pair_filters: bool = False
    default_protocol: str = ""
    default_pair: str = ""
    widget_filter_env_var: str = ""


def build_widget_endpoint(api_base_url: str, page_id: str, widget_id: str) -> str:
    base = api_base_url.rstrip("/")
    # Use the canonical legacy-compatible route shape.
    # Some running API variants only expose /api/v1/{page}/{widget}.
    return f"{base}/api/v1/{page_id}/{widget_id}"
