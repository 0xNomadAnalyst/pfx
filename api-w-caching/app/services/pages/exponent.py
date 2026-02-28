from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any

from app.services.pages.base import BasePageService


class ExponentPageService(BasePageService):
    page_id = "exponent"
    default_protocol = ""
    default_pair = ""

    _V_LAST_TTL_SECONDS = float(os.getenv("EXPONENT_V_LAST_TTL_SECONDS", "120"))
    _TIMESERIES_TTL_SECONDS = float(os.getenv("EXPONENT_TIMESERIES_TTL_SECONDS", "120"))
    _MARKET_ASSETS_TTL_SECONDS = float(os.getenv("EXPONENT_MARKET_ASSETS_TTL_SECONDS", "300"))
    _TIMESERIES_TIMEOUT_MS = 30_000

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self._handlers = {
            # Market metadata (for selector dropdowns)
            "exponent-market-meta": self._exponent_market_meta,
            # KPIs — Group 1 (next to pie chart)
            "kpi-base-token-yield": self._kpi_base_token_yield,
            "kpi-locked-base-tokens": self._kpi_locked_base_tokens,
            "kpi-current-fixed-yield": self._kpi_current_fixed_yield,
            "kpi-sy-base-collateral": self._kpi_sy_base_collateral,
            # KPIs — Group 2 (next to timeline)
            "kpi-fixed-variable-spread": self._kpi_fixed_variable_spread,
            "kpi-sy-coll-ratio": self._kpi_sy_coll_ratio,
            "kpi-yt-staked-share": self._kpi_yt_staked_share,
            "kpi-amm-depth": self._kpi_amm_depth,
            # KPIs — Group 3 (full-width row)
            "kpi-pt-base-price": self._kpi_pt_base_price,
            "kpi-apy-impact-pt-trade": self._kpi_apy_impact_pt_trade,
            "kpi-pt-vol-24h": self._kpi_pt_vol_24h,
            "kpi-amm-deployment-ratio": self._kpi_amm_deployment_ratio,
            # Special charts (from v_last)
            "exponent-pie-tvl": self._exponent_pie_tvl,
            "exponent-timeline": self._exponent_timeline,
            # Market info KPIs
            "exponent-market-info-mkt1": self._market_info_mkt1,
            "exponent-market-info-mkt2": self._market_info_mkt2,
            # Timeseries charts — mkt1
            "exponent-pt-swap-flows-mkt1": self._pt_swap_flows_mkt1,
            "exponent-token-strip-flows-mkt1": self._token_strip_flows_mkt1,
            "exponent-vault-sy-balance-mkt1": self._vault_sy_balance_mkt1,
            "exponent-yt-staked-mkt1": self._yt_staked_mkt1,
            "exponent-yield-trading-liq-mkt1": self._yield_trading_liq_mkt1,
            "exponent-realized-rates-mkt1": self._realized_rates_mkt1,
            "exponent-divergence-mkt1": self._divergence_mkt1,
            # Timeseries charts — mkt2
            "exponent-pt-swap-flows-mkt2": self._pt_swap_flows_mkt2,
            "exponent-token-strip-flows-mkt2": self._token_strip_flows_mkt2,
            "exponent-vault-sy-balance-mkt2": self._vault_sy_balance_mkt2,
            "exponent-yt-staked-mkt2": self._yt_staked_mkt2,
            "exponent-yield-trading-liq-mkt2": self._yield_trading_liq_mkt2,
            "exponent-realized-rates-mkt2": self._realized_rates_mkt2,
            "exponent-divergence-mkt2": self._divergence_mkt2,
            # Table (modal action)
            "exponent-market-assets": self._exponent_market_assets,
        }

    # ------------------------------------------------------------------
    # Window / bucket helpers (same as Kamino)
    # ------------------------------------------------------------------

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

    # ------------------------------------------------------------------
    # Shared data loaders (cached)
    # ------------------------------------------------------------------

    @staticmethod
    def _mkt_params(params: dict[str, Any]) -> tuple[str, str]:
        """Extract explicit market selections from request params."""
        return str(params.get("mkt1") or ""), str(params.get("mkt2") or "")

    def _v_last_row(self, params: dict[str, Any] | None = None) -> dict[str, Any]:
        mkt1, mkt2 = self._mkt_params(params or {})
        cache_key = f"exponent::v_last::{mkt1}::{mkt2}"

        def _load() -> dict[str, Any]:
            if mkt1 and mkt2:
                rows = self.sql.fetch_rows(
                    "SELECT * FROM exponent.get_view_exponent_last(%s, %s) LIMIT 1",
                    (mkt1, mkt2),
                )
            else:
                rows = self.sql.fetch_rows(
                    "SELECT * FROM exponent.get_view_exponent_last() LIMIT 1"
                )
            return rows[0] if rows else {}

        return self._cached(cache_key, _load, ttl_seconds=self._V_LAST_TTL_SECONDS)

    def _resolve_market(self, params: dict[str, Any], side: str) -> str:
        """Return the market selection arg for the timeseries SQL function.

        If the user has explicitly chosen a market for this side, pass the
        meta_pt_name directly so the SQL function looks it up by name.
        Otherwise fall back to the positional 'mkt1'/'mkt2' label.
        """
        mkt1, mkt2 = self._mkt_params(params)
        if side == "mkt1" and mkt1:
            return mkt1
        if side == "mkt2" and mkt2:
            return mkt2
        return side

    def _timeseries_rows(self, params: dict[str, Any], market: str) -> list[dict[str, Any]]:
        resolved = self._resolve_market(params, market)
        last_window = str(params.get("last_window", "7d"))
        cache_key = f"exponent::ts::{resolved}::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self._run_timeseries_query(resolved, last_window)

        return self._cached(cache_key, _load, ttl_seconds=self._TIMESERIES_TTL_SECONDS)

    def _run_timeseries_query(self, market: str, last_window: str) -> list[dict[str, Any]]:
        lookback = self._window_interval(last_window)
        bucket = self._bucket_interval(last_window)
        query = """
            SELECT *
            FROM exponent.get_view_exponent_timeseries(
                %s, %s,
                NOW() - %s::interval,
                NOW()
            )
            ORDER BY bucket_time
        """
        return self.sql.fetch_rows(
            query, (market, bucket, lookback),
            statement_timeout_ms=self._TIMESERIES_TIMEOUT_MS,
        )

    def _aux_key_relations_rows(self) -> list[dict[str, Any]]:
        return self._cached(
            "exponent::aux_key_relations",
            lambda: self.sql.fetch_rows(
                "SELECT * FROM exponent.aux_key_relations ORDER BY maturity_date"
            ),
            ttl_seconds=self._MARKET_ASSETS_TTL_SECONDS,
        )

    # ------------------------------------------------------------------
    # Formatting helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _fmt_array(arr: Any, fmt: str = "number", dp: int = 1) -> str:
        items = list(arr) if isinstance(arr, (list, tuple)) else []
        if not items:
            return "--"
        parts: list[str] = []
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

    @staticmethod
    def _fmt_dual(v1: Any, v2: Any, fmt: str = "pct2") -> str:
        def _one(v: Any) -> str:
            if v is None:
                return "--"
            if fmt == "pct2":
                return f"{float(v):.2f}%"
            if fmt == "pct1":
                return f"{float(v):.1f}%"
            if fmt == "pct0":
                return f"{float(v):.0f}%"
            if fmt == "ratio":
                return f"{float(v):.2f}x"
            if fmt == "precise":
                return f"{float(v):.4f}"
            if fmt == "int":
                return f"{int(round(float(v))):,}"
            return f"{float(v):,.1f}"
        return f"{_one(v1)} / {_one(v2)}"

    @staticmethod
    def _fmt_number(v: Any) -> str:
        if v is None:
            return "--"
        return f"{float(v):,.0f}"

    # ------------------------------------------------------------------
    # Market metadata (for selector dropdowns)
    # ------------------------------------------------------------------

    def _exponent_market_meta(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        all_markets = list(row.get("market_pt_symbol_array_all") or [])
        selected = list(row.get("market_pt_symbol_array_full") or [])
        return {
            "kind": "meta",
            "markets": all_markets,
            "selected_mkt1": selected[0] if len(selected) > 0 else "",
            "selected_mkt2": selected[1] if len(selected) > 1 else "",
        }

    # ------------------------------------------------------------------
    # KPIs — Group 1 (next to pie chart)
    # ------------------------------------------------------------------

    def _kpi_base_token_yield(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("apy_realized_7d_array"), "pct", dp=2),
            "secondary": self._symbols_note(row.get("base_tokens_symbols_array")) + ", Annualized",
        }

    def _kpi_locked_base_tokens(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("base_tokens_locked_array"), "int"),
            "secondary": self._symbols_note(row.get("base_tokens_symbols_array")),
        }

    def _kpi_current_fixed_yield(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        return {
            "kind": "kpi",
            "primary": self._fmt_dual(row.get("apy_market_mkt1"), row.get("apy_market_mkt2"), "pct2"),
            "secondary": "Annualized",
        }

    def _kpi_sy_base_collateral(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        arr = row.get("base_token_collateralization_ratio_array") or []
        parts = [f"{float(v):.2f}x" if v is not None else "N/A" for v in arr]
        return {
            "kind": "kpi",
            "primary": " / ".join(parts) if parts else "--",
            "secondary": self._symbols_note(row.get("base_tokens_symbols_array")),
        }

    # ------------------------------------------------------------------
    # KPIs — Group 2 (next to timeline)
    # ------------------------------------------------------------------

    def _kpi_fixed_variable_spread(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        return {
            "kind": "kpi",
            "primary": self._fmt_dual(
                row.get("apy_divergence_wrt_7d_mkt1"),
                row.get("apy_divergence_wrt_7d_mkt2"),
                "pct2",
            ),
            "secondary": "Current Market - 24hr Trailing Rate on Underlying",
        }

    def _kpi_sy_coll_ratio(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        return {
            "kind": "kpi",
            "primary": self._fmt_dual(
                row.get("sy_coll_ratio_mkt1"),
                row.get("sy_coll_ratio_mkt2"),
                "ratio",
            ),
            "secondary": "SY backing for vault claims",
        }

    def _kpi_yt_staked_share(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        return {
            "kind": "kpi",
            "primary": self._fmt_dual(
                row.get("yt_staked_pct_mkt1"),
                row.get("yt_staked_pct_mkt2"),
                "pct0",
            ),
            "secondary": "Share of underlying yield claimed on ongoing basis",
        }

    def _kpi_amm_depth(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        return {
            "kind": "kpi",
            "primary": self._fmt_dual(
                row.get("amm_depth_in_sy_mkt1"),
                row.get("amm_depth_in_sy_mkt2"),
                "int",
            ),
            "secondary": "Total SY + PT in trading pool",
        }

    # ------------------------------------------------------------------
    # KPIs — Group 3 (full-width row)
    # ------------------------------------------------------------------

    def _kpi_pt_base_price(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        symbols = self._symbols_note(row.get("market_pt_symbol_array"))
        return {
            "kind": "kpi",
            "primary": self._fmt_dual(
                row.get("pt_base_price_mkt1"),
                row.get("pt_base_price_mkt2"),
                "precise",
            ),
            "secondary": f"PT price discount to Base token, {symbols}" if symbols else "PT price discount to Base token",
        }

    def _kpi_apy_impact_pt_trade(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        trade_size = row.get("amm_impact_trade_size_pt") or 0
        symbols = self._symbols_note(row.get("market_pt_symbol_array"))
        return {
            "kind": "kpi",
            "primary": self._fmt_dual(
                row.get("amm_price_impact_mkt1_pct"),
                row.get("amm_price_impact_mkt2_pct"),
                "pct2",
            ),
            "secondary": symbols if symbols else "",
            "title_override": f"APY Change from a Buy {self._fmt_number(trade_size)} PT trade",
        }

    def _kpi_pt_vol_24h(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        symbols = self._symbols_note(row.get("market_pt_symbol_array"))
        return {
            "kind": "kpi",
            "primary": self._fmt_array(row.get("amm_pt_vol_24h_array"), "int"),
            "secondary": f"PT price discount to Base token, {symbols}" if symbols else "",
        }

    def _kpi_amm_deployment_ratio(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        return {
            "kind": "kpi",
            "primary": self._fmt_dual(
                row.get("amm_share_sy_pct_mkt1"),
                row.get("amm_share_sy_pct_mkt2"),
                "pct1",
            ),
            "secondary": "Share of total SY in AMMs",
        }

    # ------------------------------------------------------------------
    # Special charts (from v_last)
    # ------------------------------------------------------------------

    def _exponent_pie_tvl(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        symbols = row.get("market_pt_symbol_array_full") or []
        lbl_mkt1 = symbols[0] if len(symbols) > 0 else "Market 1"
        lbl_mkt2 = symbols[1] if len(symbols) > 1 else "Market 2"
        total_tvl = row.get("total_naive_tvl")
        tvl_display = self._fmt_number(total_tvl) if total_tvl is not None else "--"
        return {
            "kind": "chart",
            "chart": "pie",
            "slices": [
                {"name": lbl_mkt1, "value": float(row.get("sy_total_locked_pct_mkt1") or 0), "color": "#4bb7ff"},
                {"name": lbl_mkt2, "value": float(row.get("sy_total_locked_pct_mkt2") or 0), "color": "#f8a94a"},
                {"name": "Other", "value": float(row.get("sy_not_in_mkt1_mkt2_pct") or 0), "color": "#28c987"},
            ],
            "title_extra": f"Total TVL represented (approximated on 1:1 basis) : {tvl_display}",
        }

    def _exponent_timeline(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        symbols = row.get("market_pt_symbol_array_full") or []
        bars: list[dict[str, Any]] = []
        if row.get("start_datetime_mkt1") and row.get("end_datetime_mkt1"):
            bars.append({
                "label": symbols[0] if len(symbols) > 0 else "Market 1",
                "start": str(row["start_datetime_mkt1"]),
                "end": str(row["end_datetime_mkt1"]),
                "color": "#4bb7ff",
            })
        if row.get("start_datetime_mkt2") and row.get("end_datetime_mkt2"):
            bars.append({
                "label": symbols[1] if len(symbols) > 1 else "Market 2",
                "start": str(row["start_datetime_mkt2"]),
                "end": str(row["end_datetime_mkt2"]),
                "color": "#f8a94a",
            })
        return {
            "kind": "chart",
            "chart": "timeline",
            "bars": bars,
            "now": datetime.now(timezone.utc).isoformat(),
        }

    # ------------------------------------------------------------------
    # Market info KPIs
    # ------------------------------------------------------------------

    @staticmethod
    def _format_market_info(start_dt: Any, end_dt: Any) -> dict[str, Any]:
        if not start_dt or not end_dt:
            return {
                "kind": "kpi",
                "primary": "N/A",
                "secondary": "Accounts for next maturity not yet initialized",
            }
        try:
            start = datetime.fromisoformat(str(start_dt).replace("Z", "+00:00"))
            end = datetime.fromisoformat(str(end_dt).replace("Z", "+00:00"))
        except (ValueError, TypeError):
            return {"kind": "kpi", "primary": "N/A", "secondary": "Invalid dates"}
        now = datetime.now(timezone.utc)
        fmt = "%d %b %Y %H:%M"
        primary = f"{start.strftime(fmt)} \u2192 {end.strftime(fmt)}"
        if now < start:
            delta = start - now
            secondary = f"Starts in {delta.days}d {delta.seconds // 3600}h"
        elif now > end:
            delta = now - end
            secondary = f"Ended {delta.days}d {delta.seconds // 3600}h ago"
        else:
            delta = end - now
            secondary = f"Active \u2014 ends in {delta.days}d {delta.seconds // 3600}h"
        return {"kind": "kpi", "primary": primary, "secondary": secondary}

    def _market_info_mkt1(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        return self._format_market_info(row.get("start_datetime_mkt1"), row.get("end_datetime_mkt1"))

    def _market_info_mkt2(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._v_last_row(params)
        return self._format_market_info(row.get("start_datetime_mkt2"), row.get("end_datetime_mkt2"))

    # ------------------------------------------------------------------
    # Timeseries charts — PT Swap Flows & Swap Count
    # ------------------------------------------------------------------

    def _pt_swap_flows(self, params: dict[str, Any], market: str) -> dict[str, Any]:
        rows = self._timeseries_rows(params, market)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "PT",
            "yAxisFormat": "compact",
            "yRightAxisLabel": "Swap Count",
            "yRightAxisFormat": "compact",
            "series": [
                {"name": "Buy PT", "type": "bar", "stack": "flows", "color": "#2fbf71",
                 "data": [abs(float(row.get("amm_pt_out") or 0)) for row in rows]},
                {"name": "Sell PT", "type": "bar", "stack": "flows", "color": "#e24c4c",
                 "data": [-abs(float(row.get("amm_pt_in") or 0)) for row in rows]},
                {"name": "Swap Count", "type": "line", "yAxisIndex": 1, "color": "#4bb7ff",
                 "data": [row.get("amm_pt_swap_count") for row in rows]},
            ],
        }

    def _pt_swap_flows_mkt1(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._pt_swap_flows(params, "mkt1")

    def _pt_swap_flows_mkt2(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._pt_swap_flows(params, "mkt2")

    # ------------------------------------------------------------------
    # Timeseries charts — Token Strip Flows & Balance
    # ------------------------------------------------------------------

    def _token_strip_flows(self, params: dict[str, Any], market: str) -> dict[str, Any]:
        rows = self._timeseries_rows(params, market)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "Flows (SY)",
            "yAxisFormat": "compact",
            "yRightAxisLabel": "Balance (SY)",
            "yRightAxisFormat": "compact",
            "series": [
                {"name": "Strip flows", "type": "bar", "stack": "strip", "color": "#2fbf71",
                 "data": [row.get("pt_supply_ui_delta_pos") for row in rows]},
                {"name": "Merge flows", "type": "bar", "stack": "strip", "color": "#e24c4c",
                 "data": [-abs(float(row.get("pt_supply_ui_delta_neg") or 0)) for row in rows]},
                {"name": "PT-YT supply", "type": "line", "yAxisIndex": 1, "color": "#4bb7ff",
                 "data": [row.get("pt_supply") for row in rows]},
            ],
        }

    def _token_strip_flows_mkt1(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._token_strip_flows(params, "mkt1")

    def _token_strip_flows_mkt2(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._token_strip_flows(params, "mkt2")

    # ------------------------------------------------------------------
    # Timeseries charts — Vault SY Balance & Claims
    # ------------------------------------------------------------------

    def _vault_sy_balance(self, params: dict[str, Any], market: str) -> dict[str, Any]:
        rows = self._timeseries_rows(params, market)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "%",
            "yAxisFormat": "pct0",
            "yRightAxisLabel": "SY",
            "yRightAxisFormat": "compact",
            "series": [
                {"name": "PT claims", "type": "bar", "stack": "claims", "color": "#4bb7ff",
                 "data": [row.get("sy_for_pt_pct_sy") for row in rows]},
                {"name": "Yield claims", "type": "bar", "stack": "claims", "color": "#f8a94a",
                 "data": [row.get("sy_yield_pool_pct") for row in rows]},
                {"name": "Total SY", "type": "line", "yAxisIndex": 1, "color": "#f8a94a",
                 "data": [row.get("total_sy_in_escrow") for row in rows]},
            ],
        }

    def _vault_sy_balance_mkt1(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._vault_sy_balance(params, "mkt1")

    def _vault_sy_balance_mkt2(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._vault_sy_balance(params, "mkt2")

    # ------------------------------------------------------------------
    # Timeseries charts — Share of YT Staked vs Unclaimed SY
    # ------------------------------------------------------------------

    def _yt_staked(self, params: dict[str, Any], market: str) -> dict[str, Any]:
        rows = self._timeseries_rows(params, market)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "%",
            "yAxisFormat": "pct0",
            "yAxisMin": 0,
            "yAxisMax": 100,
            "yRightAxisLabel": "SY",
            "yRightAxisFormat": "compact",
            "series": [
                {"name": "Share of YT staked", "type": "line", "color": "#f8a94a",
                 "data": [row.get("yt_share_staked_pct") for row in rows]},
                {"name": "Uncollected Yield (SY)", "type": "bar", "yAxisIndex": 1, "color": "#4bb7ff",
                 "data": [row.get("uncollected_sy") for row in rows]},
            ],
        }

    def _yt_staked_mkt1(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._yt_staked(params, "mkt1")

    def _yt_staked_mkt2(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._yt_staked(params, "mkt2")

    # ------------------------------------------------------------------
    # Timeseries charts — Yield Trading Liquidity
    # ------------------------------------------------------------------

    def _yield_trading_liq(self, params: dict[str, Any], market: str) -> dict[str, Any]:
        rows = self._timeseries_rows(params, market)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "%",
            "yAxisFormat": "pct0",
            "yAxisMin": 0,
            "yAxisMax": 100,
            "yRightAxisLabel": "SY",
            "yRightAxisFormat": "compact",
            "series": [
                {"name": "SY % pool tokens", "type": "bar", "stack": "pool", "color": "#f8a94a",
                 "data": [row.get("pool_depth_sy_pct") for row in rows]},
                {"name": "PT % pool tokens", "type": "bar", "stack": "pool", "color": "#ae82ff",
                 "data": [row.get("pool_depth_pt_pct") for row in rows]},
                {"name": "Pool depth (in SY)", "type": "line", "yAxisIndex": 1, "color": "#28c987",
                 "data": [row.get("pool_depth_in_sy") for row in rows]},
            ],
        }

    def _yield_trading_liq_mkt1(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._yield_trading_liq(params, "mkt1")

    def _yield_trading_liq_mkt2(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._yield_trading_liq(params, "mkt2")

    # ------------------------------------------------------------------
    # Timeseries charts — Realized Underlying Rates
    # ------------------------------------------------------------------

    def _realized_rates(self, params: dict[str, Any], market: str) -> dict[str, Any]:
        rows = self._timeseries_rows(params, market)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "APY %",
            "yAxisFormat": "pct2",
            "series": [
                {"name": "24h", "type": "line", "color": "#4bb7ff",
                 "data": [row.get("sy_trailing_apy_24h") for row in rows]},
                {"name": "7d", "type": "line", "color": "#f8a94a",
                 "data": [row.get("sy_trailing_apy_7d") for row in rows]},
                {"name": "Vault-Life", "type": "line", "color": "#e8853d",
                 "data": [row.get("sy_trailing_apy_vault_life") for row in rows]},
                {"name": "All-time (rolling)", "type": "line", "color": "#28c987",
                 "data": [row.get("sy_trailing_apy_all_time") for row in rows]},
            ],
        }

    def _realized_rates_mkt1(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._realized_rates(params, "mkt1")

    def _realized_rates_mkt2(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._realized_rates(params, "mkt2")

    # ------------------------------------------------------------------
    # Timeseries charts — Fixed vs Variable Rate Divergence
    # ------------------------------------------------------------------

    def _divergence(self, params: dict[str, Any], market: str) -> dict[str, Any]:
        rows = self._timeseries_rows(params, market)
        pos_spread: list[Any] = []
        neg_spread: list[Any] = []
        for row in rows:
            val = row.get("yield_divergence_wrt_7d_rate_pct")
            if val is not None:
                fv = float(val)
                pos_spread.append(fv if fv >= 0 else 0)
                neg_spread.append(fv if fv < 0 else 0)
            else:
                pos_spread.append(None)
                neg_spread.append(None)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "APY %",
            "yAxisFormat": "pct2",
            "yRightAxisLabel": "Spread %",
            "yRightAxisFormat": "pct2",
            "series": [
                {"name": "+ve Spread", "type": "bar", "yAxisIndex": 1, "color": "#4bb7ff",
                 "data": pos_spread},
                {"name": "-ve Spread", "type": "bar", "yAxisIndex": 1, "color": "#f8a94a",
                 "data": neg_spread},
                {"name": "ATH", "type": "line", "color": "#ef4444", "lineStyle": "dashed",
                 "data": [row.get("apy_market_ath") for row in rows]},
                {"name": "ATL", "type": "line", "color": "#ef4444", "lineStyle": "dashed",
                 "data": [row.get("apy_market_atl") for row in rows]},
                {"name": "Realized 7d APY", "type": "line", "color": "#28c987",
                 "data": [row.get("sy_trailing_apy_7d") for row in rows]},
                {"name": "Market APY", "type": "line", "color": "#facc15",
                 "data": [row.get("c_market_implied_apy") for row in rows]},
            ],
        }

    def _divergence_mkt1(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._divergence(params, "mkt1")

    def _divergence_mkt2(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._divergence(params, "mkt2")

    # ------------------------------------------------------------------
    # Table — Market Assets (modal action)
    # ------------------------------------------------------------------

    def _exponent_market_assets(self, _: dict[str, Any]) -> dict[str, Any]:
        rows_raw = self._aux_key_relations_rows()
        rows = []
        for r in rows_raw:
            rows.append({
                "pt_name": r.get("meta_pt_name", ""),
                "sy_symbol": r.get("meta_sy_name", "") or r.get("env_sy_symbol", ""),
                "base_symbol": r.get("meta_base_symbol", ""),
                "interface": r.get("sy_interface_type", ""),
                "decimals": r.get("env_sy_decimals", ""),
                "maturity": str(r.get("maturity_date", "")) if r.get("maturity_date") else "",
                "vault_address": r.get("vault_address", ""),
                "market_address": r.get("market_address", ""),
                "mint_sy": r.get("mint_sy", ""),
                "mint_pt": r.get("mint_pt", ""),
                "mint_yt": r.get("mint_yt", ""),
                "mint_lp": r.get("mint_lp", "") or "",
            })
        return {
            "kind": "table",
            "columns": [
                {"key": "pt_name", "label": "PT Name"},
                {"key": "sy_symbol", "label": "SY Token"},
                {"key": "base_symbol", "label": "Base Token"},
                {"key": "interface", "label": "Interface"},
                {"key": "decimals", "label": "Decimals"},
                {"key": "maturity", "label": "Maturity"},
                {"key": "vault_address", "label": "Vault"},
                {"key": "market_address", "label": "Market"},
                {"key": "mint_sy", "label": "Mint SY"},
                {"key": "mint_pt", "label": "Mint PT"},
                {"key": "mint_yt", "label": "Mint YT"},
                {"key": "mint_lp", "label": "Mint LP"},
            ],
            "rows": rows,
        }
