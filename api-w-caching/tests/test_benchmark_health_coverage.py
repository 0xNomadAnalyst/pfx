from __future__ import annotations

import ast
import importlib.util
from pathlib import Path
import sys
import unittest


API_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = API_ROOT / "scripts" / "benchmark_dashboard.py"
HTMX_HEALTH_PAGE_PATH = API_ROOT.parent / "htmx" / "app" / "pages" / "health.py"


def _load_benchmark_module():
    spec = importlib.util.spec_from_file_location("benchmark_dashboard", SCRIPT_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _extract_expected_health_widget_ids() -> set[str]:
    source = HTMX_HEALTH_PAGE_PATH.read_text(encoding="utf-8")
    tree = ast.parse(source)
    expected: set[str] = set()

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        if isinstance(node.func, ast.Name) and node.func.id == "WidgetConfig":
            if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                expected.add(node.args[0].value)
    return expected


class BenchmarkHealthCoverageTests(unittest.TestCase):
    def test_health_page_is_registered_in_benchmark_script(self) -> None:
        module = _load_benchmark_module()
        self.assertIn("health", module.PAGE_DEFAULT_SCENARIOS)
        self.assertIn("health", module.PAGE_ALIASES)
        self.assertIn("health", module.QUICK_WIDGETS_BY_PAGE)

    def test_all_page_alias_includes_health(self) -> None:
        module = _load_benchmark_module()
        self.assertIn("health", module.parse_pages("all"))

    def test_health_scenarios_cover_htmx_widget_ids(self) -> None:
        module = _load_benchmark_module()
        expected = _extract_expected_health_widget_ids()
        scenarios = module.PAGE_DEFAULT_SCENARIOS["health"]
        benchmark_widget_ids = {scenario.widget for scenario in scenarios}

        missing = expected - benchmark_widget_ids
        self.assertFalse(
            missing,
            msg=f"Missing health widgets in benchmark scenarios: {sorted(missing)}",
        )

    def test_health_quick_widgets_exist_in_default_scenarios(self) -> None:
        module = _load_benchmark_module()
        quick = set(module.QUICK_WIDGETS_BY_PAGE["health"])
        defaults = {scenario.widget for scenario in module.PAGE_DEFAULT_SCENARIOS["health"]}
        missing = quick - defaults
        self.assertFalse(
            missing,
            msg=f"Quick health widgets missing from default scenarios: {sorted(missing)}",
        )


if __name__ == "__main__":
    unittest.main()
