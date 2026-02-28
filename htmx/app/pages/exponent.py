from __future__ import annotations

from app.pages.common import PageAction, PageConfig, WidgetConfig


PAGE_CONFIG = PageConfig(
    slug="exponent-yield",
    label="Exponent Yield",
    api_page_id="exponent",
    show_protocol_pair_filters=False,
    show_market_selectors=True,
    page_actions=[
        PageAction("exponent-explainer", "Protocol Explainer", icon="book", modal_kind="html"),
        PageAction("exponent-market-assets", "Market Assets", icon="grid", modal_kind="table", endpoint="exponent-market-assets"),
    ],
    widgets=[
        # ── Row 1-3: Pie chart (left) + 4 KPIs (right, 2x2) ──
        WidgetConfig("exponent-pie-tvl", "Exponent TVL (Vault + AMM) by Market", "chart", "panel panel-large exp-slot-pie",
                     expandable=False),
        WidgetConfig("kpi-base-token-yield", "Base Token Yield (rolling 7d basis)", "kpi", "panel panel-kpi exp-slot-kpi-a1",
                     tooltip="Uses Exponent\u2019s internal protocol accounting to calculate the annualized yield of the base token over a rolling 7-day window."),
        WidgetConfig("kpi-locked-base-tokens", "Locked Base Tokens", "kpi", "panel panel-kpi exp-slot-kpi-b1",
                     tooltip="The quantity of base tokens held in escrow to mint wrapped SY derivative tokens."),
        WidgetConfig("kpi-current-fixed-yield", "Current Fixed Yield Price", "kpi", "panel panel-kpi exp-slot-kpi-a2",
                     tooltip="The spot annualized fixed yield priced by the market. Derived from the PT/SY price and the remaining time to maturity."),
        WidgetConfig("kpi-sy-base-collateral", "SY-Base Token Collateralization", "kpi", "panel panel-kpi exp-slot-kpi-b2",
                     tooltip="The ratio of base tokens to SY tokens. If less than 1, there is insufficient collateral backing for SY claims (not expected under normal operation)."),

        # ── Row 4-6: Timeline chart (left) + 4 KPIs (right, 2x2) ──
        WidgetConfig("exponent-timeline", "Market Duration", "chart", "panel panel-large exp-slot-timeline",
                     tooltip="Timeline showing the operating periods for different vaults and markets.",
                     expandable=False),
        WidgetConfig("kpi-fixed-variable-spread", "Fixed-Variable Rate Spread (vs. 7day rate)", "kpi", "panel panel-kpi exp-slot-kpi-a3",
                     tooltip="The difference between the spot annualized fixed yield and the underlying variable rate, annualized from yields over a trailing 7-day window."),
        WidgetConfig("kpi-sy-coll-ratio", "SY Collateralization Ratio", "kpi", "panel panel-kpi exp-slot-kpi-b3",
                     tooltip="The ratio of SY tokens held in market escrow relative to all protocol-accounted claims on SY. If less than 1, there is insufficient collateral backing for SY claims (not expected under normal operation)."),
        WidgetConfig("kpi-yt-staked-share", "Share of YT Staked", "kpi", "panel panel-kpi exp-slot-kpi-a4",
                     tooltip="The share of outstanding YT that is staked to enable holders to receive variable yield prior to maturity without needing to exit by converting back into SY."),
        WidgetConfig("kpi-amm-depth", "AMM Market Depth (in SY)", "kpi", "panel panel-kpi exp-slot-kpi-b4",
                     tooltip="The total amount of PT and SY deployed as liquidity in the trading pool, valued in current SY units."),

        # ── Row 7: 4 KPIs full-width ──
        WidgetConfig("kpi-pt-base-price", "PT / Base Price", "kpi", "panel panel-kpi exp-slot-kpi-c1",
                     tooltip="The spot price of PT in base token units. Mapping this price to a fixed yield requires accounting for time to maturity."),
        WidgetConfig("kpi-apy-impact-pt-trade", "APY Change from Buy PT Trade", "kpi", "panel panel-kpi exp-slot-kpi-c2",
                     tooltip="The impact of a PT trade on the fixed-rate APY. This is measured as an absolute change in yield, not a percentage change."),
        WidgetConfig("kpi-pt-vol-24h", "PT Trading Volume last 24hrs", "kpi", "panel panel-kpi exp-slot-kpi-c3",
                     tooltip="PT bought and sold over the past 24 hours on each market\u2019s AMM."),
        WidgetConfig("kpi-amm-deployment-ratio", "AMM Deployment Ratio", "kpi", "panel panel-kpi exp-slot-kpi-c4",
                     tooltip="The fraction of total base-token value deployed as liquidity in the yield-trading AMM, measured on a current SY-value basis."),

        # ── Row 8: Market info blocks ──
        WidgetConfig("exponent-market-info-mkt1", "Market 1", "kpi", "panel panel-kpi exp-slot-info-mkt1"),
        WidgetConfig("exponent-market-info-mkt2", "Market 2", "kpi", "panel panel-kpi exp-slot-info-mkt2"),

        # ── Rows 9-11: PT Swap Flows & Swap Count ──
        WidgetConfig("exponent-pt-swap-flows-mkt1", "PT Swap Flows & Swap Count", "chart", "panel panel-large exp-slot-chart-left-1",
                     tooltip="PT bought and sold on the AMM over time, alongside total swap count per bucket."),
        WidgetConfig("exponent-pt-swap-flows-mkt2", "PT Swap Flows & Swap Count", "chart", "panel panel-large exp-slot-chart-right-1",
                     tooltip="PT bought and sold on the AMM over time, alongside total swap count per bucket."),

        # ── Rows 12-14: Token Strip Flows & Balance ──
        WidgetConfig("exponent-token-strip-flows-mkt1", "Market Vault Balance and SY Merge and Strip Flows", "chart", "panel panel-large exp-slot-chart-left-2",
                     tooltip="The quantity of SY locked to mint PT-YT pairs and its change over time. This measures capital flowing into and out of fixed and variable yield positions."),
        WidgetConfig("exponent-token-strip-flows-mkt2", "Market Vault Balance and SY Merge and Strip Flows", "chart", "panel panel-large exp-slot-chart-right-2",
                     tooltip="The quantity of SY locked to mint PT-YT pairs and its change over time. This measures capital flowing into and out of fixed and variable yield positions."),

        # ── Rows 15-17: Vault SY Balance & Claims ──
        WidgetConfig("exponent-vault-sy-balance-mkt1", "Market Vault SY Balance and Claims", "chart", "panel panel-large exp-slot-chart-left-3",
                     tooltip="The evolution of claims on SY locked in the market vault into the portion used to fulfil claims on interest, and the portion that is held available to redeem PT+SY pairs (or PT alone post maturity)."),
        WidgetConfig("exponent-vault-sy-balance-mkt2", "Market Vault SY Balance and Claims", "chart", "panel panel-large exp-slot-chart-right-3",
                     tooltip="The evolution of claims on SY locked in the market vault into the portion used to fulfil claims on interest, and the portion that is held available to redeem PT+SY pairs (or PT alone post maturity)."),

        # ── Rows 18-20: Share of YT Staked vs Unclaimed SY ──
        WidgetConfig("exponent-yt-staked-mkt1", "Share of YT Staked vs Unclaimed SY", "chart", "panel panel-large exp-slot-chart-left-4",
                     tooltip="The portion of total YT issued that is staked to earn yield prior to maturity, and the balance of SY that is claimable as yield but not yet collected."),
        WidgetConfig("exponent-yt-staked-mkt2", "Share of YT Staked vs Unclaimed SY", "chart", "panel panel-large exp-slot-chart-right-4",
                     tooltip="The portion of total YT issued that is staked to earn yield prior to maturity, and the balance of SY that is claimable as yield but not yet collected."),

        # ── Rows 21-23: Yield Trading Liquidity ──
        WidgetConfig("exponent-yield-trading-liq-mkt1", "Yield Trading Liquidity (in SY)", "chart", "panel panel-large exp-slot-chart-left-5",
                     tooltip="Total AMM liquidity over time, measured in SY units. Also shows the share of the trading inventory supplied by SY and PT."),
        WidgetConfig("exponent-yield-trading-liq-mkt2", "Yield Trading Liquidity (in SY)", "chart", "panel panel-large exp-slot-chart-right-5",
                     tooltip="Total AMM liquidity over time, measured in SY units. Also shows the share of the trading inventory supplied by SY and PT."),

        # ── Rows 24-26: Realized Underlying Rates ──
        WidgetConfig("exponent-realized-rates-mkt1", "Variable Yield On Underlying", "chart", "panel panel-large exp-slot-chart-left-6",
                     tooltip="The annualized yield on the base asset measured over rolling time windows. \u201cVault life\u201d shows yield since market creation. \u201cAll time\u201d shows yield since the SY token was first minted."),
        WidgetConfig("exponent-realized-rates-mkt2", "Variable Yield On Underlying", "chart", "panel panel-large exp-slot-chart-right-6",
                     tooltip="The annualized yield on the base asset measured over rolling time windows. \u201cVault life\u201d shows yield since market creation. \u201cAll time\u201d shows yield since the SY token was first minted."),

        # ── Rows 27-29: Fixed vs Variable Rate Divergence ──
        WidgetConfig("exponent-divergence-mkt1", "Fixed vs. 7d Variable Rates and Spread", "chart", "panel panel-large exp-slot-chart-left-7",
                     tooltip="The variable underlying rate calculated using a 7-day trailing window, and the spread between this variable rate and the fixed rate. Positive spreads imply that safety is expensive \u2014 consistent with expectations of falling future variable yields, elevated perceived risk, or strong demand for principal protection. Negative spreads imply that speculation is expensive \u2014 consistent with bullish expectations for underlying yields or increased risk tolerance relative to current market pricing."),
        WidgetConfig("exponent-divergence-mkt2", "Fixed vs. 7d Variable Rates and Spread", "chart", "panel panel-large exp-slot-chart-right-7",
                     tooltip="The variable underlying rate calculated using a 7-day trailing window, and the spread between this variable rate and the fixed rate. Positive spreads imply that safety is expensive \u2014 consistent with expectations of falling future variable yields, elevated perceived risk, or strong demand for principal protection. Negative spreads imply that speculation is expensive \u2014 consistent with bullish expectations for underlying yields or increased risk tolerance relative to current market pricing."),
    ],
)
