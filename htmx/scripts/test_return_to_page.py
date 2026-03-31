#!/usr/bin/env python
"""Test perceived performance when returning to previously visited pages.

Measures what the user actually sees: time-to-visually-complete, loading flash
duration, cache restoration, and back-button behavior.  Unlike the other
benchmarks this test focuses on the *return* journey, not the first visit.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import time
from pathlib import Path
from typing import Any


def _safe_float(v: Any) -> float:
    try:
        return max(0.0, float(v))
    except Exception:
        return 0.0


# ---------------------------------------------------------------------------
# Browser helpers
# ---------------------------------------------------------------------------

async def _wait_for_debug(page, timeout_ms: int = 20000) -> bool:
    try:
        await page.wait_for_function(
            "() => !!(window.__softNavDebug && typeof window.__softNavDebug.snapshot === 'function')",
            timeout=timeout_ms,
        )
        return True
    except Exception:
        return False


async def _wait_for_visual_idle(page, timeout_s: float = 45.0) -> tuple[bool, dict]:
    """Wait until no nav is in-flight, no widget requests pending, AND
    no widget timestamp shows 'loading...'."""
    deadline = time.monotonic() + timeout_s
    stable_since = 0.0
    last: dict = {}

    while time.monotonic() < deadline:
        try:
            result = await page.evaluate("""() => {
                const snap = (window.__softNavDebug?.snapshot) ? window.__softNavDebug.snapshot() : {};
                const navBusy = !!(snap.inFlight) || !!(snap.queuedPath);
                const widgetBusy = (parseInt(snap.widgetRequestsInFlight) || 0) > 0;

                const allUpdated = Array.from(document.querySelectorAll('.panel-updated'));
                const loadingEls = allUpdated.filter(el =>
                    el.textContent.trim().toLowerCase().includes('loading')
                );
                const totalWidgets = document.querySelectorAll('.widget-loader').length;
                const loadedWidgets = document.querySelectorAll('.widget-loader[data-has-loaded-once="1"]').length;

                return {
                    navBusy,
                    widgetBusy,
                    loadingCount: loadingEls.length,
                    totalWidgets,
                    loadedWidgets,
                    currentPath: snap.currentPath || '',
                    shellCacheHits: parseInt(snap.cacheHits) || 0,
                    shellCacheMisses: parseInt(snap.cacheMisses) || 0,
                    persistRestoreHits: parseInt(snap.persistRestoreHits) || 0,
                };
            }""")
        except Exception:
            await asyncio.sleep(0.08)
            continue

        last = result
        idle = (
            not result["navBusy"]
            and not result["widgetBusy"]
            and result["loadingCount"] == 0
        )

        if idle:
            if stable_since <= 0:
                stable_since = time.monotonic()
            elif (time.monotonic() - stable_since) >= 0.25:
                return True, last
        else:
            stable_since = 0.0

        await asyncio.sleep(0.06)

    return False, last


async def _snapshot_visual_state(page) -> dict:
    """Capture a snapshot of the visual state: which widgets show loading,
    which show data, and cache counters."""
    return await page.evaluate("""() => {
        const widgets = Array.from(document.querySelectorAll('.widget-loader'));
        const loading = [];
        const loaded = [];
        const stale = [];
        widgets.forEach(el => {
            const wid = el.dataset.widgetId || '';
            const updEl = document.getElementById('updated-' + wid);
            const text = (updEl?.textContent || '').trim().toLowerCase();
            if (text.includes('loading')) {
                loading.push(wid);
            } else {
                loaded.push(wid);
            }
            if (updEl?.classList?.contains('stale-indicator')) {
                stale.push(wid);
            }
        });
        const snap = (window.__softNavDebug?.snapshot) ? window.__softNavDebug.snapshot() : {};
        return {
            totalWidgets: widgets.length,
            loadingWidgets: loading,
            loadedWidgets: loaded,
            staleWidgets: stale,
            loadingCount: loading.length,
            loadedCount: loaded.length,
            currentPath: snap.currentPath || '',
            shellCacheHits: parseInt(snap.cacheHits) || 0,
            shellCacheMisses: parseInt(snap.cacheMisses) || 0,
            persistRestoreHits: parseInt(snap.persistRestoreHits) || 0,
            persistRestoreMisses: parseInt(snap.persistRestoreMisses) || 0,
        };
    }""")


async def _navigate_via_sidebar(page, path: str) -> float:
    """Click a sidebar link and return the monotonic timestamp of the click."""
    t = time.monotonic()
    await page.evaluate("""(targetPath) => {
        const link = document.querySelector(
            '#sidebar-nav .sidebar-nav-link[data-sidebar-path="' + targetPath + '"]'
        );
        if (link) {
            link.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true}));
        }
    }""", path)
    return t


async def _navigate_back(page) -> float:
    t = time.monotonic()
    await page.evaluate("() => window.history.back()")
    return t


async def _sample_loading_flash(page, poll_interval_s: float = 0.03, max_duration_s: float = 15.0) -> dict:
    """Poll rapidly after navigation to detect any loading flash.

    Returns timing of when loading was first/last observed, and the peak
    number of widgets simultaneously showing 'loading...'."""
    start = time.monotonic()
    deadline = start + max_duration_s
    first_loading_t = 0.0
    last_loading_t = 0.0
    peak_loading_count = 0
    samples = 0
    settled = False

    while time.monotonic() < deadline:
        try:
            snap = await page.evaluate("""() => {
                const all = document.querySelectorAll('.panel-updated');
                let lc = 0;
                all.forEach(el => {
                    if (el.textContent.trim().toLowerCase().includes('loading')) lc++;
                });
                const busy = !!(window.__softNavDebug?.snapshot?.()?.inFlight)
                    || (parseInt(window.__softNavDebug?.snapshot?.()?.widgetRequestsInFlight) || 0) > 0;
                return { loadingCount: lc, busy };
            }""")
        except Exception:
            await asyncio.sleep(poll_interval_s)
            continue

        samples += 1
        lc = snap.get("loadingCount", 0)

        if lc > 0:
            now = time.monotonic()
            if first_loading_t <= 0:
                first_loading_t = now
            last_loading_t = now
            peak_loading_count = max(peak_loading_count, lc)

        if not snap.get("busy") and lc == 0 and samples > 2:
            settled = True
            break

        await asyncio.sleep(poll_interval_s)

    elapsed = time.monotonic() - start
    flash_duration = (last_loading_t - first_loading_t) if first_loading_t > 0 else 0.0
    flash_onset = (first_loading_t - start) if first_loading_t > 0 else -1.0

    return {
        "settled": settled,
        "elapsed_s": round(elapsed, 3),
        "samples": samples,
        "flash_detected": first_loading_t > 0,
        "flash_onset_s": round(flash_onset, 3) if flash_onset >= 0 else None,
        "flash_duration_s": round(flash_duration, 3),
        "peak_loading_count": peak_loading_count,
    }


# ---------------------------------------------------------------------------
# Test scenarios
# ---------------------------------------------------------------------------

async def scenario_sidebar_return(
    page, page_a: str, page_b: str, label: str, dwell_s: float = 0.0,
) -> dict:
    """A -> B -> A via sidebar clicks. Optionally dwell on B before returning."""
    click_t = await _navigate_via_sidebar(page, page_b)
    settled_b, _ = await _wait_for_visual_idle(page, timeout_s=30.0)
    if not settled_b:
        return {"label": label, "method": "sidebar", "error": f"page B ({page_b}) did not settle"}

    if dwell_s > 0:
        await asyncio.sleep(dwell_s)

    pre_snap = await _snapshot_visual_state(page)
    return_click_t = await _navigate_via_sidebar(page, page_a)
    flash_result = await _sample_loading_flash(page, poll_interval_s=0.025, max_duration_s=20.0)
    post_snap = await _snapshot_visual_state(page)
    settled_a, idle_result = await _wait_for_visual_idle(page, timeout_s=30.0)
    final_snap = await _snapshot_visual_state(page)
    time_to_visual = time.monotonic() - return_click_t if settled_a else -1.0

    return {
        "label": label,
        "method": "sidebar",
        "page_a": page_a,
        "page_b": page_b,
        "dwell_on_b_s": dwell_s,
        "settled_on_return": settled_a,
        "time_to_visual_complete_s": round(time_to_visual, 3) if time_to_visual > 0 else None,
        "flash": flash_result,
        "loading_on_return_immediate": post_snap["loadingCount"],
        "loaded_on_return_immediate": post_snap["loadedCount"],
        "loading_on_return_final": final_snap["loadingCount"],
        "total_widgets": final_snap["totalWidgets"],
        "shell_cache_hits": final_snap["shellCacheHits"],
        "shell_cache_misses": final_snap["shellCacheMisses"],
        "persist_restore_hits": final_snap["persistRestoreHits"],
    }


async def scenario_back_button(page, page_a: str, page_b: str, label: str) -> dict:
    """A -> B -> back() to A."""
    click_t = await _navigate_via_sidebar(page, page_b)
    settled_b, _ = await _wait_for_visual_idle(page, timeout_s=30.0)
    if not settled_b:
        return {"label": label, "method": "back_button", "error": f"page B ({page_b}) did not settle"}

    pre_snap = await _snapshot_visual_state(page)
    back_t = await _navigate_back(page)
    await asyncio.sleep(0.15)
    flash_result = await _sample_loading_flash(page, poll_interval_s=0.025, max_duration_s=20.0)
    settled_a, _ = await _wait_for_visual_idle(page, timeout_s=30.0)
    final_snap = await _snapshot_visual_state(page)
    time_to_visual = time.monotonic() - back_t if settled_a else -1.0

    actual_path = final_snap.get("currentPath", "")
    path_correct = actual_path == page_a

    return {
        "label": label,
        "method": "back_button",
        "page_a": page_a,
        "page_b": page_b,
        "settled_on_return": settled_a,
        "path_correct": path_correct,
        "actual_path": actual_path,
        "time_to_visual_complete_s": round(time_to_visual, 3) if time_to_visual > 0 else None,
        "flash": flash_result,
        "loading_on_return_final": final_snap["loadingCount"],
        "total_widgets": final_snap["totalWidgets"],
        "shell_cache_hits": final_snap["shellCacheHits"],
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def run() -> int:
    parser = argparse.ArgumentParser(description="Test perceived performance on return-to-page scenarios.")
    parser.add_argument("--url", default="http://127.0.0.1:8002/global-ecosystem")
    parser.add_argument("--settle-timeout-s", type=float, default=45.0)
    parser.add_argument("--goto-timeout-ms", type=int, default=90000)
    parser.add_argument("--dwell-seconds", type=float, default=2.0,
                        help="How long to stay on page B before returning (simulates real usage)")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--json-out", default="")
    args = parser.parse_args()

    try:
        from playwright.async_api import async_playwright
    except Exception as exc:
        raise SystemExit(
            "Playwright is required.\n"
            "  pip install playwright && python -m playwright install chromium\n"
            f"\nImport error: {exc}"
        )

    results: list[dict] = []

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=args.headless)
        page = await browser.new_page(viewport={"width": 1600, "height": 1080})
        page.set_default_navigation_timeout(args.goto_timeout_ms)
        page.set_default_timeout(args.goto_timeout_ms)
        page.on("pageerror", lambda err: print(f"[pageerror] {err}"))

        # -- Open initial page and let it fully load ----------------------
        print(f"Opening {args.url}")
        await page.goto(args.url, wait_until="commit")
        if not await _wait_for_debug(page):
            await browser.close()
            raise SystemExit("__softNavDebug not available.")

        # Discover sidebar targets
        targets = await page.evaluate("""() => {
            const norm = (s) => { try { return new URL(s, location.origin).pathname; } catch(_) { return s; } };
            const cur = norm(location.pathname);
            const paths = [];
            document.querySelectorAll('#sidebar-nav .sidebar-nav-link[data-sidebar-path]').forEach(el => {
                const p = norm(el.getAttribute('data-sidebar-path') || '');
                if (p && !paths.includes(p)) paths.push(p);
            });
            return { current: cur, paths };
        }""")
        start_path = targets["current"]
        all_paths = [p for p in targets["paths"] if p]
        if len(all_paths) < 2:
            await browser.close()
            raise SystemExit("Need at least 2 sidebar targets.")

        print(f"Start: {start_path}")
        print(f"Targets: {', '.join(all_paths)}")

        # Wait for initial page to be visually complete
        print("\nWaiting for initial page to fully load...")
        settled, _ = await _wait_for_visual_idle(page, timeout_s=args.settle_timeout_s)
        if not settled:
            print("[WARN] Initial page did not reach visual idle; continuing anyway.")

        # Pick page pairs for testing
        other_paths = [p for p in all_paths if p != start_path]
        page_a = start_path
        page_b = other_paths[0] if other_paths else all_paths[0]
        page_c = other_paths[1] if len(other_paths) > 1 else other_paths[0]

        # ---- Scenario 1: Immediate return (sidebar) ---------------------
        print(f"\n--- Scenario 1: Immediate return {page_a} -> {page_b} -> {page_a} ---")
        r = await scenario_sidebar_return(page, page_a, page_b, label="immediate_return", dwell_s=0.0)
        results.append(r)
        _print_scenario(r)

        # Reset: navigate back to page_a and wait
        await _navigate_via_sidebar(page, page_a)
        await _wait_for_visual_idle(page, timeout_s=30.0)

        # ---- Scenario 2: Return after dwell (sidebar) -------------------
        print(f"\n--- Scenario 2: Return after {args.dwell_seconds}s dwell {page_a} -> {page_b} -> {page_a} ---")
        r = await scenario_sidebar_return(page, page_a, page_b, label="dwell_return", dwell_s=args.dwell_seconds)
        results.append(r)
        _print_scenario(r)

        # Reset
        await _navigate_via_sidebar(page, page_a)
        await _wait_for_visual_idle(page, timeout_s=30.0)

        # ---- Scenario 3: Back button ------------------------------------
        print(f"\n--- Scenario 3: Back button {page_a} -> {page_b} -> back() ---")
        r = await scenario_back_button(page, page_a, page_b, label="back_button")
        results.append(r)
        _print_scenario(r)

        # Reset
        await _navigate_via_sidebar(page, page_a)
        await _wait_for_visual_idle(page, timeout_s=30.0)

        # ---- Scenario 4: Multi-hop return A -> B -> C -> A --------------
        print(f"\n--- Scenario 4: Multi-hop {page_a} -> {page_b} -> {page_c} -> {page_a} ---")
        await _navigate_via_sidebar(page, page_b)
        await _wait_for_visual_idle(page, timeout_s=30.0)
        r = await scenario_sidebar_return(page, page_a, page_c, label="multi_hop_return", dwell_s=0.5)
        results.append(r)
        _print_scenario(r)

        # Reset
        await _navigate_via_sidebar(page, page_a)
        await _wait_for_visual_idle(page, timeout_s=30.0)

        # ---- Scenario 5: Rapid round-trip A -> B -> A -> B -> A ---------
        print(f"\n--- Scenario 5: Rapid round-trip x3 ---")
        for i in range(3):
            await _navigate_via_sidebar(page, page_b)
            await asyncio.sleep(0.3)
            await _navigate_via_sidebar(page, page_a)
            await asyncio.sleep(0.3)
        flash_result = await _sample_loading_flash(page, poll_interval_s=0.025, max_duration_s=15.0)
        settled, _ = await _wait_for_visual_idle(page, timeout_s=30.0)
        final = await _snapshot_visual_state(page)
        r = {
            "label": "rapid_roundtrip",
            "method": "sidebar_rapid",
            "settled_on_return": settled,
            "flash": flash_result,
            "loading_on_return_final": final["loadingCount"],
            "total_widgets": final["totalWidgets"],
            "shell_cache_hits": final["shellCacheHits"],
        }
        results.append(r)
        _print_scenario(r)

        await browser.close()

    # ---- Summary --------------------------------------------------------
    report = _build_report(results)

    print("\n" + "=" * 60)
    print("RETURN-TO-PAGE PERCEIVED PERFORMANCE SUMMARY")
    print("=" * 60)
    for r in results:
        status = "PASS" if _scenario_passed(r) else "FAIL"
        ttv = r.get("time_to_visual_complete_s")
        ttv_str = f"{ttv:.3f}s" if ttv else "n/a"
        flash = r.get("flash", {})
        flash_str = f"flash={flash.get('flash_duration_s', 0):.3f}s peak={flash.get('peak_loading_count', 0)}" if flash.get("flash_detected") else "no flash"
        method = r.get("method", "?")
        print(f"  [{status}] {r['label']:25s} | {method:15s} | ttv={ttv_str:8s} | {flash_str}")
        if r.get("error"):
            print(f"         error: {r['error']}")
        if not r.get("path_correct", True):
            print(f"         WRONG PATH: expected {r.get('page_a')}, got {r.get('actual_path')}")

    passed = sum(1 for r in results if _scenario_passed(r))
    failed = len(results) - passed
    print(f"\nTotal: {passed} passed, {failed} failed out of {len(results)} scenarios")

    if args.json_out:
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"Report written: {out_path}")

    return 1 if failed > 0 else 0


def _scenario_passed(r: dict) -> bool:
    if r.get("error"):
        return False
    if not r.get("settled_on_return", False):
        return False
    if r.get("path_correct") is False:
        return False
    flash = r.get("flash", {})
    if flash.get("peak_loading_count", 0) > (r.get("total_widgets", 0) * 0.5):
        return False
    return True


def _print_scenario(r: dict) -> None:
    status = "PASS" if _scenario_passed(r) else "FAIL"
    ttv = r.get("time_to_visual_complete_s")
    flash = r.get("flash", {})
    parts = [f"[{status}] {r['label']}"]
    if ttv:
        parts.append(f"time_to_visual={ttv:.3f}s")
    if flash.get("flash_detected"):
        parts.append(f"flash_duration={flash['flash_duration_s']:.3f}s")
        parts.append(f"peak_loading={flash['peak_loading_count']}")
    else:
        parts.append("no_loading_flash")
    parts.append(f"shell_hits={r.get('shell_cache_hits', '?')}")
    parts.append(f"persist_hits={r.get('persist_restore_hits', '?')}")
    if r.get("loading_on_return_final", 0) > 0:
        parts.append(f"STILL_LOADING={r['loading_on_return_final']}")
    if r.get("error"):
        parts.append(f"ERROR={r['error']}")
    if r.get("path_correct") is False:
        parts.append(f"WRONG_PATH={r.get('actual_path')}")
    print("  " + " | ".join(parts))


def _build_report(results: list[dict]) -> dict:
    ttv_values = [r["time_to_visual_complete_s"] for r in results if r.get("time_to_visual_complete_s")]
    flash_durations = [r["flash"]["flash_duration_s"] for r in results if r.get("flash", {}).get("flash_detected")]
    return {
        "scenarios": results,
        "summary": {
            "total": len(results),
            "passed": sum(1 for r in results if _scenario_passed(r)),
            "failed": sum(1 for r in results if not _scenario_passed(r)),
            "time_to_visual_complete": {
                "min_s": round(min(ttv_values), 3) if ttv_values else None,
                "max_s": round(max(ttv_values), 3) if ttv_values else None,
                "mean_s": round(statistics.mean(ttv_values), 3) if ttv_values else None,
                "median_s": round(statistics.median(ttv_values), 3) if ttv_values else None,
            },
            "loading_flash": {
                "scenarios_with_flash": sum(1 for r in results if r.get("flash", {}).get("flash_detected")),
                "max_flash_duration_s": round(max(flash_durations), 3) if flash_durations else 0,
                "max_peak_loading": max(
                    (r.get("flash", {}).get("peak_loading_count", 0) for r in results), default=0
                ),
            },
        },
    }


if __name__ == "__main__":
    raise SystemExit(asyncio.run(run()))
