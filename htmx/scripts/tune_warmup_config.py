#!/usr/bin/env python
import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_CANDIDATES = [
    {
        "name": "baseline",
        "env": {
            "HTMX_WARMUP_BUDGET_SECONDS": "30",
            "HTMX_WARMUP_MAX_JOBS": "30",
            "HTMX_WARMUP_CONCURRENCY": "3",
            "HTMX_WARMUP_WIDGETS_PER_PAGE": "10",
        },
    },
    {
        "name": "deeper-pass2-medium",
        "env": {
            "HTMX_WARMUP_BUDGET_SECONDS": "36",
            "HTMX_WARMUP_MAX_JOBS": "38",
            "HTMX_WARMUP_CONCURRENCY": "3",
            "HTMX_WARMUP_WIDGETS_PER_PAGE": "12",
        },
    },
    {
        "name": "deeper-pass2-high",
        "env": {
            "HTMX_WARMUP_BUDGET_SECONDS": "45",
            "HTMX_WARMUP_MAX_JOBS": "48",
            "HTMX_WARMUP_CONCURRENCY": "4",
            "HTMX_WARMUP_WIDGETS_PER_PAGE": "14",
        },
    },
]


def _safe_float(value: Any) -> float:
    try:
        return float(value)
    except Exception:
        return 0.0


def _safe_int(value: Any) -> int:
    try:
        return int(value)
    except Exception:
        return 0


def wait_for_http_ready(url: str, timeout_s: float = 45.0) -> None:
    deadline = time.time() + timeout_s
    last_err = ""
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as resp:
                if int(getattr(resp, "status", 200)) < 500:
                    return
        except Exception as exc:
            last_err = str(exc)
        time.sleep(0.5)
    raise RuntimeError(f"Timed out waiting for server at {url}. Last error: {last_err}")


def terminate_process(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        if os.name == "nt":
            proc.send_signal(signal.CTRL_BREAK_EVENT)  # type: ignore[attr-defined]
        else:
            proc.terminate()
    except Exception:
        pass
    try:
        proc.wait(timeout=5)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def run_candidate(
    htmx_dir: Path,
    candidate: dict[str, Any],
    api_base_url: str,
    port: int,
    phase_cycles: int,
    stress_bursts: int,
    stress_clicks: int,
    stress_interval_ms: int,
) -> dict[str, Any]:
    env = os.environ.copy()
    env["PORT"] = str(port)
    env["API_BASE_URL"] = api_base_url
    for key, value in (candidate.get("env") or {}).items():
        env[str(key)] = str(value)

    server_cmd = [
        sys.executable,
        "-m",
        "uvicorn",
        "app.main:app",
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
    ]
    create_flags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    server_proc = subprocess.Popen(
        server_cmd,
        cwd=str(htmx_dir),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=create_flags,
    )
    base_url = f"http://127.0.0.1:{port}/global-ecosystem"

    with tempfile.TemporaryDirectory(prefix="riskdash_tune_") as tmp:
        phase_json = Path(tmp) / "phase.json"
        stress_json = Path(tmp) / "stress.json"
        try:
            wait_for_http_ready(base_url)
            subprocess.run(
                [
                    sys.executable,
                    "scripts/soft_nav_phase_benchmark.py",
                    "--url",
                    base_url,
                    "--cycles",
                    str(phase_cycles),
                    "--headless",
                    "--json-out",
                    str(phase_json),
                ],
                cwd=str(htmx_dir),
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                [
                    sys.executable,
                    "scripts/sidebar_nav_stress_test.py",
                    "--url",
                    base_url,
                    "--bursts",
                    str(stress_bursts),
                    "--clicks-per-burst",
                    str(stress_clicks),
                    "--interval-ms",
                    str(stress_interval_ms),
                    "--headless",
                    "--json-out",
                    str(stress_json),
                ],
                cwd=str(htmx_dir),
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )
            phase = json.loads(phase_json.read_text(encoding="utf-8"))
            stress = json.loads(stress_json.read_text(encoding="utf-8"))
            return {"ok": True, "phase": phase, "stress": stress}
        except subprocess.CalledProcessError as exc:
            stderr_tail = (exc.stderr or "").splitlines()[-12:]
            stdout_tail = (exc.stdout or "").splitlines()[-12:]
            details = " | ".join(
                segment for segment in [*stdout_tail, *stderr_tail] if isinstance(segment, str) and segment.strip()
            )
            return {
                "ok": False,
                "error": f"subprocess_failed:{exc.returncode}",
                "details": details[:1000],
            }
        except Exception as exc:
            return {"ok": False, "error": str(exc)}
        finally:
            terminate_process(server_proc)


def score_result(result: dict[str, Any]) -> dict[str, Any]:
    if not result.get("ok"):
        return {"score": 1_000_000_000.0, "passed": False, "reason": result.get("error", "failed")}

    phase = result["phase"]
    stress = result["stress"]
    agg = phase.get("aggregates", {})
    route_errors = stress.get("route_error_summary", {})
    route_error_max = max((_safe_int(v.get("errors_total")) for v in route_errors.values()), default=0)
    route_timeout_max = max((_safe_int(v.get("timeouts")) for v in route_errors.values()), default=0)
    route_abort_ratio_max = 0.0
    for item in route_errors.values():
        started = _safe_float(item.get("started"))
        aborts = _safe_float(item.get("aborts"))
        ratio = aborts / max(1.0, started + aborts)
        route_abort_ratio_max = max(route_abort_ratio_max, ratio)

    timeout_count = _safe_int(agg.get("timeout_count"))
    widget_p95 = _safe_float(agg.get("widget_settle_ms_p95"))
    hydration_p95 = _safe_float(agg.get("hydration_ms_p95"))
    shell_p95 = _safe_float(agg.get("shell_visible_ms_p95"))
    restore_miss = _safe_int(agg.get("persist_restore_misses"))

    passed = timeout_count == 0 and route_error_max == 0 and route_timeout_max == 0
    # Weighted objective: favor fast data settle while controlling abort churn.
    score = (
        widget_p95
        + (0.6 * hydration_p95)
        + (0.2 * shell_p95)
        + (100.0 * route_abort_ratio_max)
        + (0.015 * restore_miss)
        + (400.0 * timeout_count)
        + (300.0 * route_error_max)
        + (300.0 * route_timeout_max)
    )
    return {
        "score": round(score, 3),
        "passed": passed,
        "metrics": {
            "widget_settle_ms_p95": widget_p95,
            "hydration_ms_p95": hydration_p95,
            "shell_visible_ms_p95": shell_p95,
            "timeout_count": timeout_count,
            "route_error_max": route_error_max,
            "route_timeout_max": route_timeout_max,
            "route_abort_ratio_max": round(route_abort_ratio_max, 4),
            "persist_restore_misses": restore_miss,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Test-driven warmup tuning harness.")
    parser.add_argument("--api-base-url", default="http://127.0.0.1:8001")
    parser.add_argument("--start-port", type=int, default=8012)
    parser.add_argument("--phase-cycles", type=int, default=1)
    parser.add_argument("--stress-bursts", type=int, default=2)
    parser.add_argument("--stress-clicks-per-burst", type=int, default=24)
    parser.add_argument("--stress-interval-ms", type=int, default=35)
    parser.add_argument("--retries", type=int, default=2, help="Retry attempts per candidate on transient failures")
    parser.add_argument(
        "--candidates-json",
        default="",
        help="Path to JSON file of candidate list; each item has {name, env}",
    )
    parser.add_argument("--json-out", default="", help="Optional output path for full tuning report")
    args = parser.parse_args()

    htmx_dir = Path(__file__).resolve().parents[1]
    if args.candidates_json:
        candidates = json.loads(Path(args.candidates_json).read_text(encoding="utf-8"))
    else:
        candidates = DEFAULT_CANDIDATES
    if not isinstance(candidates, list) or not candidates:
        raise SystemExit("No candidates provided")

    report: dict[str, Any] = {"started_at": int(time.time()), "runs": []}
    for idx, candidate in enumerate(candidates):
        name = str(candidate.get("name") or f"candidate_{idx+1}")
        result: dict[str, Any] = {"ok": False, "error": "not_run"}
        attempts = max(1, int(args.retries) + 1)
        for attempt in range(attempts):
            port = int(args.start_port) + idx + (attempt * max(1, len(candidates)))
            suffix = f" (attempt {attempt + 1}/{attempts})" if attempts > 1 else ""
            print(f"\n=== Running {name} on :{port}{suffix} ===")
            result = run_candidate(
                htmx_dir=htmx_dir,
                candidate=candidate,
                api_base_url=args.api_base_url,
                port=port,
                phase_cycles=int(args.phase_cycles),
                stress_bursts=int(args.stress_bursts),
                stress_clicks=int(args.stress_clicks_per_burst),
                stress_interval_ms=int(args.stress_interval_ms),
            )
            if result.get("ok"):
                break
        scored = score_result(result)
        run = {
            "name": name,
            "port": port,
            "env": candidate.get("env", {}),
            "ok": bool(result.get("ok")),
            "score": scored.get("score"),
            "passed": scored.get("passed"),
            "metrics": scored.get("metrics", {}),
            "error": result.get("error", ""),
            "details": result.get("details", ""),
        }
        report["runs"].append(run)
        if run["ok"]:
            print(f"{name}: score={run['score']} passed={run['passed']} metrics={run['metrics']}")
        else:
            print(f"{name}: FAILED ({run['error']})")

    sorted_runs = sorted(
        report["runs"],
        key=lambda item: (not bool(item.get("passed")), float(item.get("score", float("inf")))),
    )
    report["best"] = sorted_runs[0] if sorted_runs else None
    print("\n=== Best candidate ===")
    print(json.dumps(report["best"], indent=2))

    if args.json_out:
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
        print(f"\nWrote report: {out_path}")


if __name__ == "__main__":
    main()
