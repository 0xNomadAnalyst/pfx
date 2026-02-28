from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


API_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = API_ROOT / "scripts" / "benchmark_dashboard.py"
BASE_TEMPLATE_PATH = API_ROOT.parent / "htmx" / "app" / "templates" / "base.html"
CHARTS_JS_PATH = API_ROOT.parent / "htmx" / "app" / "static" / "js" / "charts.js"
HTMX_MAIN_PATH = API_ROOT.parent / "htmx" / "app" / "main.py"


def _load_benchmark_module():
    spec = importlib.util.spec_from_file_location("benchmark_dashboard", SCRIPT_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class BenchmarkHeaderHealthCoverageTests(unittest.TestCase):
    def test_header_health_page_is_registered_in_benchmark_script(self) -> None:
        module = _load_benchmark_module()
        self.assertIn("header-health", module.PAGE_DEFAULT_SCENARIOS)
        self.assertIn("header-health-proxy", module.PAGE_DEFAULT_SCENARIOS)
        self.assertIn("header-health", module.PAGE_ALIASES)
        self.assertIn("header-health-proxy", module.PAGE_ALIASES)
        self.assertIn("header-health", module.QUICK_WIDGETS_BY_PAGE)
        self.assertIn("header-health-proxy", module.QUICK_WIDGETS_BY_PAGE)

    def test_header_health_scenario_targets_health_status_endpoint(self) -> None:
        module = _load_benchmark_module()
        scenarios = module.PAGE_DEFAULT_SCENARIOS["header-health"]
        self.assertEqual(len(scenarios), 1)
        scenario = scenarios[0]
        self.assertEqual(scenario.widget, "health-status")
        self.assertEqual(scenario.direct_path, "/api/v1/health-status")

    def test_all_page_alias_includes_header_health(self) -> None:
        module = _load_benchmark_module()
        self.assertIn("header-health", module.parse_pages("all"))
        self.assertIn("header-health-proxy", module.parse_pages("all"))

    def test_ui_wires_always_on_header_health_indicator(self) -> None:
        base_html = BASE_TEMPLATE_PATH.read_text(encoding="utf-8")
        charts_js = CHARTS_JS_PATH.read_text(encoding="utf-8")
        htmx_main = HTMX_MAIN_PATH.read_text(encoding="utf-8")

        self.assertIn('id="health-indicator"', base_html)
        self.assertIn("/api/health-status", charts_js)
        self.assertIn("/api/v1/health-status", htmx_main)
        self.assertIn("localStorage.setItem(HEALTH_CACHE_KEY", charts_js)
        self.assertIn("schedulePoll(", charts_js)
        self.assertIn("setTimeout(() =>", charts_js)


if __name__ == "__main__":
    unittest.main()
