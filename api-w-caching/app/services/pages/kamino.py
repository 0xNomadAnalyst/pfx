from __future__ import annotations

from typing import Any

from app.services.pages.base import BasePageService


class KaminoPageService(BasePageService):
    page_id = "kamino"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._handlers = {
            "kpi-utilization-all": self._kpi_utilization_all,
            "kpi-loan-value": self._kpi_loan_value,
            "kpi-obligations-count": self._kpi_obligations_count,
            "kpi-collateral-value": self._kpi_collateral_value,
            "kpi-unhealthy-share": self._kpi_unhealthy_share,
            "kpi-bad-share": self._kpi_bad_share,
            "kpi-weighted-ltv": self._kpi_weighted_ltv,
            "kpi-weighted-hf": self._kpi_weighted_hf,
            "kpi-zero-use-count": self._kpi_zero_use_count,
            "kpi-zero-use-capacity": self._kpi_zero_use_capacity,
            "kpi-stress-risk-50": self._kpi_stress_risk_50,
            "kpi-stress-liquidatable-50": self._kpi_stress_liquidatable_50,
            "kamino-config-table": self._kamino_config_table,
            "kamino-supply-collateral-status": self._kamino_supply_collateral_status,
            "kamino-utilization-timeseries": self._kamino_utilization_timeseries,
            "kamino-rate-curve": self._kamino_rate_curve,
            "kamino-ltv-hf-timeseries": self._kamino_ltv_hf_timeseries,
            "kamino-liability-flows": self._kamino_liability_flows,
            "kamino-liquidations": self._kamino_liquidations,
            "kamino-stress-debt": self._kamino_stress_debt,
            "kamino-sensitivity-table": self._kamino_sensitivity_table,
            "kamino-obligation-watchlist": self._kamino_obligation_watchlist,
        }

    @staticmethod
    def _window_interval(last_window: str) -> str:
        mapping = {
            "1h": "1 hour",
            "4h": "4 hours",
            "6h": "6 hours",
            "24h": "24 hours",
            "7d": "7 days",
            "30d": "30 days",
            "90d": "90 days",
        }
        return mapping.get(str(last_window or "7d").lower(), "7 days")

    @staticmethod
    def _bucket_interval(last_window: str) -> str:
        mapping = {
            "1h": "1 minute",
            "4h": "5 minutes",
            "6h": "5 minutes",
            "24h": "15 minutes",
            "7d": "1 hour",
            "30d": "4 hours",
            "90d": "12 hours",
        }
        return mapping.get(str(last_window or "7d").lower(), "1 hour")

    def _v_last_row(self) -> dict[str, Any]:
        def _load() -> dict[str, Any]:
            rows = self.sql.fetch_rows("SELECT * FROM kamino_lend.v_last LIMIT 1")
            return rows[0] if rows else {}

        return self._cached("kamino::v_last", _load, ttl_seconds=15.0)

    def _v_config_row(self) -> dict[str, Any]:
        def _load() -> dict[str, Any]:
            rows = self.sql.fetch_rows("SELECT * FROM kamino_lend.v_config LIMIT 1")
            return rows[0] if rows else {}

        return self._cached("kamino::v_config", _load, ttl_seconds=30.0)

    def _rate_curve_rows(self) -> list[dict[str, Any]]:
        return self._cached("kamino::v_rate_curve_usx", lambda: self.sql.fetch_rows("SELECT * FROM kamino_lend.v_rate_curve_usx"))

    def _timeseries_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        last_window = str(params.get("last_window", "7d"))
        lookback = self._window_interval(last_window)
        bucket_interval = self._bucket_interval(last_window)
        cache_key = f"kamino::timeseries::{last_window}"

        def _load() -> list[dict[str, Any]]:
            query = """
                SELECT *
                FROM kamino_lend.get_view_klend_timeseries(
                    %s,
                    NOW() - %s::interval,
                    NOW()
                )
                ORDER BY bucket_time
            """
            return self.sql.fetch_rows(query, (bucket_interval, lookback))

        return self._cached(cache_key, _load, ttl_seconds=20.0)

    def _sensitivity_rows(self) -> list[dict[str, Any]]:
        return self._cached(
            "kamino::sensitivities",
            lambda: self.sql.fetch_rows(
                "SELECT * FROM kamino_lend.get_view_klend_sensitivities(NULL, -25, 20, 25, 10, FALSE) ORDER BY step_number"
            ),
            ttl_seconds=30.0,
        )

    def _obligation_rows(self, rows: int = 20, page: int = 1) -> list[dict[str, Any]]:
        offset = max(page - 1, 0) * rows
        cache_key = f"kamino::obligations::{rows}::{offset}"

        def _load() -> list[dict[str, Any]]:
            query = """
                SELECT *
                FROM kamino_lend.get_view_klend_obligations(
                    NOW(),
                    'risk_priority',
                    'asc',
                    NULL,
                    FALSE
                )
                OFFSET %s LIMIT %s
            """
            return self.sql.fetch_rows(query, (offset, rows))

        return self._cached(cache_key, _load, ttl_seconds=20.0)

    def _kpi_utilization_all(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("reserve_brw_all_utilization_pct"), "secondary": "%"}

    def _kpi_loan_value(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("reserve_brw_all_borrowed")}

    def _kpi_obligations_count(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("obl_debt_borrow_nonzero_count")}

    def _kpi_collateral_value(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("reserve_coll_all_collateral")}

    def _kpi_unhealthy_share(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("obl_debt_total_unhealthy_pct"), "secondary": "%"}

    def _kpi_bad_share(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("obl_debt_total_bad_pct"), "secondary": "%"}

    def _kpi_weighted_ltv(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("obl_ltv_weighted_avg_sig"), "secondary": "%"}

    def _kpi_weighted_hf(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("obl_hf_weighted_avg_sig")}

    def _kpi_zero_use_count(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("obl_debt_borrow_zero_use_count")}

    def _kpi_zero_use_capacity(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("obl_debt_borrow_zero_use_capacity")}

    def _kpi_stress_risk_50(self, _: dict[str, Any]) -> dict[str, Any]:
        row = next((item for item in self._sensitivity_rows() if abs(float(item.get("bps_change") or 0)) == 50), {})
        return {"kind": "kpi", "primary": row.get("total_at_risk_debt")}

    def _kpi_stress_liquidatable_50(self, _: dict[str, Any]) -> dict[str, Any]:
        row = next((item for item in self._sensitivity_rows() if abs(float(item.get("bps_change") or 0)) == 50), {})
        return {"kind": "kpi", "primary": row.get("total_liquidatable_value")}

    @staticmethod
    def _join_symbols(symbols: Any) -> str:
        items = [str(item) for item in (symbols or []) if item not in (None, "")]
        return " / ".join(items)

    @staticmethod
    def _format_value(value: Any) -> str:
        if isinstance(value, list):
            return " / ".join(str(item) for item in value)
        return "" if value is None else str(value)

    def _kamino_config_table(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_config_row()
        borrow_symbols = self._join_symbols(row.get("reserve_brw_all_symbols_array"))
        collateral_symbols = self._join_symbols(row.get("reserve_coll_all_symbols_array"))

        rows = [
            {"term": "Quote Currency", "units": "symbol / address", "value": self._format_value(row.get("market_quote_currency"))},
            {"term": "User Borrow Limits", "units": "quote curr. units", "value": self._format_value(row.get("market_user_borrow_limit"))},
            {
                "term": "Risk Weight for Loan LTV",
                "units": f"%, {borrow_symbols}" if borrow_symbols else "%",
                "value": self._format_value(row.get("reserve_brw_all_risk_weight_array")),
            },
            {
                "term": "General New Loan LTV",
                "units": f"%, {collateral_symbols}" if collateral_symbols else "%",
                "value": self._format_value(row.get("reserve_coll_all_ltv_new_loan_array")),
            },
            {
                "term": "Unhealthy Threshold LTV",
                "units": f"%, {collateral_symbols}" if collateral_symbols else "%",
                "value": self._format_value(row.get("reserve_coll_all_ltv_unhealthy_array")),
            },
            {"term": "Bad Debt Threshold LTV", "units": "%", "value": self._format_value(row.get("market_ltv_bad"))},
            {
                "term": "Unhealthy Loan Share Liquidatable",
                "units": "%",
                "value": self._format_value(row.get("market_liquidatable_unhealthy_share")),
            },
            {"term": "Small Loans Fully Liquidatable", "units": "quote curr. units", "value": self._format_value(row.get("market_liquidatable_small_loan_full"))},
            {"term": "Max Amount Liquidatable [Any]", "units": "quote curr. units", "value": self._format_value(row.get("market_liquidatable_max_value"))},
            {
                "term": "Min Liquidation Fee",
                "units": f"bps, {borrow_symbols}" if borrow_symbols else "bps",
                "value": self._format_value(row.get("reserve_brw_all_liquidation_fee_unhealthy_min_array")),
            },
            {
                "term": "Max Liquidation Fee",
                "units": f"bps, {borrow_symbols}" if borrow_symbols else "bps",
                "value": self._format_value(row.get("reserve_brw_all_liquidation_fee_unhealthy_max_array")),
            },
            {
                "term": "Bad Debt Liquidation Bonus",
                "units": f"bps, {borrow_symbols}" if borrow_symbols else "bps",
                "value": self._format_value(row.get("reserve_brw_all_liquidation_fee_bad_array")),
            },
            {
                "term": "Aggregate Deposit Cap",
                "units": f"tokens, {borrow_symbols}" if borrow_symbols else "tokens",
                "value": self._format_value(row.get("reserve_brw_all_deposit_max_limit_array")),
            },
            {
                "term": "Aggregate Borrow Cap",
                "units": f"tokens, {borrow_symbols}" if borrow_symbols else "tokens",
                "value": self._format_value(row.get("reserve_brw_all_borrow_max_limit_array")),
            },
            {
                "term": "Deposit & Redeem Caps [24hr]",
                "units": f"tokens, {borrow_symbols}" if borrow_symbols else "tokens",
                "value": self._format_value(row.get("reserve_brw_all_withdrawal_cap_24hr_array")),
            },
            {
                "term": "Borrow & Repay Cap [24hr]",
                "units": f"tokens, {borrow_symbols}" if borrow_symbols else "tokens",
                "value": self._format_value(row.get("reserve_brw_all_borrow_cap_24hr_array")),
            },
            {
                "term": "Market Utilization Limit",
                "units": f"%, {borrow_symbols}" if borrow_symbols else "%",
                "value": self._format_value(row.get("reserve_brw_all_utilization_borrow_limit_array")),
            },
        ]
        return {
            "kind": "table",
            "columns": [
                {"key": "term", "label": "Lending Market Terms & Config"},
                {"key": "units", "label": "Units"},
                {"key": "value", "label": "Value"},
            ],
            "rows": rows,
        }

    def _kamino_supply_collateral_status(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "chart",
            "chart": "bar",
            "x": ["Collateral", "Lend Assets"],
            "series": [
                {
                    "name": "Liquidatable",
                    "type": "bar",
                    "stack": "status",
                    "data": [row.get("obl_liquidatable_value"), None],
                },
                {
                    "name": "Healthy Collateral",
                    "type": "bar",
                    "stack": "status",
                    "data": [row.get("reserve_coll_all_collateral_less_liquidatable_mktval"), None],
                },
                {
                    "name": "Bad Debt",
                    "type": "bar",
                    "stack": "status",
                    "data": [None, row.get("obl_debt_total_bad")],
                },
                {
                    "name": "Unhealthy Debt",
                    "type": "bar",
                    "stack": "status",
                    "data": [None, row.get("obl_debt_total_unhealthy")],
                },
                {
                    "name": "Borrowed (Healthy)",
                    "type": "bar",
                    "stack": "status",
                    "data": [None, row.get("reserve_brw_all_borrowed_less_debt_at_risk_mktval")],
                },
                {
                    "name": "Available",
                    "type": "bar",
                    "stack": "status",
                    "data": [None, row.get("reserve_brw_all_available_mktval")],
                },
            ],
        }

    def _kamino_utilization_timeseries(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "series": [
                {"name": "Borrowed", "type": "bar", "data": [row.get("reserve_brw_all_borrowed_mktvalue") for row in rows]},
                {"name": "Available", "type": "bar", "data": [row.get("reserve_brw_all_available_mktvalue") for row in rows]},
                {"name": "Total Supply", "type": "line", "data": [row.get("reserve_brw_all_supply_total_mktvalue") for row in rows]},
                {"name": "Utilization %", "type": "line", "yAxisIndex": 1, "data": [row.get("reserve_brw_all_utilization_pct") for row in rows]},
            ],
        }

    def _kamino_rate_curve(self, _: dict[str, Any]) -> dict[str, Any]:
        rows = self._rate_curve_rows()
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row.get("utilization_rate_pct") for row in rows],
            "series": [{"name": "Borrow Rate %", "type": "line", "showSymbol": True, "symbolSize": 5, "data": [row.get("borrow_rate_pct") for row in rows]}],
        }

    def _kamino_ltv_hf_timeseries(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "series": [
                {"name": "Loan Wtd Avg LTV", "type": "line", "data": [row.get("obl_loan_ltv_wtd_avg_pct") for row in rows]},
                {"name": "Loan Median LTV", "type": "line", "data": [row.get("obl_loan_ltv_median_pct") for row in rows]},
                {"name": "Loan Wtd Avg HF", "type": "line", "yAxisIndex": 1, "data": [row.get("obl_loan_hf_wtd_avg") for row in rows]},
            ],
        }

    def _kamino_liability_flows(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "series": [
                {"name": "Deposits", "type": "bar", "data": [row.get("reserve_brw_all_deposit_sum") for row in rows]},
                {"name": "Repays", "type": "bar", "data": [row.get("reserve_brw_all_repay_sum") for row in rows]},
                {"name": "Liquidations", "type": "bar", "data": [row.get("reserve_brw_all_liquidate_sum") for row in rows]},
                {"name": "Withdraws", "type": "bar", "data": [-(abs(float(row.get("reserve_brw_all_withdraw_sum") or 0))) for row in rows]},
                {"name": "Borrows", "type": "bar", "data": [-(abs(float(row.get("reserve_brw_all_borrow_sum") or 0))) for row in rows]},
                {"name": "Net Flow", "type": "line", "data": [row.get("reserve_brw_all_net_flow") for row in rows]},
            ],
        }

    def _kamino_liquidations(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "series": [
                {"name": "Liquidation Flow", "type": "bar", "data": [row.get("reserve_brw_all_liquidate_sum") for row in rows]},
                {"name": "Liquidation % At-Risk", "type": "line", "yAxisIndex": 1, "data": [row.get("reserve_brw_all_liquidate_sum_pct_at_risk") for row in rows]},
            ],
        }

    def _kamino_stress_debt(self, _: dict[str, Any]) -> dict[str, Any]:
        rows = sorted(self._sensitivity_rows(), key=lambda item: float(item.get("pct_change") or 0))
        return {
            "kind": "chart",
            "chart": "line-area",
            "x": [row.get("pct_change") for row in rows],
            "series": [
                {"name": "Bad Debt (Net)", "type": "line", "area": True, "data": [row.get("bad_debt_less_liquidatable_part") for row in rows]},
                {"name": "Unhealthy Debt (Net)", "type": "line", "area": True, "data": [row.get("unhealthy_debt_less_liquidatable_part") for row in rows]},
                {"name": "Liquidatable Value", "type": "line", "area": True, "data": [row.get("total_liquidatable_value") for row in rows]},
            ],
        }

    def _kamino_sensitivity_table(self, _: dict[str, Any]) -> dict[str, Any]:
        rows = self._sensitivity_rows()
        return {
            "kind": "table",
            "columns": [
                {"key": "pct_change", "label": "Price Change (%)"},
                {"key": "total_borrows", "label": "Total Debt"},
                {"key": "total_deposits", "label": "Total Collateral"},
                {"key": "unhealthy_debt", "label": "Unhealthy Debt"},
                {"key": "bad_debt", "label": "Bad Debt"},
                {"key": "total_liquidatable_value", "label": "Liquidatable Value"},
                {"key": "liquidation_distance_to_healthy", "label": "Liquidations to HF=1"},
            ],
            "rows": rows,
        }

    def _kamino_obligation_watchlist(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = int(params.get("rows", 20))
        page = int(params.get("page", 1))
        data = self._obligation_rows(rows=rows, page=page)
        return {
            "kind": "table",
            "columns": [
                {"key": "obligation_address", "label": "Account ID"},
                {"key": "loan_value_total", "label": "Loan Value"},
                {"key": "loan_value_total_pct_debt", "label": "% Total Debt"},
                {"key": "collateral_value_total", "label": "Collateral Value"},
                {"key": "ltv_pct", "label": "LTV (%)"},
                {"key": "liquidation_buffer_pct", "label": "Liquidation Buffer (%)"},
                {"key": "health_factor", "label": "HF"},
                {"key": "status", "label": "Status"},
            ],
            "rows": data,
        }
