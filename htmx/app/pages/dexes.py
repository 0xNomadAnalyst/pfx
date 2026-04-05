from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig

_LIQ = "playbook-liquidity"
_SWP = "dex-swaps"


def _liq(wid, title, kind, css, proto, *, expandable=True, tooltip="", source_widget_id=""):
    return WidgetConfig(
        f"{proto}-{wid}", title, kind, css,
        expandable=expandable, tooltip=tooltip,
        source_page_id=_LIQ,
        source_widget_id=source_widget_id or wid,
        protocol_override=proto,
    )


def _swp(wid, title, kind, css, proto, *, expandable=True, tooltip="", source_widget_id=""):
    return WidgetConfig(
        f"{proto}-{wid}", title, kind, css,
        expandable=expandable, tooltip=tooltip,
        source_page_id=_SWP,
        source_widget_id=source_widget_id or wid,
        protocol_override=proto,
    )


def _hdr(wid, title, css):
    return WidgetConfig(wid, title, "section-header", css)


def _sub(wid, title, css, proto):
    return WidgetConfig(wid, title, "section-subheader", css, protocol_override=proto)


PAGE_CONFIG = PageConfig(
    slug="dexes",
    label="DEX Pools",
    api_page_id="dexes",
    show_asset_filter=True,
    default_asset="ONyc",
    show_pipeline_switcher=True,
    show_price_basis_filter=True,
    video_guide_youtube_id="5p5nsW3Vxtg",
    widgets=[
        # ═══════════════════════════════════════════════════════
        # Section 1: LIQUIDITY METRICS (KPIs)
        # ═══════════════════════════════════════════════════════
        _hdr("dx-hdr-1", "Liquidity Metrics", "dx-hdr-1 cv-section-header"),
        _sub("dx-sub-left-1", "Orca", "dx-sub-left-1 dx-sub-left", "orca"),
        _sub("dx-sub-right-1", "Raydium", "dx-sub-right-1 dx-sub-right", "ray"),

        _liq("kpi-tvl",            "TVL in USDC units",                    "kpi", "panel panel-kpi dx-orca-kpi-a1", "orca"),
        _liq("kpi-impact-500k",    "500,000 USX Sell Impact",              "kpi", "panel panel-kpi dx-orca-kpi-b1", "orca"),
        _liq("kpi-reserves",       "Reserve Balances",                     "kpi", "panel panel-kpi dx-orca-kpi-a2", "orca"),
        _liq("kpi-largest-impact", "Current Impact of Max. USX Sell",      "kpi", "panel panel-kpi dx-orca-kpi-b2", "orca"),
        _liq("kpi-pool-balance",   "Pool Balance",                         "kpi", "panel panel-kpi dx-orca-kpi-a3", "orca"),
        _liq("kpi-average-impact", "Current Impact of Avg. USX Sell",      "kpi", "panel panel-kpi dx-orca-kpi-b3", "orca"),

        _liq("kpi-tvl",            "TVL in USDC units",                    "kpi", "panel panel-kpi dx-ray-kpi-a1", "ray"),
        _liq("kpi-impact-500k",    "500,000 USX Sell Impact",              "kpi", "panel panel-kpi dx-ray-kpi-b1", "ray"),
        _liq("kpi-reserves",       "Reserve Balances",                     "kpi", "panel panel-kpi dx-ray-kpi-a2", "ray"),
        _liq("kpi-largest-impact", "Current Impact of Max. USX Sell",      "kpi", "panel panel-kpi dx-ray-kpi-b2", "ray"),
        _liq("kpi-pool-balance",   "Pool Balance",                         "kpi", "panel panel-kpi dx-ray-kpi-a3", "ray"),
        _liq("kpi-average-impact", "Current Impact of Avg. USX Sell",      "kpi", "panel panel-kpi dx-ray-kpi-b3", "ray"),

        # ═══════════════════════════════════════════════════════
        # Section 2: CURRENT LIQUIDITY
        # ═══════════════════════════════════════════════════════
        _hdr("dx-hdr-2", "Current Liquidity", "dx-hdr-2 cv-section-header"),
        _sub("dx-sub-left-2", "Orca", "dx-sub-left-2 dx-sub-left", "orca"),
        _sub("dx-sub-right-2", "Raydium", "dx-sub-right-2 dx-sub-right", "ray"),

        _liq("liquidity-distribution",   "Liquidity Distribution",   "chart", "panel panel-medium dx-orca-liq-1", "orca"),
        _liq("liquidity-depth",          "Liquidity Depth",          "chart", "panel panel-medium dx-orca-liq-2", "orca"),
        _liq("liquidity-change-heatmap", "Liquidity Change Heatmap", "chart", "panel panel-medium dx-orca-liq-3", "orca"),
        _liq("liquidity-depth-table",    "Liquidity Depth Table",    "table", "panel panel-wide-table dx-orca-liq-4", "orca", expandable=False),

        _liq("liquidity-distribution",   "Liquidity Distribution",   "chart", "panel panel-medium dx-ray-liq-1", "ray"),
        _liq("liquidity-depth",          "Liquidity Depth",          "chart", "panel panel-medium dx-ray-liq-2", "ray"),
        _liq("liquidity-change-heatmap", "Liquidity Change Heatmap", "chart", "panel panel-medium dx-ray-liq-3", "ray"),
        _liq("liquidity-depth-table",    "Liquidity Depth Table",    "table", "panel panel-wide-table dx-ray-liq-4", "ray", expandable=False),

        # ═══════════════════════════════════════════════════════
        # Section 3: LIQUIDITY TRENDS
        # ═══════════════════════════════════════════════════════
        _hdr("dx-hdr-3", "Liquidity Trends", "dx-hdr-3 cv-section-header"),
        _sub("dx-sub-left-3", "Orca", "dx-sub-left-3 dx-sub-left", "orca"),
        _sub("dx-sub-right-3", "Raydium", "dx-sub-right-3 dx-sub-right", "ray"),

        _liq("usdc-pool-share-concentration", "USDC Pool Share",  "chart", "panel panel-medium dx-orca-trend-1", "orca",
             tooltip="Share of pool liquidity held as USDC, and share of total liquidity resources found within +/- 5bps of peg."),
        _liq("trade-impact-toggle",           "Trade Impact",     "chart", "panel panel-medium dx-orca-trend-2", "orca"),
        _liq("usdc-lp-flows",                 "USDC LP Flows",    "chart", "panel panel-medium dx-orca-trend-3", "orca"),
        _liq("ranked-lp-events", "10 Largest LP changes In and Out (USDC)", "table-split", "panel panel-wide-table dx-orca-trend-4", "orca", expandable=False),

        _liq("usdc-pool-share-concentration", "USDC Pool Share",  "chart", "panel panel-medium dx-ray-trend-1", "ray",
             tooltip="Share of pool liquidity held as USDC, and share of total liquidity resources found within +/- 5bps of peg."),
        _liq("trade-impact-toggle",           "Trade Impact",     "chart", "panel panel-medium dx-ray-trend-2", "ray"),
        _liq("usdc-lp-flows",                 "USDC LP Flows",    "chart", "panel panel-medium dx-ray-trend-3", "ray"),
        _liq("ranked-lp-events", "10 Largest LP changes In and Out (USDC)", "table-split", "panel panel-wide-table dx-ray-trend-4", "ray", expandable=False),

        # ═══════════════════════════════════════════════════════
        # Section 4: SWAP METRICS (KPIs)
        # ═══════════════════════════════════════════════════════
        _hdr("dx-hdr-4", "Swap Metrics", "dx-hdr-4 cv-section-header"),
        _sub("dx-sub-left-4", "Orca", "dx-sub-left-4 dx-sub-left", "orca"),
        _sub("dx-sub-right-4", "Raydium", "dx-sub-right-4 dx-sub-right", "ray"),

        _swp("kpi-swap-volume-24h",    "24h Swap Volume",                                          "kpi", "panel panel-kpi dx-orca-skpi-a1", "orca"),
        _swp("kpi-swap-count-24h",     "24h Swap Count",                                           "kpi", "panel panel-kpi dx-orca-skpi-b1", "orca"),
        _swp("kpi-price-min-max",      "Price Max/Min",                                            "kpi", "panel panel-kpi dx-orca-skpi-a2", "orca"),
        _swp("kpi-vwap-buy-sell",      "VWAP Buy / Sell",                                          "kpi", "panel panel-kpi dx-orca-skpi-b2", "orca"),
        _swp("kpi-price-std-dev",      "Price Std. Dev",                                           "kpi", "panel panel-kpi dx-orca-skpi-a3", "orca"),
        _swp("kpi-vwap-spread",        "VWAP Spread (bps)",                                        "kpi", "panel panel-kpi dx-orca-skpi-b3", "orca"),
        _swp("kpi-largest-usx-buy",    "Largest USX Buy Trade & Est. Current Impact",               "kpi", "panel panel-kpi dx-orca-skpi-a4", "orca"),
        _swp("kpi-largest-usx-sell",   "Largest USX Sell Trade & Est. Current Impact",              "kpi", "panel panel-kpi dx-orca-skpi-b4", "orca"),
        _swp("kpi-max-1h-buy-pressure",  "Max. 1hr. USX Buy Pressure & Est. Current Impact",       "kpi", "panel panel-kpi dx-orca-skpi-a5", "orca"),
        _swp("kpi-max-1h-sell-pressure", "Max. 1hr. USX Sell Pressure & Est. Current Impact",      "kpi", "panel panel-kpi dx-orca-skpi-b5", "orca"),

        _swp("kpi-swap-volume-24h",    "24h Swap Volume",                                          "kpi", "panel panel-kpi dx-ray-skpi-a1", "ray"),
        _swp("kpi-swap-count-24h",     "24h Swap Count",                                           "kpi", "panel panel-kpi dx-ray-skpi-b1", "ray"),
        _swp("kpi-price-min-max",      "Price Max/Min",                                            "kpi", "panel panel-kpi dx-ray-skpi-a2", "ray"),
        _swp("kpi-vwap-buy-sell",      "VWAP Buy / Sell",                                          "kpi", "panel panel-kpi dx-ray-skpi-b2", "ray"),
        _swp("kpi-price-std-dev",      "Price Std. Dev",                                           "kpi", "panel panel-kpi dx-ray-skpi-a3", "ray"),
        _swp("kpi-vwap-spread",        "VWAP Spread (bps)",                                        "kpi", "panel panel-kpi dx-ray-skpi-b3", "ray"),
        _swp("kpi-largest-usx-buy",    "Largest USX Buy Trade & Est. Current Impact",               "kpi", "panel panel-kpi dx-ray-skpi-a4", "ray"),
        _swp("kpi-largest-usx-sell",   "Largest USX Sell Trade & Est. Current Impact",              "kpi", "panel panel-kpi dx-ray-skpi-b4", "ray"),
        _swp("kpi-max-1h-buy-pressure",  "Max. 1hr. USX Buy Pressure & Est. Current Impact",       "kpi", "panel panel-kpi dx-ray-skpi-a5", "ray"),
        _swp("kpi-max-1h-sell-pressure", "Max. 1hr. USX Sell Pressure & Est. Current Impact",      "kpi", "panel panel-kpi dx-ray-skpi-b5", "ray"),

        # ═══════════════════════════════════════════════════════
        # Section 5: PRICE TRENDS
        # ═══════════════════════════════════════════════════════
        _hdr("dx-hdr-5", "Price Trends", "dx-hdr-5 cv-section-header"),
        _sub("dx-sub-left-5", "Orca", "dx-sub-left-5 dx-sub-left", "orca"),
        _sub("dx-sub-right-5", "Raydium", "dx-sub-right-5 dx-sub-right", "ray"),

        _swp("swaps-ohlcv",            "Candlestick Chart",    "chart", "panel panel-medium dx-orca-price-1", "orca"),
        _swp("swaps-flows-toggle",     "Swap Flows + Count",   "chart", "panel panel-medium dx-orca-price-2", "orca"),
        _swp("swaps-price-impacts",    "Swap Price Impacts",   "chart", "panel panel-medium dx-orca-price-3", "orca"),
        _swp("swaps-spread-volatility", "Spread + Volatility", "chart", "panel panel-medium dx-orca-price-4", "orca",
             tooltip="Spread values are only reported for intervals in which both buy and sell trades are present."),

        _swp("swaps-ohlcv",            "Candlestick Chart",    "chart", "panel panel-medium dx-ray-price-1", "ray"),
        _swp("swaps-flows-toggle",     "Swap Flows + Count",   "chart", "panel panel-medium dx-ray-price-2", "ray"),
        _swp("swaps-price-impacts",    "Swap Price Impacts",   "chart", "panel panel-medium dx-ray-price-3", "ray"),
        _swp("swaps-spread-volatility", "Spread + Volatility", "chart", "panel panel-medium dx-ray-price-4", "ray",
             tooltip="Spread values are only reported for intervals in which both buy and sell trades are present."),

        # ═══════════════════════════════════════════════════════
        # Section 6: EVENT DISTRIBUTION ANALYSIS
        # ═══════════════════════════════════════════════════════
        _hdr("dx-hdr-6", "Event Distribution Analysis", "dx-hdr-6 cv-section-header"),
        _sub("dx-sub-left-6", "Orca", "dx-sub-left-6 dx-sub-left", "orca"),
        _sub("dx-sub-right-6", "Raydium", "dx-sub-right-6 dx-sub-right", "ray"),

        _swp("swaps-distribution-toggle", "Downside Event Distribution", "chart", "panel panel-medium dx-orca-dist-1", "orca",
             tooltip="Distribution of sell swaps by trade size, along with cumulative percentiles for each size based on all swaps in the sample. A straight line on the impact curve indicates that liquidity depth is consistent across the price range to which swaps of these sizes would reprice."),
        _swp("swaps-ranked-events", "10 Largest Buy/Sell Swaps for USX", "table-split", "panel panel-wide-table dx-orca-dist-2", "orca", expandable=False),

        _swp("swaps-distribution-toggle", "Downside Event Distribution", "chart", "panel panel-medium dx-ray-dist-1", "ray",
             tooltip="Distribution of sell swaps by trade size, along with cumulative percentiles for each size based on all swaps in the sample. A straight line on the impact curve indicates that liquidity depth is consistent across the price range to which swaps of these sizes would reprice."),
        _swp("swaps-ranked-events", "10 Largest Buy/Sell Swaps for USX", "table-split", "panel panel-wide-table dx-ray-dist-2", "ray", expandable=False),
    ],
)
