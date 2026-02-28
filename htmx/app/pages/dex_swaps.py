from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


PAGE_CONFIG = PageConfig(
    slug="dex-swaps",
    label="DEX Swaps",
    api_page_id="dex-swaps",
    show_protocol_pair_filters=True,
    default_protocol="raydium",
    default_pair="USX-USDC",
    widgets=[
        WidgetConfig("kpi-swap-volume-24h", "24h Swap Volume", "kpi", "panel panel-kpi swaps-slot-kpi-a1"),
        WidgetConfig("kpi-swap-count-24h", "24h Swap Count", "kpi", "panel panel-kpi swaps-slot-kpi-b1"),
        WidgetConfig("kpi-price-min-max", "Price Max/Min", "kpi", "panel panel-kpi swaps-slot-kpi-a2"),
        WidgetConfig("kpi-vwap-buy-sell", "VWAP Buy / Sell", "kpi", "panel panel-kpi swaps-slot-kpi-b2"),
        WidgetConfig("kpi-price-std-dev", "Price Std. Dev", "kpi", "panel panel-kpi swaps-slot-kpi-a3"),
        WidgetConfig("kpi-vwap-spread", "VWAP Spread (bps)", "kpi", "panel panel-kpi swaps-slot-kpi-b3"),
        WidgetConfig("kpi-largest-usx-sell", "Largest USX Sell Trade & Est. Current Impact", "kpi", "panel panel-kpi swaps-slot-kpi-a4"),
        WidgetConfig("kpi-largest-usx-buy", "Largest USX Buy Trade & Est. Current Impact", "kpi", "panel panel-kpi swaps-slot-kpi-b4"),
        WidgetConfig("kpi-max-1h-sell-pressure", "Max. 1hr. USX Sell Pressure & Est. Current Impact", "kpi", "panel panel-kpi swaps-slot-kpi-a5"),
        WidgetConfig("kpi-max-1h-buy-pressure", "Max. 1hr. USX Buy Pressure & Est. Current Impact", "kpi", "panel panel-kpi swaps-slot-kpi-b5"),
        WidgetConfig("swaps-flows-toggle", "Swap Flows + Count", "chart", "panel panel-medium swaps-slot-right-top"),
        WidgetConfig("swaps-price-impacts", "Swap Price Impacts", "chart", "panel panel-medium swaps-slot-right-bottom"),
        WidgetConfig("swaps-spread-volatility", "Spread + Volatility", "chart", "panel panel-medium swaps-slot-mid-1",
                     tooltip="Spread values are only reported for intervals in which both buy and sell trades are present."),
        WidgetConfig("swaps-ohlcv", "OHLCV", "chart", "panel panel-medium swaps-slot-mid-2"),
        WidgetConfig("swaps-distribution-toggle", "Swap Distribution", "chart", "panel panel-medium swaps-slot-mid-3",
                     tooltip="Distribution of sell swaps by trade size, along with cumulative percentiles for each size based on all swaps in the sample. A straight line on the impact curve indicates that liquidity depth is consistent across the price range to which swaps of these sizes would reprice."),
        WidgetConfig("swaps-ranked-events", "10 Largest Buy/Sell Swaps for USX", "table-split", "panel panel-wide-table swaps-slot-bottom", expandable=False),
    ],
)
