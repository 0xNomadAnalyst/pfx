#!/usr/bin/env python3
"""
Benchmark dashboard widget endpoints for optimization work.

This script is designed to help evaluate API/SQL changes over time by recording:
- Cold request latency (first call per scenario)
- Warm request latency distribution (repeated calls)
- Error rate and response payload size

Example:
  python scripts/benchmark_dashboard.py --protocol raydium --pair USX-USDC --windows 1h,24h,7d --repeats 5
"""

from __future__ import annotations

import argparse
import json
import statistics
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


@dataclass(frozen=True)
class WidgetScenario:
    widget: str
    extra_params: dict[str, str]
    direct_path: str = ""


LIQUIDITY_SCENARIOS: list[WidgetScenario] = [
    WidgetScenario("liquidity-distribution", {}),
    WidgetScenario("liquidity-depth", {}),
    WidgetScenario("liquidity-change-heatmap", {}),
    WidgetScenario("kpi-tvl", {}),
    WidgetScenario("kpi-impact-500k", {}),
    WidgetScenario("kpi-reserves", {}),
    WidgetScenario("kpi-largest-impact", {}),
    WidgetScenario("kpi-pool-balance", {}),
    WidgetScenario("kpi-average-impact", {}),
    WidgetScenario("liquidity-depth-table", {}),
    WidgetScenario("usdc-lp-flows", {}),
    WidgetScenario("usdc-pool-share-concentration", {}),
    WidgetScenario("trade-impact-toggle", {"impact_mode": "size"}),
    WidgetScenario("trade-impact-toggle", {"impact_mode": "impact"}),
    WidgetScenario("ranked-lp-events", {}),
]

SWAPS_SCENARIOS: list[WidgetScenario] = [
    WidgetScenario("kpi-swap-volume-24h", {}),
    WidgetScenario("kpi-swap-count-24h", {}),
    WidgetScenario("kpi-price-min-max", {}),
    WidgetScenario("kpi-vwap-buy-sell", {}),
    WidgetScenario("kpi-price-std-dev", {}),
    WidgetScenario("kpi-vwap-spread", {}),
    WidgetScenario("kpi-largest-usx-sell", {}),
    WidgetScenario("kpi-largest-usx-buy", {}),
    WidgetScenario("kpi-max-1h-sell-pressure", {}),
    WidgetScenario("kpi-max-1h-buy-pressure", {}),
    WidgetScenario("swaps-flows-toggle", {"flow_mode": "usx"}),
    WidgetScenario("swaps-flows-toggle", {"flow_mode": "usdc"}),
    WidgetScenario("swaps-price-impacts", {}),
    WidgetScenario("swaps-spread-volatility", {}),
    WidgetScenario("swaps-ohlcv", {}),
    WidgetScenario("swaps-distribution-toggle", {"distribution_mode": "sell-order"}),
    WidgetScenario("swaps-distribution-toggle", {"distribution_mode": "net-sell-pressure"}),
    WidgetScenario("swaps-ranked-events", {}),
]

KAMINO_SCENARIOS: list[WidgetScenario] = [
    # Group 1 KPIs
    WidgetScenario("kpi-utilization-by-reserve", {}),
    WidgetScenario("kpi-loan-value", {}),
    WidgetScenario("kpi-obligations-debt-size", {}),
    WidgetScenario("kpi-share-borrow-asset", {}),
    WidgetScenario("kpi-ltv-hf", {}),
    WidgetScenario("kpi-collateral-value", {}),
    WidgetScenario("kpi-unhealthy-share", {}),
    WidgetScenario("kpi-share-collateral-asset", {}),
    # Group 2 KPIs
    WidgetScenario("kpi-zero-use-count", {}),
    WidgetScenario("kpi-zero-use-capacity", {}),
    WidgetScenario("kpi-borrow-apy", {}),
    WidgetScenario("kpi-supply-apy", {}),
    # Group 3 KPIs
    WidgetScenario("kpi-borrow-vol-24h", {}),
    WidgetScenario("kpi-repay-vol-24h", {}),
    WidgetScenario("kpi-liquidation-vol-30d", {}),
    WidgetScenario("kpi-liquidation-count-30d", {}),
    WidgetScenario("kpi-withdraw-vol-24h", {}),
    WidgetScenario("kpi-deposit-vol-24h", {}),
    WidgetScenario("kpi-liquidation-avg-size", {}),
    WidgetScenario("kpi-days-no-liquidation", {}),
    # Charts
    WidgetScenario("kamino-supply-collateral-status", {}),
    WidgetScenario("kamino-rate-curve", {}),
    WidgetScenario("kamino-loan-size-dist", {}),
    WidgetScenario("kamino-stress-debt", {}),
    WidgetScenario("kamino-utilization-timeseries", {}),
    WidgetScenario("kamino-ltv-hf-timeseries", {}),
    WidgetScenario("kamino-liability-flows", {}),
    WidgetScenario("kamino-liquidations", {}),
    # Tables and page actions
    WidgetScenario("kamino-obligation-watchlist", {"rows": "20", "page": "1"}),
    WidgetScenario("kamino-config-table", {}),
    WidgetScenario("kamino-market-assets", {}),
    WidgetScenario("kamino-sensitivity-table", {}),
]

EXPONENT_SCENARIOS: list[WidgetScenario] = [
    # Market selector metadata
    WidgetScenario("exponent-market-meta", {}),
    # Group 1 KPIs and headline charts
    WidgetScenario("exponent-pie-tvl", {}),
    WidgetScenario("kpi-base-token-yield", {}),
    WidgetScenario("kpi-locked-base-tokens", {}),
    WidgetScenario("kpi-current-fixed-yield", {}),
    WidgetScenario("kpi-sy-base-collateral", {}),
    WidgetScenario("exponent-timeline", {}),
    WidgetScenario("kpi-fixed-variable-spread", {}),
    WidgetScenario("kpi-sy-coll-ratio", {}),
    WidgetScenario("kpi-yt-staked-share", {}),
    WidgetScenario("kpi-amm-depth", {}),
    # Group 2 KPIs
    WidgetScenario("kpi-pt-base-price", {}),
    WidgetScenario("kpi-apy-impact-pt-trade", {}),
    WidgetScenario("kpi-pt-vol-24h", {}),
    WidgetScenario("kpi-amm-deployment-ratio", {}),
    # Market info cards
    WidgetScenario("exponent-market-info-mkt1", {}),
    WidgetScenario("exponent-market-info-mkt2", {}),
    # Timeseries charts
    WidgetScenario("exponent-pt-swap-flows-mkt1", {}),
    WidgetScenario("exponent-pt-swap-flows-mkt2", {}),
    WidgetScenario("exponent-token-strip-flows-mkt1", {}),
    WidgetScenario("exponent-token-strip-flows-mkt2", {}),
    WidgetScenario("exponent-vault-sy-balance-mkt1", {}),
    WidgetScenario("exponent-vault-sy-balance-mkt2", {}),
    WidgetScenario("exponent-yt-staked-mkt1", {}),
    WidgetScenario("exponent-yt-staked-mkt2", {}),
    WidgetScenario("exponent-yield-trading-liq-mkt1", {}),
    WidgetScenario("exponent-yield-trading-liq-mkt2", {}),
    WidgetScenario("exponent-realized-rates-mkt1", {}),
    WidgetScenario("exponent-realized-rates-mkt2", {}),
    WidgetScenario("exponent-divergence-mkt1", {}),
    WidgetScenario("exponent-divergence-mkt2", {}),
    # Table-backed modal action
    WidgetScenario("exponent-market-assets", {}),
]

HEALTH_SCENARIOS: list[WidgetScenario] = [
    WidgetScenario("health-master", {}),
    WidgetScenario("health-queue-table", {}),
    WidgetScenario("health-queue-chart", {}),
    WidgetScenario("health-trigger-table", {}),
    WidgetScenario("health-base-table", {}),
    WidgetScenario("health-base-chart-events", {}),
    WidgetScenario("health-base-chart-accounts", {}),
    WidgetScenario("health-cagg-table", {}),
]

GLOBAL_ECOSYSTEM_SCENARIOS: list[WidgetScenario] = [
    WidgetScenario("ge-hdr-issuance", {}),
    WidgetScenario("ge-hdr-yields", {}),
    WidgetScenario("ge-hdr-availability", {}),
    WidgetScenario("ge-hdr-tvl-activity", {}),
    WidgetScenario("ge-issuance-bar", {}),
    WidgetScenario("ge-issuance-pie", {}),
    WidgetScenario("ge-issuance-time", {}),
    WidgetScenario("ge-yield-generation", {}),
    WidgetScenario("ge-yield-vesting-rate", {}),
    WidgetScenario("ge-current-yields", {}),
    WidgetScenario("ge-yields-vs-time", {}),
    WidgetScenario("ge-supply-dist-usx-pie", {}),
    WidgetScenario("ge-supply-dist-eusx-pie", {}),
    WidgetScenario("ge-supply-dist-usx-bar", {}),
    WidgetScenario("ge-supply-dist-eusx-bar", {}),
    WidgetScenario("ge-token-avail-usx", {}),
    WidgetScenario("ge-token-avail-eusx", {}),
    WidgetScenario("ge-availability-bar", {}),
    WidgetScenario("ge-availability-time", {}),
    WidgetScenario("ge-tvl-defi-usx", {}),
    WidgetScenario("ge-tvl-defi-eusx", {}),
    WidgetScenario("ge-tvl-bar", {}),
    WidgetScenario("ge-tvl-pie", {}),
    WidgetScenario("ge-tvl-time", {}),
    WidgetScenario("ge-tvl-share", {}),
    WidgetScenario("ge-tvl-share-usx", {}),
    WidgetScenario("ge-tvl-share-eusx", {}),
    WidgetScenario("ge-activity-bar", {}),
    WidgetScenario("ge-activity-pct", {}),
    WidgetScenario("ge-activity-vol", {}),
    WidgetScenario("ge-activity-share", {}),
    WidgetScenario("ge-activity-pct-usx", {}),
    WidgetScenario("ge-activity-pct-eusx", {}),
    WidgetScenario("ge-activity-vol-usx", {}),
    WidgetScenario("ge-activity-vol-eusx", {}),
    WidgetScenario("ge-activity-share-usx", {}),
    WidgetScenario("ge-activity-share-eusx", {}),
]

RISK_ANALYSIS_SCENARIOS: list[WidgetScenario] = [
    WidgetScenario("ra-pvalue-tables", {}),
    WidgetScenario("ra-liq-dist-ray", {}),
    WidgetScenario("ra-liq-dist-orca", {}),
    WidgetScenario("ra-liq-depth-ray", {}),
    WidgetScenario("ra-liq-depth-orca", {}),
    WidgetScenario("ra-prob-ray", {}),
    WidgetScenario("ra-prob-orca", {}),
    WidgetScenario("ra-xp-exposure", {}),
    WidgetScenario("ra-xp-dist-ray", {}),
    WidgetScenario("ra-xp-dist-orca", {}),
    WidgetScenario("ra-xp-depth-ray", {}),
    WidgetScenario("ra-xp-depth-orca", {}),
    WidgetScenario("ra-stress-test", {}),
    WidgetScenario("ra-sensitivity-table", {}),
    WidgetScenario("ra-cascade", {}),
]

HEADER_HEALTH_SCENARIOS: list[WidgetScenario] = [
    WidgetScenario("health-status", {}, direct_path="/api/v1/health-status"),
]

HEADER_HEALTH_PROXY_SCENARIOS: list[WidgetScenario] = [
    WidgetScenario("health-status-proxy", {}, direct_path="/api/health-status"),
]

PAGE_DEFAULT_SCENARIOS: dict[str, list[WidgetScenario]] = {
    "playbook-liquidity": LIQUIDITY_SCENARIOS,
    "dex-liquidity": LIQUIDITY_SCENARIOS,
    "dex-swaps": SWAPS_SCENARIOS,
    "kamino": KAMINO_SCENARIOS,
    "exponent": EXPONENT_SCENARIOS,
    "health": HEALTH_SCENARIOS,
    "global-ecosystem": GLOBAL_ECOSYSTEM_SCENARIOS,
    "risk-analysis": RISK_ANALYSIS_SCENARIOS,
    "header-health": HEADER_HEALTH_SCENARIOS,
    "header-health-proxy": HEADER_HEALTH_PROXY_SCENARIOS,
}

PAGE_ALIASES: dict[str, str] = {
    "all": "all",
    "playbook-liquidity": "playbook-liquidity",
    "dex-liquidity": "dex-liquidity",
    "dex-swaps": "dex-swaps",
    "kamino": "kamino",
    "exponent": "exponent",
    "health": "health",
    "global-ecosystem": "global-ecosystem",
    "risk-analysis": "risk-analysis",
    "header-health": "header-health",
    "header-health-proxy": "header-health-proxy",
}

QUICK_WIDGETS_BY_PAGE: dict[str, list[str]] = {
    "playbook-liquidity": [
        "liquidity-distribution",
        "liquidity-depth",
        "kpi-tvl",
        "trade-impact-toggle",
        "ranked-lp-events",
    ],
    "dex-liquidity": [
        "liquidity-distribution",
        "liquidity-depth",
        "kpi-tvl",
        "trade-impact-toggle",
        "ranked-lp-events",
    ],
    "dex-swaps": [
        "kpi-swap-volume-24h",
        "swaps-flows-toggle",
        "swaps-ohlcv",
        "swaps-ranked-events",
    ],
    "kamino": [
        "kpi-utilization-by-reserve",
        "kamino-market-assets",
        "kamino-rate-curve",
        "kamino-utilization-timeseries",
        "kamino-obligation-watchlist",
    ],
    "exponent": [
        "exponent-market-meta",
        "kpi-base-token-yield",
        "exponent-pie-tvl",
        "exponent-pt-swap-flows-mkt1",
        "exponent-market-assets",
    ],
    "health": [
        "health-master",
        "health-queue-chart",
        "health-base-chart-events",
        "health-cagg-table",
    ],
    "global-ecosystem": [
        "ge-issuance-bar",
        "ge-issuance-time",
        "ge-yields-vs-time",
        "ge-tvl-share-usx",
        "ge-activity-vol-usx",
    ],
    "risk-analysis": [
        "ra-pvalue-tables",
        "ra-liq-dist-orca",
        "ra-xp-exposure",
        "ra-stress-test",
        "ra-cascade",
    ],
    "header-health": [
        "health-status",
    ],
    "header-health-proxy": [
        "health-status-proxy",
    ],
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark dashboard API endpoints")
    parser.add_argument("--base-url", default="http://127.0.0.1:8001", help="API base URL")
    parser.add_argument(
        "--page",
        default="playbook-liquidity",
        help="Page segment(s): single page, comma-separated pages, or 'all'",
    )
    parser.add_argument("--protocol", default="orca", help="Protocol filter")
    parser.add_argument("--pair", default="ONyc-USDC", help="Pair filter")
    parser.add_argument("--mkt1", default="", help="Optional market selector #1 (exponent page)")
    parser.add_argument("--mkt2", default="", help="Optional market selector #2 (exponent page)")
    parser.add_argument(
        "--windows",
        default="1h,24h,7d,30d",
        help="Comma-separated last-window values (e.g. 1h,24h,7d)",
    )
    parser.add_argument("--repeats", type=int, default=5, help="Warm repeats per scenario")
    parser.add_argument("--timeout-seconds", type=float, default=30.0, help="HTTP timeout")
    parser.add_argument("--parallel", type=int, default=1, help="Concurrent scenario workers")
    parser.add_argument(
        "--parallel-ramp",
        default="",
        help="Optional comma-separated worker ramp (e.g. 1,2,4). Runs each profile sequentially.",
    )
    parser.add_argument(
        "--soak-seconds",
        type=float,
        default=0.0,
        help="Optional soak duration per profile (0 disables, runs repeated loops until duration expires).",
    )
    parser.add_argument(
        "--soak-pause-seconds",
        type=float,
        default=0.0,
        help="Pause between soak loops for the same profile.",
    )
    parser.add_argument("--output-json", default="", help="Optional output path for JSON report")
    parser.add_argument(
        "--widgets",
        default="",
        help="Optional comma-separated widget ids to include (filters default scenario list)",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Use a small representative widget subset per page for fast checks",
    )
    parser.add_argument(
        "--fail-on-errors",
        action="store_true",
        help="Exit non-zero when any scenario has cold/warm request errors",
    )
    parser.add_argument(
        "--capture-telemetry",
        action="store_true",
        help="Capture /api/v1/telemetry snapshot (if enabled on API)",
    )
    parser.add_argument(
        "--reset-telemetry",
        action="store_true",
        help="Call /api/v1/telemetry/reset before benchmark (requires --capture-telemetry)",
    )
    parser.add_argument(
        "--max-widget-errors",
        type=int,
        default=-1,
        help="Fail if any tracked widget exceeds this total error count (-1 disables).",
    )
    parser.add_argument(
        "--max-widget-5xx",
        type=int,
        default=-1,
        help="Fail if any tracked widget exceeds this 5xx count (-1 disables).",
    )
    parser.add_argument(
        "--max-widget-timeouts",
        type=int,
        default=-1,
        help="Fail if any tracked widget exceeds this timeout count (-1 disables).",
    )
    parser.add_argument(
        "--hotspot-widgets",
        default="ge-activity-vol-usx,ge-tvl-share-usx",
        help="Comma-separated widget ids to report and gate as hotspots.",
    )
    parser.add_argument(
        "--expected-refresh-interval-seconds",
        type=float,
        default=-1.0,
        help="Fail if API telemetry reports cadence outside tolerance (-1 disables).",
    )
    parser.add_argument(
        "--refresh-interval-tolerance-seconds",
        type=float,
        default=2.0,
        help="Allowed absolute delta for cadence compliance gate.",
    )
    return parser.parse_args()


def percentile(sorted_values: list[float], p: float) -> float:
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return sorted_values[0]
    idx = (len(sorted_values) - 1) * p
    lo = int(idx)
    hi = min(lo + 1, len(sorted_values) - 1)
    frac = idx - lo
    return sorted_values[lo] * (1 - frac) + sorted_values[hi] * frac


def fetch_json(url: str, timeout_seconds: float) -> tuple[dict[str, Any] | None, int, str]:
    req = Request(url, method="GET")
    try:
        with urlopen(req, timeout=timeout_seconds) as resp:
            code = int(resp.status)
            raw = resp.read()
            text = raw.decode("utf-8")
            return json.loads(text), code, text
    except HTTPError as exc:
        payload = exc.read().decode("utf-8", errors="replace")
        return None, int(exc.code), payload
    except TimeoutError as exc:
        return None, 0, str(exc)
    except URLError as exc:
        return None, 0, str(exc)
    except Exception as exc:  # pragma: no cover - defensive path
        return None, 0, str(exc)


def post_json(url: str, timeout_seconds: float) -> tuple[dict[str, Any] | None, int, str]:
    req = Request(url, method="POST")
    try:
        with urlopen(req, timeout=timeout_seconds) as resp:
            code = int(resp.status)
            raw = resp.read()
            text = raw.decode("utf-8")
            return json.loads(text), code, text
    except HTTPError as exc:
        payload = exc.read().decode("utf-8", errors="replace")
        return None, int(exc.code), payload
    except TimeoutError as exc:
        return None, 0, str(exc)
    except URLError as exc:
        return None, 0, str(exc)
    except Exception as exc:  # pragma: no cover - defensive path
        return None, 0, str(exc)


def benchmark_once(url: str, timeout_seconds: float) -> dict[str, Any]:
    started = time.perf_counter()
    payload, status_code, raw = fetch_json(url, timeout_seconds)
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    ok = (
        status_code == 200
        and payload is not None
        and (
            payload.get("status") == "success"
            or "is_green" in payload
        )
    )
    return {
        "ok": ok,
        "status_code": status_code,
        "elapsed_ms": elapsed_ms,
        "payload_bytes": len(raw.encode("utf-8", errors="ignore")),
        "error": "" if ok else raw[:500],
    }


def build_url(base_url: str, page: str, widget: str, params: dict[str, Any]) -> str:
    query = urlencode(params)
    return f"{base_url}/api/v1/{page}/{widget}?{query}"


def parse_pages(page_arg: str) -> list[str]:
    raw_items = [item.strip() for item in page_arg.split(",") if item.strip()]
    if not raw_items:
        raw_items = ["playbook-liquidity"]

    normalized: list[str] = []
    for item in raw_items:
        key = item.lower()
        if key == "all":
            return [
                "playbook-liquidity",
                "dex-swaps",
                "kamino",
                "exponent",
                "health",
                "global-ecosystem",
                "risk-analysis",
                "header-health",
                "header-health-proxy",
            ]
        alias = PAGE_ALIASES.get(key)
        if alias is None:
            raise ValueError(f"Unsupported page: {item}")
        normalized.append(alias)
    return normalized


def scenario_list_for_page(page: str, widget_filter: set[str], quick: bool) -> list[WidgetScenario]:
    scenarios = PAGE_DEFAULT_SCENARIOS.get(page, [])
    if not scenarios:
        raise ValueError(f"No scenarios defined for page: {page}")
    if quick and not widget_filter:
        quick_widgets = set(QUICK_WIDGETS_BY_PAGE.get(page, []))
        quick_scenarios = [scenario for scenario in scenarios if scenario.widget in quick_widgets]
        if quick_scenarios:
            return quick_scenarios
    if not widget_filter:
        return list(scenarios)
    filtered = [scenario for scenario in scenarios if scenario.widget in widget_filter]
    if filtered:
        return filtered
    return [WidgetScenario(widget=widget_id, extra_params={}) for widget_id in sorted(widget_filter)]


def parse_parallel_profiles(parallel: int, parallel_ramp: str) -> list[int]:
    if not parallel_ramp.strip():
        return [max(1, int(parallel))]
    parsed: list[int] = []
    for raw in parallel_ramp.split(","):
        raw = raw.strip()
        if not raw:
            continue
        try:
            value = max(1, int(raw))
        except ValueError:
            raise ValueError(f"Invalid parallel ramp value: {raw}") from None
        if value not in parsed:
            parsed.append(value)
    if not parsed:
        return [max(1, int(parallel))]
    return parsed


def run_scenario(
    base_url: str,
    page: str,
    scenario: WidgetScenario,
    common_params: dict[str, Any],
    repeats: int,
    timeout_seconds: float,
) -> dict[str, Any]:
    params = dict(common_params)
    params.update(scenario.extra_params)
    if scenario.direct_path:
        query = urlencode(params)
        base = base_url.rstrip("/")
        url = f"{base}{scenario.direct_path}"
        if query:
            url = f"{url}?{query}"
    else:
        url = build_url(base_url, page, scenario.widget, params)

    cold = benchmark_once(url, timeout_seconds)
    warm_runs = [benchmark_once(url, timeout_seconds) for _ in range(repeats)]
    warm_latencies = sorted(run["elapsed_ms"] for run in warm_runs)
    success_count = sum(1 for run in warm_runs if run["ok"])
    error_samples = [run["error"] for run in warm_runs if not run["ok"]][:2]
    warm_5xx_count = sum(1 for run in warm_runs if int(run.get("status_code", 0)) >= 500)
    warm_timeout_count = sum(1 for run in warm_runs if int(run.get("status_code", 0)) == 0)

    p50 = statistics.median(warm_latencies) if warm_latencies else 0.0
    p95 = percentile(warm_latencies, 0.95)
    avg = statistics.mean(warm_latencies) if warm_latencies else 0.0
    min_ms = min(warm_latencies) if warm_latencies else 0.0
    max_ms = max(warm_latencies) if warm_latencies else 0.0

    return {
        "page": page,
        "widget": scenario.widget,
        "params": params,
        "cold_ms": round(cold["elapsed_ms"], 2),
        "cold_ok": cold["ok"],
        "cold_status_code": cold["status_code"],
        "warm_repeats": repeats,
        "warm_success_count": success_count,
        "warm_error_count": repeats - success_count,
        "warm_5xx_count": warm_5xx_count,
        "warm_timeout_count": warm_timeout_count,
        "warm_min_ms": round(min_ms, 2),
        "warm_p50_ms": round(p50, 2),
        "warm_p95_ms": round(p95, 2),
        "warm_avg_ms": round(avg, 2),
        "warm_max_ms": round(max_ms, 2),
        "payload_bytes_p50": int(statistics.median(run["payload_bytes"] for run in warm_runs)) if warm_runs else 0,
        "error_samples": error_samples,
        "cold_timeout": int(cold.get("status_code", 0)) == 0,
        "cold_5xx": int(cold.get("status_code", 0)) >= 500,
    }


def execute_jobs(
    *,
    jobs: list[tuple[str, WidgetScenario, dict[str, Any]]],
    base_url: str,
    repeats: int,
    timeout_seconds: float,
    parallel: int,
    profile_label: str,
    loop_index: int,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    if parallel <= 1:
        for page, scenario, params in jobs:
            row = run_scenario(
                base_url=base_url,
                page=page,
                scenario=scenario,
                common_params=params,
                repeats=repeats,
                timeout_seconds=timeout_seconds,
            )
            row["profile"] = profile_label
            row["loop_index"] = loop_index
            results.append(row)
        return results

    with ThreadPoolExecutor(max_workers=parallel) as pool:
        future_map = {
            pool.submit(
                run_scenario,
                base_url,
                page,
                scenario,
                params,
                repeats,
                timeout_seconds,
            ): (page, scenario, params)
            for page, scenario, params in jobs
        }
        for future in as_completed(future_map):
            row = future.result()
            row["profile"] = profile_label
            row["loop_index"] = loop_index
            results.append(row)
    return results


def summarize_hotspot_widgets(results: list[dict[str, Any]], hotspot_widgets: set[str]) -> dict[str, dict[str, Any]]:
    summary: dict[str, dict[str, Any]] = {}
    for row in results:
        widget = str(row.get("widget", ""))
        if widget not in hotspot_widgets:
            continue
        key = f"{row.get('page', '')}/{widget}"
        if key not in summary:
            summary[key] = {
                "count": 0,
                "errors": 0,
                "errors_5xx": 0,
                "timeouts": 0,
                "warm_p95_ms_max": 0.0,
                "cold_ms_max": 0.0,
            }
        item = summary[key]
        item["count"] += 1
        errors = int(row.get("warm_error_count", 0)) + (0 if row.get("cold_ok", False) else 1)
        errors_5xx = int(row.get("warm_5xx_count", 0)) + (1 if row.get("cold_5xx") else 0)
        timeouts = int(row.get("warm_timeout_count", 0)) + (1 if row.get("cold_timeout") else 0)
        item["errors"] += errors
        item["errors_5xx"] += errors_5xx
        item["timeouts"] += timeouts
        item["warm_p95_ms_max"] = max(float(item["warm_p95_ms_max"]), float(row.get("warm_p95_ms", 0.0)))
        item["cold_ms_max"] = max(float(item["cold_ms_max"]), float(row.get("cold_ms", 0.0)))
    return summary


def print_report(results: list[dict[str, Any]]) -> None:
    print("\nBenchmark results")
    print("=" * 110)
    header = (
        f"{'Page':16} {'Widget':28} {'Window':>6} {'Cold(ms)':>9} {'P50(ms)':>9} "
        f"{'P95(ms)':>9} {'Avg(ms)':>9} {'Err':>5} {'Payload(B)':>10}"
    )
    print(header)
    print("-" * len(header))
    for row in results:
        params = row["params"]
        window = str(params.get("last_window", "n/a"))
        page = str(row.get("page", ""))
        widget_name = row["widget"]
        if "impact_mode" in params:
            widget_name = f"{widget_name}:{params['impact_mode']}"
        if "flow_mode" in params:
            widget_name = f"{widget_name}:{params['flow_mode']}"
        if "distribution_mode" in params:
            widget_name = f"{widget_name}:{params['distribution_mode']}"
        print(
            f"{page[:16]:16} {widget_name[:28]:28} {window:>6} "
            f"{row['cold_ms']:9.2f} {row['warm_p50_ms']:9.2f} {row['warm_p95_ms']:9.2f} "
            f"{row['warm_avg_ms']:9.2f} {row['warm_error_count']:5d} {row['payload_bytes_p50']:10d}"
        )
    print("=" * 110)
    failures = [
        row for row in results
        if (not row.get("cold_ok", False)) or int(row.get("warm_error_count", 0)) > 0
    ]
    print(f"Scenarios: {len(results)} | Failures: {len(failures)}")
    if failures:
        print("Failure samples:")
        for row in failures[:10]:
            samples = row.get("error_samples") or []
            sample = str(samples[0]) if samples else ""
            sample = sample.replace("\n", " ")[:160]
            print(
                f"- {row.get('page')}/{row.get('widget')} "
                f"(cold_status={row.get('cold_status_code')}, warm_errors={row.get('warm_error_count')}): {sample}"
            )
        if len(failures) > 10:
            print(f"- ... and {len(failures) - 10} more failing scenarios")


def main() -> int:
    args = parse_args()
    windows = [item.strip() for item in args.windows.split(",") if item.strip()]
    widget_filter = {item.strip() for item in args.widgets.split(",") if item.strip()}
    pages = parse_pages(args.page)
    parallel_profiles = parse_parallel_profiles(args.parallel, args.parallel_ramp)
    hotspot_widgets = {item.strip() for item in args.hotspot_widgets.split(",") if item.strip()}

    if args.reset_telemetry and not args.capture_telemetry:
        raise ValueError("--reset-telemetry requires --capture-telemetry")

    start = datetime.now(timezone.utc)
    jobs: list[tuple[str, WidgetScenario, dict[str, Any]]] = []
    for page in pages:
        scenarios = scenario_list_for_page(page, widget_filter, args.quick)
        for window in windows:
            for scenario in scenarios:
                if page == "header-health":
                    common_params = {}
                else:
                    common_params = {
                        "protocol": args.protocol,
                        "pair": args.pair,
                        "last_window": window,
                        "mkt1": args.mkt1,
                        "mkt2": args.mkt2,
                    }
                jobs.append((page, scenario, common_params))

    results: list[dict[str, Any]] = []
    profile_runs: list[dict[str, Any]] = []
    telemetry_base = args.base_url.rstrip("/")
    for parallel in parallel_profiles:
        profile_label = f"parallel-{parallel}"
        profile_before: dict[str, Any] | None = None
        profile_after: dict[str, Any] | None = None
        if args.capture_telemetry:
            if args.reset_telemetry:
                post_json(f"{telemetry_base}/api/v1/telemetry/reset", timeout_seconds=args.timeout_seconds)
            payload, status_code, _ = fetch_json(f"{telemetry_base}/api/v1/telemetry", timeout_seconds=args.timeout_seconds)
            if status_code == 200 and payload is not None:
                profile_before = payload

        profile_results: list[dict[str, Any]] = []
        loops = 0
        soak_seconds = max(0.0, float(args.soak_seconds))
        soak_deadline = time.time() + soak_seconds if soak_seconds > 0 else 0.0
        while True:
            loops += 1
            batch = execute_jobs(
                jobs=jobs,
                base_url=args.base_url,
                repeats=args.repeats,
                timeout_seconds=args.timeout_seconds,
                parallel=parallel,
                profile_label=profile_label,
                loop_index=loops,
            )
            profile_results.extend(batch)
            if soak_seconds <= 0:
                break
            if time.time() >= soak_deadline:
                break
            if args.soak_pause_seconds > 0:
                time.sleep(args.soak_pause_seconds)

        if args.capture_telemetry:
            payload, status_code, _ = fetch_json(f"{telemetry_base}/api/v1/telemetry", timeout_seconds=args.timeout_seconds)
            if status_code == 200 and payload is not None:
                profile_after = payload

        profile_runs.append(
            {
                "profile": profile_label,
                "parallel": parallel,
                "loops_completed": loops,
                "result_count": len(profile_results),
                "telemetry_before": profile_before,
                "telemetry_after": profile_after,
            }
        )
        results.extend(profile_results)

    results.sort(
        key=lambda item: (
            str(item.get("profile", "")),
            int(item.get("loop_index", 0)),
            str(item.get("page", "")),
            str(item["params"].get("last_window")),
            item["widget"],
            str(item["params"].get("impact_mode", "")),
            str(item["params"].get("flow_mode", "")),
            str(item["params"].get("distribution_mode", "")),
        )
    )
    print_report(results)
    hotspot_summary = summarize_hotspot_widgets(results, hotspot_widgets)
    if hotspot_summary:
        print("\nHotspot summary")
        print("=" * 110)
        for key, value in sorted(hotspot_summary.items()):
            print(
                f"{key}: errors={value['errors']} 5xx={value['errors_5xx']} "
                f"timeouts={value['timeouts']} warm_p95_max_ms={value['warm_p95_ms_max']:.2f}"
            )

    report = {
        "run_started_utc": start.isoformat(),
        "run_finished_utc": datetime.now(timezone.utc).isoformat(),
        "config": {
            "base_url": args.base_url,
            "pages": pages,
            "protocol": args.protocol,
            "pair": args.pair,
            "windows": windows,
            "repeats": args.repeats,
            "timeout_seconds": args.timeout_seconds,
            "parallel": args.parallel,
            "parallel_profiles": parallel_profiles,
            "parallel_ramp": args.parallel_ramp,
            "soak_seconds": args.soak_seconds,
            "soak_pause_seconds": args.soak_pause_seconds,
            "widget_filter": sorted(widget_filter),
            "quick": args.quick,
            "max_widget_errors": args.max_widget_errors,
            "max_widget_5xx": args.max_widget_5xx,
            "max_widget_timeouts": args.max_widget_timeouts,
            "hotspot_widgets": sorted(hotspot_widgets),
            "expected_refresh_interval_seconds": args.expected_refresh_interval_seconds,
            "refresh_interval_tolerance_seconds": args.refresh_interval_tolerance_seconds,
        },
        "profile_runs": profile_runs,
        "hotspot_summary": hotspot_summary,
        "results": results,
    }
    if args.capture_telemetry:
        report["telemetry"] = {
            "captured": any(isinstance(run.get("telemetry_after"), dict) for run in profile_runs),
            "profiles": profile_runs,
        }

    if args.output_json:
        output_path = Path(args.output_json)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"\nJSON report written: {output_path}")

    failures = [
        row for row in results
        if (not row.get("cold_ok", False)) or int(row.get("warm_error_count", 0)) > 0
    ]
    widget_errors_max = max((int(v.get("errors", 0)) for v in hotspot_summary.values()), default=0)
    widget_5xx_max = max((int(v.get("errors_5xx", 0)) for v in hotspot_summary.values()), default=0)
    widget_timeouts_max = max((int(v.get("timeouts", 0)) for v in hotspot_summary.values()), default=0)
    telemetry_refresh_samples = []
    for run in profile_runs:
        after = run.get("telemetry_after")
        if isinstance(after, dict):
            sample = after.get("refresh_interval_seconds")
            if sample is not None:
                try:
                    telemetry_refresh_samples.append(float(sample))
                except Exception:
                    pass
    gate_failures: list[str] = []
    if args.max_widget_errors >= 0 and widget_errors_max > args.max_widget_errors:
        gate_failures.append(f"widget_errors_max={widget_errors_max} > max_widget_errors={args.max_widget_errors}")
    if args.max_widget_5xx >= 0 and widget_5xx_max > args.max_widget_5xx:
        gate_failures.append(f"widget_5xx_max={widget_5xx_max} > max_widget_5xx={args.max_widget_5xx}")
    if args.max_widget_timeouts >= 0 and widget_timeouts_max > args.max_widget_timeouts:
        gate_failures.append(f"widget_timeouts_max={widget_timeouts_max} > max_widget_timeouts={args.max_widget_timeouts}")
    if args.expected_refresh_interval_seconds >= 0 and telemetry_refresh_samples:
        allowed_delta = max(0.0, float(args.refresh_interval_tolerance_seconds))
        target = float(args.expected_refresh_interval_seconds)
        max_delta = max(abs(sample - target) for sample in telemetry_refresh_samples)
        if max_delta > allowed_delta:
            gate_failures.append(
                f"api_refresh_interval_delta_max={max_delta:.3f}s > tolerance={allowed_delta:.3f}s (target={target:.3f}, samples={telemetry_refresh_samples})"
            )
    if args.fail_on_errors and failures:
        return 1
    if gate_failures:
        print("Widget gate failures: " + "; ".join(gate_failures))
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

