"""
QA batch runner for ONyc pools.

Tx events ingestion has only been live ~24h (Mar 6-7 2026), so instead of
5 x 2-day windows we carve 5 non-overlapping ~4-hour windows within the
available data and run vault + liquidity reconstruction in DB mode.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
QA_DIR = PROJECT_ROOT / "dexes" / "backfill-qa"

sys.path.insert(0, str(PROJECT_ROOT))
sys.path.insert(0, str(PROJECT_ROOT / "shared"))
sys.path.insert(0, str(QA_DIR))

os.environ["BACKFILL_POOLS_CONFIG"] = str(SCRIPT_DIR / "pools_config_onyc.json")

from dotenv import dotenv_values

# Load TOKENS/POOLS env vars from the pfx dexes env file BEFORE importing config,
# so TOKEN_DECIMALS and POOL_METADATA are populated for the ONyc tokens.
_pfx_dexes_env = SCRIPT_DIR / ".env.pfx.dexes.txns"
if _pfx_dexes_env.exists():
    _pfx_vals = dotenv_values(_pfx_dexes_env)
    for _key in ("TOKENS", "POOLS"):
        if _key in _pfx_vals and _pfx_vals[_key]:
            os.environ[_key] = _pfx_vals[_key]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


WINDOWS = [
    (datetime(2026, 3, 6, 0, 0, 0, tzinfo=timezone.utc),
     datetime(2026, 3, 6, 4, 30, 0, tzinfo=timezone.utc)),
    (datetime(2026, 3, 6, 4, 30, 0, tzinfo=timezone.utc),
     datetime(2026, 3, 6, 9, 0, 0, tzinfo=timezone.utc)),
    (datetime(2026, 3, 6, 9, 0, 0, tzinfo=timezone.utc),
     datetime(2026, 3, 6, 13, 30, 0, tzinfo=timezone.utc)),
    (datetime(2026, 3, 6, 13, 30, 0, tzinfo=timezone.utc),
     datetime(2026, 3, 6, 18, 0, 0, tzinfo=timezone.utc)),
    (datetime(2026, 3, 6, 18, 0, 0, tzinfo=timezone.utc),
     datetime(2026, 3, 6, 22, 30, 0, tzinfo=timezone.utc)),
]


def build_env() -> dict:
    env = dict(os.environ)
    db_env_path = PROJECT_ROOT / "pfx" / ".env.pfx.core"
    collect_env_path = PROJECT_ROOT / ".env"
    if db_env_path.exists():
        env.update({k: v for k, v in dotenv_values(db_env_path).items() if v is not None})
    if collect_env_path.exists():
        env.update({k: v for k, v in dotenv_values(collect_env_path).items() if v is not None})
    return env


def main():
    import psycopg2
    from pool_config import load_dex_pools
    from qa_vault_reconstruction import run_qa as run_vault_qa
    from qa_liquidity_reconstruction import run_qa as run_liq_qa

    env = build_env()
    pools = load_dex_pools(logger=logger)
    logger.info(f"Pools loaded: {[p['name'] for p in pools]}")

    conn = psycopg2.connect(
        host=env["DB_HOST"],
        port=int(env.get("DB_PORT", "5432")),
        dbname=env["DB_NAME"],
        user=env["DB_USER"],
        password=env["DB_PASSWORD"],
        sslmode="require",
    )

    results = {}

    for i, (start, end) in enumerate(WINDOWS, 1):
        tag = f"{start.strftime('%H%M')}_{end.strftime('%H%M')}"
        label = f"{start.strftime('%H:%M')} - {end.strftime('%H:%M')} UTC"
        output_dir = SCRIPT_DIR / f"parquet/qa_onyc_{tag}"
        output_dir.mkdir(parents=True, exist_ok=True)

        print(f"\n{'='*70}")
        print(f"[{i}/5] Window: {label}  (Mar 6 2026)")
        print(f"{'='*70}")
        t0 = time.time()

        window_result = {"window": label}

        try:
            vault_report = run_vault_qa(
                start=start, end=end, mode="db", conn=conn,
                pools=pools, abs_tol=1000.0, rel_tol=0.005,
                verbose=True, output_dir=output_dir, env=env,
            )
            window_result["vault"] = vault_report
        except Exception as e:
            logger.error(f"Vault QA failed: {e}")
            window_result["vault_error"] = str(e)

        try:
            liq_report = run_liq_qa(
                start=start, end=end, mode="db", conn=conn,
                pools=pools, abs_tol=1000.0, rel_tol=0.005,
                verbose=True, output_dir=output_dir, env=env,
            )
            window_result["liquidity"] = liq_report
        except Exception as e:
            logger.error(f"Liquidity QA failed: {e}")
            window_result["liquidity_error"] = str(e)

        elapsed = time.time() - t0
        window_result["elapsed_sec"] = round(elapsed, 1)

        vault_data = window_result.get("vault", {})
        liq_data = window_result.get("liquidity", {})
        v_summary = vault_data.get("summary", {})
        l_summary = liq_data.get("summary", {})

        v_rate = v_summary.get("overall_pass_rate", "?")
        l_rate = l_summary.get("overall_pass_rate", "?")
        v_str = f"{v_rate:.0%}" if isinstance(v_rate, (int, float)) else str(v_rate)
        l_str = f"{l_rate:.0%}" if isinstance(l_rate, (int, float)) else str(l_rate)

        print(f"\n  vault={v_str}  liquidity={l_str}  [{elapsed:.1f}s]")

        report_path = output_dir / "qa_onyc_report.json"
        with open(report_path, "w") as f:
            json.dump(window_result, f, indent=2, default=str)

        results[tag] = window_result

    conn.close()

    print(f"\n{'='*70}")
    print("ONyc QA BATCH SUMMARY (Mar 6 2026)")
    print(f"{'='*70}")
    for tag, r in results.items():
        v_data = r.get("vault", {})
        l_data = r.get("liquidity", {})
        v_rate = v_data.get("summary", {}).get("overall_pass_rate", "?")
        l_rate = l_data.get("summary", {}).get("overall_pass_rate", "?")
        v_str = f"{v_rate:.0%}" if isinstance(v_rate, (int, float)) else str(v_rate)
        l_str = f"{l_rate:.0%}" if isinstance(l_rate, (int, float)) else str(l_rate)

        v_fwd = v_data.get("summary", {}).get("forward_pass_rate", "?")
        v_bwd = v_data.get("summary", {}).get("backward_pass_rate", "?")
        l_fwd = l_data.get("summary", {}).get("forward_pass_rate", "?")
        l_bwd = l_data.get("summary", {}).get("backward_pass_rate", "?")

        v_fwd_s = f"{v_fwd:.0%}" if isinstance(v_fwd, (int, float)) else str(v_fwd)
        v_bwd_s = f"{v_bwd:.0%}" if isinstance(v_bwd, (int, float)) else str(v_bwd)
        l_fwd_s = f"{l_fwd:.0%}" if isinstance(l_fwd, (int, float)) else str(l_fwd)
        l_bwd_s = f"{l_bwd:.0%}" if isinstance(l_bwd, (int, float)) else str(l_bwd)

        print(f"  {r.get('window', tag)}")
        print(f"    vault:     overall={v_str}  fwd={v_fwd_s}  bwd={v_bwd_s}")
        print(f"    liquidity: overall={l_str}  fwd={l_fwd_s}  bwd={l_bwd_s}")

    summary_path = SCRIPT_DIR / "parquet" / "onyc_qa_batch_summary.json"
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    with open(summary_path, "w") as f:
        json.dump(results, f, indent=2, default=str)
    print(f"\nFull report saved to {summary_path}")


if __name__ == "__main__":
    main()
