from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class WidgetConfig:
    id: str
    title: str
    kind: str
    css_class: str
    refresh_interval_seconds: int = 30
    expandable: bool = True
    detail_table_id: str = ""
    tooltip: str = ""
    source_page_id: str = ""
    source_widget_id: str = ""
    protocol_override: str = ""


@dataclass(frozen=True)
class PageAction:
    id: str
    label: str
    icon: str = ""
    modal_kind: str = "html"
    endpoint: str = ""


@dataclass(frozen=True)
class PageConfig:
    slug: str
    label: str
    api_page_id: str
    widgets: list[WidgetConfig]
    show_protocol_pair_filters: bool = False
    show_asset_filter: bool = False
    show_market_selectors: bool = False
    default_protocol: str = ""
    default_pair: str = ""
    default_asset: str = ""
    show_pipeline_switcher: bool = True
    show_price_basis_filter: bool = False
    content_template: str = ""
    widget_filter_env_var: str = ""
    page_actions: list[PageAction] = field(default_factory=list)
    video_guide_youtube_id: str = "ky5vsKgcEK0"


def build_widget_endpoint(api_base_url: str, page_id: str, widget_id: str) -> str:
    base = api_base_url.rstrip("/")
    # Use the canonical legacy-compatible route shape.
    # Some running API variants only expose /api/v1/{page}/{widget}.
    return f"{base}/api/v1/{page_id}/{widget_id}"
