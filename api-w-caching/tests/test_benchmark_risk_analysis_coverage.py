from __future__ import annotations

import ast
import importlib.util
from pathlib import Path
import sys
import unittest


API_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = API_ROOT / "scripts" / "benchmark_dashboard.py"
RISK_SERVICE_PATH = API_ROOT / "app" / "services" / "pages" / "risk_analysis.py"


def _load_benchmark_module():
    spec = importlib.util.spec_from_file_location("benchmark_dashboard", SCRIPT_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _extract_risk_handler_widget_ids() -> set[str]:
    source = RISK_SERVICE_PATH.read_text(encoding="utf-8")
    tree = ast.parse(source)
    expected: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        if len(node.targets) != 1:
            continue
        target = node.targets[0]
        if not isinstance(target, ast.Attribute):
            continue
        if target.attr != "_handlers":
            continue
        if not isinstance(node.value, ast.Dict):
            continue
        for key in node.value.keys:
            if isinstance(key, ast.Constant) and isinstance(key.value, str):
                expected.add(key.value)
    return expected


class BenchmarkRiskAnalysisCoverageTests(unittest.TestCase):
    def test_risk_page_is_registered_in_benchmark_script(self) -> None:
        module = _load_benchmark_module()
        self.assertIn("risk-analysis", module.PAGE_DEFAULT_SCENARIOS)
        self.assertIn("risk-analysis", module.PAGE_ALIASES)
        self.assertIn("risk-analysis", module.QUICK_WIDGETS_BY_PAGE)

    def test_all_page_alias_includes_risk_page(self) -> None:
        module = _load_benchmark_module()
        self.assertIn("risk-analysis", module.parse_pages("all"))

    def test_risk_scenarios_cover_api_handler_widgets(self) -> None:
        module = _load_benchmark_module()
        expected = _extract_risk_handler_widget_ids()
        scenarios = module.PAGE_DEFAULT_SCENARIOS["risk-analysis"]
        benchmark_widget_ids = {scenario.widget for scenario in scenarios}
        missing = expected - benchmark_widget_ids
        self.assertFalse(
            missing,
            msg=f"Missing risk-analysis widgets in benchmark scenarios: {sorted(missing)}",
        )

    def test_risk_quick_widgets_exist_in_default_scenarios(self) -> None:
        module = _load_benchmark_module()
        quick = set(module.QUICK_WIDGETS_BY_PAGE["risk-analysis"])
        defaults = {scenario.widget for scenario in module.PAGE_DEFAULT_SCENARIOS["risk-analysis"]}
        missing = quick - defaults
        self.assertFalse(
            missing,
            msg=f"Quick risk-analysis widgets missing from default scenarios: {sorted(missing)}",
        )


if __name__ == "__main__":
    unittest.main()
