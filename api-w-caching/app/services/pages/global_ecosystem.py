from __future__ import annotations

import os
import threading
from typing import Any

from app.services.pages.base import BasePageService

_COLORS = {
    "blue": "#4bb7ff",
    "orange": "#f8a94a",
    "green": "#28c987",
    "red": "#e24c4c",
    "purple": "#ae82ff",
    "teal": "#2fbf71",
    "yellow": "#facc15",
    "grey": "#8ea1c7",
}


class GlobalEcosystemPageService(BasePageService):
    page_id = "global-ecosystem"
    default_protocol = ""
    default_pair = ""

    _V_LAST_TTL = float(os.getenv("GE_V_LAST_TTL_SECONDS", "60"))
    _TS_TTL = float(os.getenv("GE_TIMESERIES_TTL_SECONDS", "300"))
    _INTERVAL_TTL = float(os.getenv("GE_INTERVAL_TTL_SECONDS", "120"))
    _YIELD_TTL = float(os.getenv("GE_YIELD_TTL_SECONDS", "120"))
    # Global ecosystem timeseries can be expensive on cold paths. Keep the
    # query timeout high enough so at least one request can populate cache.
    _TS_TIMEOUT_MS = int(os.getenv("GE_TIMESERIES_TIMEOUT_MS", "60000"))

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self._last_ts_rows: dict[str, list[dict[str, Any]]] = {}
        self._last_ts_lock = threading.Lock()
        self._handlers = {
            "ge-issuance-bar": self._issuance_bar,
            "ge-issuance-pie": self._issuance_pie,
            "ge-issuance-time": self._issuance_time,
            "ge-yield-generation": self._yield_generation,
            "ge-yield-vesting-rate": self._yield_vesting_rate,
            "ge-current-yields": self._current_yields,
            "ge-yields-vs-time": self._yields_vs_time,
            "ge-supply-dist-usx-pie": self._supply_dist_usx_pie,
            "ge-supply-dist-eusx-pie": self._supply_dist_eusx_pie,
            "ge-supply-dist-usx-bar": self._supply_dist_usx_bar,
            "ge-supply-dist-eusx-bar": self._supply_dist_eusx_bar,
            "ge-token-avail-usx": self._token_avail_usx,
            "ge-token-avail-eusx": self._token_avail_eusx,
            "ge-tvl-defi-usx": self._tvl_defi_usx,
            "ge-tvl-defi-eusx": self._tvl_defi_eusx,
            "ge-tvl-share-usx": self._tvl_share_usx,
            "ge-tvl-share-eusx": self._tvl_share_eusx,
            "ge-activity-pct-usx": self._activity_pct_usx,
            "ge-activity-pct-eusx": self._activity_pct_eusx,
            "ge-activity-vol-usx": self._activity_vol_usx,
            "ge-activity-vol-eusx": self._activity_vol_eusx,
            "ge-activity-share-usx": self._activity_share_usx,
            "ge-activity-share-eusx": self._activity_share_eusx,
        }

    # ------------------------------------------------------------------
    # Window / bucket helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _window_interval(last_window: str) -> str:
        return {
            "1h": "1 hour", "4h": "4 hours", "6h": "6 hours",
            "24h": "24 hours", "7d": "7 days", "30d": "30 days", "90d": "90 days",
        }.get(str(last_window or "7d").lower(), "7 days")

    @staticmethod
    def _bucket_interval(last_window: str) -> str:
        return {
            "1h": "5 minutes", "4h": "15 minutes", "6h": "30 minutes",
            "24h": "1 hour", "7d": "4 hours", "30d": "1 day", "90d": "3 days",
        }.get(str(last_window or "7d").lower(), "4 hours")

    # ------------------------------------------------------------------
    # Shared data loaders (cached)
    # ------------------------------------------------------------------

    def _v_last(self) -> dict[str, Any]:
        return self._cached(
            "ge::v_prop_last",
            lambda: (self.sql.fetch_rows(
                "SELECT "
                "  ptyt_all_csupply_in_usx, sy_all_csupply_in_usx, "
                "  eusx_csupply, usx_csupply, "
                "  base_coll_total, base_coll_in_prog_vault, base_coll_aum, "
                "  usx_csupply_pure_pct, eusx_csupply_pure_pct, "
                "  sy_all_csupply_in_usx_pure_pct, ptyt_all_csupply_in_usx_pct, "
                "  yield_eusx_7d, yield_eusx_30d, yield_pteusx, yield_ptusx, yield_kusx, "
                "  usx_tvl_in_dexes_pct, usx_tvl_in_kamino_pct, usx_tvl_in_kamino_as_ptusx_pct, "
                "  usx_tvl_in_eusx_pct, usx_tvl_in_exponent_pct, usx_tvl_remainder_pct, "
                "  eusx_tvl_in_dexes_pct, eusx_tvl_in_kamino_pct, "
                "  eusx_tvl_in_kamino_as_pteusx_pct, eusx_tvl_in_exponent_only_pct, "
                "  eusx_tvl_remainder_pct, "
                "  usx_timelocked, usx_defi_deployed, usx_freeunknown, "
                "  eusx_defi_deployed, eusx_freeunknown "
                "FROM solstice_proprietary.v_prop_last "
                "LIMIT 1"
            ) or [{}])[0],
            ttl_seconds=self._V_LAST_TTL,
        )

    def _ts_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        last_window = str(params.get("last_window", "7d"))
        lookback = self._window_interval(last_window)
        bucket = self._bucket_interval(last_window)
        cache_key = f"ge::ts::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self.sql.fetch_rows(
                "SELECT "
                "  bucket_time, "
                "  usx_csupply_pure_pct, eusx_csupply_pure_pct, "
                "  sy_all_csupply_in_usx_pure_pct, ptyt_all_csupply_in_usx_pct, "
                "  yield_eusx_24h, yield_eusx_7d, yield_ptusx, yield_pteusx, yield_kusx, "
                "  usx_timelocked, usx_defi_deployed, usx_freeunknown, "
                "  eusx_defi_deployed, eusx_freeunknown, "
                "  usx_tvl_in_dexes, usx_tvl_in_kamino, usx_tvl_in_eusx, usx_tvl_in_exponent, "
                "  eusx_tvl_in_dexes, eusx_tvl_in_kamino, "
                "  eusx_tvl_in_kamino_as_pteusx, eusx_tvl_in_exponent_only, "
                "  usx_tvl_in_dexes_pct, usx_tvl_in_kamino_pct, usx_tvl_in_eusx_pct, "
                "  usx_tvl_in_exponent_pct, usx_tvl_remainder_pct, "
                "  eusx_tvl_in_dexes_pct, eusx_tvl_in_kamino_pct, "
                "  eusx_tvl_in_kamino_as_pteusx_pct, eusx_tvl_in_exponent_only_pct, "
                "  eusx_tvl_remainder_pct, "
                "  usx_eusx_yield_flows, usx_dex_flows, usx_kam_all_flows, usx_exp_all_flows, "
                "  eusx_dex_flows, eusx_kam_all_flows, eusx_exp_all_flows, "
                "  usx_eusx_yield_flows_pct_usx_activity, usx_dex_flows_pct_usx_activity, "
                "  usx_kam_all_flows_pct_usx_activity, usx_exp_all_flows_pct_usx_activity, "
                "  eusx_dex_flows_pct_eusx_activity, eusx_kam_all_flows_pct_eusx_activity, "
                "  eusx_exp_all_flows_pct_eusx_activity "
                "FROM solstice_proprietary.get_view_prop_timeseries("
                "  %s, NOW() - %s::interval, NOW()"
                ") ORDER BY bucket_time",
                (bucket, lookback),
                statement_timeout_ms=self._TS_TIMEOUT_MS,
            )

        try:
            rows = self._cached(cache_key, _load, ttl_seconds=self._TS_TTL)
            if rows:
                with self._last_ts_lock:
                    self._last_ts_rows[last_window] = rows
            return rows
        except Exception:
            # Keep charts rendering during transient DB pressure.
            with self._last_ts_lock:
                fallback_rows = self._last_ts_rows.get(last_window)
            if fallback_rows is not None:
                return fallback_rows
            return []

    def _interval_row(self, params: dict[str, Any]) -> dict[str, Any]:
        last_window = str(params.get("last_window", "24h"))
        lookback = self._window_interval(last_window)
        cache_key = f"ge::interval::{last_window}"

        def _load() -> dict[str, Any]:
            rows = self.sql.fetch_rows(
                "SELECT "
                "  usx_dex_flows_pct_usx_activity, usx_kam_all_flows_pct_usx_activity, "
                "  usx_exp_all_flows_pct_usx_activity, usx_eusx_yield_flows_pct_usx_activity, "
                "  usx_allprotocol_flows, "
                "  eusx_dex_flows_pct_eusx_activity, eusx_kam_all_flows_pct_eusx_activity, "
                "  eusx_exp_all_flows_pct_eusx_activity, "
                "  eusx_allprotocol_flows "
                "FROM solstice_proprietary.get_view_prop_last_interval(%s) "
                "LIMIT 1",
                (lookback,),
            )
            return rows[0] if rows else {}

        return self._cached(cache_key, _load, ttl_seconds=self._INTERVAL_TTL)

    def _yield_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        last_window = str(params.get("last_window", "30d"))
        lookback = self._window_interval(last_window)
        cache_key = f"ge::yield::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self.sql.fetch_rows(
                "SELECT "
                "  bucket_time, "
                "  yield_eusx_pool_total_assets, yield_eusx_pool_shares_supply, "
                "  yield_eusx_amount, "
                "  yield_eusx_apy_24h_pct, yield_eusx_apy_7d_pct, yield_eusx_apy_30d_pct "
                "FROM solstice_proprietary.v_eusx_yield_vesting "
                "WHERE bucket_time >= NOW() - %s::interval "
                "ORDER BY bucket_time",
                (lookback,),
            )

        return self._cached(cache_key, _load, ttl_seconds=self._YIELD_TTL)

    # ------------------------------------------------------------------
    # Formatting helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _fv(v: Any) -> float:
        if v is None:
            return 0.0
        return float(v)

    @staticmethod
    def _fmt_money(v: Any) -> str:
        if v is None:
            return "--"
        return f"${float(v):,.0f}"

    @staticmethod
    def _fmt_pct(v: Any, dp: int = 1) -> str:
        if v is None:
            return "--"
        return f"{float(v):.{dp}f}%"

    @staticmethod
    def _hbar(
        categories: list[str],
        values: list[float],
        colors: list[str],
        x_label: str = "USD",
        x_format: str = "compact",
    ) -> dict[str, Any]:
        """Build a bar-horizontal payload in the format the frontend expects."""
        n = len(categories)
        series = []
        for i, (cat, val, col) in enumerate(zip(categories, values, colors)):
            sparse = [None] * n
            sparse[i] = val
            series.append({
                "name": cat, "type": "bar", "stack": "total",
                "color": col, "data": sparse,
            })
        return {
            "kind": "chart",
            "chart": "bar-horizontal",
            "x": categories,
            "series": series,
            "xAxisLabel": x_label,
            "xAxisFormat": x_format,
        }

    @staticmethod
    def _vbar(
        categories: list[str],
        values: list[float],
        colors: list[str],
        y_label: str = "",
        y_format: str = "compact",
    ) -> dict[str, Any]:
        """Build a vertical bar chart with one individually-colored bar per category."""
        data = [
            {"value": val, "itemStyle": {"color": col}}
            for val, col in zip(values, colors)
        ]
        return {
            "kind": "chart",
            "chart": "line",
            "x": categories,
            "yAxisLabel": y_label,
            "yAxisFormat": y_format,
            "series": [
                {"name": "", "type": "bar", "barCategoryGap": "20%", "data": data},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Asset Issuance Bar
    # ------------------------------------------------------------------

    def _issuance_bar(self, _: dict[str, Any]) -> dict[str, Any]:
        r = self._v_last()
        return self._hbar(
            categories=[
                "PT/YT Supply (USX eq.)", "SY Supply (USX eq.)", "eUSX Supply",
                "USX Supply", "Base Coll Total", "Base Coll In Vaults", "Base Coll AUM",
            ],
            values=[
                self._fv(r.get("ptyt_all_csupply_in_usx")),
                self._fv(r.get("sy_all_csupply_in_usx")),
                self._fv(r.get("eusx_csupply")),
                self._fv(r.get("usx_csupply")),
                self._fv(r.get("base_coll_total")),
                self._fv(r.get("base_coll_in_prog_vault")),
                self._fv(r.get("base_coll_aum")),
            ],
            colors=[
                _COLORS["red"], _COLORS["yellow"], _COLORS["purple"],
                _COLORS["orange"], _COLORS["blue"], _COLORS["teal"], _COLORS["green"],
            ],
            x_label="USD",
        )

    # ------------------------------------------------------------------
    # Widget: Asset Issuance Pie
    # ------------------------------------------------------------------

    def _issuance_pie(self, _: dict[str, Any]) -> dict[str, Any]:
        r = self._v_last()
        return {
            "kind": "chart",
            "chart": "pie",
            "slices": [
                {"name": "USX (pure)", "value": self._fv(r.get("usx_csupply_pure_pct")),
                 "color": _COLORS["orange"]},
                {"name": "eUSX (pure)", "value": self._fv(r.get("eusx_csupply_pure_pct")),
                 "color": _COLORS["purple"]},
                {"name": "SY (USX eq.)", "value": self._fv(r.get("sy_all_csupply_in_usx_pure_pct")),
                 "color": _COLORS["yellow"]},
                {"name": "PT/YT (USX eq.)", "value": self._fv(r.get("ptyt_all_csupply_in_usx_pct")),
                 "color": _COLORS["blue"]},
            ],
            "title_extra": f"USX Supply: {self._fmt_money(r.get('usx_csupply'))}",
        }

    # ------------------------------------------------------------------
    # Widget: Asset Issuance Time Series
    # ------------------------------------------------------------------

    def _issuance_time(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "% of USX Supply",
            "yAxisFormat": "pct1",
            "yAxisMin": 0,
            "yAxisMax": 100,
            "series": [
                {"name": "USX (pure)", "type": "line", "area": True, "stack": "dist",
                 "color": _COLORS["orange"],
                 "data": [row.get("usx_csupply_pure_pct") for row in rows]},
                {"name": "eUSX (pure)", "type": "line", "area": True, "stack": "dist",
                 "color": _COLORS["purple"],
                 "data": [row.get("eusx_csupply_pure_pct") for row in rows]},
                {"name": "SY (USX eq.)", "type": "line", "area": True, "stack": "dist",
                 "color": _COLORS["yellow"],
                 "data": [row.get("sy_all_csupply_in_usx_pure_pct") for row in rows]},
                {"name": "PT/YT (USX eq.)", "type": "line", "area": True, "stack": "dist",
                 "color": _COLORS["blue"],
                 "data": [row.get("ptyt_all_csupply_in_usx_pct") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: AUM Yield Generation
    # ------------------------------------------------------------------

    def _yield_generation(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._yield_rows(params)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "USD",
            "yAxisFormat": "compact",
            "yRightAxisLabel": "Yield per hour",
            "yRightAxisFormat": "compact",
            "series": [
                {"name": "Pool Total Assets", "type": "line", "color": _COLORS["blue"],
                 "data": [row.get("yield_eusx_pool_total_assets") for row in rows]},
                {"name": "Shares Supply", "type": "line", "color": _COLORS["orange"],
                 "data": [row.get("yield_eusx_pool_shares_supply") for row in rows]},
                {"name": "Vested Yield", "type": "bar", "yAxisIndex": 1,
                 "color": _COLORS["green"],
                 "data": [row.get("yield_eusx_amount") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Yield Vesting Implied Rate
    # ------------------------------------------------------------------

    def _yield_vesting_rate(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._yield_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "APY %",
            "yAxisFormat": "pct2",
            "series": [
                {"name": "24h Rate", "type": "line", "color": _COLORS["blue"],
                 "data": [row.get("yield_eusx_apy_24h_pct") for row in rows]},
                {"name": "7d Rate", "type": "line", "color": _COLORS["orange"],
                 "data": [row.get("yield_eusx_apy_7d_pct") for row in rows]},
                {"name": "30d Rate", "type": "line", "color": _COLORS["green"],
                 "data": [row.get("yield_eusx_apy_30d_pct") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Current Yields Table
    # ------------------------------------------------------------------

    def _current_yields(self, _: dict[str, Any]) -> dict[str, Any]:
        r = self._v_last()
        categories = ["eUSX-7d", "eUSX-30d", "PT-eUSX", "PT-USX", "k-USX"]
        values = [
            self._fv(r.get("yield_eusx_7d")),
            self._fv(r.get("yield_eusx_30d")),
            self._fv(r.get("yield_pteusx")),
            self._fv(r.get("yield_ptusx")),
            self._fv(r.get("yield_kusx")),
        ]
        colors = ["#3b5998", "#4a6fad", _COLORS["purple"], _COLORS["blue"], _COLORS["green"]]
        return self._vbar(categories, values, colors, y_label="APY %", y_format="pct2")

    # ------------------------------------------------------------------
    # Widget: Yields vs Time
    # ------------------------------------------------------------------

    def _yields_vs_time(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "APY %",
            "yAxisFormat": "pct2",
            "series": [
                {"name": "eUSX 24h", "type": "line", "color": _COLORS["blue"],
                 "data": [row.get("yield_eusx_24h") for row in rows]},
                {"name": "eUSX 7d", "type": "line", "color": _COLORS["orange"],
                 "data": [row.get("yield_eusx_7d") for row in rows]},
                {"name": "PT-USX", "type": "line", "color": _COLORS["green"],
                 "data": [row.get("yield_ptusx") for row in rows]},
                {"name": "PT-eUSX", "type": "line", "color": _COLORS["purple"],
                 "data": [row.get("yield_pteusx") for row in rows]},
                {"name": "Kamino USX", "type": "line", "color": _COLORS["yellow"],
                 "data": [row.get("yield_kusx") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Supply Distribution Pie (USX)
    # ------------------------------------------------------------------

    def _supply_dist_usx_pie(self, _: dict[str, Any]) -> dict[str, Any]:
        r = self._v_last()
        return {
            "kind": "chart",
            "chart": "pie",
            "slices": [
                {"name": "DEXes", "value": self._fv(r.get("usx_tvl_in_dexes_pct")),
                 "color": _COLORS["blue"]},
                {"name": "Kamino", "value": self._fv(r.get("usx_tvl_in_kamino_pct")),
                 "color": _COLORS["green"]},
                {"name": "PT-USX Kamino", "value": self._fv(r.get("usx_tvl_in_kamino_as_ptusx_pct")),
                 "color": _COLORS["teal"]},
                {"name": "eUSX Vault", "value": self._fv(r.get("usx_tvl_in_eusx_pct")),
                 "color": _COLORS["purple"]},
                {"name": "Exponent", "value": self._fv(r.get("usx_tvl_in_exponent_pct")),
                 "color": _COLORS["yellow"]},
                {"name": "Remainder", "value": self._fv(r.get("usx_tvl_remainder_pct")),
                 "color": _COLORS["grey"]},
            ],
            "title_extra": f"USX Supply: {self._fmt_money(r.get('usx_csupply'))}",
        }

    # ------------------------------------------------------------------
    # Widget: Supply Distribution Pie (eUSX)
    # ------------------------------------------------------------------

    def _supply_dist_eusx_pie(self, _: dict[str, Any]) -> dict[str, Any]:
        r = self._v_last()
        return {
            "kind": "chart",
            "chart": "pie",
            "slices": [
                {"name": "DEXes", "value": self._fv(r.get("eusx_tvl_in_dexes_pct")),
                 "color": _COLORS["blue"]},
                {"name": "Kamino", "value": self._fv(r.get("eusx_tvl_in_kamino_pct")),
                 "color": _COLORS["green"]},
                {"name": "PT-eUSX Kamino", "value": self._fv(r.get("eusx_tvl_in_kamino_as_pteusx_pct")),
                 "color": _COLORS["teal"]},
                {"name": "Exponent", "value": self._fv(r.get("eusx_tvl_in_exponent_only_pct")),
                 "color": _COLORS["yellow"]},
                {"name": "Remainder", "value": self._fv(r.get("eusx_tvl_remainder_pct")),
                 "color": _COLORS["grey"]},
            ],
            "title_extra": f"eUSX Supply: {self._fmt_money(r.get('eusx_csupply'))}",
        }

    # ------------------------------------------------------------------
    # Widget: Supply Distribution Bar (USX)
    # ------------------------------------------------------------------

    def _supply_dist_usx_bar(self, _: dict[str, Any]) -> dict[str, Any]:
        r = self._v_last()
        return self._hbar(
            ["Time-locked (eUSX)", "DeFi Deployed", "Free / Unknown"],
            [self._fv(r.get("usx_timelocked")), self._fv(r.get("usx_defi_deployed")),
             self._fv(r.get("usx_freeunknown"))],
            [_COLORS["purple"], _COLORS["blue"], _COLORS["grey"]],
            x_label="USX",
        )

    # ------------------------------------------------------------------
    # Widget: Supply Distribution Bar (eUSX)
    # ------------------------------------------------------------------

    def _supply_dist_eusx_bar(self, _: dict[str, Any]) -> dict[str, Any]:
        r = self._v_last()
        return self._hbar(
            ["DeFi Deployed", "Free / Unknown"],
            [self._fv(r.get("eusx_defi_deployed")), self._fv(r.get("eusx_freeunknown"))],
            [_COLORS["blue"], _COLORS["grey"]],
            x_label="eUSX",
        )

    # ------------------------------------------------------------------
    # Widget: Token Availability USX (time series)
    # ------------------------------------------------------------------

    def _token_avail_usx(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "USX",
            "yAxisFormat": "compact",
            "series": [
                {"name": "Time-locked (eUSX)", "type": "line", "area": True, "stack": "avail",
                 "color": _COLORS["purple"],
                 "data": [row.get("usx_timelocked") for row in rows]},
                {"name": "DeFi Deployed", "type": "line", "area": True, "stack": "avail",
                 "color": _COLORS["blue"],
                 "data": [row.get("usx_defi_deployed") for row in rows]},
                {"name": "Free / Unknown", "type": "line", "area": True, "stack": "avail",
                 "color": _COLORS["grey"],
                 "data": [row.get("usx_freeunknown") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Token Availability eUSX (time series)
    # ------------------------------------------------------------------

    def _token_avail_eusx(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "eUSX",
            "yAxisFormat": "compact",
            "series": [
                {"name": "DeFi Deployed", "type": "line", "area": True, "stack": "avail",
                 "color": _COLORS["blue"],
                 "data": [row.get("eusx_defi_deployed") for row in rows]},
                {"name": "Free / Unknown", "type": "line", "area": True, "stack": "avail",
                 "color": _COLORS["grey"],
                 "data": [row.get("eusx_freeunknown") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: TVL by DeFi USX (time series)
    # ------------------------------------------------------------------

    def _tvl_defi_usx(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "USX",
            "yAxisFormat": "compact",
            "series": [
                {"name": "DEXes", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["blue"],
                 "data": [row.get("usx_tvl_in_dexes") for row in rows]},
                {"name": "Kamino", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["green"],
                 "data": [row.get("usx_tvl_in_kamino") for row in rows]},
                {"name": "eUSX Vault", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["purple"],
                 "data": [row.get("usx_tvl_in_eusx") for row in rows]},
                {"name": "Exponent", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["yellow"],
                 "data": [row.get("usx_tvl_in_exponent") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: TVL by DeFi eUSX (time series)
    # ------------------------------------------------------------------

    def _tvl_defi_eusx(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "eUSX",
            "yAxisFormat": "compact",
            "series": [
                {"name": "DEXes", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["blue"],
                 "data": [row.get("eusx_tvl_in_dexes") for row in rows]},
                {"name": "Kamino", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["green"],
                 "data": [row.get("eusx_tvl_in_kamino") for row in rows]},
                {"name": "PT-eUSX Kamino", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["teal"],
                 "data": [row.get("eusx_tvl_in_kamino_as_pteusx") for row in rows]},
                {"name": "Exponent", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["yellow"],
                 "data": [row.get("eusx_tvl_in_exponent_only") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: TVL Share USX % (time series)
    # ------------------------------------------------------------------

    def _tvl_share_usx(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "% of USX Supply",
            "yAxisFormat": "pct1",
            "yAxisMin": 0,
            "yAxisMax": 100,
            "series": [
                {"name": "DEXes", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["blue"],
                 "data": [row.get("usx_tvl_in_dexes_pct") for row in rows]},
                {"name": "Kamino", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["green"],
                 "data": [row.get("usx_tvl_in_kamino_pct") for row in rows]},
                {"name": "eUSX Vault", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["purple"],
                 "data": [row.get("usx_tvl_in_eusx_pct") for row in rows]},
                {"name": "Exponent", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["yellow"],
                 "data": [row.get("usx_tvl_in_exponent_pct") for row in rows]},
                {"name": "Remainder", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["grey"],
                 "data": [row.get("usx_tvl_remainder_pct") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: TVL Share eUSX % (time series)
    # ------------------------------------------------------------------

    def _tvl_share_eusx(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "% of eUSX Supply",
            "yAxisFormat": "pct1",
            "yAxisMin": 0,
            "yAxisMax": 100,
            "series": [
                {"name": "DEXes", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["blue"],
                 "data": [row.get("eusx_tvl_in_dexes_pct") for row in rows]},
                {"name": "Kamino", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["green"],
                 "data": [row.get("eusx_tvl_in_kamino_pct") for row in rows]},
                {"name": "PT-eUSX Kamino", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["teal"],
                 "data": [row.get("eusx_tvl_in_kamino_as_pteusx_pct") for row in rows]},
                {"name": "Exponent", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["yellow"],
                 "data": [row.get("eusx_tvl_in_exponent_only_pct") for row in rows]},
                {"name": "Remainder", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["grey"],
                 "data": [row.get("eusx_tvl_remainder_pct") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Activity Volumes % Pie (USX)
    # ------------------------------------------------------------------

    def _activity_pct_usx(self, params: dict[str, Any]) -> dict[str, Any]:
        r = self._interval_row(params)
        return {
            "kind": "chart",
            "chart": "pie",
            "slices": [
                {"name": "DEXes", "value": self._fv(r.get("usx_dex_flows_pct_usx_activity")),
                 "color": _COLORS["blue"]},
                {"name": "Kamino", "value": self._fv(r.get("usx_kam_all_flows_pct_usx_activity")),
                 "color": _COLORS["green"]},
                {"name": "Exponent", "value": self._fv(r.get("usx_exp_all_flows_pct_usx_activity")),
                 "color": _COLORS["yellow"]},
                {"name": "eUSX Yield Vault", "value": self._fv(r.get("usx_eusx_yield_flows_pct_usx_activity")),
                 "color": _COLORS["purple"]},
            ],
            "title_extra": f"Total USX Activity: {self._fmt_money(r.get('usx_allprotocol_flows'))}",
        }

    # ------------------------------------------------------------------
    # Widget: Activity Volumes % Pie (eUSX)
    # ------------------------------------------------------------------

    def _activity_pct_eusx(self, params: dict[str, Any]) -> dict[str, Any]:
        r = self._interval_row(params)
        return {
            "kind": "chart",
            "chart": "pie",
            "slices": [
                {"name": "DEXes", "value": self._fv(r.get("eusx_dex_flows_pct_eusx_activity")),
                 "color": _COLORS["blue"]},
                {"name": "Kamino", "value": self._fv(r.get("eusx_kam_all_flows_pct_eusx_activity")),
                 "color": _COLORS["green"]},
                {"name": "Exponent", "value": self._fv(r.get("eusx_exp_all_flows_pct_eusx_activity")),
                 "color": _COLORS["yellow"]},
            ],
            "title_extra": f"Total eUSX Activity: {self._fmt_money(r.get('eusx_allprotocol_flows'))}",
        }

    # ------------------------------------------------------------------
    # Widget: Activity Volumes (USX) – stacked area time series
    # ------------------------------------------------------------------

    def _activity_vol_usx(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "USX",
            "yAxisFormat": "compact",
            "series": [
                {"name": "eUSX Vault", "type": "bar", "stack": "vol",
                 "color": _COLORS["purple"],
                 "data": [row.get("usx_eusx_yield_flows") for row in rows]},
                {"name": "DEX", "type": "bar", "stack": "vol",
                 "color": _COLORS["blue"],
                 "data": [row.get("usx_dex_flows") for row in rows]},
                {"name": "Kamino", "type": "bar", "stack": "vol",
                 "color": _COLORS["green"],
                 "data": [row.get("usx_kam_all_flows") for row in rows]},
                {"name": "Exponent", "type": "bar", "stack": "vol",
                 "color": _COLORS["yellow"],
                 "data": [row.get("usx_exp_all_flows") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Activity Volumes (eUSX) – stacked area time series
    # ------------------------------------------------------------------

    def _activity_vol_eusx(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "eUSX",
            "yAxisFormat": "compact",
            "series": [
                {"name": "DEX", "type": "bar", "stack": "vol",
                 "color": _COLORS["blue"],
                 "data": [row.get("eusx_dex_flows") for row in rows]},
                {"name": "Kamino", "type": "bar", "stack": "vol",
                 "color": _COLORS["green"],
                 "data": [row.get("eusx_kam_all_flows") for row in rows]},
                {"name": "Exponent", "type": "bar", "stack": "vol",
                 "color": _COLORS["yellow"],
                 "data": [row.get("eusx_exp_all_flows") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Activity as % of USX Supply – stacked area time series
    # ------------------------------------------------------------------

    def _activity_share_usx(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "% of USX Activity",
            "yAxisFormat": "pct1",
            "yAxisMin": 0,
            "yAxisMax": 100,
            "series": [
                {"name": "eUSX Vault", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["purple"],
                 "data": [row.get("usx_eusx_yield_flows_pct_usx_activity") for row in rows]},
                {"name": "DEX", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["blue"],
                 "data": [row.get("usx_dex_flows_pct_usx_activity") for row in rows]},
                {"name": "Kamino", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["green"],
                 "data": [row.get("usx_kam_all_flows_pct_usx_activity") for row in rows]},
                {"name": "Exponent", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["yellow"],
                 "data": [row.get("usx_exp_all_flows_pct_usx_activity") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Activity as % of eUSX Supply – stacked area time series
    # ------------------------------------------------------------------

    def _activity_share_eusx(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "% of eUSX Activity",
            "yAxisFormat": "pct1",
            "yAxisMin": 0,
            "yAxisMax": 100,
            "series": [
                {"name": "DEX", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["blue"],
                 "data": [row.get("eusx_dex_flows_pct_eusx_activity") for row in rows]},
                {"name": "Kamino", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["green"],
                 "data": [row.get("eusx_kam_all_flows_pct_eusx_activity") for row in rows]},
                {"name": "Exponent", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["yellow"],
                 "data": [row.get("eusx_exp_all_flows_pct_eusx_activity") for row in rows]},
            ],
        }
