from __future__ import annotations

import logging
import math
import os
from typing import Any

from app.services.pages.base import BasePageService

logger = logging.getLogger(__name__)


class RiskAnalysisPageService(BasePageService):
    page_id = "risk-analysis"
    default_protocol = "raydium"
    default_pair = "USX-USDC"

    _PVALUE_TTL_SECONDS = float(os.getenv("RA_PVALUE_TTL_SECONDS", "120"))
    _TICK_DIST_TTL_SECONDS = float(os.getenv("RA_TICK_DIST_TTL_SECONDS", "120"))
    _XP_LAST_TTL_SECONDS = float(os.getenv("RA_XP_LAST_TTL_SECONDS", "120"))
    _SENSITIVITY_TTL_SECONDS = float(os.getenv("RA_SENSITIVITY_TTL_SECONDS", "120"))
    _VOL_TTL_SECONDS = float(os.getenv("RA_VOL_TTL_SECONDS", "300"))
    _V_LAST_TTL_SECONDS = float(os.getenv("RA_KAMINO_V_LAST_TTL_SECONDS", "120"))

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self._handlers = {
            # Section 1
            "ra-pvalue-tables": self._ra_pvalue_tables,
            "ra-liq-dist-ray": lambda p: self._ra_liq_dist(p, "raydium"),
            "ra-liq-dist-orca": lambda p: self._ra_liq_dist(p, "orca"),
            "ra-liq-depth-ray": lambda p: self._ra_liq_depth(p, "raydium"),
            "ra-liq-depth-orca": lambda p: self._ra_liq_depth(p, "orca"),
            "ra-prob-ray": lambda p: self._ra_probability(p, "raydium"),
            "ra-prob-orca": lambda p: self._ra_probability(p, "orca"),
            # Section 2
            "ra-xp-exposure": self._ra_xp_exposure,
            "ra-xp-dist-ray": lambda p: self._ra_xp_dist(p, "raydium"),
            "ra-xp-dist-orca": lambda p: self._ra_xp_dist(p, "orca"),
            "ra-xp-depth-ray": lambda p: self._ra_xp_depth(p, "raydium"),
            "ra-xp-depth-orca": lambda p: self._ra_xp_depth(p, "orca"),
            # Section 3
            "ra-stress-test": self._ra_stress_test,
            "ra-sensitivity-table": self._ra_sensitivity_table,
        }

    # ------------------------------------------------------------------
    # Shared data loaders
    # ------------------------------------------------------------------

    def _pvalue_rows(self, protocol: str, event_type: str, interval: str) -> list[dict[str, Any]]:
        cache_key = f"ra::pvalues::{protocol}::{event_type}::{interval}"

        def _load() -> list[dict[str, Any]]:
            try:
                return self.sql.fetch_rows(
                    "SELECT * FROM dexes.get_view_dex_risk_pvalues(%s, %s, %s, %s) "
                    "ORDER BY stat_order",
                    (protocol, "usx-usdc", event_type, interval),
                )
            except Exception as exc:
                logger.warning("_pvalue_rows query failed (%s/%s/%s): %s", protocol, event_type, interval, exc)
                return []

        return self._cached(cache_key, _load, ttl_seconds=self._PVALUE_TTL_SECONDS)

    def _tick_dist_rows(self, protocol: str) -> list[dict[str, Any]]:
        cache_key = f"ra::tick_dist::{protocol}"

        def _load() -> list[dict[str, Any]]:
            try:
                return self.sql.fetch_rows(
                    "SELECT * FROM dexes.get_view_tick_dist_simple(%s, %s, %s::interval) "
                    "ORDER BY tick_price_t1_per_t0",
                    (protocol, "USX-USDC", "1 hour"),
                )
            except Exception as exc:
                logger.warning("_tick_dist_rows query failed (%s): %s", protocol, exc)
                return []

        return self._cached(cache_key, _load, ttl_seconds=self._TICK_DIST_TTL_SECONDS)

    def _xp_last(self) -> dict[str, Any]:
        def _load() -> dict[str, Any]:
            try:
                rows = self.sql.fetch_rows(
                    "SELECT onyc_in_kamino, onyc_in_exponent, onyc_tracked_total, "
                    "  onyc_in_kamino_pct, onyc_in_exponent_pct, refreshed_at "
                    "FROM cross_protocol.v_xp_last LIMIT 1"
                )
                return rows[0] if rows else {}
            except Exception as exc:
                logger.warning("_xp_last query failed: %s", exc)
                return {}

        return self._cached("ra::xp_last", _load, ttl_seconds=self._XP_LAST_TTL_SECONDS)

    def _kamino_v_last_row(self) -> dict[str, Any]:
        def _load() -> dict[str, Any]:
            try:
                rows = self.sql.fetch_rows(
                    "SELECT "
                    "  reserve_coll_all_symbols_array, reserve_brw_all_symbols_array "
                    "FROM kamino_lend.v_last LIMIT 1"
                )
                return rows[0] if rows else {}
            except Exception as exc:
                logger.warning("_kamino_v_last_row query failed: %s", exc)
                return {}

        return self._cached("ra::kamino_v_last", _load, ttl_seconds=self._V_LAST_TTL_SECONDS)

    def _sensitivity_rows(self, coll_asset: str = "", debt_asset: str = "") -> list[dict[str, Any]]:
        cache_key = f"ra::sensitivities::{coll_asset}::{debt_asset}"

        def _load() -> list[dict[str, Any]]:
            try:
                return self.sql.fetch_rows(
                    "SELECT "
                    "  step_number, pct_change, "
                    "  total_borrows, total_deposits, "
                    "  unhealthy_debt, bad_debt, total_liquidatable_value, "
                    "  liquidation_distance_to_healthy, "
                    "  unhealthy_debt_less_liquidatable_part, bad_debt_less_liquidatable_part "
                    "FROM kamino_lend.get_view_klend_sensitivities(NULL, -100, 50, 100, 50, FALSE) "
                    "ORDER BY step_number"
                )
            except Exception as exc:
                logger.warning("_sensitivity_rows query failed: %s", exc)
                return []

        return self._cached(cache_key, _load, ttl_seconds=self._SENSITIVITY_TTL_SECONDS)

    def _price_volatility_7d(self) -> dict[str, float]:
        def _load() -> dict[str, float]:
            try:
                rows = self.sql.fetch_rows(
                    "SELECT symbol, STDDEV(market_price) AS sd, AVG(market_price) AS ap "
                    "FROM kamino_lend.cagg_reserves_5s "
                    "WHERE bucket >= NOW() - INTERVAL '7 days' "
                    "GROUP BY symbol"
                )
            except Exception:
                return {}
            out: dict[str, float] = {}
            for r in rows:
                sym = str(r.get("symbol") or "")
                sd = float(r.get("sd") or 0)
                ap = float(r.get("ap") or 0)
                if sym and ap > 0 and sd > 0:
                    out[sym] = sd / ap * 100
            return out

        return self._cached("ra::vol_7d", _load, ttl_seconds=self._VOL_TTL_SECONDS)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _ff(value: Any) -> float:
        try:
            v = float(value)
        except (TypeError, ValueError):
            return 0.0
        return v if math.isfinite(v) else 0.0

    def _snapped_price(self, rows: list[dict[str, Any]]) -> float | None:
        raw = None
        for r in rows:
            try:
                p = float(r.get("current_price_t1_per_t0"))  # type: ignore[arg-type]
                if math.isfinite(p) and p > 0:
                    raw = p
                    break
            except (TypeError, ValueError):
                continue
        if raw is None:
            return None
        overlap = []
        for r in rows:
            try:
                tp = float(r.get("tick_price_t1_per_t0"))  # type: ignore[arg-type]
            except (TypeError, ValueError):
                continue
            t0 = self._ff(r.get("token0_value"))
            t1 = self._ff(r.get("token1_value"))
            if t0 > 0 and t1 > 0:
                overlap.append(tp)
        if overlap:
            return min(overlap, key=lambda x: abs(x - raw))
        ticks = []
        for r in rows:
            try:
                ticks.append(float(r.get("tick_price_t1_per_t0")))  # type: ignore[arg-type]
            except (TypeError, ValueError):
                continue
        return min(ticks, key=lambda x: abs(x - raw)) if ticks else raw

    def _map_sell_amount_to_price(
        self, tick_rows: list[dict[str, Any]], sell_amount: float
    ) -> float | None:
        """Walk downside ticks consuming USX liquidity to find the price
        reached after selling ``sell_amount`` USX."""
        current_price = self._snapped_price(tick_rows)
        if current_price is None or sell_amount <= 0:
            return None

        downside_ticks = []
        for r in tick_rows:
            tp = self._ff(r.get("tick_price_t1_per_t0"))
            t0 = self._ff(r.get("token1_value"))
            if tp > 0 and tp <= current_price:
                downside_ticks.append((tp, t0))
        downside_ticks.sort(key=lambda x: x[0], reverse=True)

        remaining = sell_amount
        last_price = current_price
        for price, liquidity in downside_ticks:
            if remaining <= 0:
                break
            remaining -= liquidity
            last_price = price

        return last_price

    def _pvalue_mark_lines(
        self, tick_rows: list[dict[str, Any]], pvalue_rows: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        lines: list[dict[str, Any]] = []
        colors = ["#e24c4c", "#f8a94a", "#c9a032", "#ae82ff", "#4bb7ff", "#2fbf71", "#5c8a8a", "#888", "#aaa"]
        for idx, row in enumerate(pvalue_rows):
            stat = row.get("stat_name", "")
            value = self._ff(row.get("value"))
            if value <= 0:
                continue
            price = self._map_sell_amount_to_price(tick_rows, value)
            if price is None:
                continue
            lines.append({
                "value": price,
                "label": stat,
                "color": colors[idx % len(colors)],
            })
        return lines

    def _event_type_and_interval(self, params: dict[str, Any]) -> tuple[str, str]:
        event_type = str(params.get("risk_event_type", "Single Swaps"))
        interval = str(params.get("risk_interval", "5 minutes"))
        if event_type == "Single Swaps":
            interval = "5 minutes"
        return event_type, interval

    # ------------------------------------------------------------------
    # Section 1: Downside Price Risk - Dex Events
    # ------------------------------------------------------------------

    def _ra_pvalue_tables(self, params: dict[str, Any]) -> dict[str, Any]:
        event_type, interval = self._event_type_and_interval(params)
        ray_rows = self._pvalue_rows("raydium", event_type, interval)
        orca_rows = self._pvalue_rows("orca", event_type, interval)
        refresh_date = None
        for r in ray_rows + orca_rows:
            d = r.get("date")
            if d is not None:
                refresh_date = d
                break

        columns = [
            {"key": "stat_name", "label": "P Value"},
            {"key": "value", "label": "USX"},
            {"key": "event_count_at_or_above", "label": "Counts at or above"},
            {"key": "last_observed_at", "label": "Last observed"},
        ]
        subtitle = f"Refreshes Daily - Last Refresh at {refresh_date}" if refresh_date else ""
        return {
            "kind": "table-split",
            "columns": columns,
            "left_title": f"Raydium Extreme Sell Events",
            "right_title": f"Orca Extreme Sell Events",
            "left_rows": ray_rows,
            "right_rows": orca_rows,
            "subtitle": subtitle,
        }

    def _ra_liq_dist(self, params: dict[str, Any], protocol: str) -> dict[str, Any]:
        tick_rows = self._tick_dist_rows(protocol)
        current_price = self._snapped_price(tick_rows)
        event_type, interval = self._event_type_and_interval(params)
        pv_rows = self._pvalue_rows(protocol, event_type, interval)
        ml = self._pvalue_mark_lines(tick_rows, pv_rows)

        return {
            "kind": "chart",
            "chart": "bar",
            "x": [r["tick_price_t1_per_t0"] for r in tick_rows],
            "xAxisLabel": "Price (USDC per USX)",
            "yAxisLabel": "Liquidity Amount",
            "yAxisFormat": "compact",
            "reference_lines": {"peg": 1.0, "current_price": current_price},
            "mark_lines": ml,
            "series": [
                {"name": "USX Liquidity", "type": "bar", "stack": "liq", "data": [r["token0_value"] for r in tick_rows]},
                {"name": "USDC Liquidity", "type": "bar", "stack": "liq", "data": [r["token1_value"] for r in tick_rows]},
            ],
        }

    def _ra_liq_depth(self, params: dict[str, Any], protocol: str) -> dict[str, Any]:
        tick_rows = self._tick_dist_rows(protocol)
        current_price_raw = next(
            (r.get("current_price_t1_per_t0") for r in tick_rows if r.get("current_price_t1_per_t0") is not None), None
        )
        x_vals = [r["tick_price_t1_per_t0"] for r in tick_rows]
        usdc_cumul = [self._ff(r.get("token1_cumul")) for r in tick_rows]
        usx_cumul = [self._ff(r.get("token0_cumul")) for r in tick_rows]

        if current_price_raw is not None:
            try:
                cpf = float(current_price_raw)
                for idx, v in enumerate(x_vals):
                    if abs(float(v) - cpf) <= 1e-12:
                        usdc_cumul[idx] = 0
                        usx_cumul[idx] = 0
                        break
            except (TypeError, ValueError):
                pass

        event_type, interval = self._event_type_and_interval(params)
        pv_rows = self._pvalue_rows(protocol, event_type, interval)
        ml = self._pvalue_mark_lines(tick_rows, pv_rows)

        return {
            "kind": "chart",
            "chart": "line-area",
            "x": x_vals,
            "xAxisLabel": "Price (USDC per USX)",
            "yAxisLabel": "Cumulative Liquidity",
            "yAxisFormat": "compact",
            "reference_lines": {"peg": 1.0, "current_price": current_price_raw},
            "mark_lines": ml,
            "series": [
                {"name": "USDC Cumulative", "type": "line", "area": True, "data": usdc_cumul},
                {"name": "USX Cumulative", "type": "line", "area": True, "data": usx_cumul},
            ],
        }

    def _ra_probability(self, params: dict[str, Any], protocol: str) -> dict[str, Any]:
        tick_rows = self._tick_dist_rows(protocol)
        event_type, interval = self._event_type_and_interval(params)
        pv_rows = self._pvalue_rows(protocol, event_type, interval)

        stat_to_prob = {
            "Max": 0.0001,
            "p 99.999": 0.001,
            "p 99.99": 0.01,
            "p 99.9": 0.1,
            "p 99": 1.0,
            "p 90": 10.0,
            "p 80": 20.0,
            "p 50": 50.0,
            "Mean": None,
        }

        price_to_prob: dict[float, float] = {}
        for row in pv_rows:
            stat = row.get("stat_name", "")
            prob = stat_to_prob.get(stat)
            if prob is None:
                continue
            sell_amount = self._ff(row.get("value"))
            if sell_amount <= 0:
                continue
            price = self._map_sell_amount_to_price(tick_rows, sell_amount)
            if price is None:
                continue
            price_to_prob[price] = prob

        full_x = [r["tick_price_t1_per_t0"] for r in tick_rows]
        tick_floats = [float(v) for v in full_x]

        y_sparse: list[float | None] = [None] * len(full_x)
        for target_price, prob in price_to_prob.items():
            best_idx = min(range(len(tick_floats)),
                           key=lambda i: abs(tick_floats[i] - target_price))
            y_sparse[best_idx] = prob

        return {
            "kind": "chart",
            "chart": "probability-curve",
            "x": full_x,
            "xAxisLabel": "Price (USDC per USX)",
            "yAxisLabel": "Probability (%)",
            "reference_lines": {
                "peg": 1.0,
                "current_price": self._snapped_price(tick_rows),
            },
            "series": [
                {
                    "name": "P(price \u2264 x)",
                    "type": "line",
                    "step": "end",
                    "data": y_sparse,
                    "color": "#ae82ff",
                },
            ],
        }

    # ------------------------------------------------------------------
    # Section 2: Downside Price Risk - Cross-Protocol Events
    # ------------------------------------------------------------------

    def _ra_xp_exposure(self, params: dict[str, Any]) -> dict[str, Any]:
        xp = self._xp_last()
        kamino = self._ff(xp.get("onyc_in_kamino"))
        exponent = self._ff(xp.get("onyc_in_exponent"))
        total = self._ff(xp.get("onyc_tracked_total"))
        kam_pct = self._ff(xp.get("onyc_in_kamino_pct"))
        exp_pct = self._ff(xp.get("onyc_in_exponent_pct"))

        primary_parts = []
        if kamino > 0:
            primary_parts.append(f"Kamino: {kamino:,.0f} ONyc ({kam_pct:.1f}%)")
        if exponent > 0:
            primary_parts.append(f"Exponent: {exponent:,.0f} ONyc ({exp_pct:.1f}%)")
        primary = " | ".join(primary_parts) if primary_parts else "--"
        secondary = f"Total tracked: {total:,.0f} ONyc" if total > 0 else ""

        return {
            "kind": "kpi",
            "primary": primary,
            "secondary": secondary,
        }

    def _xp_liquidation_mark_lines(
        self, tick_rows: list[dict[str, Any]], scenario_pct: float
    ) -> list[dict[str, Any]]:
        xp = self._xp_last()
        kamino = self._ff(xp.get("onyc_in_kamino"))
        exponent = self._ff(xp.get("onyc_in_exponent"))
        frac = scenario_pct / 100.0
        lines: list[dict[str, Any]] = []

        kam_sell = kamino * frac
        if kam_sell > 0:
            price = self._map_sell_amount_to_price(tick_rows, kam_sell)
            if price is not None:
                lines.append({
                    "value": price,
                    "label": f"Kamino {scenario_pct:.0f}%",
                    "color": "#28c987",
                })

        exp_sell = exponent * frac
        if exp_sell > 0:
            price = self._map_sell_amount_to_price(tick_rows, exp_sell)
            if price is not None:
                lines.append({
                    "value": price,
                    "label": f"Exponent {scenario_pct:.0f}%",
                    "color": "#f0c431",
                })

        combined = (kamino + exponent) * frac
        if combined > 0:
            price = self._map_sell_amount_to_price(tick_rows, combined)
            if price is not None:
                lines.append({
                    "value": price,
                    "label": f"Combined {scenario_pct:.0f}%",
                    "color": "#e24c4c",
                })

        return lines

    def _ra_xp_dist(self, params: dict[str, Any], protocol: str) -> dict[str, Any]:
        tick_rows = self._tick_dist_rows(protocol)
        current_price = self._snapped_price(tick_rows)
        scenario_pct = self._ff(params.get("risk_liq_scenario", 25))
        ml = self._xp_liquidation_mark_lines(tick_rows, scenario_pct)

        return {
            "kind": "chart",
            "chart": "bar",
            "x": [r["tick_price_t1_per_t0"] for r in tick_rows],
            "xAxisLabel": "Price (USDC per USX)",
            "yAxisLabel": "Liquidity Amount",
            "yAxisFormat": "compact",
            "reference_lines": {"peg": 1.0, "current_price": current_price},
            "mark_lines": ml,
            "series": [
                {"name": "USX Liquidity", "type": "bar", "stack": "liq", "data": [r["token0_value"] for r in tick_rows]},
                {"name": "USDC Liquidity", "type": "bar", "stack": "liq", "data": [r["token1_value"] for r in tick_rows]},
            ],
        }

    def _ra_xp_depth(self, params: dict[str, Any], protocol: str) -> dict[str, Any]:
        tick_rows = self._tick_dist_rows(protocol)
        current_price_raw = next(
            (r.get("current_price_t1_per_t0") for r in tick_rows if r.get("current_price_t1_per_t0") is not None), None
        )
        x_vals = [r["tick_price_t1_per_t0"] for r in tick_rows]
        usdc_cumul = [self._ff(r.get("token1_cumul")) for r in tick_rows]
        usx_cumul = [self._ff(r.get("token0_cumul")) for r in tick_rows]

        if current_price_raw is not None:
            try:
                cpf = float(current_price_raw)
                for idx, v in enumerate(x_vals):
                    if abs(float(v) - cpf) <= 1e-12:
                        usdc_cumul[idx] = 0
                        usx_cumul[idx] = 0
                        break
            except (TypeError, ValueError):
                pass

        scenario_pct = self._ff(params.get("risk_liq_scenario", 25))
        ml = self._xp_liquidation_mark_lines(tick_rows, scenario_pct)

        return {
            "kind": "chart",
            "chart": "line-area",
            "x": x_vals,
            "xAxisLabel": "Price (USDC per USX)",
            "yAxisLabel": "Cumulative Liquidity",
            "yAxisFormat": "compact",
            "reference_lines": {"peg": 1.0, "current_price": current_price_raw},
            "mark_lines": ml,
            "series": [
                {"name": "USDC Cumulative", "type": "line", "area": True, "data": usdc_cumul},
                {"name": "USX Cumulative", "type": "line", "area": True, "data": usx_cumul},
            ],
        }

    # ------------------------------------------------------------------
    # Section 3: Lending Market Liquidations Risk
    # ------------------------------------------------------------------

    def _ra_stress_test(self, params: dict[str, Any]) -> dict[str, Any]:
        coll_asset = str(params.get("risk_stress_collateral", ""))
        debt_asset = str(params.get("risk_stress_debt", ""))
        rows = sorted(
            self._sensitivity_rows(coll_asset, debt_asset),
            key=lambda r: float(r.get("pct_change") or 0),
        )
        last = self._kamino_v_last_row()
        coll_symbols = ", ".join(str(s) for s in (last.get("reserve_coll_all_symbols_array") or []) if s)
        brw_symbols = ", ".join(str(s) for s in (last.get("reserve_brw_all_symbols_array") or []) if s)
        coll_list = [str(s) for s in (last.get("reserve_coll_all_symbols_array") or []) if s]
        brw_list = [str(s) for s in (last.get("reserve_brw_all_symbols_array") or []) if s]

        vol_map = self._price_volatility_7d()

        def _most_volatile(symbols: list[str]) -> tuple[str, float]:
            best_sym, best_pct = "", 0.0
            for s in symbols:
                pct = vol_map.get(s, 0.0)
                if pct > best_pct:
                    best_sym, best_pct = s, pct
            return best_sym, best_pct

        coll_sym, coll_sigma = _most_volatile(coll_list)
        brw_sym, brw_sigma = _most_volatile(brw_list)

        vol_lines: list[dict[str, Any]] = []
        for n in (2,):
            if coll_sym and coll_sigma > 0:
                vol_lines.append({
                    "label": f"-{n}\u03c3 {coll_sym}",
                    "value": -(coll_sigma * n),
                    "color": "#28c987",
                })
            if brw_sym and brw_sigma > 0:
                vol_lines.append({
                    "label": f"+{n}\u03c3 {brw_sym}",
                    "value": brw_sigma * n,
                    "color": "#28c987",
                })

        asset_options = {
            "collateral": coll_list,
            "debt": brw_list,
        }

        return {
            "kind": "chart",
            "chart": "line-area",
            "x": [r.get("pct_change") for r in rows],
            "xAxisLabel": "Price Change (%)",
            "direction_arrows": {"left": coll_symbols, "right": brw_symbols},
            "series": [
                {"name": "Liquidatable Value", "type": "line", "area": True, "stack": "debt", "color": "#4170a8",
                 "data": [r.get("total_liquidatable_value") for r in rows]},
                {"name": "Unhealthy Debt", "type": "line", "area": True, "stack": "debt", "color": "#c9a032",
                 "data": [r.get("unhealthy_debt_less_liquidatable_part") for r in rows]},
                {"name": "Bad Debt", "type": "line", "area": True, "stack": "debt", "color": "#e24c4c",
                 "data": [r.get("bad_debt_less_liquidatable_part") for r in rows]},
                {"name": "Price volatility levels", "type": "line", "color": "#28c987", "data": []},
            ],
            "volatility_lines": vol_lines,
            "asset_options": asset_options,
        }

    def _ra_sensitivity_table(self, params: dict[str, Any]) -> dict[str, Any]:
        coll_asset = str(params.get("risk_stress_collateral", ""))
        debt_asset = str(params.get("risk_stress_debt", ""))
        rows = self._sensitivity_rows(coll_asset, debt_asset)
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
