from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


PAGE_CONFIG = PageConfig(
    slug="dex-liquidity",
    label="DEX Liquidity",
    api_page_id="playbook-liquidity",
    show_protocol_pair_filters=True,
    default_protocol="raydium",
    default_pair="USX-USDC",
    widgets=[
        WidgetConfig("kpi-tvl", "TVL", "kpi", "panel panel-kpi slot-kpi-a1"),
        WidgetConfig("kpi-impact-500k", "500K Sell Impact", "kpi", "panel panel-kpi slot-kpi-b1"),
        WidgetConfig("kpi-reserves", "Reserves (M)", "kpi", "panel panel-kpi slot-kpi-a2"),
        WidgetConfig("kpi-largest-impact", "Largest Sell Impact", "kpi", "panel panel-kpi slot-kpi-b2"),
        WidgetConfig("kpi-pool-balance", "Pool Balance", "kpi", "panel panel-kpi slot-kpi-a3"),
        WidgetConfig("kpi-average-impact", "Average Sell Impact", "kpi", "panel panel-kpi slot-kpi-b3"),
        WidgetConfig("liquidity-distribution", "Liquidity Distribution", "chart", "panel panel-medium slot-left-top"),
        WidgetConfig("liquidity-depth", "Liquidity Depth", "chart", "panel panel-medium slot-left-middle"),
        WidgetConfig("liquidity-change-heatmap", "Liquidity Change Heatmap", "chart", "panel panel-medium slot-left-bottom"),
        WidgetConfig("usdc-pool-share-concentration", "USDC Pool Share", "chart", "panel panel-medium slot-right-1"),
        WidgetConfig("trade-impact-toggle", "Trade Impact", "chart", "panel panel-medium slot-right-2"),
        WidgetConfig("usdc-lp-flows", "USDC LP Flows", "chart", "panel panel-medium slot-right-3"),
        WidgetConfig("liquidity-depth-table", "Liquidity Depth Table", "table", "panel panel-wide-table slot-right-depth-table", expandable=False),
        WidgetConfig("ranked-lp-events", "Ranked LP Events", "table-split", "panel panel-wide-table slot-ranked", expandable=False),
    ],
)
