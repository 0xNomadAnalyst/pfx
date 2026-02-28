from __future__ import annotations

import math
import os
from typing import Any

from app.services.pages.base import BasePageService


class DexLiquidityPageService(BasePageService):
    page_id = "playbook-liquidity"
    _META_TTL_SECONDS = float(os.getenv("DEX_LIQUIDITY_META_TTL_SECONDS", "300"))
    _TICK_DIST_TTL_SECONDS = float(os.getenv("DEX_LIQUIDITY_TICK_DIST_TTL_SECONDS", "120"))
    _DEX_LAST_TTL_SECONDS = float(os.getenv("DEX_LIQUIDITY_DEX_LAST_TTL_SECONDS", "120"))
    _TIMESERIES_TTL_SECONDS = float(os.getenv("DEX_LIQUIDITY_TIMESERIES_TTL_SECONDS", "120"))
    _DEPTH_TABLE_TTL_SECONDS = float(os.getenv("DEX_LIQUIDITY_DEPTH_TABLE_TTL_SECONDS", "300"))
    _RANKED_LP_TTL_SECONDS = float(os.getenv("DEX_LIQUIDITY_RANKED_LP_TTL_SECONDS", "120"))
    _RANKED_LP_TIMEOUT_MS = int(os.getenv("DEX_LIQUIDITY_RANKED_LP_TIMEOUT_MS", "5000"))
    _RANKED_LP_FALLBACK_LOOKBACK = os.getenv("DEX_LIQUIDITY_RANKED_LP_FALLBACK_LOOKBACK", "12 hours")
    _DEX_LAST_TIMEOUT_MS = int(os.getenv("DEX_LIQUIDITY_DEX_LAST_TIMEOUT_MS", "8000"))

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._handlers = {
            "liquidity-distribution": self._liquidity_distribution,
            "liquidity-depth": self._liquidity_depth,
            "liquidity-change-heatmap": self._liquidity_change_heatmap,
            "kpi-tvl": self._kpi_tvl,
            "kpi-impact-500k": self._kpi_impact_500k,
            "kpi-reserves": self._kpi_reserves,
            "kpi-largest-impact": self._kpi_largest_impact,
            "kpi-pool-balance": self._kpi_pool_balance,
            "kpi-average-impact": self._kpi_average_impact,
            "liquidity-depth-table": self._liquidity_depth_table,
            "usdc-pool-share-concentration": self._usdc_pool_share_concentration,
            "trade-size-to-impact": self._trade_size_to_impact,
            "usdc-lp-flows": self._usdc_lp_flows,
            "impact-from-trade-size": self._impact_from_trade_size,
            "trade-impact-toggle": self._trade_impact_toggle,
            "ranked-lp-events": self._ranked_lp_events,
        }

    def get_meta(self) -> dict[str, Any]:
        def _load_meta() -> dict[str, Any]:
            query = """
                SELECT DISTINCT LOWER(protocol) AS protocol, token_pair
                FROM dexes.src_acct_tickarray_queries
                ORDER BY 1, 2
            """
            rows = self.sql.fetch_rows(query)
            protocol_pairs: list[dict[str, str]] = []
            protocols: list[str] = []
            seen_protocols: set[str] = set()
            for row in rows:
                protocol = str(row.get("protocol") or "").strip()
                pair = str(row.get("token_pair") or "").strip()
                if not protocol or not pair:
                    continue
                protocol_pairs.append({"protocol": protocol, "pair": pair})
                if protocol not in seen_protocols:
                    seen_protocols.add(protocol)
                    protocols.append(protocol)
            return {"protocols": protocols, "protocol_pairs": protocol_pairs}

        return self._cached("meta::protocol_pairs", _load_meta, ttl_seconds=self._META_TTL_SECONDS)

    def _tick_dist_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        protocol = str(params.get("protocol", "raydium"))
        pair = str(params.get("pair", "USX-USDC"))
        delta_time = str(params.get("tick_delta_time", "1 hour"))

        def _run_query(active_delta_time: str) -> list[dict[str, Any]]:
            query = """
                SELECT
                    tick_price_t1_per_t0,
                    current_price_t1_per_t0,
                    token0_value,
                    token1_value,
                    token1_cumul,
                    token0_cumul,
                    liquidity_period_delta_in_t1_units_pct
                FROM dexes.get_view_tick_dist_simple(%s, %s, %s::interval)
                ORDER BY tick_price_t1_per_t0
            """
            return self.sql.fetch_rows(query, (protocol, pair, active_delta_time))

        def _load_rows() -> list[dict[str, Any]]:
            try:
                return _run_query(delta_time)
            except Exception as exc:
                is_timeout = "statement timeout" in str(exc).lower()
                if not is_timeout or delta_time == "24 hours":
                    raise
                # Fallback keeps widget responsive when short-window queries time out.
                return _run_query("24 hours")

        cache_key = f"tick_dist::{protocol}::{pair}::{delta_time}"
        return self._cached(cache_key, _load_rows, ttl_seconds=self._TICK_DIST_TTL_SECONDS)

    @staticmethod
    def _finite_float(value: Any) -> float | None:
        try:
            numeric = float(value)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(numeric):
            return None
        return numeric

    def _snapped_tick_reference_price(self, rows: list[dict[str, Any]]) -> float | None:
        raw_current_price = None
        for row in rows:
            candidate_price = self._finite_float(row.get("current_price_t1_per_t0"))
            if candidate_price is not None and candidate_price > 0:
                raw_current_price = candidate_price
                break
        if raw_current_price is None:
            return None

        # Prefer the active overlap tick where both token sides are populated.
        overlap_tick_prices: list[float] = []
        for row in rows:
            tick_price = self._finite_float(row.get("tick_price_t1_per_t0"))
            token0_value = self._finite_float(row.get("token0_value")) or 0.0
            token1_value = self._finite_float(row.get("token1_value")) or 0.0
            if tick_price is None:
                continue
            if token0_value > 0 and token1_value > 0:
                overlap_tick_prices.append(tick_price)
        if overlap_tick_prices:
            return min(overlap_tick_prices, key=lambda tick_price: abs(tick_price - raw_current_price))

        # Fallback: snap to nearest available tick bin so the reference line aligns with bars.
        tick_prices = [self._finite_float(row.get("tick_price_t1_per_t0")) for row in rows]
        valid_tick_prices = [price for price in tick_prices if price is not None]
        if not valid_tick_prices:
            return raw_current_price
        return min(valid_tick_prices, key=lambda tick_price: abs(tick_price - raw_current_price))

    @staticmethod
    def _timeseries_window_config(last_window: str) -> tuple[str, str, int]:
        window = (last_window or "24h").lower()
        mapping: dict[str, tuple[str, str, int]] = {
            "1h": ("1 hour", "1 minute", 60),
            "4h": ("4 hours", "5 minutes", 48),
            "6h": ("6 hours", "5 minutes", 72),
            "24h": ("24 hours", "15 minutes", 96),
            "7d": ("7 days", "1 hour", 168),
            "30d": ("30 days", "4 hours", 180),
            "90d": ("90 days", "12 hours", 180),
        }
        return mapping.get(window, mapping["24h"])

    def _dex_last_row(self, params: dict[str, Any]) -> dict[str, Any]:
        protocol = str(params.get("protocol", "raydium"))
        pair = str(params.get("pair", "USX-USDC"))
        lookback = str(params.get("lookback", "1 day"))
        last_window = str(params.get("last_window", "24h"))
        lookback_from_window, _, _ = self._timeseries_window_config(last_window)
        lookback = lookback_from_window or lookback

        def _run_query(active_lookback: str) -> dict[str, Any]:
            query = """
                SELECT
                    tvl_in_t1_units,
                    impact_from_t0_sell3_bps,
                    reserve_t0_t1_millions,
                    swap_token0_in_max_impact_bps,
                    swap_token0_in_max,
                    reserve_t0_t1_balance_pct,
                    swap_token0_in_avg_impact_bps,
                    swap_token0_in_avg
                FROM dexes.get_view_dex_last(%s, %s, %s::interval)
                LIMIT 1
            """
            rows = self.sql.fetch_rows(
                query,
                (protocol, pair, active_lookback),
                statement_timeout_ms=self._DEX_LAST_TIMEOUT_MS,
            )
            return rows[0] if rows else {}

        def _load_row() -> dict[str, Any]:
            try:
                return _run_query(lookback)
            except Exception as exc:
                is_timeout = "statement timeout" in str(exc).lower()
                fallback_lookback = str(params.get("lookback", "1 day"))
                if not is_timeout or lookback == fallback_lookback:
                    raise
                return _run_query(fallback_lookback)

        cache_key = f"dex_last::{protocol}::{pair}::{lookback}"
        return self._cached(cache_key, _load_row, ttl_seconds=self._DEX_LAST_TTL_SECONDS)

    def _dex_timeseries_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        protocol = str(params.get("protocol", "raydium"))
        pair = str(params.get("pair", "USX-USDC"))
        interval = str(params.get("interval", "5 minutes"))
        rows = int(params.get("rows", 120))
        last_window = str(params.get("last_window", "24h"))
        _, interval_from_window, rows_from_window = self._timeseries_window_config(last_window)
        interval = interval_from_window or interval
        rows = rows_from_window if rows_from_window > 0 else rows

        def _load_rows() -> list[dict[str, Any]]:
            query = """
                SELECT
                    time,
                    reserve_t1_pct,
                    concentration_avg_peg_pct_1_last,
                    sell_t0_for_impact1_avg_w_last,
                    sell_t0_for_impact2_avg_w_last,
                    sell_t0_for_impact3_avg_w_last,
                    lp_t1_in,
                    lp_t1_out,
                    lp_t1_net_pct_reserve,
                    impact_from_t0_sell1_bps_avg_w_last,
                    impact_from_t0_sell2_bps_avg_w_last,
                    impact_from_t0_sell3_bps_avg_w_last,
                    impact_t0_quantities
                FROM dexes.get_view_dex_timeseries(%s, %s, %s, %s)
                ORDER BY time
            """
            return self.sql.fetch_rows(query, (protocol, pair, interval, rows))

        cache_key = f"dex_timeseries::{protocol}::{pair}::{interval}::{rows}"
        return self._cached(cache_key, _load_rows, ttl_seconds=self._TIMESERIES_TTL_SECONDS)

    def _liquidity_distribution(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._tick_dist_rows(params)
        current_price = self._snapped_tick_reference_price(rows)
        return {
            "kind": "chart",
            "chart": "bar",
            "x": [row["tick_price_t1_per_t0"] for row in rows],
            "xAxisLabel": "Price (USDC per USX)",
            "yAxisLabel": "Liquidity Amount",
            "yAxisFormat": "compact",
            "reference_lines": {
                "peg": 1.0,
                "current_price": current_price,
            },
            "series": [
                {"name": "USX Liquidity", "type": "bar", "stack": "active-tick-liquidity", "data": [row["token0_value"] for row in rows]},
                {"name": "USDC Liquidity", "type": "bar", "stack": "active-tick-liquidity", "data": [row["token1_value"] for row in rows]},
            ],
        }

    def _liquidity_depth(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._tick_dist_rows(params)
        current_price = next((row.get("current_price_t1_per_t0") for row in rows if row.get("current_price_t1_per_t0") is not None), None)
        x_values = [row["tick_price_t1_per_t0"] for row in rows]

        def _clean_depth_value(raw: Any) -> float:
            try:
                numeric = float(raw)
            except (TypeError, ValueError):
                return 0.0
            return numeric if math.isfinite(numeric) else 0.0

        usdc_cumul = [_clean_depth_value(row.get("token1_cumul")) for row in rows]
        usx_cumul = [_clean_depth_value(row.get("token0_cumul")) for row in rows]

        # Ensure both cumulative curves meet at the active tick on a shared x value.
        if current_price is not None and x_values:
            try:
                current_price_float = float(current_price)
            except (TypeError, ValueError):
                current_price_float = None
            if current_price_float is not None:
                existing_index = None
                for idx, value in enumerate(x_values):
                    try:
                        if abs(float(value) - current_price_float) <= 1e-12:
                            existing_index = idx
                            break
                    except (TypeError, ValueError):
                        continue
                if existing_index is not None:
                    usdc_cumul[existing_index] = 0
                    usx_cumul[existing_index] = 0
                else:
                    insert_idx = 0
                    while insert_idx < len(x_values):
                        try:
                            if float(x_values[insert_idx]) >= current_price_float:
                                break
                        except (TypeError, ValueError):
                            pass
                        insert_idx += 1
                    x_values.insert(insert_idx, current_price_float)
                    usdc_cumul.insert(insert_idx, 0)
                    usx_cumul.insert(insert_idx, 0)

        return {
            "kind": "chart",
            "chart": "line-area",
            "x": x_values,
            "xAxisLabel": "Price (USDC per USX)",
            "yAxisLabel": "Cumulative Liquidity",
            "yAxisFormat": "compact",
            "reference_lines": {
                "peg": 1.0,
                "current_price": current_price,
            },
            "series": [
                {"name": "USDC Cumulative", "type": "line", "area": True, "data": usdc_cumul},
                {"name": "USX Cumulative", "type": "line", "area": True, "data": usx_cumul},
            ],
        }

    def _liquidity_change_heatmap(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._tick_dist_rows(params)
        x_axis = [row["tick_price_t1_per_t0"] for row in rows]
        current_price = next((row.get("current_price_t1_per_t0") for row in rows if row.get("current_price_t1_per_t0") is not None), None)
        raw_values = [float(row.get("liquidity_period_delta_in_t1_units_pct") or 0) for row in rows]
        max_abs = max((abs(value) for value in raw_values), default=0.0)
        if max_abs == 0:
            values = [0.0 for _ in raw_values]
            min_value = -1.0
            max_value = 1.0
        else:
            deadband = max_abs * 0.1
            values = [0.0 if abs(value) <= deadband else value for value in raw_values]
            min_value = -max_abs
            max_value = max_abs
        points = [[idx, 0, value] for idx, value in enumerate(values)]
        return {
            "kind": "chart",
            "chart": "heatmap",
            "x": x_axis,
            "reference_lines": {
                "peg": 1.0,
                "current_price": current_price,
            },
            "points": points,
            "min": min_value,
            "max": max_value,
        }

    def _kpi_tvl(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {"kind": "kpi", "primary": row.get("tvl_in_t1_units"), "label": "TVL (USDC)"}

    def _kpi_impact_500k(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {
            "kind": "kpi",
            "primary": row.get("impact_from_t0_sell3_bps"),
            "secondary": 500000,
            "label": "500,000 USX sell impact (bps)",
        }

    def _kpi_reserves(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        reserve_pair = row.get("reserve_t0_t1_millions") or [None, None]
        return {
            "kind": "kpi",
            "primary": reserve_pair[0] if len(reserve_pair) > 0 else None,
            "secondary": reserve_pair[1] if len(reserve_pair) > 1 else None,
            "label": "Reserve balances (millions)",
        }

    def _kpi_largest_impact(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {
            "kind": "kpi",
            "primary": row.get("swap_token0_in_max_impact_bps"),
            "secondary": row.get("swap_token0_in_max"),
            "label": "Impact of largest USX sell trade",
        }

    def _kpi_pool_balance(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        balance_pair = row.get("reserve_t0_t1_balance_pct") or [None, None]
        return {
            "kind": "kpi",
            "primary": balance_pair[0] if len(balance_pair) > 0 else None,
            "secondary": balance_pair[1] if len(balance_pair) > 1 else None,
            "label": "Pool balance (%)",
        }

    def _kpi_average_impact(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {
            "kind": "kpi",
            "primary": row.get("swap_token0_in_avg_impact_bps"),
            "secondary": row.get("swap_token0_in_avg"),
            "label": "Impact of average USX sell trade",
        }

    def _liquidity_depth_table(self, params: dict[str, Any]) -> dict[str, Any]:
        protocol = str(params.get("protocol", "raydium"))
        pair = str(params.get("pair", "USX-USDC"))

        def _load_rows() -> list[dict[str, Any]]:
            query = """
                SELECT
                    bps_target,
                    price_change_pct,
                    calculated_price,
                    liquidity_in_band,
                    swap_size_equivalent,
                    pct_of_reserve
                FROM dexes.get_view_liquidity_depth_table(%s, %s)
                ORDER BY bps_target
            """
            return self.sql.fetch_rows(query, (protocol, pair))

        cache_key = f"depth_table::{protocol}::{pair}"
        rows = self._cached(cache_key, _load_rows, ttl_seconds=self._DEPTH_TABLE_TTL_SECONDS)
        return {
            "kind": "table",
            "columns": [
                {"key": "bps_target", "label": "Δ (bps)"},
                {"key": "price_change_pct", "label": "Δ (%)"},
                {"key": "calculated_price", "label": "Price"},
                {"key": "liquidity_in_band", "label": "Band Liquidity"},
                {"key": "swap_size_equivalent", "label": "Order Size"},
                {"key": "pct_of_reserve", "label": "% Reserve"},
            ],
            "rows": rows,
        }

    def _usdc_pool_share_concentration(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "line-area",
            "x": [row["time"] for row in rows],
            "yAxisLabel": "% of Pool",
            "series": [
                {"name": "USDC %", "type": "line", "data": [row.get("reserve_t1_pct") for row in rows]},
                {
                    "name": "Concentration ±5bps %",
                    "type": "line",
                    "area": True,
                    "data": [row.get("concentration_avg_peg_pct_1_last") for row in rows],
                },
            ],
        }

    def _trade_size_to_impact(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["time"] for row in rows],
            "yAxisLabel": "Equivalent Swap Size",
            "series": [
                {"name": "1 bps", "type": "line", "data": [row.get("sell_t0_for_impact1_avg_w_last") for row in rows]},
                {"name": "2 bps", "type": "line", "data": [row.get("sell_t0_for_impact2_avg_w_last") for row in rows]},
                {"name": "3 bps", "type": "line", "data": [row.get("sell_t0_for_impact3_avg_w_last") for row in rows]},
            ],
        }

    def _usdc_lp_flows(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["time"] for row in rows],
            "yAxisLabel": "USDC",
            "yRightAxisLabel": "% USDC Reserve",
            "series": [
                {"name": "LP In", "type": "bar", "color": "#2fbf71", "data": [row.get("lp_t1_in") for row in rows]},
                {"name": "LP Out", "type": "bar", "color": "#e24c4c", "data": [-(abs(float(row.get("lp_t1_out") or 0))) for row in rows]},
                {"name": "LP Net % Reserve", "type": "line", "color": "#38d39f", "yAxisIndex": 1, "data": [row.get("lp_t1_net_pct_reserve") for row in rows]},
            ],
        }

    def _impact_from_trade_size(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["time"] for row in rows],
            "yAxisLabel": "Simulated Trade Impact (bps)",
            "series": [
                {"name": "1 bps bucket", "type": "line", "data": [row.get("impact_from_t0_sell1_bps_avg_w_last") for row in rows]},
                {"name": "2 bps bucket", "type": "line", "data": [row.get("impact_from_t0_sell2_bps_avg_w_last") for row in rows]},
                {"name": "3 bps bucket", "type": "line", "data": [row.get("impact_from_t0_sell3_bps_avg_w_last") for row in rows]},
            ],
        }

    def _trade_impact_toggle(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        mode = str(params.get("impact_mode", "size")).lower()

        if mode == "impact":
            levels: list[Any] = []
            for row in reversed(rows):
                quantities = row.get("impact_t0_quantities")
                if isinstance(quantities, list) and len(quantities) >= 3:
                    levels = quantities[:3]
                    break

            def _level_label(index: int) -> str:
                if index < len(levels):
                    try:
                        return f"{int(float(levels[index])):,} size"
                    except (TypeError, ValueError):
                        return f"L{index + 1}"
                return f"L{index + 1}"

            return {
                "kind": "chart",
                "chart": "line",
                "mode": "impact",
                "x": [row["time"] for row in rows],
                "yAxisLabel": "Simulated Trade Impact (bps)",
                "series": [
                    {"name": _level_label(0), "type": "line", "data": [row.get("impact_from_t0_sell1_bps_avg_w_last") for row in rows]},
                    {"name": _level_label(1), "type": "line", "data": [row.get("impact_from_t0_sell2_bps_avg_w_last") for row in rows]},
                    {"name": _level_label(2), "type": "line", "data": [row.get("impact_from_t0_sell3_bps_avg_w_last") for row in rows]},
                ],
            }

        return {
            "kind": "chart",
            "chart": "line",
            "mode": "size",
            "x": [row["time"] for row in rows],
            "yAxisLabel": "Equivalent Swap Size",
            "series": [
                {"name": "1 bps", "type": "line", "data": [row.get("sell_t0_for_impact1_avg_w_last") for row in rows]},
                {"name": "2 bps", "type": "line", "data": [row.get("sell_t0_for_impact2_avg_w_last") for row in rows]},
                {"name": "3 bps", "type": "line", "data": [row.get("sell_t0_for_impact3_avg_w_last") for row in rows]},
            ],
        }

    def _ranked_lp_events(self, params: dict[str, Any]) -> dict[str, Any]:
        protocol = str(params.get("protocol", "raydium"))
        pair = str(params.get("pair", "USX-USDC"))
        rows = int(params.get("rows", 12))
        lookback = str(params.get("lookback", "1 day"))
        last_window = str(params.get("last_window", "24h"))
        lookback_from_window, _, _ = self._timeseries_window_config(last_window)
        lookback = lookback_from_window or lookback

        def _run_ranked(direction: str, active_lookback: str) -> list[dict[str, Any]]:
            query = """
                SELECT
                    tx_time,
                    primary_flow,
                    primary_flow_reserve_pct_now,
                    signature
                FROM dexes.get_view_dex_table_ranked_events(
                    %s, %s, 'lp', 't1', %s, %s, %s
                )
            """
            return self.sql.fetch_rows(
                query,
                (protocol, pair, direction, rows, active_lookback),
                statement_timeout_ms=self._RANKED_LP_TIMEOUT_MS,
            )

        def _load_ranked(direction: str) -> list[dict[str, Any]]:
            try:
                return _run_ranked(direction, lookback)
            except Exception as exc:
                is_timeout = "statement timeout" in str(exc).lower()
                if not is_timeout:
                    raise
                if lookback != self._RANKED_LP_FALLBACK_LOOKBACK:
                    return _run_ranked(direction, self._RANKED_LP_FALLBACK_LOOKBACK)
                if lookback != "24 hours":
                    return _run_ranked(direction, "24 hours")
                raise

        top_in = self._cached(
            f"ranked_lp::{protocol}::{pair}::in::{rows}::{lookback}",
            lambda: _load_ranked("in"),
            ttl_seconds=self._RANKED_LP_TTL_SECONDS,
        )
        top_out = self._cached(
            f"ranked_lp::{protocol}::{pair}::out::{rows}::{lookback}",
            lambda: _load_ranked("out"),
            ttl_seconds=self._RANKED_LP_TTL_SECONDS,
        )
        return {
            "kind": "table-split",
            "columns": [
                {"key": "tx_time", "label": "Time"},
                {"key": "primary_flow", "label": "Amount"},
                {"key": "primary_flow_reserve_pct_now", "label": "% Reserve Now"},
                {"key": "signature", "label": "Tx Signature"},
            ],
            # Match React split layout semantics: Removed on left, Added on right.
            "left_title": "Liquidity Removed",
            "right_title": "Liquidity Added",
            "left_rows": top_out,
            "right_rows": top_in,
        }
