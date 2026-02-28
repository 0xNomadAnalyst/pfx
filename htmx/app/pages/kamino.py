from __future__ import annotations

from app.pages.common import PageConfig, WidgetConfig


PAGE_CONFIG = PageConfig(
    slug="kamino",
    label="Kamino",
    api_page_id="kamino",
    show_protocol_pair_filters=False,
    widgets=[
        WidgetConfig("kpi-utilization-all", "Aggregate Utilization", "kpi", "panel panel-kpi kamino-slot-kpi-a1"),
        WidgetConfig("kpi-loan-value", "Loan Value Outstanding", "kpi", "panel panel-kpi kamino-slot-kpi-a2"),
        WidgetConfig("kpi-obligations-count", "Obligations with Debt", "kpi", "panel panel-kpi kamino-slot-kpi-a3"),
        WidgetConfig("kpi-collateral-value", "Collateral Deposited", "kpi", "panel panel-kpi kamino-slot-kpi-a4"),
        WidgetConfig("kpi-unhealthy-share", "Unhealthy Debt Share", "kpi", "panel panel-kpi kamino-slot-kpi-a5"),
        WidgetConfig("kpi-bad-share", "Bad Debt Share", "kpi", "panel panel-kpi kamino-slot-kpi-a6"),
        WidgetConfig("kpi-weighted-ltv", "Weighted Avg LTV", "kpi", "panel panel-kpi kamino-slot-kpi-b1"),
        WidgetConfig("kpi-weighted-hf", "Weighted Avg HF", "kpi", "panel panel-kpi kamino-slot-kpi-b2"),
        WidgetConfig("kpi-zero-use-count", "Zero-Use Accounts", "kpi", "panel panel-kpi kamino-slot-kpi-b3"),
        WidgetConfig("kpi-zero-use-capacity", "Zero-Use Capacity", "kpi", "panel panel-kpi kamino-slot-kpi-b4"),
        WidgetConfig("kpi-stress-risk-50", "At-Risk Debt +/-50bps", "kpi", "panel panel-kpi kamino-slot-kpi-b5"),
        WidgetConfig("kpi-stress-liquidatable-50", "Liquidatable +/-50bps", "kpi", "panel panel-kpi kamino-slot-kpi-b6"),
        WidgetConfig("kamino-config-table", "Lending Market Terms & Config", "table", "panel panel-wide-table kamino-slot-config", expandable=False),
        WidgetConfig("kamino-supply-collateral-status", "Collateral and Borrow Asset Balances & Status", "chart", "panel panel-large kamino-slot-main-left"),
        WidgetConfig("kamino-utilization-timeseries", "Utilization (timeseries)", "chart", "panel panel-large kamino-slot-main-mid"),
        WidgetConfig("kamino-rate-curve", "Borrow Rate Curve", "chart", "panel panel-large kamino-slot-main-right"),
        WidgetConfig("kamino-ltv-hf-timeseries", "Obligations: Debt-Weighted HF & LTV", "chart", "panel panel-large kamino-slot-row2-left"),
        WidgetConfig("kamino-liability-flows", "Loan Market Borrow Asset Flows by Type", "chart", "panel panel-large kamino-slot-row2-mid"),
        WidgetConfig("kamino-liquidations", "Liquidations of Borrow Asset Positions", "chart", "panel panel-large kamino-slot-row2-right"),
        WidgetConfig("kamino-stress-debt", "Stress Test: Total Debt At-Risk", "chart", "panel panel-large kamino-slot-row3-left"),
        WidgetConfig("kamino-sensitivity-table", "Stress Test: Full Detail", "table", "panel panel-wide-table kamino-slot-row3-right", expandable=False),
        WidgetConfig("kamino-obligation-watchlist", "Market Obligations Watchlist", "table", "panel panel-wide-table kamino-slot-bottom", expandable=False),
    ],
)
