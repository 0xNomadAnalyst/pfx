from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


PAGE_CONFIG = PageConfig(
    slug="global-ecosystem",
    label="Ecosystem",
    api_page_id="global-ecosystem",
    show_protocol_pair_filters=False,
    widgets=[
        # ── Row 1: Asset Issuance horizontal bar (full-width) ──
        WidgetConfig(
            "ge-issuance-bar",
            "Asset Issuance by end-claim on Base Collateral",
            "chart",
            "panel panel-large ge-slot-full-1",
            expandable=True,
            tooltip="Tracks the supply chain from base collateral through to derivative tokens. "
            "Shows collateral AUM, collateral in vaults, total collateral, USX supply, eUSX supply, "
            "SY supply (in USX terms), and PT/YT supply (in USX terms).",
        ),

        # ── Row 2: Issuance pie + Issuance time series ──
        WidgetConfig(
            "ge-issuance-pie",
            "Asset Issuance Distribution",
            "chart",
            "panel panel-large ge-slot-left-1",
            expandable=False,
            tooltip="Percentage distribution of USX supply across derivative layers: "
            "pure USX, pure eUSX, SY (in USX terms), and PT/YT (in USX terms).",
        ),
        WidgetConfig(
            "ge-issuance-time",
            "Asset Issuance Over Time",
            "chart",
            "panel panel-large ge-slot-right-1",
            expandable=True,
            tooltip="Stacked area showing how the percentage distribution of USX across derivative "
            "layers has evolved over time.",
        ),

        # ── Row 3: AUM Yield Generation + Yield Vesting Implied Rate ──
        WidgetConfig(
            "ge-yield-generation",
            "AUM Yield Generation",
            "chart",
            "panel panel-large ge-slot-left-2",
            expandable=True,
            tooltip="Yield pool total assets and shares supply over time, "
            "showing the growth of yield within the eUSX vault.",
        ),
        WidgetConfig(
            "ge-yield-vesting-rate",
            "eUSX Yield Vesting Implied Rate",
            "chart",
            "panel panel-large ge-slot-right-2",
            expandable=True,
            tooltip="Annualized yield rates implied by vested yield amounts over rolling windows. "
            "24h, 7d, and 30d rates derived from actual vesting events.",
        ),

        # ── Row 4: Current Yields table + Yields vs Time ──
        WidgetConfig(
            "ge-current-yields",
            "Current Yields by Asset",
            "chart",
            "panel panel-large ge-slot-left-3",
            expandable=False,
            tooltip="Current annualized yield for each asset class: eUSX Yield Vault (24h/7d/30d), "
            "PT-USX, PT-eUSX (time-to-maturity-weighted), and Kamino USX Supply APY.",
        ),
        WidgetConfig(
            "ge-yields-vs-time",
            "Yields Over Time",
            "chart",
            "panel panel-large ge-slot-right-3",
            expandable=True,
            tooltip="Time series of all yield metrics: eUSX vault yield, PT yields, "
            "and Kamino supply APY.",
        ),

        # ── Row 5: Supply Distribution Pie USX + eUSX ──
        WidgetConfig(
            "ge-supply-dist-usx-pie",
            "USX Supply Distribution",
            "chart",
            "panel panel-large ge-slot-left-4",
            expandable=False,
            tooltip="Percentage of USX deployed across protocols: DEXes, Kamino, "
            "eUSX Yield Vault, Exponent, and untracked remainder.",
        ),
        WidgetConfig(
            "ge-supply-dist-eusx-pie",
            "eUSX Supply Distribution",
            "chart",
            "panel panel-large ge-slot-right-4",
            expandable=False,
            tooltip="Percentage of eUSX deployed across protocols: DEXes, Kamino, "
            "PT-eUSX in Kamino, Exponent, and untracked remainder.",
        ),

        # ── Row 6: Supply Distribution Bar USX + eUSX ──
        WidgetConfig(
            "ge-supply-dist-usx-bar",
            "USX Supply Categories",
            "chart",
            "panel panel-large ge-slot-left-5",
            expandable=False,
            tooltip="USX categorized as: Time-locked (in eUSX vault), "
            "DeFi Deployed (DEXes + Kamino + Exponent), and Free/Unknown.",
        ),
        WidgetConfig(
            "ge-supply-dist-eusx-bar",
            "eUSX Supply Categories",
            "chart",
            "panel panel-large ge-slot-right-5",
            expandable=False,
            tooltip="eUSX categorized as: DeFi Deployed (DEXes + Kamino + PT-eUSX Kamino + Exponent) "
            "and Free/Unknown.",
        ),

        # ── Row 7: Token Availability USX + eUSX ──
        WidgetConfig(
            "ge-token-avail-usx",
            "USX Token Availability",
            "chart",
            "panel panel-large ge-slot-left-6",
            expandable=True,
            tooltip="USX supply breakdown over time: time-locked, DeFi deployed, "
            "and free/unknown categories as stacked area.",
        ),
        WidgetConfig(
            "ge-token-avail-eusx",
            "eUSX Token Availability",
            "chart",
            "panel panel-large ge-slot-right-6",
            expandable=True,
            tooltip="eUSX supply breakdown over time: DeFi deployed and free/unknown "
            "categories as stacked area.",
        ),

        # ── Row 8: TVL by Monitored DeFi USX + eUSX ──
        WidgetConfig(
            "ge-tvl-defi-usx",
            "TVL by Monitored DeFi (USX)",
            "chart",
            "panel panel-large ge-slot-left-7",
            expandable=True,
            tooltip="USX deployed in each DeFi protocol over time: DEXes, Kamino, "
            "eUSX Yield Vault, and Exponent.",
        ),
        WidgetConfig(
            "ge-tvl-defi-eusx",
            "TVL by Monitored DeFi (eUSX)",
            "chart",
            "panel panel-large ge-slot-right-7",
            expandable=True,
            tooltip="eUSX deployed in each DeFi protocol over time: DEXes, Kamino, "
            "PT-eUSX Kamino, and Exponent.",
        ),

        # ── Row 9: TVL Share USX + eUSX ──
        WidgetConfig(
            "ge-tvl-share-usx",
            "TVL Share by DeFi (USX %)",
            "chart",
            "panel panel-large ge-slot-left-8",
            expandable=True,
            tooltip="Percentage of USX supply deployed in each DeFi protocol over time.",
        ),
        WidgetConfig(
            "ge-tvl-share-eusx",
            "TVL Share by DeFi (eUSX %)",
            "chart",
            "panel panel-large ge-slot-right-8",
            expandable=True,
            tooltip="Percentage of eUSX supply deployed in each DeFi protocol over time.",
        ),

        # ── Row 10: Monitored Activity Volumes % (Pie) USX + eUSX ──
        WidgetConfig(
            "ge-activity-pct-usx",
            "Monitored Activity Volumes (USX %)",
            "chart",
            "panel panel-large ge-slot-left-9",
            expandable=False,
            tooltip="Share of total USX protocol activity by protocol: "
            "DEXes, Kamino, Exponent, and eUSX Yield Vault.",
        ),
        WidgetConfig(
            "ge-activity-pct-eusx",
            "Monitored Activity Volumes (eUSX %)",
            "chart",
            "panel panel-large ge-slot-right-9",
            expandable=False,
            tooltip="Share of total eUSX protocol activity by protocol: "
            "DEXes, Kamino, and Exponent.",
        ),

        # ── Row 11: Monitored Activity vs Time (stacked bar) USX + eUSX ──
        WidgetConfig(
            "ge-activity-vol-usx",
            "Monitored Activity vs. Time (USX)",
            "chart",
            "panel panel-large ge-slot-left-10",
            expandable=True,
            tooltip="Stacked bar chart showing absolute USX activity volumes by protocol over time.",
        ),
        WidgetConfig(
            "ge-activity-vol-eusx",
            "Monitored Activity vs. Time (eUSX)",
            "chart",
            "panel panel-large ge-slot-right-10",
            expandable=True,
            tooltip="Stacked bar chart showing absolute eUSX activity volumes by protocol over time.",
        ),

        # ── Row 12: Share of Monitored Activity Volume (100% stacked area) ──
        WidgetConfig(
            "ge-activity-share-usx",
            "Share of Activity Volume vs. Time (USX)",
            "chart",
            "panel panel-large ge-slot-left-11",
            expandable=True,
            tooltip="100% stacked area showing each protocol's share of total USX activity over time.",
        ),
        WidgetConfig(
            "ge-activity-share-eusx",
            "Share of Activity Volume vs. Time (eUSX)",
            "chart",
            "panel panel-large ge-slot-right-11",
            expandable=True,
            tooltip="100% stacked area showing each protocol's share of total eUSX activity over time.",
        ),
    ],
)
