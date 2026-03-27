from __future__ import annotations

import importlib
import os
import unittest
from unittest.mock import patch


class CacheConfigRefreshUnificationTests(unittest.TestCase):
    def test_dash_refresh_derives_ttl_and_swr_defaults(self) -> None:
        with patch.dict(
            os.environ,
            {
                "API_CACHE_MODE": "balanced",
                "DASH_REFRESH_INTERVAL_SECONDS": "30",
            },
            clear=False,
        ):
            os.environ.pop("API_CACHE_TTL_SECONDS", None)
            os.environ.pop("API_CACHE_SWR_SECONDS", None)
            module = importlib.import_module("app.services.cache_config")
            module = importlib.reload(module)
            cfg = module.API_CACHE_CONFIG
            self.assertAlmostEqual(float(cfg.get("API_CACHE_TTL_SECONDS", 0)), 30.0, places=3)
            self.assertAlmostEqual(float(cfg.get("API_CACHE_SWR_SECONDS", 0)), 15.0, places=3)
            self.assertAlmostEqual(float(cfg.get("DASH_REFRESH_INTERVAL_SECONDS", 0)), 30.0, places=3)

    def test_explicit_api_overrides_take_precedence(self) -> None:
        with patch.dict(
            os.environ,
            {
                "API_CACHE_MODE": "balanced",
                "DASH_REFRESH_INTERVAL_SECONDS": "30",
                "API_CACHE_TTL_SECONDS": "90",
                "API_CACHE_SWR_SECONDS": "12",
            },
            clear=False,
        ):
            module = importlib.import_module("app.services.cache_config")
            module = importlib.reload(module)
            cfg = module.API_CACHE_CONFIG
            self.assertAlmostEqual(float(cfg.get("API_CACHE_TTL_SECONDS", 0)), 90.0, places=3)
            self.assertAlmostEqual(float(cfg.get("API_CACHE_SWR_SECONDS", 0)), 12.0, places=3)


if __name__ == "__main__":
    unittest.main()
