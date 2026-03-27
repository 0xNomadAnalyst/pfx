#!/usr/bin/env python
import argparse
import asyncio
import json
import time


def _safe_int(value) -> int:
    try:
        return max(0, int(value))
    except Exception:
        return 0


async def wait_until_settled(page, timeout_s: float = 30.0, quiet_ms: int = 500) -> tuple[bool, dict]:
    deadline = time.monotonic() + timeout_s
    quiet_started = None
    last_path = ""
    last_snapshot = {}

    while time.monotonic() < deadline:
        snap = await page.evaluate(
            """() => {
              if (!window.__softNavDebug || typeof window.__softNavDebug.snapshot !== "function") return null;
              return window.__softNavDebug.snapshot();
            }"""
        )
        if snap is None:
            await asyncio.sleep(0.05)
            continue

        last_snapshot = snap
        current_path = snap.get("currentPath", "")
        busy = bool(snap.get("inFlight")) or bool(snap.get("queuedPath"))
        if not busy:
            if current_path != last_path:
                quiet_started = time.monotonic()
                last_path = current_path
            elif quiet_started is None:
                quiet_started = time.monotonic()
            elif (time.monotonic() - quiet_started) * 1000 >= quiet_ms:
                return True, snap
        else:
            quiet_started = None
            last_path = current_path

        await asyncio.sleep(0.05)

    return False, last_snapshot


async def run() -> None:
    parser = argparse.ArgumentParser(description="Stress test sidebar navigation responsiveness.")
    parser.add_argument("--url", default="http://127.0.0.1:8002/global-ecosystem")
    parser.add_argument("--bursts", type=int, default=3)
    parser.add_argument("--clicks-per-burst", type=int, default=30)
    parser.add_argument("--interval-ms", type=int, default=35)
    parser.add_argument("--settle-timeout-s", type=float, default=45.0)
    parser.add_argument("--goto-timeout-ms", type=int, default=90000)
    parser.add_argument("--max-timeouts", type=int, default=-1, help="Fail if total timed_out bursts exceeds this (-1 disables)")
    parser.add_argument("--max-route-errors", type=int, default=-1, help="Fail if any route exceeds this total error count (-1 disables)")
    parser.add_argument("--max-route-5xx", type=int, default=-1, help="Fail if any route exceeds this 5xx count (-1 disables)")
    parser.add_argument("--max-route-timeouts", type=int, default=-1, help="Fail if any route exceeds this timeout count (-1 disables)")
    parser.add_argument(
        "--max-route-abort-ratio",
        type=float,
        default=-1.0,
        help="Fail if any route abort_ratio (aborts/started) exceeds this (-1 disables)",
    )
    parser.add_argument("--max-hydration-orphans", type=int, default=-1, help="Fail if hydration starts do not close cleanly (-1 disables)")
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
    parser.add_argument(
        "--json-out",
        default="",
        help="Optional path to write the stress report JSON",
    )
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
        await page.wait_for_selector("#sidebar-nav .sidebar-nav-link", timeout=15000)

        has_debug = await page.evaluate(
            "() => !!(window.__softNavDebug && typeof window.__softNavDebug.reset === 'function')"
        )
        if not has_debug:
            await browser.close()
            raise SystemExit("window.__softNavDebug is missing. Ensure charts.js is the updated build and reload page.")

        await page.evaluate("() => window.__softNavDebug.reset()")

        link_count = await page.locator("#sidebar-nav .sidebar-nav-link").count()
        if link_count < 2:
            await browser.close()
            raise SystemExit("Need at least 2 sidebar links to run stress test.")

        print(f"Found {link_count} sidebar links.")

        previous = {
            "widgetRequestsStarted": 0,
            "widgetRequestsAborted": 0,
            "widgetRequestErrors": 0,
            "widgetRequestTimeouts": 0,
            "widgetRequest5xx": 0,
        }
        burst_summaries: list[dict] = []
        overall_start = time.monotonic()
        for burst in range(args.bursts):
            print(f"\nBurst {burst + 1}/{args.bursts}: {args.clicks_per_burst} rapid clicks")
            for i in range(args.clicks_per_burst):
                idx = i % link_count
                await page.evaluate(
                    """(index) => {
                      const links = Array.from(document.querySelectorAll("#sidebar-nav .sidebar-nav-link[data-sidebar-path]"));
                      const link = links[index];
                      if (!link) return;
                      link.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
                    }""",
                    idx,
                )
                await asyncio.sleep(args.interval_ms / 1000.0)

            settled, snapshot = await wait_until_settled(page, timeout_s=args.settle_timeout_s)
            started_now = _safe_int(snapshot.get("widgetRequestsStarted"))
            aborted_now = _safe_int(snapshot.get("widgetRequestsAborted"))
            errors_now = _safe_int(snapshot.get("widgetRequestErrors"))
            timeout_now = _safe_int(snapshot.get("widgetRequestTimeouts"))
            e5xx_now = _safe_int(snapshot.get("widgetRequest5xx"))
            burst_summary = {
                "burst_index": burst + 1,
                "target_path": str(snapshot.get("currentPath") or ""),
                "settled": bool(settled),
                "hydration_terminal_reason": str(snapshot.get("lastHydrationTerminalReason") or ""),
                "started_delta": max(0, started_now - previous["widgetRequestsStarted"]),
                "aborts_delta": max(0, aborted_now - previous["widgetRequestsAborted"]),
                "errors_delta": max(0, errors_now - previous["widgetRequestErrors"]),
                "timeouts_delta": max(0, timeout_now - previous["widgetRequestTimeouts"]),
                "errors_5xx_delta": max(0, e5xx_now - previous["widgetRequest5xx"]),
                "persist_restore_hits": _safe_int(snapshot.get("persistRestoreHits")),
                "persist_restore_misses": _safe_int(snapshot.get("persistRestoreMisses")),
                "persist_expired": _safe_int(snapshot.get("persistExpired")),
                "refresh_interval_seconds": float(snapshot.get("refreshIntervalSeconds") or 0.0),
            }
            burst_summaries.append(burst_summary)
            previous = {
                "widgetRequestsStarted": started_now,
                "widgetRequestsAborted": aborted_now,
                "widgetRequestErrors": errors_now,
                "widgetRequestTimeouts": timeout_now,
                "widgetRequest5xx": e5xx_now,
            }
            status = "settled" if settled else "timed_out"
            print(
                f"  -> {status} | current={snapshot.get('currentPath')} | inFlight={snapshot.get('inFlight')} | "
                f"queued={snapshot.get('queuedPath')} | 5xx+err+abort="
                f"{burst_summary['errors_5xx_delta']}/{burst_summary['errors_delta']}/{burst_summary['aborts_delta']}"
            )

        elapsed = time.monotonic() - overall_start
        final_snapshot = await page.evaluate("() => window.__softNavDebug.snapshot()")
        route_error_summary: dict[str, dict[str, int]] = {}
        for burst in burst_summaries:
            path = burst["target_path"] or "unknown"
            if path not in route_error_summary:
                route_error_summary[path] = {"errors_5xx": 0, "errors_total": 0, "timeouts": 0, "aborts": 0, "started": 0}
            route_error_summary[path]["errors_5xx"] += int(burst["errors_5xx_delta"])
            route_error_summary[path]["errors_total"] += int(burst["errors_delta"])
            route_error_summary[path]["timeouts"] += int(burst["timeouts_delta"])
            route_error_summary[path]["aborts"] += int(burst["aborts_delta"])
            route_error_summary[path]["started"] += int(burst["started_delta"])
        report = {
            "elapsed_seconds": round(elapsed, 3),
            "bursts": args.bursts,
            "clicks_per_burst": args.clicks_per_burst,
            "interval_ms": args.interval_ms,
            "burst_summaries": burst_summaries,
            "route_error_summary": route_error_summary,
            "metrics": final_snapshot,
        }
        print("\n=== Soft-nav stress report ===")
        print(json.dumps(report, indent=2))
        if args.json_out:
            with open(args.json_out, "w", encoding="utf-8") as fh:
                json.dump(report, fh, indent=2)

        timeouts_total = sum(1 for item in burst_summaries if not item.get("settled"))
        hydration_starts = _safe_int(final_snapshot.get("hydrationStarts"))
        hydration_finishes = _safe_int(final_snapshot.get("hydrationFinishes"))
        hydration_skips = _safe_int(final_snapshot.get("hydrationSkips"))
        hydration_orphans = max(0, hydration_starts - (hydration_finishes + hydration_skips))
        route_error_max = max((item.get("errors_total", 0) for item in route_error_summary.values()), default=0)
        route_5xx_max = max((item.get("errors_5xx", 0) for item in route_error_summary.values()), default=0)
        route_timeout_max = max((item.get("timeouts", 0) for item in route_error_summary.values()), default=0)
        route_abort_ratio_max = max(
            (
                float(item.get("aborts", 0)) / max(1.0, float(item.get("started", 0)) + float(item.get("aborts", 0)))
                for item in route_error_summary.values()
            ),
            default=0.0,
        )
        restore_hits = _safe_int(final_snapshot.get("persistRestoreHits"))
        restore_misses = _safe_int(final_snapshot.get("persistRestoreMisses"))
        restore_hit_rate = float(restore_hits) / float(max(1, restore_hits + restore_misses))
        persist_expired = _safe_int(final_snapshot.get("persistExpired"))
        refresh_interval_seconds = float(final_snapshot.get("refreshIntervalSeconds") or 0.0)

        violated = []
        if args.max_timeouts >= 0 and timeouts_total > args.max_timeouts:
            violated.append(f"timeouts_total={timeouts_total} > max_timeouts={args.max_timeouts}")
        if args.max_route_errors >= 0 and route_error_max > args.max_route_errors:
            violated.append(f"route_error_max={route_error_max} > max_route_errors={args.max_route_errors}")
        if args.max_route_5xx >= 0 and route_5xx_max > args.max_route_5xx:
            violated.append(f"route_5xx_max={route_5xx_max} > max_route_5xx={args.max_route_5xx}")
        if args.max_route_timeouts >= 0 and route_timeout_max > args.max_route_timeouts:
            violated.append(f"route_timeout_max={route_timeout_max} > max_route_timeouts={args.max_route_timeouts}")
        if args.max_route_abort_ratio >= 0 and route_abort_ratio_max > args.max_route_abort_ratio:
            violated.append(
                f"route_abort_ratio_max={route_abort_ratio_max:.4f} > max_route_abort_ratio={args.max_route_abort_ratio}"
            )
        if args.max_hydration_orphans >= 0 and hydration_orphans > args.max_hydration_orphans:
            violated.append(
                f"hydration_orphans={hydration_orphans} > max_hydration_orphans={args.max_hydration_orphans}"
            )
        if args.min_restore_hit_rate >= 0 and restore_hit_rate < args.min_restore_hit_rate:
            violated.append(f"restore_hit_rate={restore_hit_rate:.4f} < min_restore_hit_rate={args.min_restore_hit_rate}")
        if args.max_persist_expired >= 0 and persist_expired > args.max_persist_expired:
            violated.append(f"persist_expired={persist_expired} > max_persist_expired={args.max_persist_expired}")
        if args.expected_refresh_interval_seconds >= 0:
            allowed_delta = max(0.0, float(args.refresh_interval_tolerance_seconds))
            actual_delta = abs(refresh_interval_seconds - float(args.expected_refresh_interval_seconds))
            if actual_delta > allowed_delta:
                violated.append(
                    f"refresh_interval_seconds={refresh_interval_seconds:.3f} differs from expected={args.expected_refresh_interval_seconds} by {actual_delta:.3f}s (allowed {allowed_delta:.3f}s)"
                )

        if violated:
            await browser.close()
            raise SystemExit("Stress assertions failed: " + "; ".join(violated))

        await browser.close()


if __name__ == "__main__":
    asyncio.run(run())
