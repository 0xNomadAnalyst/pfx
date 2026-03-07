"""
Kamino balance reconstruction QA for ONyc lending market.

Uses snapshot_time_col='time' because gRPC-sourced src_reserves rows
have corrupted block_time values (shifted ~14 months into the future).
The 'time' column (DB insert timestamp) is accurate.
"""
from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
KAMINO_QA_DIR = PROJECT_ROOT / "kamino" / "backfill-qa"

sys.path.insert(0, str(PROJECT_ROOT))
sys.path.insert(0, str(PROJECT_ROOT / "shared"))
sys.path.insert(0, str(KAMINO_QA_DIR))

os.environ["KAMINO_BACKFILL_CONFIG"] = str(SCRIPT_DIR / "discovery_config_onyc_kamino.json")

from dotenv import load_dotenv
from backfill_qa import merged_env
from qa_balance_reconstruction import run_qa, log_balance_summary

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logging.getLogger("data.tx_events").setLevel(logging.ERROR)
logger = logging.getLogger(__name__)

PERIODS = [
    ("2026-02-13", "2026-02-14"),
    ("2026-02-19", "2026-02-20"),
    ("2026-02-25", "2026-02-26"),
    ("2026-03-01", "2026-03-02"),
    ("2026-03-05", "2026-03-06"),
]

DB_ENV_FILE = "pfx/.env.pfx.core"
COLLECT_ENV_FILE = ".env"


def main():
    env = merged_env(PROJECT_ROOT, db_env_file=DB_ENV_FILE, collect_env_file=COLLECT_ENV_FILE)
    load_dotenv(PROJECT_ROOT / DB_ENV_FILE, override=True)
    load_dotenv(PROJECT_ROOT / COLLECT_ENV_FILE, override=True)

    all_reports = {}

    for start, end in PERIODS:
        tag = f"{start}_to_{end}"
        out_dir = (SCRIPT_DIR / "parquet" / f"qa_kamino_2day_{tag}").resolve()
        out_dir.mkdir(parents=True, exist_ok=True)

        logger.info("=" * 70)
        logger.info("PERIOD: %s to %s", start, end)
        logger.info("=" * 70)

        try:
            report = run_qa(
                start=start,
                end=end,
                mode="solscan",
                env=env,
                output_dir=out_dir,
                db_env_file=DB_ENV_FILE,
                collect_env_file=COLLECT_ENV_FILE,
                rel_tolerance=0.01,
                abs_tolerance=1000.0,
                verbose=False,
                snapshot_time_col="time",
            )
            report_path = out_dir / "qa_balance_report.json"
            report_path.write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")
            log_balance_summary(report)
            all_reports[tag] = report
        except Exception:
            logger.exception("FAILED period %s to %s", start, end)
            all_reports[tag] = {"error": True}

    logger.info("")
    logger.info("=" * 90)
    logger.info("COMBINED SUMMARY  (Solscan reconstruction vs DB polled reserves)")
    logger.info("=" * 90)
    header = f"{'Period':<28} {'Reserve':<8} {'Evts':>5} {'Fwd Liq%':>9} {'Bwd Liq%':>9} {'Fwd Col%':>9} {'Bwd Col%':>9}"
    logger.info(header)
    logger.info("-" * 90)

    for tag, report in all_reports.items():
        if report.get("error"):
            logger.info(f"{tag:<28} ERROR")
            continue
        section = report.get("solscan", {})
        for addr, data in section.get("reserves", {}).items():
            if data.get("status") != "ok":
                continue
            sym = data.get("symbol", "?")
            n = data.get("n_events", 0)
            fwd = data.get("forward", {})
            bwd = data.get("backward", {})
            fl = fwd.get("liquidity_available_amount", {}).get("pct_within_tolerance", 0)
            bl = bwd.get("liquidity_available_amount", {}).get("pct_within_tolerance", 0)
            fc = fwd.get("collateral_mint_total_supply", {}).get("pct_within_tolerance", 0)
            bc = bwd.get("collateral_mint_total_supply", {}).get("pct_within_tolerance", 0)
            logger.info(f"{tag:<28} {sym:<8} {n:>5} {fl:>8.1f}% {bl:>8.1f}% {fc:>8.1f}% {bc:>8.1f}%")
        logger.info("-" * 90)

    combined_path = SCRIPT_DIR / "parquet" / "onyc_kamino_qa_summary.json"
    combined_path.write_text(json.dumps(all_reports, indent=2, default=str), encoding="utf-8")
    logger.info("Combined report: %s", combined_path)


if __name__ == "__main__":
    main()
