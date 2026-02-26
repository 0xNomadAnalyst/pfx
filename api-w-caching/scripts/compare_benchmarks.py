#!/usr/bin/env python3
"""
Compare two benchmark JSON reports produced by benchmark_dashboard.py.

Example:
  python scripts/compare_benchmarks.py \
    --baseline reports/bench-before.json \
    --candidate reports/bench-after.json
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class RowKey:
    page: str
    widget: str
    window: str
    impact_mode: str
    flow_mode: str
    distribution_mode: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare dashboard benchmark reports")
    parser.add_argument("--baseline", required=True, help="Path to baseline JSON report")
    parser.add_argument("--candidate", required=True, help="Path to candidate JSON report")
    parser.add_argument(
        "--regression-threshold-pct",
        type=float,
        default=10.0,
        help="Percent increase considered a regression (default: 10)",
    )
    parser.add_argument(
        "--improvement-threshold-pct",
        type=float,
        default=10.0,
        help="Percent decrease considered an improvement (default: 10)",
    )
    parser.add_argument(
        "--sort-by",
        default="p95_delta_pct",
        choices=["p95_delta_pct", "p50_delta_pct", "avg_delta_pct", "cold_delta_pct"],
        help="Sort key for output rows",
    )
    parser.add_argument(
        "--page",
        default="",
        help="Optional page filter (single page or comma-separated pages)",
    )
    parser.add_argument(
        "--fail-on-regression",
        action="store_true",
        help="Exit with code 1 if any regression is detected",
    )
    return parser.parse_args()


def load_report(path: str) -> dict[str, Any]:
    raw = Path(path).read_text(encoding="utf-8")
    data = json.loads(raw)
    if not isinstance(data, dict) or "results" not in data:
        raise ValueError(f"Invalid report format: {path}")
    return data


def as_index(report: dict[str, Any]) -> dict[RowKey, dict[str, Any]]:
    out: dict[RowKey, dict[str, Any]] = {}
    for row in report.get("results", []):
        params = row.get("params", {}) or {}
        key = RowKey(
            page=str(row.get("page", "")),
            widget=str(row.get("widget", "")),
            window=str(params.get("last_window", "")),
            impact_mode=str(params.get("impact_mode", "")),
            flow_mode=str(params.get("flow_mode", "")),
            distribution_mode=str(params.get("distribution_mode", "")),
        )
        out[key] = row
    return out


def pct_delta(new_value: float, old_value: float) -> float:
    if old_value == 0:
        return 0.0 if new_value == 0 else 100.0
    return ((new_value - old_value) / old_value) * 100.0


def classify(delta_pct: float, improve_threshold: float, regress_threshold: float) -> str:
    if delta_pct <= -improve_threshold:
        return "improved"
    if delta_pct >= regress_threshold:
        return "regressed"
    return "neutral"


def compare_rows(
    baseline_row: dict[str, Any],
    candidate_row: dict[str, Any],
    improve_threshold: float,
    regress_threshold: float,
) -> dict[str, Any]:
    metrics = ["cold_ms", "warm_p50_ms", "warm_p95_ms", "warm_avg_ms"]
    out: dict[str, Any] = {}
    for metric in metrics:
        old = float(baseline_row.get(metric, 0.0))
        new = float(candidate_row.get(metric, 0.0))
        delta_abs = new - old
        delta_pct = pct_delta(new, old)
        out[metric] = {
            "baseline": round(old, 2),
            "candidate": round(new, 2),
            "delta_ms": round(delta_abs, 2),
            "delta_pct": round(delta_pct, 2),
            "status": classify(delta_pct, improve_threshold, regress_threshold),
        }

    baseline_errors = int(baseline_row.get("warm_error_count", 0))
    candidate_errors = int(candidate_row.get("warm_error_count", 0))
    out["errors"] = {
        "baseline": baseline_errors,
        "candidate": candidate_errors,
        "delta": candidate_errors - baseline_errors,
        "status": "regressed" if candidate_errors > baseline_errors else "neutral",
    }
    return out


def metric_for_sort(item: dict[str, Any], sort_by: str) -> float:
    key_map = {
        "p95_delta_pct": ("warm_p95_ms", "delta_pct"),
        "p50_delta_pct": ("warm_p50_ms", "delta_pct"),
        "avg_delta_pct": ("warm_avg_ms", "delta_pct"),
        "cold_delta_pct": ("cold_ms", "delta_pct"),
    }
    metric, field = key_map[sort_by]
    return float(item["comparison"][metric][field])


def main() -> int:
    args = parse_args()
    baseline = load_report(args.baseline)
    candidate = load_report(args.candidate)

    page_filter = {item.strip() for item in args.page.split(",") if item.strip()}

    baseline_idx = as_index(baseline)
    candidate_idx = as_index(candidate)

    common_keys = set(baseline_idx).intersection(candidate_idx)
    only_baseline = set(baseline_idx).difference(candidate_idx)
    only_candidate = set(candidate_idx).difference(baseline_idx)

    compared: list[dict[str, Any]] = []
    for key in common_keys:
        if page_filter and key.page not in page_filter:
            continue
        comp = compare_rows(
            baseline_idx[key],
            candidate_idx[key],
            improve_threshold=args.improvement_threshold_pct,
            regress_threshold=args.regression_threshold_pct,
        )
        compared.append(
            {
                "widget": key.widget,
                "page": key.page,
                "window": key.window,
                "impact_mode": key.impact_mode,
                "flow_mode": key.flow_mode,
                "distribution_mode": key.distribution_mode,
                "comparison": comp,
            }
        )

    compared.sort(key=lambda item: metric_for_sort(item, args.sort_by), reverse=True)

    print("\nBenchmark comparison")
    print("=" * 144)
    header = (
        f"{'Page':16} {'Widget':30} {'Window':>6} {'Mode':>8} {'Flow':>10} {'Dist':>12} "
        f"{'P95 d%':>9} {'P50 d%':>9} {'Avg d%':>9} {'Cold d%':>9} {'Err d':>6} {'Status':>10}"
    )
    print(header)
    print("-" * len(header))

    regressions = 0
    improvements = 0
    for item in compared:
        p95 = item["comparison"]["warm_p95_ms"]["delta_pct"]
        p50 = item["comparison"]["warm_p50_ms"]["delta_pct"]
        avg = item["comparison"]["warm_avg_ms"]["delta_pct"]
        cold = item["comparison"]["cold_ms"]["delta_pct"]
        err_delta = item["comparison"]["errors"]["delta"]

        statuses = {
            item["comparison"]["warm_p95_ms"]["status"],
            item["comparison"]["warm_p50_ms"]["status"],
            item["comparison"]["warm_avg_ms"]["status"],
            item["comparison"]["cold_ms"]["status"],
        }
        if err_delta > 0:
            statuses.add("regressed")

        if "regressed" in statuses:
            overall = "regressed"
            regressions += 1
        elif "improved" in statuses:
            overall = "improved"
            improvements += 1
        else:
            overall = "neutral"

        mode = item["impact_mode"] or "-"
        flow_mode = item["flow_mode"] or "-"
        dist_mode = item["distribution_mode"] or "-"
        widget_name = item["widget"]
        print(
            f"{item['page'][:16]:16} {widget_name[:30]:30} {item['window']:>6} {mode[:8]:>8} {flow_mode[:10]:>10} {dist_mode[:12]:>12} "
            f"{p95:9.2f} {p50:9.2f} {avg:9.2f} {cold:9.2f} {err_delta:6d} {overall:>10}"
        )

    print("=" * 144)
    print(
        f"Compared rows: {len(compared)} | Regressed: {regressions} | "
        f"Improved: {improvements} | Neutral: {len(compared) - regressions - improvements}"
    )
    if only_baseline:
        print(f"Missing in candidate: {len(only_baseline)} rows")
    if only_candidate:
        print(f"New in candidate: {len(only_candidate)} rows")

    if args.fail_on_regression and regressions > 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

