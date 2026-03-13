from __future__ import annotations

import json
import logging
import os
import threading
import urllib.request
from typing import Any

from app.services.pages.base import BasePageService

_log = logging.getLogger(__name__)

_ONYC_MINT = "5Y8NV33Vv7WbnLfq3zBcKSdYPrk7g2KoiQoe7M2tcxp5"
_SOLANA_RPC_URL = os.getenv(
    "SOLANA_RPC_URL", "https://api.mainnet-beta.solana.com"
)

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
    _ISSUANCE_TTL = float(os.getenv("GE_ISSUANCE_TTL_SECONDS", "120"))
    _ONYC_SUPPLY_TTL = float(os.getenv("GE_ONYC_SUPPLY_TTL_SECONDS", "300"))
    _TS_TIMEOUT_MS = int(os.getenv("GE_TIMESERIES_TIMEOUT_MS", "60000"))

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self._last_ts_rows: dict[str, list[dict[str, Any]]] = {}
        self._last_ts_lock = threading.Lock()
        self._handlers = {
            "ge-issuance-bar": self._issuance_bar,
            "ge-issuance-pie": self._issuance_pie,
            "ge-issuance-time": self._issuance_time,
            "ge-tvl-bar": self._tvl_bar,
            "ge-tvl-pie": self._tvl_pie,
            "ge-tvl-time": self._tvl_time,
            "ge-current-yields": self._current_yields,
            "ge-yields-vs-time": self._yields_vs_time,
            "ge-tvl-share": self._tvl_share,
            "ge-activity-pct": self._activity_pct,
            "ge-activity-vol": self._activity_vol,
            "ge-activity-share": self._activity_share,
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
            "ge::v_xp_last",
            lambda: (self.sql.fetch_rows(
                "SELECT "
                "  onyc_in_dexes, onyc_in_kamino, onyc_in_exponent, onyc_tracked_total, "
                "  onyc_in_dexes_pct, onyc_in_kamino_pct, onyc_in_exponent_pct, "
                "  kam_onyc_supply_apy_pct, kam_onyc_borrow_apy_pct, "
                "  kam_onyc_utilization_pct, exp_weighted_implied_apy_pct, "
                "  dex_avg_price_t1_per_t0, "
                "  kam_total_collateral_value, kam_total_borrow_value, kam_weighted_avg_ltv_pct, "
                "  refreshed_at "
                "FROM cross_protocol.v_xp_last "
                "LIMIT 1"
            ) or [{}])[0],
            ttl_seconds=self._V_LAST_TTL,
        )

    def _ts_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        last_window = str(params.get("last_window", "7d"))
        lookback = self._window_interval(last_window)
        bucket = self._bucket_interval(last_window)
        cache_key = f"ge::xp_ts::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self.sql.fetch_rows(
                "SELECT "
                "  bucket_time, "
                "  onyc_in_dexes, onyc_in_kamino, onyc_in_exponent, onyc_tracked_total, "
                "  onyc_in_dexes_pct, onyc_in_kamino_pct, onyc_in_exponent_pct, "
                "  dex_swap_volume, dex_lp_volume, dex_total_volume, "
                "  kam_total_volume, exp_total_volume, all_protocol_volume, "
                "  dex_volume_pct, kam_volume_pct, exp_volume_pct, "
                "  kam_onyc_supply_apy, exp_weighted_implied_apy "
                "FROM cross_protocol.get_view_xp_timeseries("
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
            with self._last_ts_lock:
                fallback_rows = self._last_ts_rows.get(last_window)
            if fallback_rows is not None:
                return fallback_rows
            return []

    def _interval_row(self, params: dict[str, Any]) -> dict[str, Any]:
        last_window = str(params.get("last_window", "24h"))
        lookback = self._window_interval(last_window)
        cache_key = f"ge::xp_activity::{last_window}"

        def _load() -> dict[str, Any]:
            rows = self.sql.fetch_rows(
                "SELECT "
                "  dex_swap_volume, dex_lp_volume, dex_total_volume, "
                "  kam_total_volume, exp_total_volume, all_protocol_volume, "
                "  dex_volume_pct, kam_volume_pct, exp_volume_pct "
                "FROM cross_protocol.get_view_xp_activity(%s) "
                "LIMIT 1",
                (lookback,),
            )
            return rows[0] if rows else {}

        return self._cached(cache_key, _load, ttl_seconds=self._INTERVAL_TTL)

    # ------------------------------------------------------------------
    # Issuance data loaders (SY/PT supply from DB, ONyc supply from RPC)
    # ------------------------------------------------------------------

    def _fetch_onyc_total_supply(self) -> float:
        """Fetch ONyc circulating supply from Solana RPC getTokenSupply."""
        def _load() -> float:
            try:
                payload = json.dumps({
                    "jsonrpc": "2.0", "id": 1,
                    "method": "getTokenSupply",
                    "params": [_ONYC_MINT],
                }).encode()
                req = urllib.request.Request(
                    _SOLANA_RPC_URL,
                    data=payload,
                    headers={"Content-Type": "application/json"},
                )
                with urllib.request.urlopen(req, timeout=10) as resp:
                    data = json.loads(resp.read())
                ui_amount = data.get("result", {}).get("value", {}).get("uiAmount")
                return float(ui_amount) if ui_amount is not None else 0.0
            except Exception as exc:
                _log.warning("Failed to fetch ONyc supply from RPC: %s", exc)
                return 0.0

        return self._cached("ge::onyc_total_supply", _load, ttl_seconds=self._ONYC_SUPPLY_TTL)

    def _issuance_snapshot(self) -> dict[str, Any]:
        """Latest SY supply, PT supply, exchange rate, and ONyc total supply."""
        def _load() -> dict[str, Any]:
            rows = self.sql.fetch_rows(
                "WITH latest_sy AS ( "
                "    SELECT DISTINCT ON (mint_sy) "
                "        supply / POWER(10, decimals) AS sy_supply "
                "    FROM exponent.cagg_sy_token_account_5s "
                "    WHERE meta_base_mint = %s "
                "    ORDER BY mint_sy, bucket DESC "
                "), "
                "latest_vaults AS ( "
                "    SELECT "
                "        SUM(pt_supply / POWER(10, COALESCE(env_sy_decimals, 9))) AS pt_supply "
                "    FROM ( "
                "        SELECT DISTINCT ON (vault_address) pt_supply, env_sy_decimals "
                "        FROM exponent.cagg_vaults_5s "
                "        WHERE meta_base_mint = %s "
                "        ORDER BY vault_address, bucket DESC "
                "    ) sub "
                "), "
                "latest_rate AS ( "
                "    SELECT DISTINCT ON (mint_sy) "
                "        1.0 / NULLIF(sy_exchange_rate, 0) AS onyc_per_sy "
                "    FROM exponent.cagg_sy_meta_account_5s "
                "    WHERE meta_base_mint = %s "
                "    ORDER BY mint_sy, bucket DESC "
                ") "
                "SELECT "
                "    COALESCE(s.sy_supply, 0) AS sy_supply, "
                "    COALESCE(v.pt_supply, 0) AS pt_supply, "
                "    COALESCE(r.onyc_per_sy, 1) AS onyc_per_sy "
                "FROM latest_sy s "
                "CROSS JOIN latest_vaults v "
                "CROSS JOIN latest_rate r",
                (_ONYC_MINT, _ONYC_MINT, _ONYC_MINT),
            )
            row = rows[0] if rows else {}
            onyc_per_sy = float(row.get("onyc_per_sy", 1))
            sy_supply = float(row.get("sy_supply", 0))
            pt_supply = float(row.get("pt_supply", 0))
            return {
                "sy_supply": sy_supply,
                "sy_supply_in_onyc": round(sy_supply * onyc_per_sy, 0),
                "pt_supply": pt_supply,
                "ptyt_supply_in_onyc": round(pt_supply * onyc_per_sy, 0),
                "onyc_per_sy": onyc_per_sy,
            }

        return self._cached("ge::issuance_snapshot", _load, ttl_seconds=self._ISSUANCE_TTL)

    def _issuance_ts_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        """Timeseries of SY and PT supply from exponent CAGGs."""
        last_window = str(params.get("last_window", "7d"))
        lookback = self._window_interval(last_window)
        bucket = self._bucket_interval(last_window)
        cache_key = f"ge::issuance_ts::{last_window}"

        def _load() -> list[dict[str, Any]]:
            return self.sql.fetch_rows(
                "WITH sy_ts AS ( "
                "    SELECT "
                "        time_bucket(%s::interval, bucket) AS bt, "
                "        LAST(supply / POWER(10, decimals), bucket) AS sy_supply "
                "    FROM exponent.cagg_sy_token_account_5s "
                "    WHERE meta_base_mint = %s "
                "      AND bucket >= NOW() - %s::interval "
                "    GROUP BY bt "
                "), "
                "vault_per_addr AS ( "
                "    SELECT "
                "        time_bucket(%s::interval, bucket) AS bt, vault_address, "
                "        LAST(pt_supply / POWER(10, COALESCE(env_sy_decimals, 9)), bucket) AS pt_supply "
                "    FROM exponent.cagg_vaults_5s "
                "    WHERE meta_base_mint = %s "
                "      AND bucket >= NOW() - %s::interval "
                "    GROUP BY bt, vault_address "
                "), "
                "vault_ts AS ( "
                "    SELECT bt, SUM(pt_supply) AS pt_supply FROM vault_per_addr GROUP BY bt "
                "), "
                "rate_ts AS ( "
                "    SELECT "
                "        time_bucket(%s::interval, bucket) AS bt, "
                "        LAST(1.0 / NULLIF(sy_exchange_rate, 0), bucket) AS onyc_per_sy "
                "    FROM exponent.cagg_sy_meta_account_5s "
                "    WHERE meta_base_mint = %s "
                "      AND bucket >= NOW() - %s::interval "
                "    GROUP BY bt "
                "), "
                "combined AS ( "
                "    SELECT "
                "        COALESCE(s.bt, v.bt) AS bucket_time, "
                "        COALESCE(s.sy_supply, 0) AS sy_supply, "
                "        COALESCE(v.pt_supply, 0) AS pt_supply, "
                "        r.onyc_per_sy AS raw_rate "
                "    FROM sy_ts s "
                "    FULL OUTER JOIN vault_ts v ON s.bt = v.bt "
                "    LEFT JOIN rate_ts r ON COALESCE(s.bt, v.bt) = r.bt "
                "), "
                "filled AS ( "
                "    SELECT *, COALESCE(raw_rate, "
                "        MAX(raw_rate) OVER ( "
                "            ORDER BY bucket_time "
                "            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING "
                "        ) "
                "    ) AS onyc_per_sy "
                "    FROM combined "
                ") "
                "SELECT bucket_time, sy_supply, pt_supply, "
                "    ROUND(COALESCE(sy_supply * onyc_per_sy, 0)::NUMERIC, 0) AS sy_in_onyc, "
                "    ROUND(COALESCE(pt_supply * onyc_per_sy, 0)::NUMERIC, 0) AS ptyt_in_onyc "
                "FROM filled ORDER BY bucket_time",
                (bucket, _ONYC_MINT, lookback,
                 bucket, _ONYC_MINT, lookback,
                 bucket, _ONYC_MINT, lookback),
                statement_timeout_ms=self._TS_TIMEOUT_MS,
            )

        return self._cached(cache_key, _load, ttl_seconds=self._TS_TTL)

    # ------------------------------------------------------------------
    # Formatting helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _fv(v: Any) -> float:
        if v is None:
            return 0.0
        return float(v)

    @staticmethod
    def _fmt_onyc(v: Any) -> str:
        if v is None:
            return "--"
        return f"{float(v):,.0f} ONyc"

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
        x_label: str = "ONyc",
        x_format: str = "compact",
    ) -> dict[str, Any]:
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
    # Widget: Token Supply Outstanding (horizontal bar)
    # ------------------------------------------------------------------

    def _issuance_bar(self, _: dict[str, Any]) -> dict[str, Any]:
        snap = self._issuance_snapshot()
        onyc_supply = self._fetch_onyc_total_supply()
        return self._hbar(
            categories=["ONyc Supply", "SY Supply (ONyc eq.)", "PT+YT Supply (ONyc eq.)"],
            values=[
                onyc_supply,
                self._fv(snap.get("sy_supply_in_onyc")),
                self._fv(snap.get("ptyt_supply_in_onyc")),
            ],
            colors=[_COLORS["orange"], _COLORS["purple"], _COLORS["blue"]],
            x_label="ONyc",
        )

    # ------------------------------------------------------------------
    # Widget: Token Issuance Distribution (pie)
    # ------------------------------------------------------------------

    def _issuance_pie(self, _: dict[str, Any]) -> dict[str, Any]:
        snap = self._issuance_snapshot()
        onyc_supply = self._fetch_onyc_total_supply()
        sy_in_onyc = self._fv(snap.get("sy_supply_in_onyc"))
        ptyt_in_onyc = self._fv(snap.get("ptyt_supply_in_onyc"))
        unwrapped = max(onyc_supply - sy_in_onyc, 0)

        total = onyc_supply if onyc_supply > 0 else 1
        return {
            "kind": "chart",
            "chart": "pie",
            "slices": [
                {"name": "ONyc (unwrapped)", "value": round(unwrapped / total * 100, 1),
                 "color": _COLORS["orange"]},
                {"name": "SY (ONyc eq.)", "value": round(sy_in_onyc / total * 100, 1),
                 "color": _COLORS["purple"]},
                {"name": "PT+YT (ONyc eq.)", "value": round(ptyt_in_onyc / total * 100, 1),
                 "color": _COLORS["blue"]},
            ],
            "title_extra": f"ONyc Supply: {self._fmt_onyc(onyc_supply)}",
        }

    # ------------------------------------------------------------------
    # Widget: Token Issuance Over Time (stacked area)
    # ------------------------------------------------------------------

    def _issuance_time(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._issuance_ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "ONyc",
            "yAxisFormat": "compact",
            "series": [
                {"name": "SY (ONyc eq.)", "type": "line", "area": True, "stack": "issuance",
                 "color": _COLORS["purple"],
                 "data": [row.get("sy_in_onyc") for row in rows]},
                {"name": "PT+YT (ONyc eq.)", "type": "line", "area": True, "stack": "issuance",
                 "color": _COLORS["blue"],
                 "data": [row.get("ptyt_in_onyc") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: ONyc TVL by Protocol (horizontal bar)
    # ------------------------------------------------------------------

    def _tvl_bar(self, _: dict[str, Any]) -> dict[str, Any]:
        r = self._v_last()
        return self._hbar(
            categories=["DEXes", "Kamino", "Exponent"],
            values=[
                self._fv(r.get("onyc_in_dexes")),
                self._fv(r.get("onyc_in_kamino")),
                self._fv(r.get("onyc_in_exponent")),
            ],
            colors=[_COLORS["blue"], _COLORS["green"], _COLORS["yellow"]],
            x_label="ONyc",
        )

    # ------------------------------------------------------------------
    # Widget: ONyc TVL Distribution (pie)
    # ------------------------------------------------------------------

    def _tvl_pie(self, _: dict[str, Any]) -> dict[str, Any]:
        r = self._v_last()
        return {
            "kind": "chart",
            "chart": "pie",
            "slices": [
                {"name": "DEXes", "value": self._fv(r.get("onyc_in_dexes_pct")),
                 "color": _COLORS["blue"]},
                {"name": "Kamino", "value": self._fv(r.get("onyc_in_kamino_pct")),
                 "color": _COLORS["green"]},
                {"name": "Exponent", "value": self._fv(r.get("onyc_in_exponent_pct")),
                 "color": _COLORS["yellow"]},
            ],
            "title_extra": f"Total Tracked: {self._fmt_onyc(r.get('onyc_tracked_total'))}",
        }

    # ------------------------------------------------------------------
    # Widget: ONyc TVL Over Time (stacked area)
    # ------------------------------------------------------------------

    def _tvl_time(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "ONyc",
            "yAxisFormat": "compact",
            "series": [
                {"name": "DEXes", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["blue"],
                 "data": [row.get("onyc_in_dexes") for row in rows]},
                {"name": "Kamino", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["green"],
                 "data": [row.get("onyc_in_kamino") for row in rows]},
                {"name": "Exponent", "type": "line", "area": True, "stack": "tvl",
                 "color": _COLORS["yellow"],
                 "data": [row.get("onyc_in_exponent") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Current Yields (vertical bar)
    # ------------------------------------------------------------------

    def _current_yields(self, _: dict[str, Any]) -> dict[str, Any]:
        r = self._v_last()
        categories = ["Kamino Supply APY", "Exponent Implied APY"]
        values = [
            self._fv(r.get("kam_onyc_supply_apy_pct")),
            self._fv(r.get("exp_weighted_implied_apy_pct")),
        ]
        colors = [_COLORS["green"], _COLORS["yellow"]]
        return self._vbar(categories, values, colors, y_label="APY %", y_format="pct2")

    # ------------------------------------------------------------------
    # Widget: Yields Over Time (line)
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
                {"name": "Kamino Supply APY", "type": "line", "color": _COLORS["green"],
                 "data": [row.get("kam_onyc_supply_apy") for row in rows]},
                {"name": "Exponent Implied APY", "type": "line", "color": _COLORS["yellow"],
                 "data": [row.get("exp_weighted_implied_apy") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: TVL Share by Protocol % (100% stacked area)
    # ------------------------------------------------------------------

    def _tvl_share(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "% of Tracked ONyc",
            "yAxisFormat": "pct1",
            "yAxisMin": 0,
            "yAxisMax": 100,
            "series": [
                {"name": "DEXes", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["blue"],
                 "data": [row.get("onyc_in_dexes_pct") for row in rows]},
                {"name": "Kamino", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["green"],
                 "data": [row.get("onyc_in_kamino_pct") for row in rows]},
                {"name": "Exponent", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["yellow"],
                 "data": [row.get("onyc_in_exponent_pct") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Activity Volumes % Pie
    # ------------------------------------------------------------------

    def _activity_pct(self, params: dict[str, Any]) -> dict[str, Any]:
        r = self._interval_row(params)
        return {
            "kind": "chart",
            "chart": "pie",
            "slices": [
                {"name": "DEXes", "value": self._fv(r.get("dex_volume_pct")),
                 "color": _COLORS["blue"]},
                {"name": "Kamino", "value": self._fv(r.get("kam_volume_pct")),
                 "color": _COLORS["green"]},
                {"name": "Exponent", "value": self._fv(r.get("exp_volume_pct")),
                 "color": _COLORS["yellow"]},
            ],
            "title_extra": f"Total Activity: {self._fmt_onyc(r.get('all_protocol_volume'))}",
        }

    # ------------------------------------------------------------------
    # Widget: Activity Volume Over Time (stacked bar)
    # ------------------------------------------------------------------

    def _activity_vol(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "ONyc",
            "yAxisFormat": "compact",
            "series": [
                {"name": "DEXes", "type": "bar", "stack": "vol",
                 "color": _COLORS["blue"],
                 "data": [row.get("dex_total_volume") for row in rows]},
                {"name": "Kamino", "type": "bar", "stack": "vol",
                 "color": _COLORS["green"],
                 "data": [row.get("kam_total_volume") for row in rows]},
                {"name": "Exponent", "type": "bar", "stack": "vol",
                 "color": _COLORS["yellow"],
                 "data": [row.get("exp_total_volume") for row in rows]},
            ],
        }

    # ------------------------------------------------------------------
    # Widget: Activity Share Over Time (100% stacked area)
    # ------------------------------------------------------------------

    def _activity_share(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._ts_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["bucket_time"] for row in rows],
            "yAxisLabel": "% of Activity",
            "yAxisFormat": "pct1",
            "yAxisMin": 0,
            "yAxisMax": 100,
            "series": [
                {"name": "DEXes", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["blue"],
                 "data": [row.get("dex_volume_pct") for row in rows]},
                {"name": "Kamino", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["green"],
                 "data": [row.get("kam_volume_pct") for row in rows]},
                {"name": "Exponent", "type": "line", "area": True, "stack": "pct",
                 "color": _COLORS["yellow"],
                 "data": [row.get("exp_volume_pct") for row in rows]},
            ],
        }
