from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


API_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = API_ROOT / "scripts" / "benchmark_dashboard.py"


def _load_benchmark_module():
    spec = importlib.util.spec_from_file_location("benchmark_dashboard", SCRIPT_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class BenchmarkWidgetGateTests(unittest.TestCase):
    def test_hotspot_summary_accumulates_error_timeout_and_5xx(self) -> None:
        module = _load_benchmark_module()
        rows = [
            {
                "page": "global-ecosystem",
                "widget": "ge-activity-vol-usx",
                "cold_ok": False,
                "cold_5xx": True,
                "cold_timeout": False,
                "warm_error_count": 2,
                "warm_5xx_count": 1,
                "warm_timeout_count": 0,
                "warm_p95_ms": 120.0,
                "cold_ms": 80.0,
            },
            {
                "page": "global-ecosystem",
                "widget": "ge-activity-vol-usx",
                "cold_ok": True,
                "cold_5xx": False,
                "cold_timeout": False,
                "warm_error_count": 1,
                "warm_5xx_count": 0,
                "warm_timeout_count": 1,
                "warm_p95_ms": 210.0,
                "cold_ms": 45.0,
            },
        ]
        summary = module.summarize_hotspot_widgets(rows, {"ge-activity-vol-usx"})
        key = "global-ecosystem/ge-activity-vol-usx"
        self.assertIn(key, summary)
        self.assertEqual(summary[key]["errors"], 4)
        self.assertEqual(summary[key]["errors_5xx"], 2)
        self.assertEqual(summary[key]["timeouts"], 1)
        self.assertGreaterEqual(float(summary[key]["warm_p95_ms_max"]), 210.0)


if __name__ == "__main__":
    unittest.main()
