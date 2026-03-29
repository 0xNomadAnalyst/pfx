#!/usr/bin/env python
from __future__ import annotations

import importlib
import json
from datetime import datetime, timezone
from pathlib import Path
import sys
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
HTMX_ROOT = REPO_ROOT / "htmx"
if str(HTMX_ROOT) not in sys.path:
    sys.path.insert(0, str(HTMX_ROOT))

from app.pages.common import PageConfig, WidgetConfig  # noqa: E402
from app.shared_families import SHARED_DATA_FAMILY_HINTS  # noqa: E402


OUT_PATH = REPO_ROOT / "htmx" / "config" / "widget_call_mappings.json"
PAGE_MODULES = [
    "app.pages.cover",
    "app.pages.global",
    "app.pages.dex_liquidity",
    "app.pages.dex_swaps",
    "app.pages.dexes",
    "app.pages.kamino",
    "app.pages.exponent",
    "app.pages.risk_analysis",
    "app.pages.health",
]

COMMON_PARAM_DRIVERS = [
    "protocol",
    "pair",
    "last_window",
    "_pipeline",
    "price_basis",
    "mkt1",
    "mkt2",
]

WIDGET_PARAM_DRIVERS: dict[str, list[str]] = {
    "trade-impact-toggle": ["impact_mode"],
    "swaps-flows-toggle": ["flow_mode"],
    "swaps-distribution-toggle": ["distribution_mode"],
    "swaps-ohlcv": ["ohlcv_interval"],
    "health-queue-chart": ["health_schema", "health_attribute"],
    "health-queue-chart-2": ["health_schema", "health_attribute"],
    "health-base-chart-events": ["health_base_schema"],
    "health-base-chart-accounts": ["health_base_schema"],
    "health-base-chart-insert-timing": ["health_base_schema"],
    "ra-pvalue-tables": ["risk_event_type", "risk_interval"],
    "ra-liq-dist-ray": ["risk_event_type", "risk_interval"],
    "ra-liq-dist-orca": ["risk_event_type", "risk_interval"],
    "ra-liq-depth-ray": ["risk_event_type", "risk_interval"],
    "ra-liq-depth-orca": ["risk_event_type", "risk_interval"],
    "ra-prob-ray": ["risk_event_type", "risk_interval"],
    "ra-prob-orca": ["risk_event_type", "risk_interval"],
    "ra-xp-exposure": ["risk_liq_source"],
    "ra-xp-dist-ray": ["risk_liq_source"],
    "ra-xp-dist-orca": ["risk_liq_source"],
    "ra-xp-depth-ray": ["risk_liq_source"],
    "ra-xp-depth-orca": ["risk_liq_source"],
    "ra-stress-test": ["risk_stress_collateral", "risk_stress_debt"],
    "ra-sensitivity-table": ["risk_stress_collateral", "risk_stress_debt"],
    "ra-cascade": [
        "risk_stress_collateral",
        "risk_stress_debt",
        "risk_cascade_pool",
        "risk_cascade_model_mode",
        "risk_cascade_bonus_mode",
    ],
}

DATA_FAMILY_HINTS: dict[tuple[str, str], str] = dict(SHARED_DATA_FAMILY_HINTS)


def _cohort_key(frontend_widget_id: str, protocol_override: str) -> str:
    if protocol_override:
        return f"proto:{protocol_override}"
    if "-mkt1" in frontend_widget_id:
        return "market:mkt1"
    if "-mkt2" in frontend_widget_id:
        return "market:mkt2"
    return "default"


def _widget_mapping(page: PageConfig, widget: WidgetConfig) -> dict[str, Any] | None:
    if widget.kind in {"section-header", "section-subheader", "placeholder"}:
        return None

    source_page_id = widget.source_page_id or page.api_page_id
    source_widget_id = widget.source_widget_id or widget.id
    family = DATA_FAMILY_HINTS.get((source_page_id, source_widget_id), f"endpoint::{source_page_id}/{source_widget_id}")
    specific_params = WIDGET_PARAM_DRIVERS.get(source_widget_id, [])
    endpoint_path = f"/api/v1/{source_page_id}/{source_widget_id}"
    protocol_override = widget.protocol_override or ""

    notes = []
    if protocol_override:
        notes.append("protocol/pair are derived from widget protocol override + current asset filter")
    if source_widget_id.startswith("exponent-") and ("-mkt1" in source_widget_id or "-mkt2" in source_widget_id):
        notes.append("market selector values (mkt1/mkt2) influence params")

    return {
        "frontend_widget_id": widget.id,
        "title": widget.title,
        "kind": widget.kind,
        "source_page_id": source_page_id,
        "source_widget_id": source_widget_id,
        "endpoint": {
            "method": "GET",
            "path": endpoint_path,
        },
        "protocol_override": protocol_override,
        "data_family": family,
        "cohort_key": _cohort_key(widget.id, protocol_override),
        "param_drivers": {
            "common": COMMON_PARAM_DRIVERS,
            "widget_specific": specific_params,
            "notes": notes,
        },
    }


def _build_mapping() -> dict[str, Any]:
    pages: list[PageConfig] = []
    for module_name in PAGE_MODULES:
        mod = importlib.import_module(module_name)
        pages.append(mod.PAGE_CONFIG)

    pages_out: list[dict[str, Any]] = []
    group_rows: list[dict[str, Any]] = []

    for page in pages:
        widgets = []
        for w in page.widgets:
            mapped = _widget_mapping(page, w)
            if mapped is None:
                continue
            widgets.append(mapped)
            group_rows.append(
                {
                    "page_slug": page.slug,
                    "route": f"/{page.slug}",
                    "data_family": mapped["data_family"],
                    "cohort_key": mapped["cohort_key"],
                    "frontend_widget_id": mapped["frontend_widget_id"],
                }
            )

        pages_out.append(
            {
                "slug": page.slug,
                "label": page.label,
                "api_page_id": page.api_page_id,
                "route": f"/{page.slug}",
                "defaults": {
                    "default_protocol": page.default_protocol,
                    "default_pair": page.default_pair,
                    "default_asset": page.default_asset,
                    "show_protocol_pair_filters": bool(page.show_protocol_pair_filters),
                    "show_asset_filter": bool(page.show_asset_filter),
                    "show_market_selectors": bool(page.show_market_selectors),
                },
                "widgets": widgets,
            }
        )

    grouped: dict[tuple[str, str, str], list[str]] = {}
    route_by_page: dict[str, str] = {}
    for row in group_rows:
        key = (row["page_slug"], row["data_family"], row["cohort_key"])
        grouped.setdefault(key, []).append(row["frontend_widget_id"])
        route_by_page[row["page_slug"]] = row["route"]

    shared_groups: list[dict[str, Any]] = []
    for (page_slug, data_family, cohort_key), widget_ids in sorted(grouped.items()):
        deduped = sorted(set(widget_ids))
        if len(deduped) < 2:
            continue
        shared_groups.append(
            {
                "id": f"{page_slug}:{data_family}:{cohort_key}",
                "page_slug": page_slug,
                "route": route_by_page.get(page_slug, f"/{page_slug}"),
                "data_family": data_family,
                "cohort_key": cohort_key,
                "frontend_widget_ids": deduped,
                "sync_expectation": {
                    "max_completion_skew_ms": 1200,
                    "max_missing_widgets": 0,
                },
            }
        )

    return {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "generator": "htmx/scripts/refresh_widget_call_mappings.py",
        "pages": pages_out,
        "shared_data_groups": shared_groups,
    }


def main() -> int:
    payload = _build_mapping()
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"Wrote mapping: {OUT_PATH}")
    print(f"Pages: {len(payload['pages'])} | Shared groups: {len(payload['shared_data_groups'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
