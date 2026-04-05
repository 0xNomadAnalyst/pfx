"""
Tests for pipeline selector: verifies each pipeline's meta, defaults,
widget accessibility, and switching behaviour.

Usage:
    # Unit tests only (no server needed):
    python -m unittest tests.test_pipeline_switcher.TestPipelineConfigUnit -v

    # Integration: pipeline API + meta + all widgets per pipeline:
    python -m unittest tests.test_pipeline_switcher -v

    # Quick diagnostic of all widgets on the currently-active pipeline:
    python -m unittest tests.test_pipeline_switcher.TestAllWidgetsCurrentPipeline -v
"""
from __future__ import annotations

import json
import os
import sys
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

API_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API_ROOT))

API_BASE = os.getenv("TEST_API_BASE_URL", "http://localhost:8001")
UI_BASE = os.getenv("TEST_UI_BASE_URL", "http://localhost:8002")
TIMEOUT = 15

EXPECTED_PIPELINES = ["solstice", "onyc"]

PIPELINE_EXPECTED_META = {
    "solstice": {
        "protocols_contain": ["raydium"],
        "pairs_contain": ["USDG-ONyc"],
    },
    "onyc": {
        "protocols_contain": ["orca", "raydium"],
        "pairs_contain": ["ONyc-USDC", "USDG-ONyc"],
    },
}

PIPELINE_DEFAULTS = {
    "solstice": {"protocol": "raydium", "pair": "USDG-ONyc"},
    "onyc":     {"protocol": "orca",    "pair": "ONyc-USDC"},
}

ALL_WIDGETS: dict[str, dict] = {
    "dex-liquidity": {
        "uses_pair": True,
        "widgets": [
            "kpi-tvl", "kpi-impact-500k", "kpi-reserves", "kpi-largest-impact",
            "kpi-pool-balance", "kpi-average-impact",
            "liquidity-distribution", "liquidity-depth", "liquidity-change-heatmap",
            "liquidity-depth-table", "usdc-pool-share-concentration",
            "trade-size-to-impact", "usdc-lp-flows", "impact-from-trade-size",
            "trade-impact-toggle", "ranked-lp-events",
        ],
    },
    "dex-swaps": {
        "uses_pair": True,
        "widgets": [
            "kpi-swap-volume-24h", "kpi-swap-count-24h", "kpi-price-min-max",
            "kpi-vwap-buy-sell", "kpi-price-std-dev", "kpi-vwap-spread",
            "kpi-largest-usx-sell", "kpi-largest-usx-buy",
            "kpi-max-1h-sell-pressure", "kpi-max-1h-buy-pressure",
            "swaps-flows-toggle", "swaps-price-impacts", "swaps-spread-volatility",
            "swaps-ohlcv", "swaps-distribution-toggle",
            "swaps-ranked-events",
        ],
    },
    "kamino": {
        "uses_pair": False,
        "widgets": [
            "kpi-utilization-by-reserve", "kpi-loan-value",
            "kpi-obligations-debt-size", "kpi-share-borrow-asset",
            "kpi-ltv-hf", "kpi-collateral-value", "kpi-unhealthy-share",
            "kpi-share-collateral-asset",
            "kpi-zero-use-count", "kpi-zero-use-capacity",
            "kpi-borrow-apy", "kpi-supply-apy",
            "kpi-borrow-vol-24h", "kpi-repay-vol-24h",
            "kpi-liquidation-vol-30d", "kpi-liquidation-count-30d",
            "kpi-withdraw-vol-24h", "kpi-deposit-vol-24h",
            "kpi-liquidation-avg-size", "kpi-days-no-liquidation",
            "kamino-config-table", "kamino-market-assets",
            "kamino-supply-collateral-status", "kamino-utilization-timeseries",
            "kamino-rate-curve", "kamino-loan-size-dist",
            "kamino-ltv-hf-timeseries", "kamino-liability-flows",
            "kamino-liquidations", "kamino-stress-debt",
            "kamino-sensitivity-table", "kamino-obligation-watchlist",
        ],
    },
    "exponent": {
        "uses_pair": False,
        "widgets": [
            "kpi-base-token-yield", "exponent-pie-tvl",
            "kpi-locked-base-tokens", "kpi-current-fixed-yield",
            "kpi-sy-base-collateral", "kpi-sy-coll-ratio",
            "exponent-timeline", "kpi-fixed-variable-spread",
            "kpi-yt-staked-share", "kpi-amm-depth",
            "kpi-pt-base-price", "kpi-apy-impact-pt-trade",
            "kpi-pt-vol-24h", "kpi-amm-deployment-ratio",
            "exponent-market-meta", "exponent-market-assets",
            "exponent-market-info-mkt1", "exponent-market-info-mkt2",
            "exponent-pt-swap-flows-mkt1", "exponent-pt-swap-flows-mkt2",
            "exponent-token-strip-flows-mkt1", "exponent-token-strip-flows-mkt2",
            "exponent-vault-sy-balance-mkt1", "exponent-vault-sy-balance-mkt2",
            "exponent-yt-staked-mkt1", "exponent-yt-staked-mkt2",
            "exponent-yield-trading-liq-mkt1", "exponent-yield-trading-liq-mkt2",
            "exponent-realized-rates-mkt1", "exponent-realized-rates-mkt2",
            "exponent-divergence-mkt1", "exponent-divergence-mkt2",
        ],
    },
    "health": {
        "uses_pair": False,
        "widgets": [
            "health-master", "health-queue-table", "health-queue-chart",
            "health-trigger-table", "health-base-table",
            "health-base-chart-events", "health-base-chart-accounts",
            "health-cagg-table",
        ],
    },
    "global-ecosystem": {
        "uses_pair": False,
        "widgets": [
            "ge-issuance-bar", "ge-issuance-time",
            "ge-activity-pct-usx", "ge-yield-generation",
        ],
    },
}


# ─── Helpers ─────────────────────────────────────────────────────────────────

def _api_get_raw(path: str) -> tuple[int, dict]:
    """Return (status_code, body_dict). Captures error bodies on 4xx/5xx."""
    req = urllib.request.Request(f"{API_BASE}{path}")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        try:
            body = json.loads(exc.read())
        except Exception:
            body = {"detail": str(exc)}
        return exc.code, body
    except Exception as exc:
        return 0, {"detail": f"Connection error: {exc}"}


def _api_get(path: str) -> dict:
    req = urllib.request.Request(f"{API_BASE}{path}")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read())


def _api_post(path: str, body: dict) -> dict:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{API_BASE}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read())


def _ui_get(path: str) -> str:
    req = urllib.request.Request(f"{UI_BASE}{path}")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read().decode()


def _api_reachable() -> bool:
    try:
        _api_get("/health")
        return True
    except Exception:
        return False


def _ui_reachable() -> bool:
    try:
        _ui_get("/dex-liquidity")
        return True
    except Exception:
        return False


_skip_api = not _api_reachable()
_skip_ui = not _ui_reachable()

skip_api = unittest.skipIf(_skip_api, "API server not reachable")
skip_ui = unittest.skipIf(_skip_ui, "UI server not reachable")


def _build_widget_url(page_id: str, widget: str, pipeline: str) -> str:
    defaults = PIPELINE_DEFAULTS.get(pipeline, {})
    page_cfg = ALL_WIDGETS[page_id]
    params = "last_window=24h&rows=5"
    if page_cfg["uses_pair"]:
        params += f"&protocol={defaults.get('protocol', 'orca')}&pair={defaults.get('pair', 'ONyc-USDC')}"
    return f"/api/v1/{page_id}/{widget}?{params}"


def _switch_pipeline(name: str) -> None:
    _api_post("/api/v1/pipeline", {"pipeline": name})
    time.sleep(0.3)


def _data_is_nonempty(payload: dict) -> bool:
    """Check that the widget response contains actual data, not just an empty shell."""
    data = payload.get("data", {})
    kind = data.get("kind", "")
    if kind == "kpi":
        primary = data.get("primary")
        return primary is not None and primary != "--" and primary != ""
    if kind in ("table", "table-split"):
        rows = data.get("rows") or data.get("left_rows") or []
        return len(rows) > 0
    if kind == "chart":
        series = data.get("series", [])
        for s in series:
            d = s.get("data", [])
            if any(v is not None for v in d):
                return True
        return False
    return bool(data)


# ─── Unit tests (no running servers) ────────────────────────────────────────

class TestPipelineConfigUnit(unittest.TestCase):
    """Tests for pipeline_config module internals."""

    def test_unit_module_loads(self) -> None:
        from app.services import pipeline_config
        self.assertTrue(hasattr(pipeline_config, "PIPELINES"))
        self.assertTrue(hasattr(pipeline_config, "PIPELINE_DEFAULTS"))

    def test_unit_both_pipelines_loaded(self) -> None:
        from app.services import pipeline_config
        for name in EXPECTED_PIPELINES:
            self.assertIn(name, pipeline_config.PIPELINES,
                          f"Pipeline '{name}' not loaded — check env files exist")

    def test_unit_pipeline_has_db_keys(self) -> None:
        from app.services import pipeline_config
        required = {"DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"}
        for name, cfg in pipeline_config.PIPELINES.items():
            for key in required:
                self.assertIn(key, cfg, f"Pipeline '{name}' missing DB key '{key}'")
                self.assertTrue(cfg[key], f"Pipeline '{name}' has empty '{key}'")

    def test_unit_defaults_defined_for_each_pipeline(self) -> None:
        from app.services import pipeline_config
        for name in EXPECTED_PIPELINES:
            self.assertIn(name, pipeline_config.PIPELINE_DEFAULTS,
                          f"No PIPELINE_DEFAULTS for '{name}'")
            defaults = pipeline_config.PIPELINE_DEFAULTS[name]
            self.assertIn("protocol", defaults)
            self.assertIn("pair", defaults)
            self.assertTrue(defaults["protocol"], f"Empty protocol default for '{name}'")
            self.assertTrue(defaults["pair"], f"Empty pair default for '{name}'")

    def test_unit_defaults_match_expected(self) -> None:
        from app.services import pipeline_config
        for name, expected in PIPELINE_DEFAULTS.items():
            actual = pipeline_config.PIPELINE_DEFAULTS.get(name, {})
            self.assertEqual(actual.get("protocol"), expected["protocol"],
                             f"Protocol default mismatch for '{name}'")
            self.assertEqual(actual.get("pair"), expected["pair"],
                             f"Pair default mismatch for '{name}'")

    def test_unit_get_current_returns_string(self) -> None:
        from app.services import pipeline_config
        current = pipeline_config.get_current()
        self.assertIsInstance(current, str)
        self.assertIn(current, EXPECTED_PIPELINES)

    def test_unit_get_available_returns_list(self) -> None:
        from app.services import pipeline_config
        available = pipeline_config.get_available()
        self.assertIsInstance(available, list)
        ids = {item["id"] for item in available}
        for name in EXPECTED_PIPELINES:
            self.assertIn(name, ids)

    def test_unit_switch_to_valid(self) -> None:
        from app.services import pipeline_config
        original = pipeline_config.get_current()
        try:
            for name in EXPECTED_PIPELINES:
                self.assertTrue(pipeline_config.switch_to(name))
                self.assertEqual(pipeline_config.get_current(), name)
        finally:
            pipeline_config.switch_to(original)

    def test_unit_switch_to_invalid(self) -> None:
        from app.services import pipeline_config
        self.assertFalse(pipeline_config.switch_to("nonexistent-pipeline"))

    def test_unit_is_enabled_reflects_env(self) -> None:
        from app.services import pipeline_config
        old = os.environ.get("ENABLE_PIPELINE_SWITCHER")
        try:
            os.environ["ENABLE_PIPELINE_SWITCHER"] = "1"
            self.assertTrue(pipeline_config.is_enabled())
            os.environ["ENABLE_PIPELINE_SWITCHER"] = "0"
            self.assertFalse(pipeline_config.is_enabled())
        finally:
            if old is None:
                os.environ.pop("ENABLE_PIPELINE_SWITCHER", None)
            else:
                os.environ["ENABLE_PIPELINE_SWITCHER"] = old


# ─── Integration: Pipeline API endpoints ─────────────────────────────────────

class TestPipelineAPIIntegration(unittest.TestCase):

    @skip_api
    def test_integration_get_pipeline(self) -> None:
        data = _api_get("/api/v1/pipeline")
        self.assertIn("current", data)
        self.assertIn("available", data)
        self.assertIn("defaults", data)
        self.assertIn(data["current"], EXPECTED_PIPELINES)

    @skip_api
    def test_integration_available_pipelines_complete(self) -> None:
        data = _api_get("/api/v1/pipeline")
        ids = {p["id"] for p in data["available"]}
        for name in EXPECTED_PIPELINES:
            self.assertIn(name, ids, f"'{name}' not in available pipelines")

    @skip_api
    def test_integration_defaults_have_protocol_and_pair(self) -> None:
        data = _api_get("/api/v1/pipeline")
        defaults = data["defaults"]
        self.assertTrue(defaults.get("protocol"), "defaults.protocol is empty")
        self.assertTrue(defaults.get("pair"), "defaults.pair is empty")

    @skip_api
    def test_integration_switch_roundtrip(self) -> None:
        initial = _api_get("/api/v1/pipeline")["current"]
        try:
            for name in EXPECTED_PIPELINES:
                result = _api_post("/api/v1/pipeline", {"pipeline": name})
                self.assertEqual(result["current"], name,
                                 f"POST did not confirm switch to '{name}'")
                time.sleep(0.5)
                verify = _api_get("/api/v1/pipeline")
                self.assertEqual(verify["current"], name,
                                 f"GET after switch returned '{verify['current']}' not '{name}'")
        finally:
            _api_post("/api/v1/pipeline", {"pipeline": initial})

    @skip_api
    def test_integration_switch_invalid_returns_400(self) -> None:
        try:
            _api_post("/api/v1/pipeline", {"pipeline": "bogus"})
            self.fail("Expected HTTP 400")
        except urllib.error.HTTPError as exc:
            self.assertEqual(exc.code, 400)

    @skip_api
    def test_integration_cache_flushed_on_switch(self) -> None:
        """After switching pipelines, cached data should be invalidated."""
        initial = _api_get("/api/v1/pipeline")["current"]
        try:
            _switch_pipeline("solstice")
            code1, body1 = _api_get_raw("/api/v1/kamino/kpi-loan-value?last_window=24h")
            val_solstice = body1.get("data", {}).get("primary") if code1 == 200 else None

            _switch_pipeline("onyc")
            code2, body2 = _api_get_raw("/api/v1/kamino/kpi-loan-value?last_window=24h")
            val_onyc = body2.get("data", {}).get("primary") if code2 == 200 else None

            if code1 == 200 and code2 == 200 and val_solstice is not None and val_onyc is not None:
                self.assertNotEqual(
                    val_solstice, val_onyc,
                    "kpi-loan-value returned identical data for both pipelines — cache may not be flushed"
                )
        finally:
            _api_post("/api/v1/pipeline", {"pipeline": initial})


# ─── Integration: Meta endpoint per pipeline ─────────────────────────────────

class TestMetaPerPipelineIntegration(unittest.TestCase):

    @skip_api
    def test_integration_meta_solstice(self) -> None:
        self._check_meta_for("solstice")

    @skip_api
    def test_integration_meta_onyc(self) -> None:
        self._check_meta_for("onyc")

    def _check_meta_for(self, pipeline: str) -> None:
        initial = _api_get("/api/v1/pipeline")["current"]
        try:
            _switch_pipeline(pipeline)
            meta = _api_get("/api/v1/meta")
            expected = PIPELINE_EXPECTED_META[pipeline]
            protocols = meta.get("protocols", [])
            pairs = [pp["pair"] for pp in meta.get("protocol_pairs", [])]
            for proto in expected["protocols_contain"]:
                self.assertIn(proto, protocols,
                              f"{pipeline}: expected protocol '{proto}' in {protocols}")
            for pair in expected["pairs_contain"]:
                self.assertIn(pair, pairs,
                              f"{pipeline}: expected pair '{pair}' in {pairs}")
        finally:
            _api_post("/api/v1/pipeline", {"pipeline": initial})


# ─── Integration: Comprehensive widget tests per pipeline ─────────────────────

class TestAllWidgetsSolstice(unittest.TestCase):
    """Probe every widget on the solstice pipeline."""

    @classmethod
    def setUpClass(cls) -> None:
        if _skip_api:
            raise unittest.SkipTest("API not reachable")
        cls._initial = _api_get("/api/v1/pipeline")["current"]
        _switch_pipeline("solstice")

    @classmethod
    def tearDownClass(cls) -> None:
        try:
            _api_post("/api/v1/pipeline", {"pipeline": cls._initial})
        except Exception:
            pass

    def _probe_widget(self, page_id: str, widget: str) -> None:
        url = _build_widget_url(page_id, widget, "solstice")
        code, body = _api_get_raw(url)
        detail = body.get("detail", "")
        self.assertEqual(
            code, 200,
            f"[solstice] {page_id}/{widget} → HTTP {code}: {detail}"
        )
        status = body.get("status")
        self.assertEqual(
            status, "success",
            f"[solstice] {page_id}/{widget} → status='{status}'"
        )


def _make_solstice_widget_test(page_id: str, widget: str):
    def test_method(self):
        self._probe_widget(page_id, widget)
    test_method.__doc__ = f"solstice: {page_id}/{widget}"
    return test_method


for _page, _cfg in ALL_WIDGETS.items():
    for _widget in _cfg["widgets"]:
        _name = f"test_{_page.replace('-', '_')}__{_widget.replace('-', '_')}"
        setattr(TestAllWidgetsSolstice, _name, _make_solstice_widget_test(_page, _widget))


class TestAllWidgetsOnyc(unittest.TestCase):
    """Probe every widget on the onyc pipeline."""

    @classmethod
    def setUpClass(cls) -> None:
        if _skip_api:
            raise unittest.SkipTest("API not reachable")
        cls._initial = _api_get("/api/v1/pipeline")["current"]
        _switch_pipeline("onyc")

    @classmethod
    def tearDownClass(cls) -> None:
        try:
            _api_post("/api/v1/pipeline", {"pipeline": cls._initial})
        except Exception:
            pass

    def _probe_widget(self, page_id: str, widget: str) -> None:
        url = _build_widget_url(page_id, widget, "onyc")
        code, body = _api_get_raw(url)
        detail = body.get("detail", "")
        self.assertEqual(
            code, 200,
            f"[onyc] {page_id}/{widget} → HTTP {code}: {detail}"
        )
        status = body.get("status")
        self.assertEqual(
            status, "success",
            f"[onyc] {page_id}/{widget} → status='{status}'"
        )


def _make_onyc_widget_test(page_id: str, widget: str):
    def test_method(self):
        self._probe_widget(page_id, widget)
    test_method.__doc__ = f"onyc: {page_id}/{widget}"
    return test_method


for _page, _cfg in ALL_WIDGETS.items():
    for _widget in _cfg["widgets"]:
        _name = f"test_{_page.replace('-', '_')}__{_widget.replace('-', '_')}"
        setattr(TestAllWidgetsOnyc, _name, _make_onyc_widget_test(_page, _widget))


# ─── Quick diagnostic: all widgets on whichever pipeline is currently active ──

class TestAllWidgetsCurrentPipeline(unittest.TestCase):
    """Run against the currently-active pipeline. No switching."""

    @classmethod
    def setUpClass(cls) -> None:
        if _skip_api:
            raise unittest.SkipTest("API not reachable")
        info = _api_get("/api/v1/pipeline")
        cls._pipeline = info["current"]

    def _probe_widget(self, page_id: str, widget: str) -> None:
        url = _build_widget_url(page_id, widget, self._pipeline)
        code, body = _api_get_raw(url)
        detail = body.get("detail", "")
        self.assertEqual(
            code, 200,
            f"[{self._pipeline}] {page_id}/{widget} → HTTP {code}: {detail}"
        )
        status = body.get("status")
        self.assertEqual(
            status, "success",
            f"[{self._pipeline}] {page_id}/{widget} → status='{status}'"
        )


def _make_current_widget_test(page_id: str, widget: str):
    def test_method(self):
        self._probe_widget(page_id, widget)
    test_method.__doc__ = f"current: {page_id}/{widget}"
    return test_method


for _page, _cfg in ALL_WIDGETS.items():
    for _widget in _cfg["widgets"]:
        _name = f"test_{_page.replace('-', '_')}__{_widget.replace('-', '_')}"
        setattr(TestAllWidgetsCurrentPipeline, _name, _make_current_widget_test(_page, _widget))


# ─── Integration: UI pipeline dropdown rendering ─────────────────────────────

class TestUIDropdownIntegration(unittest.TestCase):

    @skip_ui
    def test_integration_dropdown_rendered_on_dex_liquidity(self) -> None:
        html = _ui_get("/dex-liquidity")
        self.assertIn('id="pipeline-select"', html,
                      "Pipeline dropdown not found in rendered HTML")
        self.assertIn("switchPipeline", html,
                      "switchPipeline JS function not found")

    @skip_ui
    def test_integration_dropdown_has_both_options(self) -> None:
        html = _ui_get("/dex-liquidity")
        for name in EXPECTED_PIPELINES:
            self.assertIn(f'value="{name}"', html,
                          f"Option for '{name}' not found in dropdown HTML")

    @skip_ui
    def test_integration_pair_matches_pipeline_on_each_page(self) -> None:
        initial = _api_get("/api/v1/pipeline")["current"]
        try:
            for pipeline_name, expected in PIPELINE_DEFAULTS.items():
                _switch_pipeline(pipeline_name)
                html = _ui_get("/dex-swaps")
                pair_value = expected["pair"]
                self.assertIn(
                    pair_value, html,
                    f"After switching to '{pipeline_name}', expected pair "
                    f"'{pair_value}' not found in /dex-swaps HTML"
                )
        finally:
            _api_post("/api/v1/pipeline", {"pipeline": initial})

    @skip_ui
    def test_integration_pipeline_dropdown_on_all_pages(self) -> None:
        page_paths = [
            "/dex-liquidity", "/dex-swaps", "/kamino",
            "/exponent-yield", "/system-health", "/global-ecosystem",
        ]
        missing: list[str] = []
        for path in page_paths:
            try:
                html = _ui_get(path)
                if 'id="pipeline-select"' not in html:
                    missing.append(path)
            except Exception as exc:
                missing.append(f"{path} (error: {exc})")
        if missing:
            self.fail(f"Pipeline dropdown missing on: {missing}")


if __name__ == "__main__":
    unittest.main()
