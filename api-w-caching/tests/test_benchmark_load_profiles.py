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


class BenchmarkLoadProfileTests(unittest.TestCase):
    def test_parse_parallel_profiles_uses_default_parallel(self) -> None:
        module = _load_benchmark_module()
        self.assertEqual(module.parse_parallel_profiles(3, ""), [3])

    def test_parse_parallel_profiles_parses_unique_ramp_values(self) -> None:
        module = _load_benchmark_module()
        self.assertEqual(module.parse_parallel_profiles(1, "1,2,2,4"), [1, 2, 4])

    def test_parse_parallel_profiles_rejects_invalid_value(self) -> None:
        module = _load_benchmark_module()
        with self.assertRaises(ValueError):
            module.parse_parallel_profiles(1, "1,bad,4")


if __name__ == "__main__":
    unittest.main()
