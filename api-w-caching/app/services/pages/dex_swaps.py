from __future__ import annotations

import math
import statistics
from datetime import UTC, datetime
from math import ceil
from typing import Any

from app.services.pages.base import BasePageService


class DexSwapsPageService(BasePageService):
    page_id = "dex-swaps"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._handlers = {
            "kpi-swap-volume-24h": self._kpi_swap_volume_24h,
            "kpi-swap-count-24h": self._kpi_swap_count_24h,
            "kpi-price-min-max": self._kpi_price_min_max,
            "kpi-vwap-buy-sell": self._kpi_vwap_buy_sell,
            "kpi-price-std-dev": self._kpi_price_std_dev,
            "kpi-vwap-spread": self._kpi_vwap_spread,
            "kpi-largest-usx-sell": self._kpi_largest_usx_sell,
            "kpi-largest-usx-buy": self._kpi_largest_usx_buy,
            "kpi-max-1h-sell-pressure": self._kpi_max_1h_sell_pressure,
            "kpi-max-1h-buy-pressure": self._kpi_max_1h_buy_pressure,
            "swaps-flows-toggle": self._swaps_flows_toggle,
            "swaps-price-impacts": self._swaps_price_impacts,
            "swaps-spread-volatility": self._swaps_spread_volatility,
            "swaps-directional-vwap-spread": self._swaps_spread_volatility,
            "swaps-ohlcv": self._swaps_ohlcv,
            "swaps-distribution-toggle": self._swaps_distribution_toggle,
            "swaps-sell-usx-distribution": self._swaps_sell_usx_distribution,
            "swaps-1h-net-sell-pressure-distribution": self._swaps_1h_net_sell_pressure_distribution,
            "swaps-ranked-events": self._swaps_ranked_events,
        }

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

    @staticmethod
    def _window_seconds(last_window: str) -> int:
        window = (last_window or "24h").lower()
        mapping: dict[str, int] = {
            "1h": 60 * 60,
            "4h": 4 * 60 * 60,
            "6h": 6 * 60 * 60,
            "24h": 24 * 60 * 60,
            "7d": 7 * 24 * 60 * 60,
            "30d": 30 * 24 * 60 * 60,
            "90d": 90 * 24 * 60 * 60,
        }
        return mapping.get(window, mapping["24h"])

    @staticmethod
    def _interval_seconds(interval: str) -> int:
        normalized = (interval or "").strip().lower()
        mapping: dict[str, int] = {
            "1 minute": 60,
            "5 minutes": 5 * 60,
            "15 minutes": 15 * 60,
            "1 hour": 60 * 60,
            "4 hours": 4 * 60 * 60,
            "12 hours": 12 * 60 * 60,
            "1 day": 24 * 60 * 60,
        }
        return mapping.get(normalized, 0)

    def _drop_incomplete_trailing_bucket(self, rows: list[dict[str, Any]], interval: str) -> list[dict[str, Any]]:
        if len(rows) < 2:
            return rows
        expected_seconds = self._interval_seconds(interval)
        if expected_seconds <= 0:
            return rows
        last_time_raw = rows[-1].get("time")
        if not last_time_raw:
            return rows
        try:
            last_time = datetime.fromisoformat(str(last_time_raw).replace("Z", "+00:00"))
        except ValueError:
            return rows
        if last_time.tzinfo is None:
            last_time = last_time.replace(tzinfo=UTC)
        now_utc = datetime.now(UTC)
        last_utc = last_time.astimezone(UTC)
        age_seconds = (now_utc - last_utc).total_seconds()
        # Treat latest bucket as incomplete if it is still inside the current interval window.
        if age_seconds < expected_seconds:
            return rows[:-1]
        # Also drop if last bucket equals the current interval bucket start.
        current_bucket_start = int(now_utc.timestamp() // expected_seconds) * expected_seconds
        last_bucket_start = int(last_utc.timestamp() // expected_seconds) * expected_seconds
        if last_bucket_start == current_bucket_start:
            return rows[:-1]
        return rows

    @staticmethod
    def _to_float_or_none(value: Any) -> float | None:
        try:
            parsed = float(value)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(parsed):
            return None
        return parsed

    @staticmethod
    def _forward_fill(values: list[float | None]) -> list[float | None]:
        out: list[float | None] = []
        last_seen: float | None = None
        for value in values:
            if value is None:
                out.append(last_seen)
                continue
            last_seen = value
            out.append(value)
        return out

    def _lookback(self, params: dict[str, Any]) -> str:
        fallback = str(params.get("lookback", "1 day"))
        last_window = str(params.get("last_window", "24h"))
        lookback_from_window, _, _ = self._timeseries_window_config(last_window)
        return lookback_from_window or fallback

    def _dex_last_row(self, params: dict[str, Any]) -> dict[str, Any]:
        protocol = str(params.get("protocol", self.default_protocol))
        pair = str(params.get("pair", self.default_pair))
        lookback = self._lookback(params)

        def _load_row() -> dict[str, Any]:
            query = """
                SELECT *
                FROM dexes.get_view_dex_last(%s, %s, %s::interval)
                LIMIT 1
            """
            rows = self.sql.fetch_rows(query, (protocol, pair, lookback))
            return rows[0] if rows else {}

        cache_key = f"dex_swaps::dex_last::{protocol}::{pair}::{lookback}"
        return self._cached(cache_key, _load_row)

    def _dex_timeseries_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        protocol = str(params.get("protocol", self.default_protocol))
        pair = str(params.get("pair", self.default_pair))
        interval = str(params.get("interval", "5 minutes"))
        rows = int(params.get("rows", 120))
        last_window = str(params.get("last_window", "24h"))
        _, interval_from_window, rows_from_window = self._timeseries_window_config(last_window)
        interval = interval_from_window or interval
        rows = rows_from_window if rows_from_window > 0 else rows

        def _load_rows() -> list[dict[str, Any]]:
            query = """
                SELECT *
                FROM dexes.get_view_dex_timeseries(%s, %s, %s, %s)
                ORDER BY time
            """
            return self.sql.fetch_rows(query, (protocol, pair, interval, rows))

        cache_key = f"dex_swaps::dex_timeseries::v2::{protocol}::{pair}::{interval}::{rows}"
        cached_rows = self._cached(cache_key, _load_rows)
        return self._drop_incomplete_trailing_bucket(cached_rows, interval)

    def _dex_ohlcv_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        protocol = str(params.get("protocol", self.default_protocol))
        pair = str(params.get("pair", self.default_pair))
        last_window = str(params.get("last_window", "24h"))
        interval_key = str(params.get("ohlcv_interval", "1d")).strip().lower()
        interval_map: dict[str, str] = {
            "1m": "1 minute",
            "5m": "5 minutes",
            "15m": "15 minutes",
            "1h": "1 hour",
            "4h": "4 hours",
            "1d": "1 day",
        }
        interval = interval_map.get(interval_key, "1 day")
        interval_seconds = self._interval_seconds(interval)
        window_seconds = self._window_seconds(last_window)
        rows = 180
        if interval_seconds > 0 and window_seconds > 0:
            rows = int(ceil(window_seconds / interval_seconds))
        rows = max(2, min(rows, 1000))

        def _load_rows() -> list[dict[str, Any]]:
            query = """
                SELECT *
                FROM dexes.get_view_dex_ohlcv(%s, %s, %s, %s)
                ORDER BY time
            """
            return self.sql.fetch_rows(query, (protocol, pair, interval, rows))

        cache_key = f"dex_swaps::dex_ohlcv::v2::{protocol}::{pair}::{last_window}::{interval}::{rows}"
        cached_rows = self._cached(cache_key, _load_rows)
        return self._drop_incomplete_trailing_bucket(cached_rows, interval)

    def _tick_dist_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        protocol = str(params.get("protocol", self.default_protocol))
        pair = str(params.get("pair", self.default_pair))
        delta_time = str(params.get("tick_delta_time", "1 hour"))

        def _load_rows() -> list[dict[str, Any]]:
            query = """
                SELECT *
                FROM dexes.get_view_tick_dist_simple(%s, %s, %s::interval)
                ORDER BY tick_price_t1_per_t0
            """
            return self.sql.fetch_rows(query, (protocol, pair, delta_time))

        cache_key = f"dex_swaps::tick_dist::v2::{protocol}::{pair}::{delta_time}"
        return self._cached(cache_key, _load_rows)

    def _sell_swaps_distribution_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        protocol = str(params.get("protocol", self.default_protocol))
        pair = str(params.get("pair", self.default_pair))
        lookback = self._lookback(params)

        def _load_rows() -> list[dict[str, Any]]:
            query = """
                SELECT *
                FROM dexes.get_view_sell_swaps_distribution(%s, %s, 't0', %s, %s)
                ORDER BY bucket_number
            """
            return self.sql.fetch_rows(query, (protocol, pair, lookback, 10))

        cache_key = f"dex_swaps::sell_swaps_distribution::{protocol}::{pair}::{lookback}"
        return self._cached(cache_key, _load_rows)

    def _sell_pressure_distribution_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        protocol = str(params.get("protocol", self.default_protocol))
        pair = str(params.get("pair", self.default_pair))
        lookback = self._lookback(params)

        def _load_rows() -> list[dict[str, Any]]:
            query = """
                SELECT *
                FROM dexes.get_view_sell_pressure_t0_distribution(%s, %s, '1 hour', %s, %s, 'sell_only')
                ORDER BY bucket_number
            """
            return self.sql.fetch_rows(query, (protocol, pair, lookback, 10))

        cache_key = f"dex_swaps::sell_pressure_distribution::{protocol}::{pair}::{lookback}"
        return self._cached(cache_key, _load_rows)

    def _swaps_ranked_events_rows(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        protocol = str(params.get("protocol", self.default_protocol))
        pair = str(params.get("pair", self.default_pair))
        lookback = self._lookback(params)
        rows = 6

        def _load_rows() -> list[dict[str, Any]]:
            query = """
                SELECT *
                FROM dexes.get_view_dex_table_ranked_events(
                    %s, %s, 'swap', 't0', %s, %s, %s
                )
            """

            def _run_for_lookback(active_lookback: str) -> list[dict[str, Any]]:
                sell_rows = self.sql.fetch_rows(query, (protocol, pair, "in", rows, active_lookback))
                buy_rows = self.sql.fetch_rows(query, (protocol, pair, "out", rows, active_lookback))
                enriched_sell = [{**row, "side": "Sell USX"} for row in sell_rows]
                enriched_buy = [{**row, "side": "Buy USX"} for row in buy_rows]
                combined = enriched_sell + enriched_buy
                combined.sort(key=lambda row: float(row.get("primary_flow") or 0), reverse=True)
                return combined[: rows * 2]

            try:
                return _run_for_lookback(lookback)
            except Exception as exc:
                if "statement timeout" not in str(exc).lower() or lookback == "24 hours":
                    raise
                # Fallback keeps widget responsive for very long windows.
                return _run_for_lookback("24 hours")

        cache_key = f"dex_swaps::ranked_events::{protocol}::{pair}::{lookback}"
        return self._cached(cache_key, _load_rows)

    def _kpi_swap_volume_24h(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {"kind": "kpi", "primary": row.get("swap_vol_t1_total_24h"), "label": "24h Transaction Volume"}

    def _kpi_swap_count_24h(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {"kind": "kpi", "primary": row.get("swap_count_24h"), "label": "24h Swap Count"}

    def _kpi_price_min_max(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {
            "kind": "kpi",
            "primary": row.get("price_t1_per_t0_min"),
            "secondary": row.get("price_t1_per_t0_max"),
            "label": "Price Min/Max",
        }

    def _kpi_vwap_buy_sell(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {
            "kind": "kpi",
            "primary": row.get("vwap_buy_t0_avg"),
            "secondary": row.get("vwap_sell_t0_avg"),
            "label": "VWAP Buy/Sell",
        }

    def _kpi_price_std_dev(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {"kind": "kpi", "primary": row.get("price_t1_per_t0_std"), "label": "Price Std. Dev"}

    def _kpi_vwap_spread(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {"kind": "kpi", "primary": row.get("spread_vwap_avg_bps"), "label": "VWAP Spread (bps)"}

    def _kpi_largest_usx_sell(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {
            "kind": "kpi",
            "primary": row.get("swap_token0_in_max"),
            "secondary": row.get("swap_token0_in_max_impact_bps"),
            "label": "Largest USX Sell Trade & Est. Current Impact",
        }

    def _kpi_largest_usx_buy(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {
            "kind": "kpi",
            "primary": row.get("swap_token0_out_max"),
            "secondary": row.get("swap_token0_out_max_impact_bps"),
            "label": "Largest USX Buy Trade & Est. Current Impact",
        }

    def _kpi_max_1h_sell_pressure(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {
            "kind": "kpi",
            "primary": row.get("max_1h_t0_sell_pressure_in_period"),
            "secondary": row.get("max_1h_t0_sell_pressure_in_period_impact_bps"),
            "label": "Max. 1hr. USX Sell Pressure & Est. Current Impact",
        }

    def _kpi_max_1h_buy_pressure(self, params: dict[str, Any]) -> dict[str, Any]:
        row = self._dex_last_row(params)
        return {
            "kind": "kpi",
            "primary": row.get("max_1h_t0_buy_pressure_in_period"),
            "secondary": row.get("max_1h_t0_buy_pressure_in_period_impact_bps"),
            "label": "Max. 1hr. USX Buy Pressure & Est. Current Impact",
        }

    def _swaps_flows_toggle(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        mode = str(params.get("flow_mode", "usx")).strip().lower()
        is_usdc = mode == "usdc"
        buy_key = "swap_t1_out" if is_usdc else "swap_t0_out"
        sell_key = "swap_t1_in" if is_usdc else "swap_t0_in"
        buy_label = "Buy USDC" if is_usdc else "Buy USX"
        sell_label = "Sell USDC" if is_usdc else "Sell USX"
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["time"] for row in rows],
            "series": [
                {"name": buy_label, "type": "bar", "yAxisIndex": 0, "color": "#2fbf71", "data": [row.get(buy_key) for row in rows]},
                {"name": sell_label, "type": "bar", "yAxisIndex": 0, "color": "#e24c4c", "data": [-(abs(float(row.get(sell_key) or 0))) for row in rows]},
                {"name": "Swap Count", "type": "line", "area": True, "yAxisIndex": 1, "color": "#f8a94a", "data": [row.get("swap_count") for row in rows]},
            ],
        }

    def _swaps_price_impacts(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        avg_impacts = [self._to_float_or_none(row.get("avg_est_swap_impact_bps_all")) for row in rows]
        max_sell_impacts_raw = [self._to_float_or_none(row.get("min_est_swap_impact_bps_t0_sell")) for row in rows]
        max_sell_impacts = self._forward_fill(max_sell_impacts_raw)
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["time"] for row in rows],
            "series": [
                {"name": "Avg. Swap Impact", "type": "line", "yAxisIndex": 0, "color": "#f8a94a", "connectNulls": True, "data": avg_impacts},
                {"name": "Max. Sell USX Impact", "type": "line", "yAxisIndex": 0, "color": "#c186ff", "connectNulls": True, "data": max_sell_impacts},
            ],
        }

    def _swaps_spread_volatility(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        prices = [float(row.get("price_t1_per_t0") or 0) if row.get("price_t1_per_t0") is not None else None for row in rows]
        window = 12
        std_values: list[float | None] = []
        for idx in range(len(prices)):
            window_values = [value for value in prices[max(0, idx - window + 1) : idx + 1] if value is not None]
            if len(window_values) < 2:
                std_values.append(None)
                continue
            std_values.append(float(statistics.pstdev(window_values)))
        return {
            "kind": "chart",
            "chart": "line",
            "x": [row["time"] for row in rows],
            "series": [
                {"name": "VWAP Spread", "type": "bar", "yAxisIndex": 0, "color": "#f8a94a", "data": [self._to_float_or_none(row.get("avg_vwap_spread_bps_w_last")) for row in rows]},
                {"name": "Std. Dev.", "type": "line", "yAxisIndex": 1, "color": "#4bb7ff", "data": std_values},
            ],
        }

    def _swaps_ohlcv(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_ohlcv_rows(params)
        tick_rows = self._tick_dist_rows(params)
        anchor_price = 1.0
        for row in tick_rows:
            try:
                candidate_anchor = float(row.get("current_price_t1_per_t0") or 0)
            except (TypeError, ValueError):
                continue
            if math.isfinite(candidate_anchor) and candidate_anchor > 0:
                anchor_price = candidate_anchor
                break
        liquidity_profile: list[dict[str, float]] = []
        for row in tick_rows:
            try:
                price = float(row.get("tick_price_t1_per_t0") or 0)
                token0_liquidity = float(row.get("token0_value") or 0)
                token1_liquidity = float(row.get("token1_value") or 0)
            except (TypeError, ValueError):
                continue
            # Token-order-consistent side selection for t1-per-t0 price charts:
            # - below/at anchor: token0-side liquidity
            # - above anchor: token1-side liquidity
            # Convert token0 into token1 units so both sides share the same unit.
            token0_in_t1_units = token0_liquidity * price
            if price <= anchor_price:
                primary_liquidity = token0_in_t1_units
                secondary_liquidity = token1_liquidity
            else:
                primary_liquidity = token1_liquidity
                secondary_liquidity = token0_in_t1_units
            liquidity = abs(primary_liquidity)
            if liquidity <= 0:
                # Fallback handles sparse/edge rows where only the opposite token bucket is populated.
                liquidity = abs(secondary_liquidity)
            if not math.isfinite(price) or not math.isfinite(liquidity) or liquidity <= 0:
                continue
            liquidity_profile.append({"price": price, "liquidity": liquidity})
        return {
            "kind": "chart",
            "chart": "candlestick-volume",
            "x": [row["time"] for row in rows],
            "candles": [
                [
                    row.get("open_price"),
                    row.get("close_price"),
                    row.get("low_price"),
                    row.get("high_price"),
                ]
                for row in rows
            ],
            "volume": [row.get("volume_t1") for row in rows],
            "liquidity_profile": liquidity_profile,
        }

    @staticmethod
    def _distribution_axis_label(row: dict[str, Any]) -> str:
        upper = float(row.get("bucket_max_in_k") or 0)
        pct = float(row.get("cumulative_share") or 0)
        return f"{upper:.1f}k\n{pct:.0f}%"

    def _swaps_sell_usx_distribution(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._sell_swaps_distribution_rows(params)
        x = [self._distribution_axis_label(row) for row in rows]
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": x,
            "series": [
                {"name": "Swap Count", "type": "bar", "yAxisIndex": 0, "color": "#4bb7ff", "data": [row.get("swap_count") for row in rows]},
                {
                    "name": "Price Impact",
                    "type": "line",
                    "yAxisIndex": 1,
                    "color": "#38d39f",
                    "showSymbol": True,
                    "symbolSize": 6,
                    "data": [row.get("price_impact_bps_abs") for row in rows],
                },
            ],
        }

    def _swaps_1h_net_sell_pressure_distribution(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._sell_pressure_distribution_rows(params)
        x = [self._distribution_axis_label(row) for row in rows]
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": x,
            "series": [
                {"name": "Pressure Counted", "type": "bar", "yAxisIndex": 0, "color": "#4bb7ff", "data": [row.get("interval_count") for row in rows]},
                {
                    "name": "Price Impact",
                    "type": "line",
                    "yAxisIndex": 1,
                    "color": "#38d39f",
                    "showSymbol": True,
                    "symbolSize": 6,
                    "data": [row.get("price_impact_bps_abs") for row in rows],
                },
            ],
        }

    def _swaps_distribution_toggle(self, params: dict[str, Any]) -> dict[str, Any]:
        mode = str(params.get("distribution_mode", "sell-order")).strip().lower()
        if mode == "net-sell-pressure":
            return self._swaps_1h_net_sell_pressure_distribution(params)
        return self._swaps_sell_usx_distribution(params)

    def _swaps_ranked_events(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._swaps_ranked_events_rows(params)
        return {
            "kind": "table",
            "columns": [
                {"key": "tx_time", "label": "Time"},
                {"key": "side", "label": "Side"},
                {"key": "primary_flow", "label": "USX Amount"},
                {"key": "primary_flow_impact_bps_now", "label": "Est. Price Impact (bps)"},
                {"key": "signature", "label": "Tx Signature"},
            ],
            "rows": rows,
        }
