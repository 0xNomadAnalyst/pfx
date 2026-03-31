#!/usr/bin/env python
"""Profile load_delay_seconds for every widget on every page.

Replicates the delay calculation from main.py _build_page_context to produce
a full report of stagger timings without requiring FastAPI or a running server.

Usage:
    python htmx/scripts/profile_stagger_delays.py
"""
from __future__ import annotations

import importlib
import json
import os
import sys
from pathlib import Path

HTMX_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HTMX_ROOT))

from app.pages.common import PageConfig  # noqa: E402
from app.shared_families import resolve_shared_data_family  # noqa: E402

HTMX_HEALTH_TABLE_BASE_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_TABLE_BASE_DELAY_SECONDS", "0.08"))
HTMX_HEALTH_TABLE_STEP_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_TABLE_STEP_DELAY_SECONDS", "0.12"))
HTMX_HEALTH_CHART_BASE_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_CHART_BASE_DELAY_SECONDS", "0.35"))
HTMX_HEALTH_CHART_STEP_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_CHART_STEP_DELAY_SECONDS", "0.18"))
HTMX_KPI_STEP_DELAY_SECONDS = float(os.getenv("HTMX_KPI_STEP_DELAY_SECONDS", "0.05"))
HTMX_CHART_BASE_DELAY_SECONDS = float(os.getenv("HTMX_CHART_BASE_DELAY_SECONDS", "1.0"))
HTMX_CHART_STEP_DELAY_SECONDS = float(os.getenv("HTMX_CHART_STEP_DELAY_SECONDS", "0.15"))
HTMX_FAMILY_MEMBER_STAGGER_SECONDS = float(os.getenv("HTMX_FAMILY_MEMBER_STAGGER_SECONDS", "0.02"))

_PAGE_MODULES = [
    ("PAGE_COVER",            "app.pages.cover",                   "0"),
    ("PAGE_GLOBAL_ECOSYSTEM", "app.pages.global",                   "1"),
    ("PAGE_GLOBAL_SOLSTICE",  "app.pages.global_solstice_version", "0"),
    ("PAGE_DEX_LIQUIDITY",    "app.pages.dex_liquidity",           "0"),
    ("PAGE_DEX_SWAPS",        "app.pages.dex_swaps",               "0"),
    ("PAGE_DEXES",            "app.pages.dexes",                   "1"),
    ("PAGE_KAMINO",           "app.pages.kamino",                  "1"),
    ("PAGE_EXPONENT_YIELD",   "app.pages.exponent",                "1"),
    ("PAGE_RISK_ANALYSIS",    "app.pages.risk_analysis",           "1"),
    ("PAGE_SYSTEM_HEALTH",    "app.pages.health",                  "1"),
]


def _load_pages() -> list[PageConfig]:
    pages: list[PageConfig] = []
    for env_key, mod_path, default in _PAGE_MODULES:
        if os.getenv(env_key, default) == "1":
            try:
                mod = importlib.import_module(mod_path)
                pages.append(mod.PAGE_CONFIG)
            except Exception as exc:
                print(f"  [WARN] could not load {mod_path}: {exc}")
    return pages


def _compute_delays(page: PageConfig) -> list[dict]:
    dual_pool_pages = {"risk-analysis", "dexes", "exponent-yield"}
    widgets = [w for w in page.widgets if w.kind not in {"section-header", "section-subheader", "placeholder"}]

    kpi_index = 0
    non_kpi_index = 0
    last_chart_delay = 0.0
    lane_delay_by_group: dict[str, float] = {}
    health_table_index = 0
    health_chart_index = 0
    health_queue_pair_delay: float | None = None
    bindings: list[dict] = []

    def _is_secondary_lane(widget) -> bool:
        css = str(getattr(widget, "css_class", "") or "").lower()
        wid = str(getattr(widget, "id", "") or "").lower()
        proto = str(getattr(widget, "protocol_override", "") or "").lower()
        return (
            "dx-ray-" in css
            or "mkt2" in css
            or "-right" in css
            or wid.endswith("-mkt2")
            or wid.endswith("-ray")
            or "-ray-" in wid
            or proto in {"ray", "mkt2", "mkt2-sy"}
        )

    def _lane_group_key(widget) -> str:
        css = str(getattr(widget, "css_class", "") or "")
        tokens = [tok for tok in css.split() if tok]
        normalized: list[str] = []
        for tok in tokens:
            key = tok
            key = key.replace("dx-ray-", "dx-orca-")
            key = key.replace("-ray-", "-orca-")
            if key.endswith("-ray"):
                key = f"{key[:-4]}-orca"
            key = key.replace("mkt2", "mkt1")
            key = key.replace("right", "left")
            normalized.append(key)
        normalized.sort()
        return f"{getattr(widget, 'kind', '')}|{' '.join(normalized)}"

    for widget in widgets:
        endpoint_page = widget.source_page_id or page.api_page_id
        endpoint_wid = widget.source_widget_id or widget.id
        shared_data_family = resolve_shared_data_family(endpoint_page, endpoint_wid)

        if widget.kind == "kpi":
            load_delay_seconds = kpi_index * HTMX_KPI_STEP_DELAY_SECONDS
            kpi_index += 1
        else:
            is_right = "chart-right" in (widget.css_class or "") or "-mkt2" in (widget.css_class or "")
            if is_right:
                load_delay_seconds = last_chart_delay
            else:
                load_delay_seconds = HTMX_CHART_BASE_DELAY_SECONDS + non_kpi_index * HTMX_CHART_STEP_DELAY_SECONDS
                non_kpi_index += 1
            last_chart_delay = load_delay_seconds

        if (
            page.slug in dual_pool_pages
            and widget.kind in {"kpi", "chart", "table", "table-split"}
            and not shared_data_family
        ):
            lane_key = _lane_group_key(widget)
            if _is_secondary_lane(widget) and lane_key in lane_delay_by_group:
                load_delay_seconds = lane_delay_by_group[lane_key]
            elif lane_key:
                lane_delay_by_group[lane_key] = load_delay_seconds

        if page.slug == "system-health":
            if widget.kind in {"table", "table-split"}:
                health_delay = (
                    HTMX_HEALTH_TABLE_BASE_DELAY_SECONDS
                    + health_table_index * HTMX_HEALTH_TABLE_STEP_DELAY_SECONDS
                )
                load_delay_seconds = min(load_delay_seconds, health_delay)
                health_table_index += 1
            elif widget.kind == "chart":
                if widget.id == "health-queue-chart-2" and health_queue_pair_delay is not None:
                    load_delay_seconds = min(load_delay_seconds, health_queue_pair_delay)
                else:
                    health_delay = (
                        HTMX_HEALTH_CHART_BASE_DELAY_SECONDS
                        + health_chart_index * HTMX_HEALTH_CHART_STEP_DELAY_SECONDS
                    )
                    load_delay_seconds = min(load_delay_seconds, health_delay)
                    if widget.id == "health-queue-chart":
                        health_queue_pair_delay = load_delay_seconds
                    health_chart_index += 1

        bindings.append({
            "id": widget.id,
            "kind": widget.kind,
            "load_delay_seconds": load_delay_seconds,
            "shared_data_family": shared_data_family,
        })

    family_min_delay: dict[str, float] = {}
    for b in bindings:
        family = str(b.get("shared_data_family") or "").strip()
        if not family:
            continue
        ep_page = page.api_page_id
        family_key = f"{ep_page}::{family}"
        current = float(b["load_delay_seconds"])
        if family_key in family_min_delay:
            family_min_delay[family_key] = min(family_min_delay[family_key], current)
        else:
            family_min_delay[family_key] = current
    family_member_index: dict[str, int] = {}
    for b in bindings:
        family = str(b.get("shared_data_family") or "").strip()
        if not family:
            continue
        ep_page = page.api_page_id
        family_key = f"{ep_page}::{family}"
        if family_key in family_min_delay:
            idx = family_member_index.get(family_key, 0)
            b["load_delay_seconds"] = family_min_delay[family_key] + idx * HTMX_FAMILY_MEMBER_STAGGER_SECONDS
            family_member_index[family_key] = idx + 1

    return bindings


def main():
    pages = _load_pages()
    print(f"Loaded {len(pages)} pages\n")

    all_results: list[dict] = []

    for page in pages:
        bindings = _compute_delays(page)
        if not bindings:
            continue

        delays = [b["load_delay_seconds"] for b in bindings]
        kpi_delays = [b["load_delay_seconds"] for b in bindings if b["kind"] == "kpi"]
        chart_delays = [b["load_delay_seconds"] for b in bindings if b["kind"] == "chart"]
        table_delays = [b["load_delay_seconds"] for b in bindings if b["kind"] in {"table", "table-split"}]

        page_summary = {
            "page": page.slug,
            "widget_count": len(bindings),
            "kpi_count": len(kpi_delays),
            "chart_count": len(chart_delays),
            "table_count": len(table_delays),
            "max_delay_s": round(max(delays), 2),
            "min_delay_s": round(min(delays), 2),
            "mean_delay_s": round(sum(delays) / len(delays), 2),
            "last_chart_fires_at_s": round(max(chart_delays), 2) if chart_delays else 0,
            "last_kpi_fires_at_s": round(max(kpi_delays), 2) if kpi_delays else 0,
        }
        all_results.append(page_summary)

        print(f"-- {page.slug} ({len(bindings)} widgets) --")
        print(f"   KPIs: {len(kpi_delays)}  Charts: {len(chart_delays)}  Tables: {len(table_delays)}")
        print(f"   Delay range: {page_summary['min_delay_s']}s -> {page_summary['max_delay_s']}s   (mean {page_summary['mean_delay_s']}s)")
        if chart_delays:
            print(f"   Last chart request at: {page_summary['last_chart_fires_at_s']}s")
        if kpi_delays:
            print(f"   Last KPI request at:   {page_summary['last_kpi_fires_at_s']}s")

        print(f"   {'Widget ID':<45} {'Kind':<12} {'Delay (s)':>10}  Family")
        for b in sorted(bindings, key=lambda x: x["load_delay_seconds"]):
            fam = b.get("shared_data_family") or ""
            print(f"   {b['id']:<45} {b['kind']:<12} {b['load_delay_seconds']:>10.2f}  {fam}")
        print()

    print("\n==============================================")
    print("SUMMARY: Time until last widget REQUEST fires")
    print("==============================================")
    for r in sorted(all_results, key=lambda x: -x["max_delay_s"]):
        print(f"  {r['page']:<22} {r['max_delay_s']:>6.2f}s  ({r['widget_count']} widgets)")

    print(f"\n  Active formula: KPI step = {HTMX_KPI_STEP_DELAY_SECONDS}s, "
          f"Chart base = {HTMX_CHART_BASE_DELAY_SECONDS}s, Chart step = {HTMX_CHART_STEP_DELAY_SECONDS}s")

    return json.dumps(all_results, indent=2)


if __name__ == "__main__":
    main()
