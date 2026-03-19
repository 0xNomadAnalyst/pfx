from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


def _hdr(wid, title, css):
    return WidgetConfig(wid, title, "section-header", css)


def _sub(wid, title, css, proto):
    return WidgetConfig(wid, title, "section-subheader", css, protocol_override=proto)


PAGE_CONFIG = PageConfig(
    slug="risk-analysis",
    label="Risk Analysis",
    api_page_id="risk-analysis",
    show_protocol_pair_filters=False,
    show_pipeline_switcher=False,
    show_price_basis_filter=True,
    video_guide_youtube_id="ky5vsKgcEK0",
    widgets=[
        # ═══════════════════════════════════════════════════════
        # Section 1: DOWNSIDE PRICE RISK - DEX EVENTS
        # ═══════════════════════════════════════════════════════
        _hdr("ra-hdr-dex", "Downside Price Risk - Dex Events", "ra-hdr-1 cv-section-header"),

        WidgetConfig(
            "ra-pvalue-tables",
            "Extreme Sell Events",
            "table-split",
            "panel panel-wide-table ra-slot-tables",
            expandable=False,
            tooltip="Percentile statistics for extreme sell events on Raydium and Orca pools.",
        ),

        _sub("ra-sub-left-1", "Orca", "ra-sub-left-1 ra-sub-left", "orca"),
        _sub("ra-sub-right-1", "Raydium", "ra-sub-right-1 ra-sub-right", "ray"),

        WidgetConfig(
            "ra-liq-dist-orca",
            "Liquidity Distribution",
            "chart",
            "panel panel-medium ra-slot-s1-left-1",
            tooltip="Tick-level liquidity profile for the Orca pool with "
            "vertical reference lines at p-value sell impact prices.",
        ),
        WidgetConfig(
            "ra-liq-dist-ray",
            "Liquidity Distribution",
            "chart",
            "panel panel-medium ra-slot-s1-right-1",
            tooltip="Tick-level liquidity profile for the Raydium pool with "
            "vertical reference lines at p-value sell impact prices.",
        ),

        WidgetConfig(
            "ra-liq-depth-orca",
            "Liquidity Depth",
            "chart",
            "panel panel-medium ra-slot-s1-left-2",
            tooltip="Cumulative liquidity depth for the Orca pool with "
            "vertical reference lines at p-value sell impact prices.",
        ),
        WidgetConfig(
            "ra-liq-depth-ray",
            "Liquidity Depth",
            "chart",
            "panel panel-medium ra-slot-s1-right-2",
            tooltip="Cumulative liquidity depth for the Raydium pool with "
            "vertical reference lines at p-value sell impact prices.",
        ),

        WidgetConfig(
            "ra-prob-orca",
            "Downside Move Probability",
            "chart",
            "panel panel-medium ra-slot-s1-left-3",
            tooltip="Probability of a downside price move of at least the indicated "
            "magnitude, derived from historical sell event percentiles and current "
            "liquidity depth on Orca.",
        ),
        WidgetConfig(
            "ra-prob-ray",
            "Downside Move Probability",
            "chart",
            "panel panel-medium ra-slot-s1-right-3",
            tooltip="Probability of a downside price move of at least the indicated "
            "magnitude, derived from historical sell event percentiles and current "
            "liquidity depth on Raydium.",
        ),

        # ═══════════════════════════════════════════════════════
        # Section 2: DOWNSIDE PRICE RISK - CROSS-PROTOCOL EVENTS
        # ═══════════════════════════════════════════════════════
        _hdr("ra-hdr-xp", "Downside Price Risk - Cross-Protocol Events", "ra-hdr-2 cv-section-header"),

        WidgetConfig(
            "ra-xp-exposure",
            "Cross-Protocol Exposure",
            "kpi",
            "panel panel-kpi ra-slot-s2-exposure",
            tooltip="Summary of ONyc deployed in Kamino and Exponent that could "
            "generate sell pressure on DEX pools if liquidated.",
        ),

        _sub("ra-sub-left-2", "Orca", "ra-sub-left-2 ra-sub-left", "orca"),
        _sub("ra-sub-right-2", "Raydium", "ra-sub-right-2 ra-sub-right", "ray"),

        WidgetConfig(
            "ra-xp-dist-orca",
            "Liquidity Distribution",
            "chart",
            "panel panel-medium ra-slot-s2-left-1",
            tooltip="Orca liquidity distribution with reference lines showing the "
            "price impact if a fraction of Kamino/Exponent deployment were liquidated.",
        ),
        WidgetConfig(
            "ra-xp-dist-ray",
            "Liquidity Distribution",
            "chart",
            "panel panel-medium ra-slot-s2-right-1",
            tooltip="Raydium liquidity distribution with reference lines showing the "
            "price impact if a fraction of Kamino/Exponent deployment were liquidated.",
        ),

        WidgetConfig(
            "ra-xp-depth-orca",
            "Liquidity Depth",
            "chart",
            "panel panel-medium ra-slot-s2-left-2",
            tooltip="Orca liquidity depth with reference lines showing the "
            "price impact if a fraction of Kamino/Exponent deployment were liquidated.",
        ),
        WidgetConfig(
            "ra-xp-depth-ray",
            "Liquidity Depth",
            "chart",
            "panel panel-medium ra-slot-s2-right-2",
            tooltip="Raydium liquidity depth with reference lines showing the "
            "price impact if a fraction of Kamino/Exponent deployment were liquidated.",
        ),

        # ═══════════════════════════════════════════════════════
        # Section 3: LENDING MARKET LIQUIDATIONS RISK
        # ═══════════════════════════════════════════════════════
        _hdr("ra-hdr-lending", "Lending Market Liquidations Risk", "ra-hdr-3 cv-section-header"),

        WidgetConfig(
            "ra-stress-test",
            "Stress Test: Total Debt At-Risk",
            "chart",
            "panel panel-large ra-slot-s3-full",
            detail_table_id="ra-sensitivity-table",
            tooltip="Examines how much the value of liabilities would need to rise, "
            "or collateral would need to fall, before debt becomes unhealthy. "
            "Filter by collateral and debt assets to isolate specific risk exposures.",
        ),

        WidgetConfig(
            "ra-cascade",
            "Liquidation Cascade Amplification",
            "chart",
            "panel panel-large ra-slot-s3-cascade",
            tooltip="Second-order effects of collateral liquidation on DEX pools. "
            "Shows how sell pressure from liquidations pushes collateral prices down "
            "further, potentially triggering additional liquidations. "
            "Protocol mode uses per-obligation liquidation mechanics with bonus "
            "gross-up; heuristic mode uses aggregate sensitivity curves. "
            "Uses the collateral/debt filters from the stress test above.",
        ),
    ],
)
