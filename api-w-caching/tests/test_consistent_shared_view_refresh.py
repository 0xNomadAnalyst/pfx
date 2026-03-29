from __future__ import annotations

import importlib
import os
import unittest
from unittest.mock import patch


class _RecordingCache:
    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

    def cached_swr(self, key, fn, ttl_seconds=30.0, swr_seconds=15.0):
        self.calls.append(
            {
                "key": key,
                "ttl_seconds": float(ttl_seconds),
                "swr_seconds": float(swr_seconds),
            }
        )
        return fn()


class _StubSql:
    def fetch_rows(self, query, *_args, **_kwargs):
        q = " ".join(str(query).split()).lower()
        if "cross_protocol.v_xp_last" in q:
            return [{}]
        if "cross_protocol.get_view_xp_timeseries" in q:
            return [{"bucket_time": "2026-01-01T00:00:00Z"}]
        if "cross_protocol.get_view_xp_activity" in q:
            return [{"all_protocol_volume": 0}]
        if "get_view_dex_risk_pvalues" in q:
            return [{"stat_order": 1, "stat_name": "p 99", "value": 1, "date": "2026-01-01"}]
        if "dexes.pool_tokens_reference" in q:
            return [{"token_pair": "ONyc-USDC", "token0_symbol": "ONyc", "token1_symbol": "USDC"}]
        return []


class ConsistentSharedViewRefreshTests(unittest.TestCase):
    def test_shared_loaders_disable_swr_when_enabled(self) -> None:
        with patch.dict(
            os.environ,
            {
                "API_CONSISTENT_SHARED_VIEW_REFRESH": "1",
                "API_CACHE_SWR_SECONDS": "12",
            },
            clear=False,
        ):
            ge_module = importlib.import_module("app.services.pages.global_ecosystem")
            ge_module = importlib.reload(ge_module)
            cache = _RecordingCache()
            svc = ge_module.GlobalEcosystemPageService(_StubSql(), cache)
            svc._v_last()
            svc._ts_rows({"last_window": "24h"})
            svc._interval_row({"last_window": "24h"})
            ge_calls = {str(item["key"]): float(item["swr_seconds"]) for item in cache.calls}
            self.assertEqual(ge_calls["ge::v_xp_last"], 0.0)
            self.assertEqual(ge_calls["ge::xp_ts::24h"], 0.0)
            self.assertEqual(ge_calls["ge::xp_activity::24h"], 0.0)

            ra_module = importlib.import_module("app.services.pages.risk_analysis")
            ra_module = importlib.reload(ra_module)
            cache_ra = _RecordingCache()
            ra = ra_module.RiskAnalysisPageService(_StubSql(), cache_ra)
            ra._pvalue_rows("raydium", "Single Swaps", "5 minutes")
            ra._xp_last()
            ra_calls = {str(item["key"]): float(item["swr_seconds"]) for item in cache_ra.calls}
            self.assertEqual(ra_calls["ra::pvalues::raydium::Single Swaps::5 minutes"], 0.0)
            self.assertEqual(ra_calls["ra::xp_last"], 0.0)

    def test_shared_loaders_use_default_swr_when_disabled(self) -> None:
        with patch.dict(
            os.environ,
            {
                "API_CONSISTENT_SHARED_VIEW_REFRESH": "0",
                "API_CACHE_SWR_SECONDS": "12",
            },
            clear=False,
        ):
            ge_module = importlib.import_module("app.services.pages.global_ecosystem")
            ge_module = importlib.reload(ge_module)
            cache = _RecordingCache()
            svc = ge_module.GlobalEcosystemPageService(_StubSql(), cache)
            svc._ts_rows({"last_window": "24h"})
            call = next(item for item in cache.calls if str(item["key"]) == "ge::xp_ts::24h")
            self.assertAlmostEqual(float(call["swr_seconds"]), 12.0, places=3)


if __name__ == "__main__":
    unittest.main()
