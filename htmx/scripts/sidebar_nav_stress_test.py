#!/usr/bin/env python
import argparse
import asyncio
import json
import time


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
            status = "settled" if settled else "timed_out"
            print(f"  -> {status} | current={snapshot.get('currentPath')} | inFlight={snapshot.get('inFlight')} | queued={snapshot.get('queuedPath')}")

        elapsed = time.monotonic() - overall_start
        final_snapshot = await page.evaluate("() => window.__softNavDebug.snapshot()")
        report = {
            "elapsed_seconds": round(elapsed, 3),
            "bursts": args.bursts,
            "clicks_per_burst": args.clicks_per_burst,
            "interval_ms": args.interval_ms,
            "metrics": final_snapshot,
        }
        print("\n=== Soft-nav stress report ===")
        print(json.dumps(report, indent=2))

        await browser.close()


if __name__ == "__main__":
    asyncio.run(run())
