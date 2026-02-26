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

PAGE_DEFAULT_SCENARIOS: dict[str, list[WidgetScenario]] = {
    "playbook-liquidity": LIQUIDITY_SCENARIOS,
    "dex-liquidity": LIQUIDITY_SCENARIOS,
    "dex-swaps": SWAPS_SCENARIOS,
}

PAGE_ALIASES: dict[str, str] = {
    "all": "all",
    "playbook-liquidity": "playbook-liquidity",
    "dex-liquidity": "dex-liquidity",
    "dex-swaps": "dex-swaps",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark dashboard API endpoints")
    parser.add_argument("--base-url", default="http://127.0.0.1:8001", help="API base URL")
    parser.add_argument(
        "--page",
        default="playbook-liquidity",
        help="Page segment(s): single page, comma-separated pages, or 'all'",
    )
    parser.add_argument("--protocol", default="raydium", help="Protocol filter")
    parser.add_argument("--pair", default="USX-USDC", help="Pair filter")
    parser.add_argument(
        "--windows",
        default="1h,24h,7d,30d",
        help="Comma-separated last-window values (e.g. 1h,24h,7d)",
    )
    parser.add_argument("--repeats", type=int, default=5, help="Warm repeats per scenario")
    parser.add_argument("--timeout-seconds", type=float, default=30.0, help="HTTP timeout")
    parser.add_argument("--parallel", type=int, default=1, help="Concurrent scenario workers")
    parser.add_argument("--output-json", default="", help="Optional output path for JSON report")
    parser.add_argument(
        "--widgets",
        default="",
        help="Optional comma-separated widget ids to include (filters default scenario list)",
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


def benchmark_once(url: str, timeout_seconds: float) -> dict[str, Any]:
    started = time.perf_counter()
    payload, status_code, raw = fetch_json(url, timeout_seconds)
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    ok = status_code == 200 and payload is not None and payload.get("status") == "success"
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
            return ["playbook-liquidity", "dex-swaps"]
        alias = PAGE_ALIASES.get(key)
        if alias is None:
            raise ValueError(f"Unsupported page: {item}")
        normalized.append(alias)
    return normalized


def scenario_list_for_page(page: str, widget_filter: set[str]) -> list[WidgetScenario]:
    scenarios = PAGE_DEFAULT_SCENARIOS.get(page, [])
    if not scenarios:
        raise ValueError(f"No scenarios defined for page: {page}")
    if not widget_filter:
        return list(scenarios)
    filtered = [scenario for scenario in scenarios if scenario.widget in widget_filter]
    if filtered:
        return filtered
    return [WidgetScenario(widget=widget_id, extra_params={}) for widget_id in sorted(widget_filter)]


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
    url = build_url(base_url, page, scenario.widget, params)

    cold = benchmark_once(url, timeout_seconds)
    warm_runs = [benchmark_once(url, timeout_seconds) for _ in range(repeats)]
    warm_latencies = sorted(run["elapsed_ms"] for run in warm_runs)
    success_count = sum(1 for run in warm_runs if run["ok"])
    error_samples = [run["error"] for run in warm_runs if not run["ok"]][:2]

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
        "warm_min_ms": round(min_ms, 2),
        "warm_p50_ms": round(p50, 2),
        "warm_p95_ms": round(p95, 2),
        "warm_avg_ms": round(avg, 2),
        "warm_max_ms": round(max_ms, 2),
        "payload_bytes_p50": int(statistics.median(run["payload_bytes"] for run in warm_runs)) if warm_runs else 0,
        "error_samples": error_samples,
    }


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


def main() -> int:
    args = parse_args()
    windows = [item.strip() for item in args.windows.split(",") if item.strip()]
    widget_filter = {item.strip() for item in args.widgets.split(",") if item.strip()}
    pages = parse_pages(args.page)

    start = datetime.now(timezone.utc)
    jobs: list[tuple[str, WidgetScenario, dict[str, Any]]] = []
    for page in pages:
        scenarios = scenario_list_for_page(page, widget_filter)
        for window in windows:
            for scenario in scenarios:
                common_params = {
                    "protocol": args.protocol,
                    "pair": args.pair,
                    "last_window": window,
                }
                jobs.append((page, scenario, common_params))

    results: list[dict[str, Any]] = []
    if args.parallel <= 1:
        for page, scenario, params in jobs:
            results.append(
                run_scenario(
                    base_url=args.base_url,
                    page=page,
                    scenario=scenario,
                    common_params=params,
                    repeats=args.repeats,
                    timeout_seconds=args.timeout_seconds,
                )
            )
    else:
        with ThreadPoolExecutor(max_workers=args.parallel) as pool:
            future_map = {
                pool.submit(
                    run_scenario,
                    args.base_url,
                    page,
                    scenario,
                    params,
                    args.repeats,
                    args.timeout_seconds,
                ): (page, scenario, params)
                for page, scenario, params in jobs
            }
            for future in as_completed(future_map):
                results.append(future.result())

    results.sort(
        key=lambda item: (
            str(item.get("page", "")),
            str(item["params"].get("last_window")),
            item["widget"],
            str(item["params"].get("impact_mode", "")),
            str(item["params"].get("flow_mode", "")),
            str(item["params"].get("distribution_mode", "")),
        )
    )
    print_report(results)

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
            "widget_filter": sorted(widget_filter),
        },
        "results": results,
    }

    if args.output_json:
        output_path = Path(args.output_json)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"\nJSON report written: {output_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

