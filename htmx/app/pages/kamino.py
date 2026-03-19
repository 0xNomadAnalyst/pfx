from __future__ import annotations

from app.pages.common import PageAction, PageConfig, WidgetConfig


def _hdr(wid, title, css):
    return WidgetConfig(wid, title, "section-header", css)


PAGE_CONFIG = PageConfig(
    slug="kamino",
    label="Kamino Lend",
    api_page_id="kamino",
    show_protocol_pair_filters=False,
    video_guide_youtube_id="ky5vsKgcEK0",
    page_actions=[
        PageAction("kamino-explainer", "Protocol Explainer", icon="book", modal_kind="html"),
        PageAction("kamino-market-assets", "Market Assets", icon="grid", modal_kind="table", endpoint="kamino-market-assets"),
        PageAction("kamino-market-terms", "Market Terms", icon="settings", modal_kind="table", endpoint="kamino-config-table"),
    ],
    widgets=[
        # ═══════════════════════════════════════════════════════
        # Section 1: MARKET RESERVES
        # ═══════════════════════════════════════════════════════
        _hdr("km-hdr-1", "Market Reserve Balances", "km-hdr-1 cv-section-header"),

        WidgetConfig("kamino-supply-collateral-status", "Collateral and Borrow Asset Balances & Status", "chart", "panel panel-large km-s1-chart",
                     tooltip="Total collateral and borrow assets tied to this market across all tokens, valued in market currency and broken down by economic, health, and risk status."),
        WidgetConfig("kpi-collateral-value", "Collateral Deposited", "kpi", "panel panel-kpi km-s1-kpi-a",
                     tooltip="The total value of collateral deposited across all obligations and all tokens, valued in market quote currency."),
        WidgetConfig("kpi-loan-value", "Loan Value Outstanding", "kpi", "panel panel-kpi km-s1-kpi-b",
                     tooltip="The total value of debt outstanding across all obligations and all tokens, valued in market quote currency."),
        WidgetConfig("kpi-share-collateral-asset", "Share by Collateral Asset", "kpi", "panel panel-kpi km-s1-kpi-c",
                     tooltip="Share of total collateral value represented by each collateral asset accepted in this market."),
        WidgetConfig("kpi-share-borrow-asset", "Share by Borrow Asset", "kpi", "panel panel-kpi km-s1-kpi-d",
                     tooltip="Share of total outstanding debt represented by each borrow asset in this market."),
        WidgetConfig("kpi-collateral-qty", "Collateral Quantity by Asset", "kpi", "panel panel-kpi km-s1-kpi-e",
                     tooltip="Total token quantity deposited as collateral for each accepted collateral asset, expressed in native token units (rounded to nearest thousand)."),
        WidgetConfig("kpi-borrow-qty", "Borrow Quantity by Asset", "kpi", "panel panel-kpi km-s1-kpi-f",
                     tooltip="Total token quantity outstanding as debt for each borrow asset, expressed in native token units (rounded to nearest thousand)."),

        # ═══════════════════════════════════════════════════════
        # Section 2: UTILIZATION & APY
        # ═══════════════════════════════════════════════════════
        _hdr("km-hdr-2", "Utilization & APY", "km-hdr-2 cv-section-header"),

        WidgetConfig("kamino-rate-curve", "Borrow Rate Curve", "chart", "panel panel-large km-s2-chart",
                     tooltip="Visualizes the protocol\u2019s APY pricing curve and where the utilization of each asset currently lies."),
        WidgetConfig("kpi-utilization-by-reserve", "Utilization Factor by Reserve", "kpi", "panel panel-kpi km-s2-kpi-a",
                     tooltip="The current ratio of borrow assets outstanding vs. total assets supplied. This variable determines supply and borrow APYs and is also a key indicator of available liquidity for withdrawals."),
        WidgetConfig("kpi-borrow-apy", "Current Borrow APY by Asset", "kpi", "panel panel-kpi km-s2-kpi-b",
                     tooltip="The core APY excluding any additional rewards or incentive programs."),
        WidgetConfig("kpi-supply-apy", "Current Supply APY by Asset", "kpi", "panel panel-kpi km-s2-kpi-d",
                     tooltip="The core APY excluding any additional rewards or incentive programs."),

        # ═══════════════════════════════════════════════════════
        # Section 3: DEBT STATUS
        # ═══════════════════════════════════════════════════════
        _hdr("km-hdr-3", "Debt Characteristics", "km-hdr-3 cv-section-header"),

        WidgetConfig("kamino-loan-size-dist", "Loan Size Distribution & Health Factors", "chart", "panel panel-large km-s3-chart",
                     tooltip="Visualises the ranked distribution of obligation debt at market currency value, and HF associated with each one."),
        WidgetConfig("kpi-obligations-debt-size", "Number of Obligations with Debt and Avg.Size", "kpi", "panel panel-kpi km-s3-kpi-a",
                     tooltip="Count of obligations with non-negligible debt and the average debt value held by them."),
        WidgetConfig("kpi-ltv-hf", "Avg. Current Loan LTV / HF", "kpi", "panel panel-kpi km-s3-kpi-b",
                     tooltip="Average LTV and Health Factor (HF) weighted by market value of debt for obligations with debt value \u2265 1 (in market currency). Positions become liquidatable when HF = 1. The health factor is the ratio of the unhealthy borrow limit (based on collateral composition and liquidation thresholds) divided by the borrow-factor-adjusted market value of debt."),
        WidgetConfig("kpi-zero-use-count", "Zero-Use Accounts", "kpi", "panel panel-kpi km-s3-kpi-c",
                     tooltip="The number of accounts with deposits only and no outstanding loans."),
        WidgetConfig("kpi-zero-use-capacity", "Zero-Use Capacity", "kpi", "panel panel-kpi km-s3-kpi-d",
                     tooltip="The total borrowing capacity available to deposit-only accounts."),

        # ═══════════════════════════════════════════════════════
        # Section 4: RISK ANALYSIS
        # ═══════════════════════════════════════════════════════
        _hdr("km-hdr-4", "Liquidation Risk", "km-hdr-4 cv-section-header"),

        WidgetConfig("kamino-stress-debt", "Stress Test: Total Debt At-Risk", "chart", "panel panel-large km-s4-chart", detail_table_id="kamino-sensitivity-table",
                     tooltip="Examines how much the value of liabilities would need to rise, or collateral would need to fall, before debt becomes unhealthy. The fraction of debt that becomes liquidatable is highlighted. If health factors are closer to 1, slopes draw inward. Vertical green dotted lines show 1st and 2nd standard deviations of underlying token price; if these intersect the slopes, ordinary volatility implies plausible liquidation risk."),
        WidgetConfig("kpi-unhealthy-share", "Unhealthy Loans %", "kpi", "panel panel-kpi km-s4-kpi-a",
                     tooltip="Share of total outstanding debt value currently marked as unhealthy."),
        WidgetConfig("kpi-stress-buffer", "Stress Buffer", "kpi", "panel panel-kpi km-s4-kpi-b",
                     source_widget_id="kamino-stress-debt",
                     tooltip="The minimum collateral price decline at which at-risk debt doubles from its current baseline. Derived from the stress test chart."),
        WidgetConfig("kpi-debt-at-risk-1s", "Debt at Risk (1\u03c3)", "kpi", "panel panel-kpi km-s4-kpi-c",
                     source_widget_id="kamino-stress-debt",
                     tooltip="Shows \u20131\u03c3 (downside) / +1\u03c3 (upside) debt at risk. Assumes a uniform price stress is applied simultaneously to all collateral and borrow assets. Derived from stress test chart and historical volatility."),
        WidgetConfig("kpi-debt-at-risk-2s", "Debt at Risk (2\u03c3)", "kpi", "panel panel-kpi km-s4-kpi-d",
                     source_widget_id="kamino-stress-debt",
                     tooltip="Shows \u20132\u03c3 (downside) / +2\u03c3 (upside) debt at risk. Assumes a uniform price stress is applied simultaneously to all collateral and borrow assets. Derived from stress test chart and historical volatility."),

        # ═══════════════════════════════════════════════════════
        # Section 5: TIME SERIES TRENDS
        # ═══════════════════════════════════════════════════════
        _hdr("km-hdr-5", "Activity & Time Series Trends", "km-hdr-5 cv-section-header"),

        WidgetConfig("kamino-utilization-timeseries", "Utilization (timeseries)", "chart", "panel panel-large km-s5-chart-1",
                     tooltip="Time series of all borrow assets supplied and borrowed over time, alongside utilization."),

        WidgetConfig("kamino-ltv-hf-timeseries", "Obligations: Debt-Weighted HF & LTV", "chart", "panel panel-large km-s5-chart-2",
                     tooltip="Shows median and weighted average LTVs, and weighted average HF over time for obligations with debt value \u2265 1."),

        WidgetConfig("kamino-liability-flows", "Loan Market Borrow Asset Flows by Type", "chart", "panel panel-large km-s5-chart-3",
                     tooltip="Monitors all token flows for market reserves, including both borrow and collateral activity."),
        WidgetConfig("kpi-borrow-vol-24h", "24h Borrow Volume by Asset", "kpi", "panel panel-kpi km-s5-kpi-3a"),
        WidgetConfig("kpi-repay-vol-24h", "24h Repay Volume by Asset", "kpi", "panel panel-kpi km-s5-kpi-3b"),
        WidgetConfig("kpi-deposit-vol-24h", "24hr Deposit Volume by Asset", "kpi", "panel panel-kpi km-s5-kpi-3c"),
        WidgetConfig("kpi-withdraw-vol-24h", "24hr Withdraw Volume by Asset", "kpi", "panel panel-kpi km-s5-kpi-3d"),

        WidgetConfig("kamino-liquidations", "Liquidations of Borrow Asset Positions", "chart", "panel panel-large km-s5-chart-4",
                     tooltip="Monitors all liquidations across the market. Under normal conditions, this chart is expected to show little to no activity."),
        WidgetConfig("kpi-days-no-liquidation", "Days without Liquidations", "kpi", "panel panel-kpi km-s5-kpi-4a"),
        WidgetConfig("kpi-liquidation-count-30d", "30d Liquidations Count", "kpi", "panel panel-kpi km-s5-kpi-4b"),
        WidgetConfig("kpi-liquidation-vol-30d", "30d Liquidation Volume", "kpi", "panel panel-kpi km-s5-kpi-4c"),
        WidgetConfig("kpi-liquidation-avg-size", "Average Liquidation Size", "kpi", "panel panel-kpi km-s5-kpi-4d"),

        # ═══════════════════════════════════════════════════════
        # Section 6: CURRENT LOAN BOOK
        # ═══════════════════════════════════════════════════════
        _hdr("km-hdr-6", "Current Loan Book", "km-hdr-6 cv-section-header"),

        WidgetConfig("kamino-obligation-watchlist", "Market Obligations Watchlist", "table", "panel panel-wide-table km-s6-table", expandable=False),
    ],
)
