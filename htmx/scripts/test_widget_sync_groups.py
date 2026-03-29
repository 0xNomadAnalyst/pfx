#!/usr/bin/env python
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
from typing import Any


DEFAULT_MAPPING = Path("htmx/config/widget_call_mappings.json")


def _parse_page_filter(raw: str) -> set[str]:
    items = {item.strip() for item in (raw or "").split(",") if item.strip()}
    return items


async def _install_probe(page) -> None:
    await page.evaluate(
        """() => {
          if (window.__widgetSyncProbeInstalled) return;
          window.__widgetSyncProbeInstalled = true;
          window.__widgetSyncProbe = { cycleId: "", events: [] };
          const pushEvent = (type, widgetId, extra = {}) => {
            window.__widgetSyncProbe.events.push({
              t: performance.now(),
              cycleId: window.__widgetSyncProbe.cycleId || "",
              type,
              widgetId: String(widgetId || ""),
              ...extra,
            });
            if (window.__widgetSyncProbe.events.length > 4000) {
              window.__widgetSyncProbe.events.splice(0, window.__widgetSyncProbe.events.length - 4000);
            }
          };
          document.body.addEventListener("htmx:beforeSend", (event) => {
            const el = event?.detail?.elt;
            if (!el || !el.classList || !el.classList.contains("widget-loader")) return;
            pushEvent("started", el.dataset.widgetId || "");
          });
          document.body.addEventListener("htmx:afterRequest", (event) => {
            const el = event?.detail?.elt;
            if (!el || !el.classList || !el.classList.contains("widget-loader")) return;
            const ok = !!event?.detail?.successful;
            pushEvent(ok ? "completed" : "after_request_failed", el.dataset.widgetId || "");
          });
          document.body.addEventListener("htmx:responseError", (event) => {
            const el = event?.detail?.elt;
            if (!el || !el.classList || !el.classList.contains("widget-loader")) return;
            pushEvent("response_error", el.dataset.widgetId || "");
          });
          document.body.addEventListener("htmx:sendError", (event) => {
            const el = event?.detail?.elt;
            if (!el || !el.classList || !el.classList.contains("widget-loader")) return;
            pushEvent("send_error", el.dataset.widgetId || "");
          });
          document.body.addEventListener("htmx:timeout", (event) => {
            const el = event?.detail?.elt;
            if (!el || !el.classList || !el.classList.contains("widget-loader")) return;
            pushEvent("timeout", el.dataset.widgetId || "");
          });
          document.body.addEventListener("htmx:abort", (event) => {
            const el = event?.detail?.elt || event?.target;
            if (!el || !el.classList || !el.classList.contains("widget-loader")) return;
            pushEvent("abort", el.dataset.widgetId || "");
          });
        }"""
    )


async def _wait_for_dashboard_idle(page, timeout_ms: int = 45000) -> bool:
    deadline = asyncio.get_running_loop().time() + (timeout_ms / 1000.0)
    while asyncio.get_running_loop().time() < deadline:
        try:
            snap = await page.evaluate(
                """() => {
                  if (!window.__softNavDebug || typeof window.__softNavDebug.snapshot !== "function") return null;
                  return window.__softNavDebug.snapshot();
                }"""
            )
        except Exception:
            snap = None
        if isinstance(snap, dict):
            in_flight = bool(snap.get("inFlight")) or bool(snap.get("queuedPath"))
            widget_in_flight = int(snap.get("widgetRequestsInFlight") or 0)
            if (not in_flight) and widget_in_flight <= 0:
                return True
        await asyncio.sleep(0.1)
    return False


async def _run_group_cycle(page, widget_ids: list[str], cycle_id: str, timeout_ms: int) -> dict[str, Any]:
    return await page.evaluate(
        """async ({ widgetIds, cycleId, timeoutMs }) => {
          const existing = widgetIds.filter((wid) => !!document.getElementById(`widget-${wid}`));
          const visibleBefore = {};
          const isVisible = (el) => {
            if (!el) return false;
            const rect = el.getBoundingClientRect();
            const inVertical = rect.bottom > 0 && rect.top < window.innerHeight;
            const inHorizontal = rect.right > 0 && rect.left < window.innerWidth;
            return inVertical && inHorizontal;
          };
          for (const wid of existing) {
            const el = document.getElementById(`widget-${wid}`);
            let nowVisible = false;
            for (let i = 0; i < 4; i += 1) {
              try { el?.scrollIntoView({ block: "center", inline: "nearest" }); } catch (_) {}
              await new Promise((resolve) => setTimeout(resolve, 40));
              nowVisible = isVisible(el);
              if (nowVisible) break;
            }
            visibleBefore[wid] = nowVisible;
          }
          if (!window.__widgetSyncProbe) {
            window.__widgetSyncProbe = { cycleId: "", events: [] };
          }
          window.__widgetSyncProbe.cycleId = String(cycleId);
          const startedAt = performance.now();

          const refreshBtn = document.getElementById("refresh-dashboard");
          if (refreshBtn) {
            refreshBtn.click();
          } else {
            document.body.dispatchEvent(new Event("dashboard-refresh", { bubbles: true }));
          }

          const isTerminalType = (eventType) => (
            eventType === "completed"
            || eventType === "after_request_failed"
            || eventType === "response_error"
            || eventType === "send_error"
            || eventType === "timeout"
            || eventType === "abort"
          );

          const summarize = () => {
            const events = Array.isArray(window.__widgetSyncProbe?.events) ? window.__widgetSyncProbe.events : [];
            const cycleEvents = events.filter((ev) => (
              String(ev?.cycleId || "") === String(cycleId)
              && Number(ev?.t || 0) >= startedAt
            ));
            const status = {};
            existing.forEach((wid) => {
              const perWidget = cycleEvents.filter((ev) => String(ev?.widgetId || "") === wid);
              const startedEv = perWidget.length ? perWidget.slice().reverse().find((ev) => ev.type === "started") : null;
              const completedEv = perWidget.length ? perWidget.slice().reverse().find((ev) => ev.type === "completed") : null;
              const terminalEv = perWidget.length ? perWidget.slice().reverse().find((ev) => isTerminalType(ev.type)) : null;
              const updatedText = String(document.getElementById(`updated-${wid}`)?.textContent || "");
              status[wid] = {
                started_at_ms: startedEv ? Number(startedEv.t || 0) : null,
                completed_at_ms: completedEv ? Number(completedEv.t || 0) : null,
                terminal_type: terminalEv ? String(terminalEv.type || "") : "",
                updated_text: updatedText,
                loading_visible: updatedText.toLowerCase().includes("loading..."),
              };
            });
            return status;
          };

          const done = (status) => {
            return existing.every((wid) => {
              const s = status[wid] || {};
              return !!s.terminal_type;
            });
          };

          while (performance.now() - startedAt < timeoutMs) {
            const status = summarize();
            if (done(status)) {
              return {
                cycle_id: cycleId,
                elapsed_ms: performance.now() - startedAt,
                widget_status: status,
                existing_widget_ids: existing,
              visible_before_refresh: visibleBefore,
                timed_out: false,
              };
            }
            await new Promise((resolve) => setTimeout(resolve, 60));
          }

          return {
            cycle_id: cycleId,
            elapsed_ms: performance.now() - startedAt,
            widget_status: summarize(),
            existing_widget_ids: existing,
            visible_before_refresh: visibleBefore,
            timed_out: true,
          };
        }""",
        {"widgetIds": widget_ids, "cycleId": cycle_id, "timeoutMs": timeout_ms},
    )


def _skew_ms(widget_status: dict[str, Any]) -> float:
    completed = [
        float(entry["completed_at_ms"])
        for entry in widget_status.values()
        if entry.get("completed_at_ms") is not None
    ]
    if len(completed) < 2:
        return 0.0
    return max(completed) - min(completed)


async def run() -> int:
    parser = argparse.ArgumentParser(description="Validate shared-widget sync behavior from mapping config.")
    parser.add_argument("--base-url", default="http://127.0.0.1:8002")
    parser.add_argument("--mapping-file", default=str(DEFAULT_MAPPING))
    parser.add_argument("--pages", default="", help="Comma-separated page slugs to test (default: all in mapping)")
    parser.add_argument("--group-contains", default="", help="Filter groups containing this substring in id")
    parser.add_argument("--timeout-ms", type=int, default=20000)
    parser.add_argument("--max-completion-skew-ms", type=float, default=1200.0)
    parser.add_argument("--allow-render-errors", action="store_true")
    parser.add_argument("--allow-missing", action="store_true")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--json-out", default="")
    args = parser.parse_args()

    mapping_path = Path(args.mapping_file)
    if not mapping_path.exists():
        raise SystemExit(f"Mapping file not found: {mapping_path}")
    mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
    groups = list(mapping.get("shared_data_groups", []))

    selected_pages = _parse_page_filter(args.pages)
    if selected_pages:
        groups = [g for g in groups if str(g.get("page_slug")) in selected_pages]
    if args.group_contains.strip():
        needle = args.group_contains.strip().lower()
        groups = [g for g in groups if needle in str(g.get("id", "")).lower()]

    if not groups:
        raise SystemExit("No groups selected from mapping.")

    by_page: dict[str, list[dict[str, Any]]] = {}
    for g in groups:
        by_page.setdefault(str(g["page_slug"]), []).append(g)

    try:
        from playwright.async_api import async_playwright
    except Exception as exc:
        raise SystemExit(
            "Playwright is required.\n"
            "Install with:\n"
            "  pip install playwright\n"
            "  python -m playwright install chromium\n"
            f"\nImport error: {exc}"
        )

    report: dict[str, Any] = {
        "mapping_file": str(mapping_path),
        "base_url": args.base_url,
        "max_completion_skew_ms": args.max_completion_skew_ms,
        "results": [],
        "skipped_pages": [],
    }

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=args.headless)
        page = await browser.new_page(viewport={"width": 1920, "height": 2600})
        page.set_default_timeout(max(30000, args.timeout_ms + 5000))

        for page_slug, page_groups in sorted(by_page.items()):
            route = str(page_groups[0].get("route") or f"/{page_slug}")
            url = f"{args.base_url.rstrip('/')}{route}"
            print(f"\nOpening {url}")
            try:
                response = await page.goto(url, wait_until="domcontentloaded")
            except Exception as exc:
                reason = f"navigation timeout/error: {exc}"
                report["skipped_pages"].append({"page_slug": page_slug, "route": route, "reason": reason})
                print(f"[SKIP] {page_slug} ({reason})")
                continue
            status = int(response.status) if response is not None else 0
            if status >= 400:
                reason = f"route returned HTTP {status}"
                report["skipped_pages"].append({"page_slug": page_slug, "route": route, "reason": reason})
                print(f"[SKIP] {page_slug} ({reason})")
                continue
            try:
                await page.wait_for_selector(".widget-loader", timeout=10000)
            except Exception:
                reason = "no widget loaders found on page"
                report["skipped_pages"].append({"page_slug": page_slug, "route": route, "reason": reason})
                print(f"[SKIP] {page_slug} ({reason})")
                continue
            await _install_probe(page)
            await _wait_for_dashboard_idle(page, timeout_ms=max(args.timeout_ms, 45000))

            for idx, group in enumerate(page_groups, start=1):
                widget_ids = [str(wid) for wid in group.get("frontend_widget_ids", [])]
                cycle_id = f"{page_slug}:{idx}:{int(asyncio.get_running_loop().time() * 1000)}"
                result = await _run_group_cycle(page, widget_ids, cycle_id, args.timeout_ms)
                statuses = result.get("widget_status", {})
                skew = _skew_ms(statuses)
                completed = [wid for wid, st in statuses.items() if st.get("completed_at_ms") is not None]
                started = [wid for wid, st in statuses.items() if st.get("started_at_ms") is not None]
                render_errors = [
                    wid
                    for wid, st in statuses.items()
                    if st.get("terminal_type") in {"after_request_failed", "response_error", "send_error", "timeout"}
                ]
                render_stuck = [
                    wid
                    for wid, st in statuses.items()
                    if st.get("completed_at_ms") is not None and st.get("loading_visible")
                ]
                missing = sorted(set(result.get("existing_widget_ids", [])) - set(started))
                passed = True
                reasons: list[str] = []
                if result.get("timed_out"):
                    passed = False
                    reasons.append("group timed out before all widgets reached terminal state")
                if skew > float(args.max_completion_skew_ms):
                    passed = False
                    reasons.append(f"completion skew {skew:.1f}ms exceeded {args.max_completion_skew_ms:.1f}ms")
                if render_stuck:
                    passed = False
                    reasons.append(f"widgets still show loading after completion: {', '.join(render_stuck)}")
                if (not args.allow_render_errors) and render_errors:
                    passed = False
                    reasons.append(f"widgets failed request/render cycle: {', '.join(render_errors)}")
                if (not args.allow_missing) and missing:
                    passed = False
                    reasons.append(f"widgets did not start request in cycle: {', '.join(missing)}")

                terminal_types = {str(st.get("terminal_type") or "") for st in statuses.values()}
                backend_error_types = {"response_error", "send_error", "timeout", "after_request_failed"}
                failure_tags: list[str] = []
                has_backend_error_signal = bool(render_errors) or bool(terminal_types & backend_error_types)
                has_frontend_split_signal = (
                    bool(render_stuck)
                    or skew > float(args.max_completion_skew_ms)
                    or (bool(missing) and bool(completed))
                )
                if result.get("timed_out") and not started:
                    has_backend_error_signal = True
                if has_backend_error_signal:
                    failure_tags.append("backend_unavailable_or_timeout")
                if has_frontend_split_signal:
                    failure_tags.append("frontend_sync_split")
                if (not has_backend_error_signal) and (not has_frontend_split_signal) and (not passed):
                    failure_tags.append("unclassified")

                group_out = {
                    "id": group.get("id"),
                    "page_slug": page_slug,
                    "route": route,
                    "data_family": group.get("data_family"),
                    "cohort_key": group.get("cohort_key"),
                    "skew_ms": round(skew, 2),
                    "timed_out": bool(result.get("timed_out")),
                    "completed_widgets": completed,
                    "started_widgets": started,
                    "missing_widgets": missing,
                    "render_error_widgets": render_errors,
                    "render_stuck_widgets": render_stuck,
                    "failure_tags": failure_tags,
                    "visible_before_refresh": result.get("visible_before_refresh", {}),
                    "widget_status": statuses,
                    "passed": passed,
                    "reasons": reasons,
                }
                report["results"].append(group_out)
                status = "PASS" if passed else "FAIL"
                tag_text = f" | tags={','.join(failure_tags)}" if failure_tags else ""
                print(f"[{status}] {group_out['id']} | skew={group_out['skew_ms']}ms | missing={len(missing)}{tag_text}")
                if reasons:
                    print("  - " + "; ".join(reasons))

        await browser.close()

    report["summary"] = {
        "group_count": len(report["results"]),
        "passed_count": sum(1 for row in report["results"] if row.get("passed")),
        "failed_count": sum(1 for row in report["results"] if not row.get("passed")),
        "skipped_page_count": len(report["skipped_pages"]),
    }

    print("\n=== Widget Sync Group Test Summary ===")
    print(json.dumps(report["summary"], indent=2))
    if args.json_out:
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"Report written: {out_path}")

    failures = [row for row in report["results"] if not row.get("passed")]
    if failures:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(run()))
