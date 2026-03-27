from __future__ import annotations

import unittest

from app.services.data_service import DataService


class DataServiceTelemetryRollupTests(unittest.TestCase):
    def test_latency_rollup_emits_percentiles(self) -> None:
        raw = {
            "risk-analysis": {
                "count": 4,
                "total_ms": 100.0,
                "max_ms": 40.0,
                "samples": [10.0, 20.0, 30.0, 40.0],
            }
        }
        rolled = DataService._latency_rollup(raw)
        self.assertIn("risk-analysis", rolled)
        self.assertEqual(rolled["risk-analysis"]["count"], 4)
        self.assertAlmostEqual(rolled["risk-analysis"]["avg_ms"], 25.0, places=3)
        self.assertAlmostEqual(rolled["risk-analysis"]["p50_ms"], 25.0, places=3)
        self.assertGreaterEqual(rolled["risk-analysis"]["p95_ms"], 38.0)
        self.assertGreaterEqual(rolled["risk-analysis"]["p99_ms"], 39.0)


if __name__ == "__main__":
    unittest.main()
