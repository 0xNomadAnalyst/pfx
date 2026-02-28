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
        WidgetConfig("kpi-tvl", "TVL in USDC units", "kpi", "panel panel-kpi slot-kpi-a1"),
        WidgetConfig("kpi-impact-500k", "500,000 USX sell impact", "kpi", "panel panel-kpi slot-kpi-b1"),
        WidgetConfig("kpi-reserves", "Reserve Balances (millions)", "kpi", "panel panel-kpi slot-kpi-a2"),
        WidgetConfig("kpi-largest-impact", "Current Impact of Largest USX Sell Trade", "kpi", "panel panel-kpi slot-kpi-b2"),
        WidgetConfig("kpi-pool-balance", "Pool Balance", "kpi", "panel panel-kpi slot-kpi-a3"),
        WidgetConfig("kpi-average-impact", "Current Impact of Average USX Sell Trade", "kpi", "panel panel-kpi slot-kpi-b3"),
        WidgetConfig("liquidity-distribution", "Liquidity Distribution", "chart", "panel panel-medium slot-left-top"),
        WidgetConfig("liquidity-depth", "Liquidity Depth", "chart", "panel panel-medium slot-left-middle"),
        WidgetConfig("liquidity-change-heatmap", "Liquidity Change Heatmap", "chart", "panel panel-medium slot-left-bottom"),
        WidgetConfig("usdc-pool-share-concentration", "USDC Pool Share", "chart", "panel panel-medium slot-right-1",
                     tooltip="Share of pool liquidity held as USDC, and share of total liquidity resources found within +/- 5bps of peg."),
        WidgetConfig("trade-impact-toggle", "Trade Impact", "chart", "panel panel-medium slot-right-2"),
        WidgetConfig("usdc-lp-flows", "USDC LP Flows", "chart", "panel panel-medium slot-right-3"),
        WidgetConfig("liquidity-depth-table", "Liquidity Depth Table", "table", "panel panel-wide-table slot-right-depth-table", expandable=False),
        WidgetConfig("ranked-lp-events", "Largest LP changes In and Out (USDC)", "table-split", "panel panel-wide-table slot-ranked", expandable=False),
    ],
)
