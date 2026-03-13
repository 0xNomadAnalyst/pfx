from __future__ import annotations

import logging
import math
import os
from typing import Any

from app.services.pages.base import BasePageService

logger = logging.getLogger(__name__)


class RiskAnalysisPageService(BasePageService):
    page_id = "risk-analysis"
    default_protocol = "orca"
    default_pair = "ONyc-USDC"

    _POOL_REF_TTL_SECONDS = float(os.getenv("RA_POOL_REF_TTL_SECONDS", "600"))
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
    # Pool token reference lookup (per protocol)
    # ------------------------------------------------------------------

    def _pool_ref(self, protocol: str) -> dict[str, str]:
        """Fetch token_pair, token0_symbol, token1_symbol from the pool
        reference table for a given protocol.  Cached per protocol."""
        cache_key = f"ra::pool_ref::{protocol}"

        def _load() -> dict[str, str]:
            try:
                rows = self.sql.fetch_rows(
                    "SELECT token_pair, token0_symbol, token1_symbol "
                    "FROM dexes.pool_tokens_reference "
                    "WHERE protocol = %s LIMIT 1",
                    (protocol,),
                )
                if rows:
                    return {
                        "token_pair": str(rows[0].get("token_pair") or ""),
                        "token0_symbol": str(rows[0].get("token0_symbol") or ""),
                        "token1_symbol": str(rows[0].get("token1_symbol") or ""),
                    }
            except Exception as exc:
                logger.warning("_pool_ref query failed for %s: %s", protocol, exc)
            return {"token_pair": "", "token0_symbol": "", "token1_symbol": ""}

        return self._cached(cache_key, _load, ttl_seconds=self._POOL_REF_TTL_SECONDS)

    def _pair(self, protocol: str) -> str:
        return self._pool_ref(protocol).get("token_pair") or "ONyc-USDC"

    def _pair_lower(self, protocol: str) -> str:
        return self._pair(protocol).lower()

    def _token0(self, protocol: str) -> str:
        return self._pool_ref(protocol).get("token0_symbol") or "ONyc"

    def _token1(self, protocol: str) -> str:
        return self._pool_ref(protocol).get("token1_symbol") or "USDC"

    _COLOR_ONYC = "#f0a030"
    _COLOR_COUNTER = "#5470c6"

    def _token_color(self, symbol: str) -> str:
        return self._COLOR_ONYC if symbol.upper() == "ONYC" else self._COLOR_COUNTER

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
                    (protocol, self._pair_lower(protocol), event_type, interval),
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
                    (protocol, self._pair(protocol), "1 hour"),
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

    def _sell_is_token1(self, protocol: str | None) -> bool:
        """True when the non-stablecoin (sell) token is token1 in the pair."""
        if not protocol:
            return False
        ref = self._pool_ref(protocol)
        t0_sym = ref.get("token0_symbol", "")
        stables = {"USDC", "USDG", "USDT"}
        return t0_sym.upper() in stables

    def _map_sell_amount_to_price(
        self, tick_rows: list[dict[str, Any]], sell_amount: float,
        protocol: str | None = None,
    ) -> tuple[float | None, bool]:
        """Walk ticks away from the current price in the direction that a sell
        of the non-stablecoin token pushes the market.

        * ONyc is token0 (Orca): selling pushes price DOWN  -> walk LEFT
        * ONyc is token1 (Raydium): selling pushes price UP -> walk RIGHT

        On the impact side the dominant physical token is token1 (RIGHT) or
        token0 (LEFT); we convert to sell-token units for a fair comparison.

        Returns ``(price, exhausted)`` — *exhausted* is True when liquidity
        runs out before the full sell amount is absorbed.
        """
        current_price = self._snapped_price(tick_rows)
        if current_price is None or sell_amount <= 0:
            return None, False

        sell_t1 = self._sell_is_token1(protocol)

        impact_ticks: list[tuple[float, float]] = []
        for r in tick_rows:
            tp = self._ff(r.get("tick_price_t1_per_t0"))
            if tp <= 0:
                continue
            if sell_t1 and tp < current_price:
                continue
            if not sell_t1 and tp > current_price:
                continue
            t0_val = self._ff(r.get("token0_value"))
            t1_val = self._ff(r.get("token1_value"))
            if sell_t1:
                capacity = t1_val + t0_val * tp
            else:
                capacity = t0_val + (t1_val / tp if tp > 0 else 0)
            impact_ticks.append((tp, capacity))

        if sell_t1:
            impact_ticks.sort(key=lambda x: x[0])
        else:
            impact_ticks.sort(key=lambda x: x[0], reverse=True)

        remaining = sell_amount
        last_price = current_price
        for price, liquidity in impact_ticks:
            if remaining <= 0:
                break
            remaining -= liquidity
            last_price = price

        return last_price, remaining > 0

    def _pvalue_mark_lines(
        self, tick_rows: list[dict[str, Any]], pvalue_rows: list[dict[str, Any]],
        protocol: str | None = None,
    ) -> list[dict[str, Any]]:
        lines: list[dict[str, Any]] = []
        colors = ["#e24c4c", "#f8a94a", "#c9a032", "#ae82ff", "#4bb7ff", "#2fbf71", "#5c8a8a", "#888", "#aaa"]
        for idx, row in enumerate(pvalue_rows):
            stat = row.get("stat_name", "")
            value = self._ff(row.get("value"))
            if value <= 0:
                continue
            price, _ = self._map_sell_amount_to_price(tick_rows, value, protocol)
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
            {"key": "value", "label": "Sell Amount"},
            {"key": "event_count_at_or_above", "label": "Counts at or above"},
            {"key": "last_observed_at", "label": "Last observed"},
        ]
        subtitle = f"Refreshes Daily - Last Refresh at {refresh_date}" if refresh_date else ""
        return {
            "kind": "table-split",
            "columns": columns,
            "left_title": f"Raydium {self._pair('raydium')}",
            "left_rows": ray_rows,
            "right_title": f"Orca {self._pair('orca')}",
            "right_rows": orca_rows,
            "subtitle": subtitle,
            "window_label": "All Time",
        }

    def _ra_liq_dist(self, params: dict[str, Any], protocol: str) -> dict[str, Any]:
        tick_rows = self._tick_dist_rows(protocol)
        current_price = self._snapped_price(tick_rows)
        event_type, interval = self._event_type_and_interval(params)
        pv_rows = self._pvalue_rows(protocol, event_type, interval)
        ml = self._pvalue_mark_lines(tick_rows, pv_rows, protocol)

        return {
            "kind": "chart",
            "chart": "bar",
            "x": [r["tick_price_t1_per_t0"] for r in tick_rows],
            "xAxisLabel": f"Price ({self._token1(protocol)} per {self._token0(protocol)})",
            "yAxisLabel": "Liquidity Amount",
            "yAxisFormat": "compact",
            "reference_lines": {"peg": 1.0, "current_price": current_price},
            "mark_lines": ml,
            "series": [
                {"name": f"{self._token0(protocol)} Liquidity", "type": "bar", "stack": "liq", "data": [r["token0_value"] for r in tick_rows], "color": self._token_color(self._token0(protocol))},
                {"name": f"{self._token1(protocol)} Liquidity", "type": "bar", "stack": "liq", "data": [r["token1_value"] for r in tick_rows], "color": self._token_color(self._token1(protocol))},
            ],
        }

    def _ra_liq_depth(self, params: dict[str, Any], protocol: str) -> dict[str, Any]:
        tick_rows = self._tick_dist_rows(protocol)
        current_price_raw = next(
            (r.get("current_price_t1_per_t0") for r in tick_rows if r.get("current_price_t1_per_t0") is not None), None
        )
        x_vals = [r["tick_price_t1_per_t0"] for r in tick_rows]
        usdc_cumul = [self._ff(r.get("token1_cumul")) for r in tick_rows]
        t0_cumul = [self._ff(r.get("token0_cumul")) for r in tick_rows]

        if current_price_raw is not None:
            try:
                cpf = float(current_price_raw)
                for idx, v in enumerate(x_vals):
                    if abs(float(v) - cpf) <= 1e-12:
                        usdc_cumul[idx] = 0
                        t0_cumul[idx] = 0
                        break
            except (TypeError, ValueError):
                pass

        event_type, interval = self._event_type_and_interval(params)
        pv_rows = self._pvalue_rows(protocol, event_type, interval)
        ml = self._pvalue_mark_lines(tick_rows, pv_rows, protocol)

        return {
            "kind": "chart",
            "chart": "line-area",
            "x": x_vals,
            "xAxisLabel": f"Price ({self._token1(protocol)} per {self._token0(protocol)})",
            "yAxisLabel": "Cumulative Liquidity",
            "yAxisFormat": "compact",
            "reference_lines": {"peg": 1.0, "current_price": current_price_raw},
            "mark_lines": ml,
            "series": [
                {"name": f"{self._token1(protocol)} Cumulative", "type": "line", "area": True, "data": usdc_cumul, "color": self._token_color(self._token1(protocol))},
                {"name": f"{self._token0(protocol)} Cumulative", "type": "line", "area": True, "data": t0_cumul, "color": self._token_color(self._token0(protocol))},
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
            price, _ = self._map_sell_amount_to_price(tick_rows, sell_amount, protocol)
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
            "xAxisLabel": f"Price ({self._token1(protocol)} per {self._token0(protocol)})",
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

    def _pool_impact_liquidity(self, protocol: str) -> dict[str, Any]:
        """Counter-asset liquidity on the sell-impact side of the pool.

        Returns the raw stablecoin balance available to absorb a sell of ONyc,
        along with the stablecoin symbol.
        """
        tick_rows = self._tick_dist_rows(protocol)
        current_price = self._snapped_price(tick_rows) or 0
        sell_t1 = self._sell_is_token1(protocol)
        ref = self._pool_ref(protocol) if protocol else {}
        if sell_t1:
            counter_sym = ref.get("token0_symbol", "USD")
        else:
            counter_sym = ref.get("token1_symbol", "USD")

        counter_total = 0.0
        for r in tick_rows:
            tp = self._ff(r.get("tick_price_t1_per_t0"))
            if tp <= 0:
                continue
            if sell_t1 and tp < current_price:
                continue
            if not sell_t1 and tp > current_price:
                continue
            t0_val = self._ff(r.get("token0_value"))
            t1_val = self._ff(r.get("token1_value"))
            if sell_t1:
                counter_total += t0_val
            else:
                counter_total += t1_val
        return {"amount": counter_total, "symbol": counter_sym}

    @staticmethod
    def _fmt_compact(value: float) -> str:
        if value >= 1e6:
            return f"{value / 1e6:.1f}M"
        if value >= 1e3:
            return f"{value / 1e3:.0f}K"
        return f"{value:,.0f}"

    def _ra_xp_exposure(self, params: dict[str, Any]) -> dict[str, Any]:
        xp = self._xp_last()
        kamino = self._ff(xp.get("onyc_in_kamino"))
        exponent = self._ff(xp.get("onyc_in_exponent"))
        total = self._ff(xp.get("onyc_tracked_total"))
        kam_pct = self._ff(xp.get("onyc_in_kamino_pct"))
        exp_pct = self._ff(xp.get("onyc_in_exponent_pct"))
        fmt = self._fmt_compact

        primary_parts = []
        if kamino > 0:
            primary_parts.append(f"Kamino: {fmt(kamino)} ONyc ({kam_pct:.1f}%)")
        if exponent > 0:
            primary_parts.append(f"Exponent: {fmt(exponent)} ONyc ({exp_pct:.1f}%)")
        primary = " | ".join(primary_parts) if primary_parts else "--"
        secondary = f"Total tracked: {fmt(total)} ONyc" if total > 0 else ""

        ray_liq = self._pool_impact_liquidity("raydium")
        orca_liq = self._pool_impact_liquidity("orca")

        return {
            "kind": "kpi",
            "primary": primary,
            "secondary": secondary,
            "ray_downside_liq": ray_liq["amount"],
            "ray_downside_sym": ray_liq["symbol"],
            "orca_downside_liq": orca_liq["amount"],
            "orca_downside_sym": orca_liq["symbol"],
        }

    _XP_LIQUIDATION_PCTS = [1, 5, 10, 20, 50, 100]
    _XP_LIQUIDATION_COLORS = {
        1: "#5e8aae",
        5: "#6bc4a6",
        10: "#28c987",
        20: "#f0c431",
        50: "#e8853d",
        100: "#e24c4c",
    }

    def _xp_liquidation_mark_lines(
        self, tick_rows: list[dict[str, Any]], source: str,
        protocol: str = "orca",
    ) -> list[dict[str, Any]]:
        xp = self._xp_last()
        kamino = self._ff(xp.get("onyc_in_kamino"))
        exponent = self._ff(xp.get("onyc_in_exponent"))

        if source == "kamino":
            base_amount = kamino
        elif source == "exponent":
            base_amount = exponent
        else:
            base_amount = kamino + exponent

        current_price = self._snapped_price(tick_rows) or 0
        sell_t1 = self._sell_is_token1(protocol)

        total_impact_liq = 0.0
        for r in tick_rows:
            tp = self._ff(r.get("tick_price_t1_per_t0"))
            if tp <= 0:
                continue
            if sell_t1 and tp < current_price:
                continue
            if not sell_t1 and tp > current_price:
                continue
            t0_val = self._ff(r.get("token0_value"))
            t1_val = self._ff(r.get("token1_value"))
            if sell_t1:
                total_impact_liq += t1_val + t0_val * tp
            else:
                total_impact_liq += t0_val + (t1_val / tp if tp > 0 else 0)

        logger.info(
            "xp_mark_lines: protocol=%s source=%s base_amount=%.2f "
            "total_impact_liq=%.2f sell_is_t1=%s ticks=%d",
            protocol, source, base_amount, total_impact_liq,
            sell_t1, len(tick_rows),
        )

        lines: list[dict[str, Any]] = []
        for pct in self._XP_LIQUIDATION_PCTS:
            sell_amount = base_amount * (pct / 100.0)
            if sell_amount <= 0:
                continue
            price, exhausted = self._map_sell_amount_to_price(
                tick_rows, sell_amount, protocol,
            )
            if price is None:
                continue
            if exhausted:
                absorbed_pct = (
                    (total_impact_liq / base_amount) * 100.0
                    if base_amount > 0
                    else 0.0
                )
                lines.append({
                    "value": price,
                    "label": f"~{absorbed_pct:.1f}% (liq. exhausted)",
                    "color": "#e24c4c",
                })
                break
            lines.append({
                "value": price,
                "label": f"{pct}%",
                "color": self._XP_LIQUIDATION_COLORS.get(pct, "#ae82ff"),
            })

        logger.info("xp_mark_lines result: %d lines  %s", len(lines), lines[:3])
        return lines

    def _ra_xp_dist(self, params: dict[str, Any], protocol: str) -> dict[str, Any]:
        tick_rows = self._tick_dist_rows(protocol)
        current_price = self._snapped_price(tick_rows)
        source = str(params.get("risk_liq_source", "all"))
        ml = self._xp_liquidation_mark_lines(tick_rows, source, protocol)

        return {
            "kind": "chart",
            "chart": "bar",
            "x": [r["tick_price_t1_per_t0"] for r in tick_rows],
            "xAxisLabel": f"Price ({self._token1(protocol)} per {self._token0(protocol)})",
            "yAxisLabel": "Liquidity Amount",
            "yAxisFormat": "compact",
            "reference_lines": {"peg": 1.0, "current_price": current_price},
            "mark_lines": ml,
            "series": [
                {"name": f"{self._token0(protocol)} Liquidity", "type": "bar", "stack": "liq", "data": [r["token0_value"] for r in tick_rows], "color": self._token_color(self._token0(protocol))},
                {"name": f"{self._token1(protocol)} Liquidity", "type": "bar", "stack": "liq", "data": [r["token1_value"] for r in tick_rows], "color": self._token_color(self._token1(protocol))},
            ],
        }

    def _ra_xp_depth(self, params: dict[str, Any], protocol: str) -> dict[str, Any]:
        tick_rows = self._tick_dist_rows(protocol)
        current_price_raw = next(
            (r.get("current_price_t1_per_t0") for r in tick_rows if r.get("current_price_t1_per_t0") is not None), None
        )
        x_vals = [r["tick_price_t1_per_t0"] for r in tick_rows]
        usdc_cumul = [self._ff(r.get("token1_cumul")) for r in tick_rows]
        t0_cumul = [self._ff(r.get("token0_cumul")) for r in tick_rows]

        if current_price_raw is not None:
            try:
                cpf = float(current_price_raw)
                for idx, v in enumerate(x_vals):
                    if abs(float(v) - cpf) <= 1e-12:
                        usdc_cumul[idx] = 0
                        t0_cumul[idx] = 0
                        break
            except (TypeError, ValueError):
                pass

        source = str(params.get("risk_liq_source", "all"))
        ml = self._xp_liquidation_mark_lines(tick_rows, source, protocol)

        return {
            "kind": "chart",
            "chart": "line-area",
            "x": x_vals,
            "xAxisLabel": f"Price ({self._token1(protocol)} per {self._token0(protocol)})",
            "yAxisLabel": "Cumulative Liquidity",
            "yAxisFormat": "compact",
            "reference_lines": {"peg": 1.0, "current_price": current_price_raw},
            "mark_lines": ml,
            "series": [
                {"name": f"{self._token1(protocol)} Cumulative", "type": "line", "area": True, "data": usdc_cumul, "color": self._token_color(self._token1(protocol))},
                {"name": f"{self._token0(protocol)} Cumulative", "type": "line", "area": True, "data": t0_cumul, "color": self._token_color(self._token0(protocol))},
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
