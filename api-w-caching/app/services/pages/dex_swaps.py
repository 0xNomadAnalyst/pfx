from __future__ import annotations

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
            "swaps-usx-flows-impacts": self._swaps_usx_flows_impacts,
            "swaps-usdc-flows-count": self._swaps_usdc_flows_count,
            "swaps-directional-vwap-spread": self._swaps_directional_vwap_spread,
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

        cache_key = f"dex_swaps::dex_timeseries::{protocol}::{pair}::{interval}::{rows}"
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

    def _swaps_usx_flows_impacts(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["time"] for row in rows],
            "series": [
                {"name": "Buy USX", "type": "bar", "yAxisIndex": 0, "color": "#2fbf71", "data": [row.get("swap_t0_out") for row in rows]},
                {"name": "Sell USX", "type": "bar", "yAxisIndex": 0, "color": "#e24c4c", "data": [-(abs(float(row.get("swap_t0_in") or 0))) for row in rows]},
                {"name": "Avg. Swap Impact", "type": "line", "yAxisIndex": 1, "color": "#f8a94a", "data": [row.get("avg_est_swap_impact_bps_all") for row in rows]},
                {"name": "Max. Sell USX Impact", "type": "line", "yAxisIndex": 1, "color": "#c186ff", "data": [row.get("min_est_swap_impact_bps_t0_sell") for row in rows]},
            ],
        }

    def _swaps_usdc_flows_count(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["time"] for row in rows],
            "series": [
                {"name": "Buy USDC", "type": "bar", "yAxisIndex": 0, "color": "#2fbf71", "data": [row.get("swap_t1_out") for row in rows]},
                {"name": "Sell USDC", "type": "bar", "yAxisIndex": 0, "color": "#e24c4c", "data": [-(abs(float(row.get("swap_t1_in") or 0))) for row in rows]},
                {"name": "Swap Count", "type": "line", "area": True, "yAxisIndex": 1, "color": "#f8a94a", "data": [row.get("swap_count") for row in rows]},
            ],
        }

    def _swaps_directional_vwap_spread(self, params: dict[str, Any]) -> dict[str, Any]:
        rows = self._dex_timeseries_rows(params)
        return {
            "kind": "chart",
            "chart": "bar-line",
            "x": [row["time"] for row in rows],
            "series": [
                {"name": "VWAP Buy", "type": "line", "yAxisIndex": 0, "color": "#2fbf71", "data": [row.get("last_avg_vwap_buy_t0_w_last") for row in rows]},
                {"name": "VWAP Sell", "type": "line", "yAxisIndex": 0, "color": "#f8a94a", "data": [row.get("last_avg_vwap_sell_t0_w_last") for row in rows]},
                {"name": "Avg. Spread", "type": "bar", "yAxisIndex": 1, "color": "#4bb7ff", "data": [row.get("avg_vwap_spread_bps_w_last") for row in rows]},
            ],
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
