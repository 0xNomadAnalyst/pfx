from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


WIDGETS: list[WidgetConfig] = [
    WidgetConfig("liquidity-distribution", "Liquidity Distribution (in token units)", "chart", 60, "panel panel-large slot-left-top"),
    WidgetConfig("kpi-tvl", "TVL in USDC Units", "kpi", 30, "panel panel-kpi slot-kpi-a1"),
    WidgetConfig("kpi-impact-500k", "500,000 USX Sell Impact", "kpi", 30, "panel panel-kpi slot-kpi-b1"),
    WidgetConfig("kpi-reserves", "Reserve Balances (millions)", "kpi", 30, "panel panel-kpi slot-kpi-a2"),
    WidgetConfig("kpi-largest-impact", "Current Impact of Largest USX Sell Trade", "kpi", 30, "panel panel-kpi slot-kpi-b2"),
    WidgetConfig("kpi-pool-balance", "Pool Balance", "kpi", 30, "panel panel-kpi slot-kpi-a3"),
    WidgetConfig("kpi-average-impact", "Current Impact of Average USX Sell Trade", "kpi", 30, "panel panel-kpi slot-kpi-b3"),
    WidgetConfig("liquidity-depth", "Liquidity Depth (in token units)", "chart", 60, "panel panel-large slot-left-middle"),
    WidgetConfig("liquidity-change-heatmap", "Liquidity Change Heatmap", "chart", 60, "panel panel-medium slot-left-bottom"),
    WidgetConfig("liquidity-depth-table", "Liquidity Depth Table", "table", 60, "panel panel-table slot-right-depth-table"),
    WidgetConfig("usdc-lp-flows", "USDC LP Liquidity Flows", "chart", 60, "panel panel-medium slot-right-1"),
    WidgetConfig("usdc-pool-share-concentration", "USDC Pool Share & Concentration ± 5bps", "chart", 60, "panel panel-medium slot-right-2"),
    WidgetConfig("trade-impact-toggle", "Trade Size / Impact Over Time (sell USX)", "chart", 60, "panel panel-medium slot-right-3"),
    WidgetConfig("ranked-lp-events", "Largest LP Changes In and Out (USDC)", "table-split", 60, "panel panel-wide-table slot-ranked"),
]


PAGE_CONFIG = PageConfig(
    slug="dex-liquidity",
    label="DEX Liquidity",
    api_page_id="playbook-liquidity",
    widgets=WIDGETS,
    default_protocol="raydium",
    default_pair="USX-USDC",
    show_protocol_pair_filters=True,
    widget_filter_env_var="DASHBOARD_WIDGET_IDS",
)
