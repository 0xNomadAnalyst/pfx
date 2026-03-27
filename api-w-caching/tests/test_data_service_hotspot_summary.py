from __future__ import annotations

import unittest

from app.services.data_service import DataService


class DataServiceHotspotSummaryTests(unittest.TestCase):
    def test_build_hotspot_summary_includes_latency_status_and_fingerprints(self) -> None:
        request_stats = {
            "latency_by_widget": {
                "global-ecosystem/ge-activity-vol-usx": {"p95_ms": 123.4, "p99_ms": 150.1},
                "global-ecosystem/ge-tvl-share-usx": {"p95_ms": 95.2, "p99_ms": 120.0},
            },
            "status_family_by_widget": {
                "global-ecosystem/ge-activity-vol-usx": {"2xx": 8, "5xx": 1},
                "global-ecosystem/ge-tvl-share-usx": {"2xx": 9},
            },
        }
        sql_snapshot = {
            "pool_checkout_wait_avg_ms": 3.2,
            "pool_checkout_wait_max_ms": 18.7,
            "query_fingerprint_stats": {
                "global-ecosystem/ge-activity-vol-usx/abc": {
                    "page": "global-ecosystem",
                    "widget": "ge-activity-vol-usx",
                    "count": 5,
                    "error_count": 1,
                    "avg_ms": 32.0,
                    "p95_ms": 55.0,
                    "p99_ms": 61.0,
                    "max_ms": 62.0,
                    "query_preview": "SELECT ...",
                }
            },
        }
        summary = DataService._build_hotspot_summary(request_stats, sql_snapshot)
        widgets = summary["widgets"]
        self.assertIn("global-ecosystem/ge-activity-vol-usx", widgets)
        self.assertIn("global-ecosystem/ge-tvl-share-usx", widgets)
        self.assertEqual(summary["pool_wait_avg_ms"], 3.2)
        self.assertEqual(summary["pool_wait_max_ms"], 18.7)
        activity = widgets["global-ecosystem/ge-activity-vol-usx"]
        self.assertEqual(activity["status_families"]["5xx"], 1)
        self.assertGreaterEqual(len(activity["top_sql_fingerprints"]), 1)


if __name__ == "__main__":
    unittest.main()
