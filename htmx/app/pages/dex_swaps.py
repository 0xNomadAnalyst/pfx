from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


WIDGETS: list[WidgetConfig] = [
    WidgetConfig("kpi-swap-volume-24h", "24h Transaction Volume", "kpi", 30, "panel panel-kpi swaps-slot-kpi-a1"),
    WidgetConfig("kpi-swap-count-24h", "24h Swap Count", "kpi", 30, "panel panel-kpi swaps-slot-kpi-b1"),
    WidgetConfig("kpi-price-min-max", "Price Min/Max", "kpi", 30, "panel panel-kpi swaps-slot-kpi-a2"),
    WidgetConfig("kpi-vwap-buy-sell", "VWAP Buy/Sell", "kpi", 30, "panel panel-kpi swaps-slot-kpi-b2"),
    WidgetConfig("kpi-price-std-dev", "Price Std. Dev", "kpi", 30, "panel panel-kpi swaps-slot-kpi-a3"),
    WidgetConfig("kpi-vwap-spread", "VWAP Spread (bps)", "kpi", 30, "panel panel-kpi swaps-slot-kpi-b3"),
    WidgetConfig("kpi-largest-usx-sell", "Largest USX Sell Trade & Est. Current Impact", "kpi", 30, "panel panel-kpi swaps-slot-kpi-a4"),
    WidgetConfig("kpi-largest-usx-buy", "Largest USX Buy Trade & Est. Current Impact", "kpi", 30, "panel panel-kpi swaps-slot-kpi-b4"),
    WidgetConfig("kpi-max-1h-sell-pressure", "Max. 1hr. USX Sell Pressure & Est. Current Impact", "kpi", 30, "panel panel-kpi swaps-slot-kpi-a5"),
    WidgetConfig("kpi-max-1h-buy-pressure", "Max. 1hr. USX Buy Pressure & Est. Current Impact", "kpi", 30, "panel panel-kpi swaps-slot-kpi-b5"),
    WidgetConfig("swaps-usx-flows-impacts", "USX Swap Flows vs. Max. & Avg. Impacts", "chart", 60, "panel panel-medium swaps-slot-mid-1"),
    WidgetConfig("swaps-usdc-flows-count", "USDC Swap Flows & Swap Count", "chart", 60, "panel panel-medium swaps-slot-mid-2"),
    WidgetConfig("swaps-directional-vwap-spread", "Directional VWAP & Spread", "chart", 60, "panel panel-medium swaps-slot-mid-3"),
    WidgetConfig("swaps-ohlcv", "USX OHLCV (Candles + Volume)", "chart", 60, "panel panel-medium swaps-slot-right-top"),
    WidgetConfig("swaps-distribution-toggle", "Sell Order / Net Sell Pressure Distribution", "chart", 60, "panel panel-medium swaps-slot-right-bottom"),
    WidgetConfig("swaps-ranked-events", "Largest Buy/Sell Swaps for USX", "table", 60, "panel panel-wide-table swaps-slot-bottom"),
]


PAGE_CONFIG = PageConfig(
    slug="dex-swaps",
    label="DEX Swaps",
    api_page_id="dex-swaps",
    widgets=WIDGETS,
    show_protocol_pair_filters=True,
)
