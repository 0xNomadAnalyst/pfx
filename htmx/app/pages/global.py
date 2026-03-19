from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


PAGE_CONFIG = PageConfig(
    slug="global-ecosystem",
    label="Ecosystem",
    api_page_id="global-ecosystem",
    show_protocol_pair_filters=False,
    video_guide_youtube_id="Ktk99W77UWk",
    widgets=[
        # ═══════════════════════════════════════════════════════
        # Section: ISSUANCE
        # ═══════════════════════════════════════════════════════
        WidgetConfig(
            "ge-hdr-issuance", "Issuance", "section-header",
            "ge-hdr-1",
        ),

        WidgetConfig(
            "ge-issuance-bar",
            "Token Supply Outstanding",
            "chart",
            "panel panel-large ge-slot-full-1",
            expandable=True,
            tooltip="ONyc token supply and derivative token supply outstanding. "
            "Shows ONyc circulating supply, Exponent SY (wONyc) supply, "
            "and PT+YT supply aggregated across all maturities, in ONyc terms.",
        ),

        WidgetConfig(
            "ge-issuance-pie",
            "Token Issuance Distribution",
            "chart",
            "panel panel-large ge-slot-left-1",
            expandable=False,
            tooltip="Percentage of ONyc supply wrapped into derivative layers: "
            "unwrapped ONyc, SY (wONyc in ONyc terms), and PT+YT (in ONyc terms).",
        ),
        WidgetConfig(
            "ge-issuance-time",
            "Token Issuance Over Time",
            "chart",
            "panel panel-large ge-slot-right-1",
            expandable=True,
            tooltip="Stacked area showing how derivative token supply "
            "(SY, PT+YT in ONyc terms) has evolved over time.",
        ),

        # ═══════════════════════════════════════════════════════
        # Section: YIELDS
        # ═══════════════════════════════════════════════════════
        WidgetConfig(
            "ge-hdr-yields", "Yields", "section-header",
            "ge-hdr-2",
        ),

        WidgetConfig(
            "ge-current-yields",
            "Current Yields",
            "chart",
            "panel panel-large ge-slot-left-2",
            expandable=False,
            tooltip="Current annualized yields: ONyc base token trailing rates "
            "(24h, 7d, 30d), Kamino borrow APYs for each stablecoin that ONyc "
            "collateral backs, and Exponent depth-weighted implied APY.",
        ),
        WidgetConfig(
            "ge-yields-vs-time",
            "Yields Over Time",
            "chart",
            "panel panel-large ge-slot-right-2",
            expandable=True,
            tooltip="Time series of ONyc base token trailing yield, per-asset "
            "Kamino borrow APYs (USDC, USDG, USDS), and Exponent implied APY.",
        ),

        # ═══════════════════════════════════════════════════════
        # Section: TOKEN AVAILABILITY
        # ═══════════════════════════════════════════════════════
        WidgetConfig(
            "ge-hdr-availability", "Token Availability", "section-header",
            "ge-hdr-3",
        ),

        WidgetConfig(
            "ge-availability-bar",
            "Supply Distribution by Availability",
            "chart",
            "panel panel-large ge-slot-left-3",
            expandable=False,
            tooltip="Current ONyc supply classified by mobility: "
            "Illiquid DeFi (Kamino collateral), "
            "Liquid DeFi (DEX LP + Exponent), "
            "and Free / Undeployed tokens.",
        ),
        WidgetConfig(
            "ge-availability-time",
            "Token Availability Over Time",
            "chart",
            "panel panel-large ge-slot-right-3",
            expandable=True,
            tooltip="100% stacked area showing how ONyc supply is distributed "
            "across availability tiers over time. Uses current total supply "
            "as denominator.",
        ),

        # ═══════════════════════════════════════════════════════
        # Section: TVL & ACTIVITY
        # ═══════════════════════════════════════════════════════
        WidgetConfig(
            "ge-hdr-tvl-activity", "TVL & Activity", "section-header",
            "ge-hdr-4",
        ),

        WidgetConfig(
            "ge-tvl-bar",
            "ONyc TVL by Protocol",
            "chart",
            "panel panel-large ge-slot-left-4",
            expandable=True,
            tooltip="Total tracked ONyc across DeFi protocols: DEXes, Kamino Lending, "
            "and Exponent. Shows absolute ONyc deployed in each protocol.",
        ),
        WidgetConfig(
            "ge-activity-bar",
            "Activity by Protocol",
            "chart",
            "panel panel-large ge-slot-right-4",
            expandable=True,
            tooltip="Monitored ONyc activity volumes by protocol: "
            "DEXes, Kamino, and Exponent. Window adjusts with the time filter.",
        ),

        WidgetConfig(
            "ge-tvl-pie",
            "ONyc TVL Distribution",
            "chart",
            "panel panel-large ge-slot-left-5",
            expandable=False,
            tooltip="Percentage distribution of tracked ONyc across protocols: "
            "DEXes, Kamino, and Exponent.",
        ),
        WidgetConfig(
            "ge-activity-pct",
            "Activity Distribution",
            "chart",
            "panel panel-large ge-slot-right-5",
            expandable=False,
            tooltip="Share of total ONyc protocol activity by protocol: "
            "DEXes, Kamino, and Exponent. Window adjusts with the time filter.",
        ),

        WidgetConfig(
            "ge-tvl-time",
            "ONyc TVL Over Time",
            "chart",
            "panel panel-large ge-slot-left-6",
            expandable=True,
            tooltip="Stacked area showing ONyc deployed across DeFi protocols over time.",
        ),
        WidgetConfig(
            "ge-activity-vol",
            "Activity Volume vs. Time",
            "chart",
            "panel panel-large ge-slot-right-6",
            expandable=True,
            tooltip="Stacked bar chart showing absolute ONyc activity volumes "
            "by protocol over time.",
        ),

        WidgetConfig(
            "ge-tvl-share",
            "TVL Share by Protocol (%)",
            "chart",
            "panel panel-large ge-slot-left-7",
            expandable=True,
            tooltip="Percentage of tracked ONyc deployed in each DeFi protocol over time.",
        ),
        WidgetConfig(
            "ge-activity-share",
            "Share of Activity Volume vs. Time",
            "chart",
            "panel panel-large ge-slot-right-7",
            expandable=True,
            tooltip="100% stacked area showing each protocol's share of total "
            "ONyc activity over time.",
        ),
    ],
)
