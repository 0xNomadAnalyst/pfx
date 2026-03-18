from __future__ import annotations

from app.pages.common import PageAction, PageConfig, WidgetConfig


def _hdr(wid, title, css):
    return WidgetConfig(wid, title, "section-header", css)


def _sub(wid, title, css, proto):
    return WidgetConfig(wid, title, "section-subheader", css, protocol_override=proto)


def _kpi(wid, title, css, *, tooltip="", source_widget_id=""):
    return WidgetConfig(wid, title, "kpi", f"panel panel-kpi {css}",
                        tooltip=tooltip, source_widget_id=source_widget_id)


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
        # ═══════════════════════════════════════════════════════
        # Section 1: SUMMARY METRICS
        # ═══════════════════════════════════════════════════════
        _hdr("exp-hdr-1", "Summary Metrics", "exp-hdr-1 cv-section-header"),

        WidgetConfig("exponent-pie-tvl", "Exponent TVL (Vault + AMM) by Market", "chart", "panel panel-large exp-slot-pie",
                     expandable=False),
        WidgetConfig("exponent-timeline", "Market Duration", "chart", "panel panel-large exp-slot-timeline",
                     tooltip="Timeline showing the operating periods for different vaults and markets.",
                     expandable=False),

        WidgetConfig("exponent-market-info-mkt1", "Market 1", "kpi", "panel panel-kpi exp-slot-info-mkt1"),
        WidgetConfig("exponent-market-info-mkt2", "Market 2", "kpi", "panel panel-kpi exp-slot-info-mkt2"),

        # ═══════════════════════════════════════════════════════
        # Section 2: PROTOCOL CAPITAL FLOWS
        # ═══════════════════════════════════════════════════════
        _hdr("exp-hdr-2", "Protocol Capital Flows", "exp-hdr-2 cv-section-header"),
        _sub("exp-sub-left-2", "Market 1", "exp-sub-left-2 exp-sub-left", "mkt1-sy"),
        _sub("exp-sub-right-2", "Market 2", "exp-sub-right-2 exp-sub-right", "mkt2-sy"),

        _kpi("kpi-locked-base-tokens-mkt1", "Locked Base Tokens", "exp-s2-kpi-left-1",
             tooltip="The quantity of base tokens held in escrow to mint wrapped SY derivative tokens.",
             source_widget_id="kpi-locked-base-tokens"),
        _kpi("kpi-locked-base-tokens-mkt2", "Locked Base Tokens", "exp-s2-kpi-right-1",
             tooltip="The quantity of base tokens held in escrow to mint wrapped SY derivative tokens.",
             source_widget_id="kpi-locked-base-tokens"),

        _kpi("kpi-sy-base-collateral-mkt1", "SY-Base Token Collateralization", "exp-s2-kpi-left-2",
             tooltip="The ratio of base tokens to SY tokens. If less than 1, there is insufficient collateral backing for SY claims (not expected under normal operation).",
             source_widget_id="kpi-sy-base-collateral"),
        _kpi("kpi-sy-base-collateral-mkt2", "SY-Base Token Collateralization", "exp-s2-kpi-right-2",
             tooltip="The ratio of base tokens to SY tokens. If less than 1, there is insufficient collateral backing for SY claims (not expected under normal operation).",
             source_widget_id="kpi-sy-base-collateral"),

        _kpi("kpi-sy-coll-ratio-mkt1", "SY Collateralization Ratio", "exp-s2-kpi-left-3",
             tooltip="The ratio of SY tokens held in market escrow relative to all protocol-accounted claims on SY. If less than 1, there is insufficient collateral backing for SY claims (not expected under normal operation).",
             source_widget_id="kpi-sy-coll-ratio"),
        _kpi("kpi-sy-coll-ratio-mkt2", "SY Collateralization Ratio", "exp-s2-kpi-right-3",
             tooltip="The ratio of SY tokens held in market escrow relative to all protocol-accounted claims on SY. If less than 1, there is insufficient collateral backing for SY claims (not expected under normal operation).",
             source_widget_id="kpi-sy-coll-ratio"),

        WidgetConfig("exponent-token-strip-flows-mkt1", "Market Vault Balance and SY Merge and Strip Flows", "chart", "panel panel-large exp-slot-chart-left-2",
                     tooltip="The quantity of SY locked to mint PT-YT pairs and its change over time. This measures capital flowing into and out of fixed and variable yield positions."),
        WidgetConfig("exponent-token-strip-flows-mkt2", "Market Vault Balance and SY Merge and Strip Flows", "chart", "panel panel-large exp-slot-chart-right-2",
                     tooltip="The quantity of SY locked to mint PT-YT pairs and its change over time. This measures capital flowing into and out of fixed and variable yield positions."),

        WidgetConfig("exponent-vault-sy-balance-mkt1", "Market Vault SY Balance and Claims", "chart", "panel panel-large exp-slot-chart-left-3",
                     tooltip="The evolution of claims on SY locked in the market vault into the portion used to fulfil claims on interest, and the portion that is held available to redeem PT+SY pairs (or PT alone post maturity)."),
        WidgetConfig("exponent-vault-sy-balance-mkt2", "Market Vault SY Balance and Claims", "chart", "panel panel-large exp-slot-chart-right-3",
                     tooltip="The evolution of claims on SY locked in the market vault into the portion used to fulfil claims on interest, and the portion that is held available to redeem PT+SY pairs (or PT alone post maturity)."),

        # ═══════════════════════════════════════════════════════
        # Section 3: STAKING FOR VARIABLE YIELD COLLECTION
        # ═══════════════════════════════════════════════════════
        _hdr("exp-hdr-3", "Staking for Variable Yield Collection", "exp-hdr-3 cv-section-header"),
        _sub("exp-sub-left-3", "Market 1", "exp-sub-left-3 exp-sub-left", "mkt1"),
        _sub("exp-sub-right-3", "Market 2", "exp-sub-right-3 exp-sub-right", "mkt2"),

        _kpi("kpi-yt-staked-share-mkt1", "Share of YT Staked", "exp-s3-kpi-left-1",
             tooltip="The share of outstanding YT that is staked to enable holders to receive variable yield prior to maturity without needing to exit by converting back into SY.",
             source_widget_id="kpi-yt-staked-share"),
        _kpi("kpi-yt-staked-share-mkt2", "Share of YT Staked", "exp-s3-kpi-right-1",
             tooltip="The share of outstanding YT that is staked to enable holders to receive variable yield prior to maturity without needing to exit by converting back into SY.",
             source_widget_id="kpi-yt-staked-share"),

        WidgetConfig("exponent-yt-staked-mkt1", "Share of YT Staked vs Unclaimed SY", "chart", "panel panel-large exp-slot-chart-left-4",
                     tooltip="The portion of total YT issued that is staked to earn yield prior to maturity, and the balance of SY that is claimable as yield but not yet collected."),
        WidgetConfig("exponent-yt-staked-mkt2", "Share of YT Staked vs Unclaimed SY", "chart", "panel panel-large exp-slot-chart-right-4",
                     tooltip="The portion of total YT issued that is staked to earn yield prior to maturity, and the balance of SY that is claimable as yield but not yet collected."),

        # ═══════════════════════════════════════════════════════
        # Section 4: YIELD TRADING ACTIVITY
        # ═══════════════════════════════════════════════════════
        _hdr("exp-hdr-4", "Yield Trading Activity", "exp-hdr-4 cv-section-header"),
        _sub("exp-sub-left-4", "Market 1", "exp-sub-left-4 exp-sub-left", "mkt1"),
        _sub("exp-sub-right-4", "Market 2", "exp-sub-right-4 exp-sub-right", "mkt2"),

        _kpi("kpi-pt-base-price-mkt1", "PT / Base Price", "exp-s4-kpi-left-1",
             tooltip="The spot price of PT in base token units. Approaches 1.0 at maturity. The discount (1 \u2212 ptPrice) represents the fixed yield earned if held to maturity.",
             source_widget_id="kpi-pt-base-price"),
        _kpi("kpi-pt-base-price-mkt2", "PT / Base Price", "exp-s4-kpi-right-1",
             tooltip="The spot price of PT in base token units. Approaches 1.0 at maturity. The discount (1 \u2212 ptPrice) represents the fixed yield earned if held to maturity.",
             source_widget_id="kpi-pt-base-price"),

        _kpi("kpi-pt-vol-24h-mkt1", "PT Trading Volume last 24hrs", "exp-s4-kpi-left-2",
             tooltip="PT bought and sold over the past 24 hours on each market\u2019s AMM.",
             source_widget_id="kpi-pt-vol-24h"),
        _kpi("kpi-pt-vol-24h-mkt2", "PT Trading Volume last 24hrs", "exp-s4-kpi-right-2",
             tooltip="PT bought and sold over the past 24 hours on each market\u2019s AMM.",
             source_widget_id="kpi-pt-vol-24h"),

        _kpi("kpi-apy-impact-pt-trade-mkt1", "APY Change from Buy PT Trade", "exp-s4-kpi-left-3",
             tooltip="The impact of a PT trade on the fixed-rate APY. This is measured as an absolute change in yield, not a percentage change.",
             source_widget_id="kpi-apy-impact-pt-trade"),
        _kpi("kpi-apy-impact-pt-trade-mkt2", "APY Change from Buy PT Trade", "exp-s4-kpi-right-3",
             tooltip="The impact of a PT trade on the fixed-rate APY. This is measured as an absolute change in yield, not a percentage change.",
             source_widget_id="kpi-apy-impact-pt-trade"),

        WidgetConfig("exponent-pt-swap-flows-mkt1", "PT Swap Flows & Swap Count", "chart", "panel panel-large exp-slot-chart-left-1",
                     tooltip="PT bought and sold on the AMM over time, alongside total swap count per bucket."),
        WidgetConfig("exponent-pt-swap-flows-mkt2", "PT Swap Flows & Swap Count", "chart", "panel panel-large exp-slot-chart-right-1",
                     tooltip="PT bought and sold on the AMM over time, alongside total swap count per bucket."),

        # ═══════════════════════════════════════════════════════
        # Section 5: AMM CAPITAL FLOWS
        # ═══════════════════════════════════════════════════════
        _hdr("exp-hdr-5", "AMM Capital Flows", "exp-hdr-5 cv-section-header"),
        _sub("exp-sub-left-5", "Market 1", "exp-sub-left-5 exp-sub-left", "mkt1"),
        _sub("exp-sub-right-5", "Market 2", "exp-sub-right-5 exp-sub-right", "mkt2"),

        _kpi("kpi-amm-depth-mkt1", "AMM Market Depth (in SY)", "exp-s5-kpi-left-1",
             tooltip="The total amount of PT and SY deployed as liquidity in the trading pool, valued in current SY units.",
             source_widget_id="kpi-amm-depth"),
        _kpi("kpi-amm-depth-mkt2", "AMM Market Depth (in SY)", "exp-s5-kpi-right-1",
             tooltip="The total amount of PT and SY deployed as liquidity in the trading pool, valued in current SY units.",
             source_widget_id="kpi-amm-depth"),

        _kpi("kpi-amm-deployment-ratio-mkt1", "AMM Deployment Ratio", "exp-s5-kpi-left-2",
             tooltip="The fraction of total base-token value deployed as liquidity in the yield-trading AMM, measured on a current SY-value basis.",
             source_widget_id="kpi-amm-deployment-ratio"),
        _kpi("kpi-amm-deployment-ratio-mkt2", "AMM Deployment Ratio", "exp-s5-kpi-right-2",
             tooltip="The fraction of total base-token value deployed as liquidity in the yield-trading AMM, measured on a current SY-value basis.",
             source_widget_id="kpi-amm-deployment-ratio"),

        WidgetConfig("exponent-yield-trading-liq-mkt1", "Yield Trading Liquidity (in SY)", "chart", "panel panel-large exp-slot-chart-left-5",
                     tooltip="Total AMM liquidity over time, measured in SY units. Also shows the share of the trading inventory supplied by SY and PT."),
        WidgetConfig("exponent-yield-trading-liq-mkt2", "Yield Trading Liquidity (in SY)", "chart", "panel panel-large exp-slot-chart-right-5",
                     tooltip="Total AMM liquidity over time, measured in SY units. Also shows the share of the trading inventory supplied by SY and PT."),

        # ═══════════════════════════════════════════════════════
        # Section 6: YIELDS ANALYSIS
        # ═══════════════════════════════════════════════════════
        _hdr("exp-hdr-6", "Yields Analysis", "exp-hdr-6 cv-section-header"),
        _sub("exp-sub-left-6", "Market 1", "exp-sub-left-6 exp-sub-left", "mkt1"),
        _sub("exp-sub-right-6", "Market 2", "exp-sub-right-6 exp-sub-right", "mkt2"),

        _kpi("kpi-current-fixed-yield-mkt1", "Current Fixed Yield Price", "exp-s6-kpi-left-1",
             tooltip="The spot annualized fixed yield priced by the market, using simple (linear) annualization: (1/ptPrice \u2212 1) / years_to_maturity. Matches the Exponent web UI convention.",
             source_widget_id="kpi-current-fixed-yield"),
        _kpi("kpi-current-fixed-yield-mkt2", "Current Fixed Yield Price", "exp-s6-kpi-right-1",
             tooltip="The spot annualized fixed yield priced by the market, using simple (linear) annualization: (1/ptPrice \u2212 1) / years_to_maturity. Matches the Exponent web UI convention.",
             source_widget_id="kpi-current-fixed-yield"),

        _kpi("kpi-base-token-yield-mkt1", "Base Token Yield (rolling 7d basis)", "exp-s6-kpi-left-2",
             tooltip="Uses Exponent\u2019s internal protocol accounting to calculate the annualized yield of the base token over a rolling 7-day window.",
             source_widget_id="kpi-base-token-yield"),
        _kpi("kpi-base-token-yield-mkt2", "Base Token Yield (rolling 7d basis)", "exp-s6-kpi-right-2",
             tooltip="Uses Exponent\u2019s internal protocol accounting to calculate the annualized yield of the base token over a rolling 7-day window.",
             source_widget_id="kpi-base-token-yield"),

        _kpi("kpi-fixed-variable-spread-mkt1", "Fixed-Variable Rate Spread (vs. 7day rate)", "exp-s6-kpi-left-3",
             tooltip="The difference between the simple-annualized fixed yield and the underlying variable rate over a trailing 7-day window. Positive = fixed > variable (safety premium); negative = variable > fixed (yield speculation premium).",
             source_widget_id="kpi-fixed-variable-spread"),
        _kpi("kpi-fixed-variable-spread-mkt2", "Fixed-Variable Rate Spread (vs. 7day rate)", "exp-s6-kpi-right-3",
             tooltip="The difference between the simple-annualized fixed yield and the underlying variable rate over a trailing 7-day window. Positive = fixed > variable (safety premium); negative = variable > fixed (yield speculation premium).",
             source_widget_id="kpi-fixed-variable-spread"),

        WidgetConfig("exponent-realized-rates-mkt1", "Variable Yield On Underlying", "chart", "panel panel-large exp-slot-chart-left-6",
                     tooltip="The annualized yield on the base asset measured over rolling time windows. \u201cVault life\u201d shows yield since market creation. \u201cAll time\u201d shows yield since the SY token was first minted."),
        WidgetConfig("exponent-realized-rates-mkt2", "Variable Yield On Underlying", "chart", "panel panel-large exp-slot-chart-right-6",
                     tooltip="The annualized yield on the base asset measured over rolling time windows. \u201cVault life\u201d shows yield since market creation. \u201cAll time\u201d shows yield since the SY token was first minted."),

        WidgetConfig("exponent-divergence-mkt1", "Fixed vs. 7d Variable Rates and Spread", "chart", "panel panel-large exp-slot-chart-left-7",
                     tooltip="The variable underlying rate calculated using a 7-day trailing window, and the spread between this variable rate and the fixed rate. Positive spreads imply that safety is expensive \u2014 consistent with expectations of falling future variable yields, elevated perceived risk, or strong demand for principal protection. Negative spreads imply that speculation is expensive \u2014 consistent with bullish expectations for underlying yields or increased risk tolerance relative to current market pricing."),
        WidgetConfig("exponent-divergence-mkt2", "Fixed vs. 7d Variable Rates and Spread", "chart", "panel panel-large exp-slot-chart-right-7",
                     tooltip="The variable underlying rate calculated using a 7-day trailing window, and the spread between this variable rate and the fixed rate. Positive spreads imply that safety is expensive \u2014 consistent with expectations of falling future variable yields, elevated perceived risk, or strong demand for principal protection. Negative spreads imply that speculation is expensive \u2014 consistent with bullish expectations for underlying yields or increased risk tolerance relative to current market pricing."),
    ],
)
