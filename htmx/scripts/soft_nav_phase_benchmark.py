#!/usr/bin/env python
import argparse
import asyncio
import json
import statistics
import time
from typing import Any


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return float(values[0])
    ordered = sorted(float(v) for v in values)
    rank = (len(ordered) - 1) * max(0.0, min(100.0, pct)) / 100.0
    lo = int(rank)
    hi = min(lo + 1, len(ordered) - 1)
    frac = rank - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac


def _safe_float(value: Any) -> float:
    try:
        num = float(value)
    except Exception:
        return 0.0
    if num < 0:
        return 0.0
    return num


def _safe_int(value: Any) -> int:
    try:
        return max(0, int(value))
    except Exception:
        return 0


async def wait_for_target_settle(page, target_path: str, timeout_s: float = 45.0) -> tuple[bool, dict]:
    deadline = time.monotonic() + timeout_s
    last_snapshot: dict = {}
    stable_since = 0.0

    while time.monotonic() < deadline:
        try:
            snap = await page.evaluate(
                """() => {
                  if (!window.__softNavDebug || typeof window.__softNavDebug.snapshot !== "function") return null;
                  return window.__softNavDebug.snapshot();
                }"""
            )
        except Exception:
            # Can happen during same-tab hard navigations or brief context swaps.
            await asyncio.sleep(0.08)
            continue
        if not isinstance(snap, dict):
            await asyncio.sleep(0.05)
            continue
        last_snapshot = snap

        at_target = str(snap.get("currentPath") or "") == str(target_path)
        idle = (not bool(snap.get("inFlight"))) and (not bool(snap.get("queuedPath"))) and int(snap.get("widgetRequestsInFlight") or 0) <= 0

        if at_target and idle:
            if stable_since <= 0:
                stable_since = time.monotonic()
            elif (time.monotonic() - stable_since) >= 0.20:
                return True, snap
        else:
            stable_since = 0.0

        await asyncio.sleep(0.05)

    return False, last_snapshot


async def read_terminal_hydration_reason(page, target_path: str) -> str:
    try:
        reason = await page.evaluate(
            """(path) => {
              if (!window.__softNavDebug || typeof window.__softNavDebug.snapshot !== "function") return "";
              const snap = window.__softNavDebug.snapshot();
              const events = Array.isArray(snap.events) ? snap.events : [];
              for (let idx = events.length - 1; idx >= 0; idx -= 1) {
                const ev = events[idx];
                if (!ev || !ev.details) continue;
                const evPath = String(ev.details.path || "");
                if (evPath !== String(path)) continue;
                if (ev.type === "hydrate_finish" || ev.type === "hydrate_skip") {
                  const reason = String(ev.details.reason || "");
                  if (reason) return reason;
                }
              }
              return String(snap.lastHydrationTerminalReason || "");
            }""",
            target_path,
        )
    except Exception:
        return ""
    return str(reason or "")


async def run() -> None:
    parser = argparse.ArgumentParser(description="Benchmark soft-nav shell/hydration/data-settle phases.")
    parser.add_argument("--url", default="http://127.0.0.1:8002/global-ecosystem")
    parser.add_argument("--cycles", type=int, default=2, help="How many full rounds through targets")
    parser.add_argument("--settle-timeout-s", type=float, default=45.0)
    parser.add_argument("--goto-timeout-ms", type=int, default=90000)
    parser.add_argument("--max-timeouts", type=int, default=-1, help="Fail if total timed-out targets exceeds this (-1 disables)")
    parser.add_argument("--max-route-errors", type=int, default=-1, help="Fail if any route exceeds this total error count (-1 disables)")
    parser.add_argument("--max-route-5xx", type=int, default=-1, help="Fail if any route exceeds this 5xx error count (-1 disables)")
    parser.add_argument("--max-route-timeouts", type=int, default=-1, help="Fail if any route exceeds this timeout count (-1 disables)")
    parser.add_argument(
        "--max-route-abort-ratio",
        type=float,
        default=-1.0,
        help="Fail if any route abort_ratio (aborts/started) exceeds this (-1 disables)",
    )
    parser.add_argument("--max-hydration-orphans", type=int, default=-1, help="Fail if hydration traces remain unclosed (-1 disables)")
    parser.add_argument("--min-restore-hit-rate", type=float, default=-1.0, help="Fail if persisted restore hit-rate falls below this (-1 disables)")
    parser.add_argument("--max-persist-expired", type=int, default=-1, help="Fail if persisted cache expiry count exceeds this (-1 disables)")
    parser.add_argument(
        "--expected-refresh-interval-seconds",
        type=float,
        default=-1.0,
        help="Fail if reported unified refresh interval differs from this target (-1 disables)",
    )
    parser.add_argument(
        "--refresh-interval-tolerance-seconds",
        type=float,
        default=2.0,
        help="Allowed absolute delta for cadence compliance gate",
    )
    parser.add_argument("--headless", action="store_true")
    args = parser.parse_args()

    try:
        from playwright.async_api import async_playwright
    except Exception as exc:
        raise SystemExit(
            "Playwright is required.\n"
            "Install with:\n"
            "  pip install playwright\n"
            "  playwright install chromium\n"
            f"\nImport error: {exc}"
        )

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=args.headless)
        page = await browser.new_page(viewport={"width": 1600, "height": 900})
        page.set_default_navigation_timeout(args.goto_timeout_ms)
        page.set_default_timeout(args.goto_timeout_ms)

        page.on("pageerror", lambda err: print(f"[pageerror] {err}"))
        page.on("console", lambda msg: print(f"[console:{msg.type}] {msg.text}") if msg.type == "error" else None)

        print(f"Opening {args.url}")
        await page.goto(args.url, wait_until="commit")
        await page.wait_for_function(
            "() => !!(window.__softNavDebug && typeof window.__softNavDebug.snapshot === 'function' && typeof window.__softNavDebug.reset === 'function')",
            timeout=20000,
        )

        has_debug = await page.evaluate(
            "() => !!(window.__softNavDebug && typeof window.__softNavDebug.snapshot === 'function' && typeof window.__softNavDebug.reset === 'function')"
        )
        if not has_debug:
            await browser.close()
            raise SystemExit("window.__softNavDebug is missing. Ensure charts.js is updated and page is hard-refreshed.")

        targets = await page.evaluate(
            """() => {
              const normalize = (input) => {
                try {
                  const u = new URL(input, window.location.origin);
                  return `${u.pathname}${u.search || ""}`;
                } catch (_) {
                  return String(input || "");
                }
              };
              const current = normalize(`${window.location.pathname}${window.location.search || ""}`);
              const paths = [];

              document.querySelectorAll("#sidebar-nav .sidebar-nav-link[data-sidebar-path]").forEach((el) => {
                const p = normalize(el.getAttribute("data-sidebar-path") || "");
                if (p && !paths.includes(p)) paths.push(p);
              });
              if (!paths.length) {
                const sel = document.getElementById("page-select");
                if (sel) {
                  Array.from(sel.options).forEach((opt) => {
                    const p = normalize(opt.value || "");
                    if (p && !paths.includes(p)) paths.push(p);
                  });
                }
              }
              return { current, paths };
            }"""
        )
        current_path = str(targets.get("current") or "")
        target_paths = [p for p in targets.get("paths", []) if isinstance(p, str) and p and p != current_path]
        if not target_paths:
            await browser.close()
            raise SystemExit("No alternate navigation targets found (sidebar links or page-select options).")

        print(f"Targets ({len(target_paths)}): {', '.join(target_paths)}")
        await page.evaluate("() => window.__softNavDebug.reset()")

        samples: list[dict[str, Any]] = []
        previous_counters = {
            "widgetRequestsStarted": 0,
            "widgetRequestsAborted": 0,
            "widgetRequestErrors": 0,
            "widgetRequestTimeouts": 0,
            "widgetRequest5xx": 0,
        }
        route_error_summary: dict[str, dict[str, int]] = {}
        terminal_reasons: dict[str, dict[str, int]] = {}
        started_at = time.monotonic()
        for cycle in range(args.cycles):
            print(f"\nCycle {cycle + 1}/{args.cycles}")
            for path in target_paths:
                await page.evaluate(
                    """(targetPath) => {
                      const matchSidebar = document.querySelector(`#sidebar-nav .sidebar-nav-link[data-sidebar-path="${targetPath}"]`);
                      if (matchSidebar) {
                        matchSidebar.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
                        return;
                      }
                      const sel = document.getElementById("page-select");
                      if (sel) {
                        sel.value = targetPath;
                        sel.dispatchEvent(new Event("change", { bubbles: true }));
                      }
                    }""",
                    path,
                )
                settled, snap = await wait_for_target_settle(page, path, timeout_s=args.settle_timeout_s)
                terminal_reason = await read_terminal_hydration_reason(page, path)
                started_now = _safe_int(snap.get("widgetRequestsStarted"))
                aborted_now = _safe_int(snap.get("widgetRequestsAborted"))
                errors_now = _safe_int(snap.get("widgetRequestErrors"))
                timeout_now = _safe_int(snap.get("widgetRequestTimeouts"))
                e5xx_now = _safe_int(snap.get("widgetRequest5xx"))
                widget_started_delta = max(0, started_now - previous_counters["widgetRequestsStarted"])
                widget_aborted_delta = max(0, aborted_now - previous_counters["widgetRequestsAborted"])
                widget_errors_delta = max(0, errors_now - previous_counters["widgetRequestErrors"])
                widget_timeout_delta = max(0, timeout_now - previous_counters["widgetRequestTimeouts"])
                widget_5xx_delta = max(0, e5xx_now - previous_counters["widgetRequest5xx"])
                previous_counters = {
                    "widgetRequestsStarted": started_now,
                    "widgetRequestsAborted": aborted_now,
                    "widgetRequestErrors": errors_now,
                    "widgetRequestTimeouts": timeout_now,
                    "widgetRequest5xx": e5xx_now,
                }
                measured_settle_ms = _safe_float(snap.get("lastWidgetSettleMs"))
                if widget_started_delta > 0 and measured_settle_ms <= 0:
                    measured_settle_ms = max(1.0, _safe_float(snap.get("lastHydrationMs")))
                sample = {
                    "path": path,
                    "settled": bool(settled),
                    "shell_visible_ms": _safe_float(snap.get("lastShellVisibleMs")),
                    "hydration_ms": _safe_float(snap.get("lastHydrationMs")),
                    "widget_settle_ms": measured_settle_ms,
                    "in_flight_ms": _safe_float(snap.get("lastInFlightMs")),
                    "hydration_terminal_reason": terminal_reason,
                    "cache_hits": int(snap.get("cacheHits") or 0),
                    "cache_misses": int(snap.get("cacheMisses") or 0),
                    "widget_requests_started": int(snap.get("widgetRequestsStarted") or 0),
                    "widget_requests_completed": int(snap.get("widgetRequestsCompleted") or 0),
                    "widget_requests_aborted": int(snap.get("widgetRequestsAborted") or 0),
                    "widget_request_errors": int(snap.get("widgetRequestErrors") or 0),
                    "widget_request_5xx": int(snap.get("widgetRequest5xx") or 0),
                    "widget_request_timeouts": int(snap.get("widgetRequestTimeouts") or 0),
                    "widget_requests_started_delta": widget_started_delta,
                    "widget_requests_aborted_delta": widget_aborted_delta,
                    "widget_request_errors_delta": widget_errors_delta,
                    "widget_request_5xx_delta": widget_5xx_delta,
                    "widget_request_timeouts_delta": widget_timeout_delta,
                    "shell_cache_size": int(snap.get("shellCacheSize") or 0),
                    "shell_cache_capacity": int(snap.get("shellCacheCapacity") or 0),
                    "persist_restore_hits": _safe_int(snap.get("persistRestoreHits")),
                    "persist_restore_misses": _safe_int(snap.get("persistRestoreMisses")),
                    "persist_expired": _safe_int(snap.get("persistExpired")),
                    "refresh_interval_seconds": _safe_float(snap.get("refreshIntervalSeconds")),
                }
                samples.append(sample)
                if path not in route_error_summary:
                    route_error_summary[path] = {"errors_5xx": 0, "aborts": 0, "timeouts": 0, "errors_total": 0, "started": 0}
                route_error_summary[path]["errors_5xx"] += widget_5xx_delta
                route_error_summary[path]["aborts"] += widget_aborted_delta
                route_error_summary[path]["timeouts"] += widget_timeout_delta
                route_error_summary[path]["errors_total"] += widget_errors_delta
                route_error_summary[path]["started"] += widget_started_delta
                reason_bucket = terminal_reason or "unknown"
                if path not in terminal_reasons:
                    terminal_reasons[path] = {}
                terminal_reasons[path][reason_bucket] = terminal_reasons[path].get(reason_bucket, 0) + 1
                status = "settled" if settled else "timed_out"
                print(
                    f"  {path} -> {status} | shell={sample['shell_visible_ms']:.1f}ms | "
                    f"hydrate={sample['hydration_ms']:.1f}ms | data={sample['widget_settle_ms']:.1f}ms | "
                    f"reason={reason_bucket}"
                )

        elapsed = round(time.monotonic() - started_at, 3)
        final_snapshot = await page.evaluate("() => window.__softNavDebug.snapshot()")

        shell_vals = [s["shell_visible_ms"] for s in samples if s["settled"]]
        hydrate_vals = [s["hydration_ms"] for s in samples if s["settled"]]
        settle_vals = [s["widget_settle_ms"] for s in samples if s["settled"]]
        inflight_vals = [s["in_flight_ms"] for s in samples if s["settled"]]

        summary = {
            "elapsed_seconds": elapsed,
            "cycles": args.cycles,
            "targets": target_paths,
            "samples": samples,
            "aggregates": {
                "settled_count": sum(1 for s in samples if s["settled"]),
                "timeout_count": sum(1 for s in samples if not s["settled"]),
                "shell_visible_ms_avg": round(statistics.fmean(shell_vals), 2) if shell_vals else 0.0,
                "shell_visible_ms_p95": round(_percentile(shell_vals, 95), 2),
                "hydration_ms_avg": round(statistics.fmean(hydrate_vals), 2) if hydrate_vals else 0.0,
                "hydration_ms_p95": round(_percentile(hydrate_vals, 95), 2),
                "widget_settle_ms_avg": round(statistics.fmean(settle_vals), 2) if settle_vals else 0.0,
                "widget_settle_ms_p95": round(_percentile(settle_vals, 95), 2),
                "in_flight_ms_avg": round(statistics.fmean(inflight_vals), 2) if inflight_vals else 0.0,
                "in_flight_ms_p95": round(_percentile(inflight_vals, 95), 2),
                "persist_restore_hits": _safe_int(final_snapshot.get("persistRestoreHits")),
                "persist_restore_misses": _safe_int(final_snapshot.get("persistRestoreMisses")),
                "persist_expired": _safe_int(final_snapshot.get("persistExpired")),
                "persist_stale_served": _safe_int(final_snapshot.get("persistStaleServed")),
                "persist_stale_refreshed": _safe_int(final_snapshot.get("persistStaleRefreshed")),
                "refresh_interval_seconds": _safe_float(final_snapshot.get("refreshIntervalSeconds")),
            },
            "terminal_hydration_reasons_by_path": terminal_reasons,
            "route_error_summary": route_error_summary,
            "final_debug_snapshot": final_snapshot,
        }

        print("\n=== Soft-nav phase benchmark ===")
        print(json.dumps(summary, indent=2))

        timeout_count = int(summary["aggregates"].get("timeout_count", 0))
        route_error_max = max((item.get("errors_total", 0) for item in route_error_summary.values()), default=0)
        route_5xx_max = max((item.get("errors_5xx", 0) for item in route_error_summary.values()), default=0)
        route_timeout_max = max((item.get("timeouts", 0) for item in route_error_summary.values()), default=0)
        route_abort_ratio_max = max(
            (
                (float(item.get("aborts", 0)) / max(1.0, float(item.get("started", 0)) + float(item.get("aborts", 0))))
                for item in route_error_summary.values()
            ),
            default=0.0,
        )
        hydration_starts = _safe_int(final_snapshot.get("hydrationStarts"))
        hydration_finishes = _safe_int(final_snapshot.get("hydrationFinishes"))
        hydration_skips = _safe_int(final_snapshot.get("hydrationSkips"))
        hydration_orphans = max(0, hydration_starts - (hydration_finishes + hydration_skips))
        restore_hits = _safe_int(final_snapshot.get("persistRestoreHits"))
        restore_misses = _safe_int(final_snapshot.get("persistRestoreMisses"))
        restore_den = max(1, restore_hits + restore_misses)
        restore_hit_rate = float(restore_hits) / float(restore_den)
        persist_expired = _safe_int(final_snapshot.get("persistExpired"))
        refresh_interval_seconds = _safe_float(final_snapshot.get("refreshIntervalSeconds"))
        failures = []
        if args.max_timeouts >= 0 and timeout_count > args.max_timeouts:
            failures.append(f"timeout_count={timeout_count} > max_timeouts={args.max_timeouts}")
        if args.max_route_errors >= 0 and route_error_max > args.max_route_errors:
            failures.append(f"route_error_max={route_error_max} > max_route_errors={args.max_route_errors}")
        if args.max_route_5xx >= 0 and route_5xx_max > args.max_route_5xx:
            failures.append(f"route_5xx_max={route_5xx_max} > max_route_5xx={args.max_route_5xx}")
        if args.max_route_timeouts >= 0 and route_timeout_max > args.max_route_timeouts:
            failures.append(f"route_timeout_max={route_timeout_max} > max_route_timeouts={args.max_route_timeouts}")
        if args.max_route_abort_ratio >= 0 and route_abort_ratio_max > args.max_route_abort_ratio:
            failures.append(
                f"route_abort_ratio_max={route_abort_ratio_max:.4f} > max_route_abort_ratio={args.max_route_abort_ratio}"
            )
        if args.max_hydration_orphans >= 0 and hydration_orphans > args.max_hydration_orphans:
            failures.append(f"hydration_orphans={hydration_orphans} > max_hydration_orphans={args.max_hydration_orphans}")
        if args.min_restore_hit_rate >= 0 and restore_hit_rate < args.min_restore_hit_rate:
            failures.append(f"restore_hit_rate={restore_hit_rate:.4f} < min_restore_hit_rate={args.min_restore_hit_rate}")
        if args.max_persist_expired >= 0 and persist_expired > args.max_persist_expired:
            failures.append(f"persist_expired={persist_expired} > max_persist_expired={args.max_persist_expired}")
        if args.expected_refresh_interval_seconds >= 0:
            allowed_delta = max(0.0, float(args.refresh_interval_tolerance_seconds))
            actual_delta = abs(refresh_interval_seconds - float(args.expected_refresh_interval_seconds))
            if actual_delta > allowed_delta:
                failures.append(
                    f"refresh_interval_seconds={refresh_interval_seconds:.3f} differs from expected={args.expected_refresh_interval_seconds} by {actual_delta:.3f}s (allowed {allowed_delta:.3f}s)"
                )
        if failures:
            await browser.close()
            raise SystemExit("Phase benchmark assertions failed: " + "; ".join(failures))
        await browser.close()


if __name__ == "__main__":
    asyncio.run(run())
