from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


PAGE_CONFIG = PageConfig(
    slug="global-ecosystem",
    label="Ecosystem",
    api_page_id="global-ecosystem",
    show_protocol_pair_filters=False,
    widgets=[
        # ── Row 1: ONyc TVL by Protocol (full-width horizontal bar) ──
        WidgetConfig(
            "ge-tvl-bar",
            "ONyc TVL by Protocol",
            "chart",
            "panel panel-large ge-slot-full-1",
            expandable=True,
            tooltip="Total tracked ONyc across DeFi protocols: DEXes, Kamino Lending, "
            "and Exponent. Shows absolute ONyc deployed in each protocol.",
        ),

        # ── Row 2: TVL Distribution pie + TVL Over Time ──
        WidgetConfig(
            "ge-tvl-pie",
            "ONyc TVL Distribution",
            "chart",
            "panel panel-large ge-slot-left-1",
            expandable=False,
            tooltip="Percentage distribution of tracked ONyc across protocols: "
            "DEXes, Kamino, and Exponent.",
        ),
        WidgetConfig(
            "ge-tvl-time",
            "ONyc TVL Over Time",
            "chart",
            "panel panel-large ge-slot-right-1",
            expandable=True,
            tooltip="Stacked area showing ONyc deployed across DeFi protocols over time.",
        ),

        # ── Row 3: Current Yields + Yields Over Time ──
        WidgetConfig(
            "ge-current-yields",
            "Current Yields",
            "chart",
            "panel panel-large ge-slot-left-2",
            expandable=False,
            tooltip="Current annualized yields: Kamino ONyc Supply APY and "
            "Exponent depth-weighted implied APY.",
        ),
        WidgetConfig(
            "ge-yields-vs-time",
            "Yields Over Time",
            "chart",
            "panel panel-large ge-slot-right-2",
            expandable=True,
            tooltip="Time series of Kamino supply APY and Exponent implied APY for ONyc.",
        ),

        # ── Row 4: TVL Share % + Activity Distribution Pie ──
        WidgetConfig(
            "ge-tvl-share",
            "TVL Share by Protocol (%)",
            "chart",
            "panel panel-large ge-slot-left-3",
            expandable=True,
            tooltip="Percentage of tracked ONyc deployed in each DeFi protocol over time.",
        ),
        WidgetConfig(
            "ge-activity-pct",
            "Monitored Activity Volumes (%)",
            "chart",
            "panel panel-large ge-slot-right-3",
            expandable=False,
            tooltip="Share of total ONyc protocol activity by protocol: "
            "DEXes, Kamino, and Exponent.",
        ),

        # ── Row 5: Activity Volume + Activity Share over time ──
        WidgetConfig(
            "ge-activity-vol",
            "Activity Volume vs. Time",
            "chart",
            "panel panel-large ge-slot-left-4",
            expandable=True,
            tooltip="Stacked bar chart showing absolute ONyc activity volumes "
            "by protocol over time.",
        ),
        WidgetConfig(
            "ge-activity-share",
            "Share of Activity Volume vs. Time",
            "chart",
            "panel panel-large ge-slot-right-4",
            expandable=True,
            tooltip="100% stacked area showing each protocol's share of total "
            "ONyc activity over time.",
        ),
    ],
)
