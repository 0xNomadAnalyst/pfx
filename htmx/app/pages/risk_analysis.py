from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


PAGE_CONFIG = PageConfig(
    slug="risk-analysis",
    label="Risk Analysis",
    api_page_id="risk-analysis",
    show_protocol_pair_filters=False,
    show_pipeline_switcher=False,
    widgets=[
        # ═══════════════════════════════════════════════════════
        # Section 1: DOWNSIDE PRICE RISK - DEX EVENTS
        # ═══════════════════════════════════════════════════════
        WidgetConfig(
            "ra-hdr-dex",
            "Downside Price Risk - Dex Events",
            "section-header",
            "ra-hdr-1",
        ),

        WidgetConfig(
            "ra-pvalue-tables",
            "Extreme Sell Events",
            "table-split",
            "panel panel-wide-table ra-slot-tables",
            expandable=False,
            tooltip="Percentile statistics for extreme sell events on each DEX pool. "
            "Select an event type and interval to compare Raydium and Orca side-by-side.",
        ),

        WidgetConfig(
            "ra-liq-dist-ray",
            "Liquidity Distribution - Raydium",
            "chart",
            "panel panel-medium ra-slot-s1-left-1",
            tooltip="Tick-level liquidity profile for the Raydium pool with "
            "vertical reference lines at p-value sell impact prices.",
        ),
        WidgetConfig(
            "ra-liq-dist-orca",
            "Liquidity Distribution - Orca",
            "chart",
            "panel panel-medium ra-slot-s1-right-1",
            tooltip="Tick-level liquidity profile for the Orca pool with "
            "vertical reference lines at p-value sell impact prices.",
        ),

        WidgetConfig(
            "ra-liq-depth-ray",
            "Liquidity Depth - Raydium",
            "chart",
            "panel panel-medium ra-slot-s1-left-2",
            tooltip="Cumulative liquidity depth for the Raydium pool with "
            "vertical reference lines at p-value sell impact prices.",
        ),
        WidgetConfig(
            "ra-liq-depth-orca",
            "Liquidity Depth - Orca",
            "chart",
            "panel panel-medium ra-slot-s1-right-2",
            tooltip="Cumulative liquidity depth for the Orca pool with "
            "vertical reference lines at p-value sell impact prices.",
        ),

        WidgetConfig(
            "ra-prob-ray",
            "Downside Move Probability - Raydium",
            "chart",
            "panel panel-medium ra-slot-s1-left-3",
            tooltip="Probability of a downside price move of at least the indicated "
            "magnitude, derived from historical sell event percentiles and current "
            "liquidity depth on Raydium.",
        ),
        WidgetConfig(
            "ra-prob-orca",
            "Downside Move Probability - Orca",
            "chart",
            "panel panel-medium ra-slot-s1-right-3",
            tooltip="Probability of a downside price move of at least the indicated "
            "magnitude, derived from historical sell event percentiles and current "
            "liquidity depth on Orca.",
        ),

        # ═══════════════════════════════════════════════════════
        # Section 2: DOWNSIDE PRICE RISK - CROSS-PROTOCOL EVENTS
        # ═══════════════════════════════════════════════════════
        WidgetConfig(
            "ra-hdr-xp",
            "Downside Price Risk - Cross-Protocol Events",
            "section-header",
            "ra-hdr-2",
        ),

        WidgetConfig(
            "ra-xp-exposure",
            "Cross-Protocol Exposure",
            "kpi",
            "panel panel-kpi ra-slot-s2-exposure",
            tooltip="Summary of ONyc deployed in Kamino and Exponent that could "
            "generate sell pressure on DEX pools if liquidated.",
        ),

        WidgetConfig(
            "ra-xp-dist-ray",
            "Liquidity Distribution - Raydium (Cross-Protocol)",
            "chart",
            "panel panel-medium ra-slot-s2-left-1",
            tooltip="Raydium liquidity distribution with reference lines showing the "
            "price impact if a fraction of Kamino/Exponent deployment were liquidated.",
        ),
        WidgetConfig(
            "ra-xp-dist-orca",
            "Liquidity Distribution - Orca (Cross-Protocol)",
            "chart",
            "panel panel-medium ra-slot-s2-right-1",
            tooltip="Orca liquidity distribution with reference lines showing the "
            "price impact if a fraction of Kamino/Exponent deployment were liquidated.",
        ),

        WidgetConfig(
            "ra-xp-depth-ray",
            "Liquidity Depth - Raydium (Cross-Protocol)",
            "chart",
            "panel panel-medium ra-slot-s2-left-2",
            tooltip="Raydium liquidity depth with reference lines showing the "
            "price impact if a fraction of Kamino/Exponent deployment were liquidated.",
        ),
        WidgetConfig(
            "ra-xp-depth-orca",
            "Liquidity Depth - Orca (Cross-Protocol)",
            "chart",
            "panel panel-medium ra-slot-s2-right-2",
            tooltip="Orca liquidity depth with reference lines showing the "
            "price impact if a fraction of Kamino/Exponent deployment were liquidated.",
        ),

        # ═══════════════════════════════════════════════════════
        # Section 3: LENDING MARKET LIQUIDATIONS RISK
        # ═══════════════════════════════════════════════════════
        WidgetConfig(
            "ra-hdr-lending",
            "Lending Market Liquidations Risk",
            "section-header",
            "ra-hdr-3",
        ),

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
    ],
)
