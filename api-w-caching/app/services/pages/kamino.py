from __future__ import annotations

import os
from typing import Any

from app.services.pages.base import BasePageService


class KaminoPageService(BasePageService):
    page_id = "kamino"
    _V_LAST_TTL_SECONDS = float(os.getenv("KAMINO_V_LAST_TTL_SECONDS", "120"))
    _CONFIG_TTL_SECONDS = float(os.getenv("KAMINO_CONFIG_TTL_SECONDS", "300"))
    _RATE_CURVE_TTL_SECONDS = float(os.getenv("KAMINO_RATE_CURVE_TTL_SECONDS", "300"))
    _MARKET_ASSETS_TTL_SECONDS = float(os.getenv("KAMINO_MARKET_ASSETS_TTL_SECONDS", "300"))
    _SENSITIVITY_TTL_SECONDS = float(os.getenv("KAMINO_SENSITIVITY_TTL_SECONDS", "120"))
    _OBLIGATION_TTL_SECONDS = float(os.getenv("KAMINO_OBLIGATION_TTL_SECONDS", "120"))
    _LOAN_SIZE_TTL_SECONDS = float(os.getenv("KAMINO_LOAN_SIZE_TTL_SECONDS", "120"))

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._handlers = {
            # Group 1
            "kpi-utilization-by-reserve": self._kpi_utilization_by_reserve,
            "kpi-loan-value": self._kpi_loan_value,
            "kpi-obligations-debt-size": self._kpi_obligations_debt_size,
            "kpi-share-borrow-asset": self._kpi_share_borrow_asset,
            "kpi-ltv-hf": self._kpi_ltv_hf,
            "kpi-collateral-value": self._kpi_collateral_value,
            "kpi-unhealthy-share": self._kpi_unhealthy_share,
            "kpi-share-collateral-asset": self._kpi_share_collateral_asset,
            # Group 2
            "kpi-zero-use-count": self._kpi_zero_use_count,
            "kpi-zero-use-capacity": self._kpi_zero_use_capacity,
            "kpi-borrow-apy": self._kpi_borrow_apy,
            "kpi-supply-apy": self._kpi_supply_apy,
            # Group 3
            "kpi-borrow-vol-24h": self._kpi_borrow_vol_24h,
            "kpi-repay-vol-24h": self._kpi_repay_vol_24h,
            "kpi-liquidation-vol-30d": self._kpi_liquidation_vol_30d,
            "kpi-liquidation-count-30d": self._kpi_liquidation_count_30d,
            "kpi-withdraw-vol-24h": self._kpi_withdraw_vol_24h,
            "kpi-deposit-vol-24h": self._kpi_deposit_vol_24h,
            "kpi-liquidation-avg-size": self._kpi_liquidation_avg_size,
            "kpi-days-no-liquidation": self._kpi_days_no_liquidation,
            "kamino-config-table": self._kamino_config_table,
            "kamino-market-assets": self._kamino_market_assets,
            "kamino-supply-collateral-status": self._kamino_supply_collateral_status,
            "kamino-utilization-timeseries": self._kamino_utilization_timeseries,
            "kamino-rate-curve": self._kamino_rate_curve,
            "kamino-loan-size-dist": self._kamino_loan_size_dist,
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

        return self._cached("kamino::v_last", _load, ttl_seconds=self._V_LAST_TTL_SECONDS)

    def _v_config_row(self) -> dict[str, Any]:
        def _load() -> dict[str, Any]:
            rows = self.sql.fetch_rows("SELECT * FROM kamino_lend.v_config LIMIT 1")
            return rows[0] if rows else {}

        return self._cached("kamino::v_config", _load, ttl_seconds=self._CONFIG_TTL_SECONDS)

    def _rate_curve_rows(self) -> list[dict[str, Any]]:
        return self._cached(
            "kamino::v_rate_curve_usx",
            lambda: self.sql.fetch_rows("SELECT * FROM kamino_lend.v_rate_curve_usx"),
            ttl_seconds=self._RATE_CURVE_TTL_SECONDS,
        )

    _TIMESERIES_TIMEOUT_MS = 30_000

    def _timeseries_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        last_window = str(params.get("last_window", "7d"))
        cache_key = f"kamino::timeseries::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self._run_timeseries_query(last_window)

        return self._cached(cache_key, _load, ttl_seconds=60.0)

    def _run_timeseries_query(self, last_window: str) -> list[dict[str, Any]]:
        lookback = self._window_interval(last_window)
        bucket_interval = self._bucket_interval(last_window)
        query = """
            SELECT *
            FROM kamino_lend.get_view_klend_timeseries(
                %s,
                NOW() - %s::interval,
                NOW()
            )
            ORDER BY bucket_time
        """
        return self.sql.fetch_rows(
            query, (bucket_interval, lookback),
            statement_timeout_ms=self._TIMESERIES_TIMEOUT_MS,
        )

    def _sensitivity_rows(self) -> list[dict[str, Any]]:
        return self._cached(
            "kamino::sensitivities",
            lambda: self.sql.fetch_rows(
                "SELECT * FROM kamino_lend.get_view_klend_sensitivities(NULL, -50, 25, 50, 25, FALSE) ORDER BY step_number"
            ),
            ttl_seconds=self._SENSITIVITY_TTL_SECONDS,
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

        return self._cached(cache_key, _load, ttl_seconds=self._OBLIGATION_TTL_SECONDS)

    @staticmethod
    def _fmt_array(arr: Any, fmt: str = "number", dp: int = 1) -> str:
        items = list(arr) if isinstance(arr, (list, tuple)) else []
        if not items:
            return "--"
        parts = []
        for v in items:
            if v is None:
                parts.append("--")
            elif fmt == "pct":
                parts.append(f"{float(v):.{dp}f}%")
            elif fmt == "int":
                parts.append(f"{int(round(float(v))):,}")
            else:
                parts.append(f"{float(v):,.{dp}f}")
        return " / ".join(parts)

    @staticmethod
    def _symbols_note(arr: Any) -> str:
        items = [str(s) for s in (arr or []) if s not in (None, "")]
        return ", ".join(items) if items else ""

    # --- Group 1 ---

    def _kpi_utilization_by_reserve(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_utilization_pct_array"), "pct"),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    def _kpi_loan_value(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("reserve_brw_all_borrowed"), "secondary": "Valued in market quote currency"}

    def _kpi_obligations_debt_size(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        count = row.get("obl_debt_borrow_nonzero_count")
        avg = row.get("obl_loan_avg_size")
        parts = []
        if count is not None:
            parts.append(f"{int(count):,}")
        if avg is not None:
            parts.append(f"{int(round(float(avg))):,}")
        return {"kind": "kpi", "primary": " / ".join(parts) or "--", "secondary": "for all loans >= 1"}

    def _kpi_share_borrow_asset(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_shares_pct_array"), "pct"),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    def _kpi_ltv_hf(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        ltv = row.get("obl_ltv_weighted_avg_sig")
        hf = row.get("obl_hf_weighted_avg_sig")
        parts = []
        if ltv is not None:
            parts.append(f"{float(ltv):.1f}%")
        if hf is not None:
            parts.append(f"{float(hf):.2f}")
        return {"kind": "kpi", "primary": " / ".join(parts) or "--", "secondary": "for all loans >= 1"}

    def _kpi_collateral_value(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("reserve_coll_all_collateral"), "secondary": "Valued in market quote currency"}

    def _kpi_unhealthy_share(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        val = row.get("obl_debt_total_unhealthy_pct")
        display = f"{float(val):.2f}%" if val is not None else "--"
        return {"kind": "kpi", "primary": display, "secondary": "Portion of all debt marked as unhealthy"}

    def _kpi_share_collateral_asset(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_coll_all_shares_pct_array"), "pct"),
            "secondary": self._symbols_note(row.get("reserve_coll_all_symbols_array")),
        }

    # --- Group 2 ---

    def _kpi_zero_use_count(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("obl_debt_borrow_zero_use_count"), "secondary": "Accounts with collateral but borrowing < 1"}

    def _kpi_zero_use_capacity(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {"kind": "kpi", "primary": row.get("obl_debt_borrow_zero_use_capacity"), "secondary": "Borrowable value for zero-use accounts"}

    def _kpi_borrow_apy(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_borrow_apy_array"), "pct", dp=2),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    def _kpi_supply_apy(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_supply_apy_array"), "pct", dp=2),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    # --- Group 3 ---

    def _kpi_borrow_vol_24h(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_borrow_vol_24h_array"), "int"),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    def _kpi_repay_vol_24h(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_repay_vol_24h_array"), "int"),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    def _kpi_liquidation_vol_30d(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_liquidated_vol_30d_array"), "int"),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    def _kpi_liquidation_count_30d(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_liquidated_count_30d_array"), "int"),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    def _kpi_withdraw_vol_24h(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_withdraw_vol_24h_array"), "int"),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    def _kpi_deposit_vol_24h(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_deposit_vol_24h_array"), "int"),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    def _kpi_liquidation_avg_size(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("reserve_brw_all_liquidated_avg_size_array"), "int"),
            "secondary": self._symbols_note(row.get("reserve_brw_all_symbols_array")),
        }

    def _kpi_days_no_liquidation(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        val = row.get("last_liquidation_days_ago")
        display = "N/A" if val is None else str(int(val))
        return {"kind": "kpi", "primary": display, "secondary": "All"}

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
                {"key": "term", "label": "Item"},
                {"key": "units", "label": "Units"},
                {"key": "value", "label": "Value"},
            ],
            "rows": rows,
        }

    def _kamino_market_assets(self, _: dict[str, Any]) -> dict[str, Any]:
        def _load() -> list[dict[str, Any]]:
            return self.sql.fetch_rows("SELECT * FROM kamino_lend.v_market_assets")

        rows_raw = self._cached("kamino::market_assets", _load, ttl_seconds=self._MARKET_ASSETS_TTL_SECONDS)
        rows = []
        for r in rows_raw:
            rows.append({
                "symbol": r.get("token_symbol", ""),
                "role": (r.get("reserve_type") or "").title(),
                "status": r.get("reserve_status", ""),
                "ltv_pct": self._format_value(r.get("loan_to_value_pct")),
                "liq_threshold_pct": self._format_value(r.get("liquidation_threshold_pct")),
                "borrow_factor_pct": self._format_value(r.get("borrow_factor_pct")),
                "available": self._format_value(r.get("available_tokens")),
                "borrowed": self._format_value(r.get("borrowed_tokens")),
                "total_supply": self._format_value(r.get("total_supply")),
                "utilization": self._format_value(r.get("utilization_pct")),
                "supply_apy": self._format_value(r.get("supply_apy_pct")),
                "borrow_apy": self._format_value(r.get("borrow_apy_pct")),
                "reserve_address": r.get("reserve_address", ""),
                "token_mint": r.get("token_mint", ""),
            })
        return {
            "kind": "table",
            "columns": [
                {"key": "symbol", "label": "Symbol"},
                {"key": "role", "label": "Role"},
                {"key": "status", "label": "Status"},
                {"key": "ltv_pct", "label": "LTV %"},
                {"key": "liq_threshold_pct", "label": "Liq Threshold %"},
                {"key": "borrow_factor_pct", "label": "Borrow Factor %"},
                {"key": "available", "label": "Available"},
                {"key": "borrowed", "label": "Borrowed"},
                {"key": "total_supply", "label": "Total Supply"},
                {"key": "utilization", "label": "Util %"},
                {"key": "supply_apy", "label": "Supply APY %"},
                {"key": "borrow_apy", "label": "Borrow APY %"},
                {"key": "reserve_address", "label": "Reserve Address"},
                {"key": "token_mint", "label": "Token Mint"},
            ],
            "rows": rows,
        }

    def _kamino_supply_collateral_status(self, _: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row()
        return {
            "kind": "chart",
            "chart": "bar-horizontal",
            "x": ["Loan Assets", "Collateral"],
            "barWidth": 38,
            "legend_groups": [
                {"title": "Collateral", "items": ["Healthy", "Liquidatable"]},
                {"title": "Loan Assets", "items": ["Borrowed", "Available/Unused", "Unhealthy Debt", "Bad Debt"]},
            ],
            "series": [
                {
                    "name": "Healthy",
                    "type": "bar",
                    "stack": "status",
                    "color": "#4bb7ff",
                    "data": [None, row.get("reserve_coll_all_collateral_less_liquidatable_mktval")],
                },
                {
                    "name": "Liquidatable",
                    "type": "bar",
                    "stack": "status",
                    "color": "#ae82ff",
                    "data": [None, row.get("obl_liquidatable_value")],
                },
                {
                    "name": "Borrowed",
                    "type": "bar",
                    "stack": "status",
                    "color": "#f0c431",
                    "data": [row.get("reserve_brw_all_borrowed_less_debt_at_risk_mktval"), None],
                },
                {
                    "name": "Available/Unused",
                    "type": "bar",
                    "stack": "status",
                    "color": "#28c987",
                    "data": [row.get("reserve_brw_all_available_mktval"), None],
                },
                {
                    "name": "Unhealthy Debt",
                    "type": "bar",
                    "stack": "status",
                    "color": "#f8a94a",
                    "data": [row.get("obl_debt_total_unhealthy"), None],
                },
                {
                    "name": "Bad Debt",
                    "type": "bar",
                    "stack": "status",
                    "color": "#e24c4c",
                    "data": [row.get("obl_debt_total_bad"), None],
                },
            ],
        }

    def _kamino_utilization_timeseries(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "Value ($)",
            "yRightAxisLabel": "Utilization",
            "yRightAxisFormat": "pct0",
            "series": [
                {"name": "Borrowed", "type": "bar", "stack": "supply", "data": [row.get("reserve_brw_all_borrowed_mktvalue") for row in rows]},
                {"name": "Available", "type": "bar", "stack": "supply", "data": [row.get("reserve_brw_all_available_mktvalue") for row in rows]},
                {"name": "Total Supply", "type": "line", "data": [row.get("reserve_brw_all_supply_total_mktvalue") for row in rows]},
                {"name": "Utilization %", "type": "line", "yAxisIndex": 1, "data": [row.get("reserve_brw_all_utilization_pct") for row in rows]},
            ],
        }

    def _kamino_rate_curve(self, _: dict[str, Any]) -> dict[str, Any]:
        rows = self._rate_curve_rows()
        last = self._v_last_row()
        symbols = last.get("reserve_brw_all_symbols_array") or []
        utils = last.get("reserve_brw_all_utilization_pct_array") or []
        ref_colors = ["#f8a94a", "#4bb7ff", "#26c6da", "#ef5350", "#66bb6a", "#ab47bc"]
        ref_lines = []
        for i, (sym, util_val) in enumerate(zip(symbols, utils)):
            if util_val is not None:
                ref_lines.append({
                    "label": f"{sym}: {util_val}%",
                    "value": float(util_val),
                    "color": ref_colors[i % len(ref_colors)],
                })
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row.get("utilization_rate_pct") for row in rows],
            "xAxisLabel": "Utilization Rate (%)",
            "xAxisFormat": "pct0",
            "yAxisLabel": "Borrow Rate (%)",
            "yAxisFormat": "pct0",
            "series": [{"name": "Borrow Rate %", "type": "line", "showSymbol": True, "symbolSize": 5, "color": "#28c987", "data": [row.get("borrow_rate_pct") for row in rows]}],
            "mark_lines": ref_lines,
        }

    def _loan_size_rows(self, limit: int = 30) -> list[dict[str, Any]]:
        cache_key = f"kamino::loan_size_dist::{limit}"

        def _load() -> list[dict[str, Any]]:
            query = """
                SELECT obligation_address, loan_value_total, health_factor
                FROM kamino_lend.get_view_klend_obligations(
                    NOW(), 'loan_value_total', 'desc', %s, FALSE
                )
            """
            return self.sql.fetch_rows(query, (limit,))

        return self._cached(cache_key, _load, ttl_seconds=self._LOAN_SIZE_TTL_SECONDS)

    def _kamino_loan_size_dist(self, _: dict[str, Any]) -> dict[str, Any]:
        rows = self._loan_size_rows(30)
        addresses = [r["obligation_address"][:6] for r in rows]
        loan_values = [float(r.get("loan_value_total") or 0) for r in rows]
        health_factors = [round(float(r.get("health_factor") or 0), 2) for r in rows]
        return {
            "kind": "chart",
            "chart": "bar-line-dual",
            "x": addresses,
            "yLeftLabel": "Loan Value Total ($)",
            "yRightLabel": "Health Factor",
            "series": [
                {
                    "name": "Loan Value",
                    "type": "bar",
                    "yAxisIndex": 0,
                    "color": "#4bb7ff",
                    "data": loan_values,
                },
                {
                    "name": "Health Factor",
                    "type": "line",
                    "yAxisIndex": 1,
                    "color": "#f8a94a",
                    "showSymbol": True,
                    "symbolSize": 6,
                    "smooth": False,
                    "data": health_factors,
                },
            ],
            "reference_lines_y": [
                {"label": "Unhealthy Limit (HF = 1.0)", "value": 1.0, "color": "#ef4444", "yAxisIndex": 1},
            ],
        }

    def _kamino_ltv_hf_timeseries(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "LTV",
            "yAxisFormat": "pct0",
            "yRightAxisLabel": "Health Factor",
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
            "yAxisLabel": "USX Amount",
            "yAxisFormat": "compact",
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
            "yAxisLabel": "Liquidation Flow",
            "yRightAxisLabel": "% At-Risk",
            "series": [
                {"name": "Liquidation Flow", "type": "bar", "data": [row.get("reserve_brw_all_liquidate_sum") for row in rows]},
                {"name": "Liquidation % At-Risk", "type": "line", "yAxisIndex": 1, "data": [row.get("reserve_brw_all_liquidate_sum_pct_at_risk") for row in rows]},
            ],
        }

    def _kamino_stress_debt(self, _: dict[str, Any]) -> dict[str, Any]:
        rows = sorted(self._sensitivity_rows(), key=lambda item: float(item.get("pct_change") or 0))
        last = self._v_last_row()
        coll_symbols = ", ".join(str(s) for s in (last.get("reserve_coll_all_symbols_array") or []) if s)
        brw_symbols = ", ".join(str(s) for s in (last.get("reserve_brw_all_symbols_array") or []) if s)
        vol_lines = []
        for field, label in [
            ("reserve_eusx_price_stddev_7d_pct", "-1\u03c3 eUSX"),
            ("reserve_eusx_price_2sigma_7d_pct", "-2\u03c3 eUSX"),
            ("reserve_usx_price_stddev_7d_pct", "+1\u03c3 USX"),
            ("reserve_usx_price_2sigma_7d_pct", "+2\u03c3 USX"),
        ]:
            val = last.get(field)
            if val is not None:
                signed = -abs(float(val)) if label.startswith("-") else abs(float(val))
                vol_lines.append({"label": label, "value": signed, "color": "#28c987"})
        return {
            "kind": "chart",
            "chart": "line-area",
            "x": [row.get("pct_change") for row in rows],
            "xAxisLabel": "Price Change (%)",
            "direction_arrows": {"left": coll_symbols, "right": brw_symbols},
            "series": [
                {"name": "Liquidatable Value", "type": "line", "area": True, "stack": "debt", "color": "#4170a8", "data": [row.get("total_liquidatable_value") for row in rows]},
                {"name": "Unhealthy Debt", "type": "line", "area": True, "stack": "debt", "color": "#c9a032", "data": [row.get("unhealthy_debt_less_liquidatable_part") for row in rows]},
                {"name": "Bad Debt", "type": "line", "area": True, "stack": "debt", "color": "#e24c4c", "data": [row.get("bad_debt_less_liquidatable_part") for row in rows]},
                {"name": "Price volatility levels", "type": "line", "color": "#28c987", "data": []},
            ],
            "volatility_lines": vol_lines,
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
