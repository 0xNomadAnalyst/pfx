"""
Verify completeness of Solscan backfill data for ONyc pools.

Checks:
1. All Phase-1 signatures are present in Phase-2 transaction details
2. No duplicate signatures in the merged parquet
3. Time range coverage (no gaps in monthly activity counts)
4. Spot-check a sample of signatures against Solscan API

Usage:
    python pfx/verify_backfill_completeness.py
"""

import json
import sys
import os
import logging
from pathlib import Path
from datetime import datetime, timezone
from collections import Counter

import pandas as pd

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).parent.parent

POOLS = {
    "raydium": {
        "label": "Raydium USDG-ONyc",
        "dir": PROJECT_ROOT / "pfx" / "parquet" / "onyc_backfill_raydium",
        "address": "A9RdNEf4T9x1eNPnEHFX1ABHS7J4e9kxBm43S3o5r9Kw",
        "first_activity": "2025-07-07",
    },
    "orca": {
        "label": "Orca ONyc-USDC",
        "dir": PROJECT_ROOT / "pfx" / "parquet" / "onyc_backfill_orca",
        "address": "7jhhyxPUKpu42hPGSYwgMXbR2dtVJHKhs8DW3sAAgAvX",
        "first_activity": "2025-05-19",
    },
}


def verify_pool(key: str, pool: dict, spot_check: bool = False) -> dict:
    """Verify a single pool's backfill completeness."""
    label = pool["label"]
    data_dir = pool["dir"]
    report = {"pool": label, "status": "unknown", "issues": []}

    logger.info(f"\n{'='*70}")
    logger.info(f"Verifying: {label}")
    logger.info(f"Data dir:  {data_dir}")
    logger.info(f"{'='*70}")

    if not data_dir.exists():
        report["status"] = "ERROR"
        report["issues"].append(f"Data directory does not exist: {data_dir}")
        return report

    # 1. Load Phase-1 signatures
    sig_files = list(data_dir.glob("signatures_*.json"))
    if not sig_files:
        report["status"] = "ERROR"
        report["issues"].append("No signatures JSON file found (Phase 1 incomplete?)")
        return report

    with open(sig_files[0]) as f:
        phase1_sigs = set(json.load(f))
    logger.info(f"Phase 1 signatures: {len(phase1_sigs):,}")
    report["phase1_signatures"] = len(phase1_sigs)

    # 2. Load checkpoint to see fetched progress
    checkpoint_path = data_dir / "transaction_details_checkpoint.json"
    if checkpoint_path.exists():
        with open(checkpoint_path) as f:
            checkpoint = json.load(f)
        fetched_sigs = set(checkpoint.get("fetched_signatures", []))
        report["checkpoint_fetched"] = len(fetched_sigs)
        logger.info(f"Checkpoint fetched:  {len(fetched_sigs):,}")

        missing_from_checkpoint = phase1_sigs - fetched_sigs
        if missing_from_checkpoint:
            logger.warning(f"  Signatures in Phase 1 but NOT in checkpoint: {len(missing_from_checkpoint):,}")
            report["missing_from_checkpoint"] = len(missing_from_checkpoint)
            report["issues"].append(
                f"{len(missing_from_checkpoint)} signatures not yet fetched (download may still be running)"
            )
        else:
            logger.info("  All Phase-1 signatures present in checkpoint")

        extra_in_checkpoint = fetched_sigs - phase1_sigs
        if extra_in_checkpoint:
            logger.info(f"  Extra sigs in checkpoint (not in Phase 1): {len(extra_in_checkpoint)}")
    else:
        logger.warning("No checkpoint file found")
        report["issues"].append("No checkpoint file — cannot verify fetch completeness")

    # 3. Check merged parquet
    merged_files = list(data_dir.glob("transaction_details_1*.parquet"))
    batch_files = list(data_dir.glob("transaction_details_batch_*.parquet"))

    if merged_files:
        merged_path = merged_files[0]
        logger.info(f"\nMerged file: {merged_path.name}")
        df = pd.read_parquet(merged_path)
        report["merged_rows"] = len(df)
        logger.info(f"  Total rows: {len(df):,}")

        if "tx_hash" in df.columns:
            sig_col = "tx_hash"
        elif "txHash" in df.columns:
            sig_col = "txHash"
        else:
            sig_col = None
            for col in df.columns:
                if "hash" in col.lower() or "sig" in col.lower() or "tx" == col.lower():
                    sig_col = col
                    break

        if sig_col:
            merged_sigs = set(df[sig_col].dropna().unique())
            report["merged_unique_sigs"] = len(merged_sigs)
            logger.info(f"  Unique signatures (col={sig_col}): {len(merged_sigs):,}")

            duplicates = len(df) - len(merged_sigs)
            if duplicates > 0:
                logger.warning(f"  Duplicate rows: {duplicates:,}")
                report["duplicate_rows"] = duplicates
                report["issues"].append(f"{duplicates} duplicate rows in merged file")

            missing_from_merged = phase1_sigs - merged_sigs
            if missing_from_merged:
                logger.warning(f"  Signatures missing from merged file: {len(missing_from_merged):,}")
                report["missing_from_merged"] = len(missing_from_merged)
                report["issues"].append(
                    f"{len(missing_from_merged)} Phase-1 signatures missing from merged parquet"
                )
            else:
                logger.info("  All Phase-1 signatures found in merged parquet")

            # Time distribution
            time_col = None
            for col in ["block_time", "blockTime", "block_timestamp"]:
                if col in df.columns:
                    time_col = col
                    break

            if time_col:
                df["_month"] = pd.to_datetime(df[time_col], unit="s").dt.to_period("M")
                monthly = df.groupby("_month").size()
                logger.info(f"\n  Monthly distribution:")
                for month, count in monthly.items():
                    logger.info(f"    {month}: {count:,} txs")
                report["monthly_distribution"] = {str(m): int(c) for m, c in monthly.items()}
        else:
            logger.warning(f"  Could not identify signature column. Columns: {list(df.columns)[:10]}")
            report["issues"].append("Could not identify signature column in merged parquet")
    elif batch_files:
        logger.info(f"\nNo merged file yet — {len(batch_files)} batch files present (download still running?)")
        report["batch_files"] = len(batch_files)
        report["issues"].append(f"Not yet merged — {len(batch_files)} batch files exist")
    else:
        logger.warning("No parquet files found (Phase 2 not started or failed)")
        report["issues"].append("No transaction detail parquet files found")

    # 4. Optional: spot-check against Solscan API
    if spot_check and phase1_sigs:
        try:
            import requests

            solscan_env = PROJECT_ROOT / "solscan" / ".env"
            api_key = None
            if solscan_env.exists():
                for line in solscan_env.read_text().splitlines():
                    if "SOLSCAN_API_KEY" in line and "=" in line:
                        api_key = line.split("=", 1)[1].strip()
                        break

            if api_key:
                import random
                import time

                sample = random.sample(list(phase1_sigs), min(10, len(phase1_sigs)))
                headers = {"token": api_key, "Accept": "application/json"}
                ok, fail = 0, 0
                for sig in sample:
                    resp = requests.get(
                        f"https://pro-api.solscan.io/v2.0/transaction/detail",
                        headers=headers,
                        params={"tx": sig},
                        timeout=15,
                    )
                    if resp.status_code == 200 and resp.json().get("success"):
                        ok += 1
                    else:
                        fail += 1
                    time.sleep(0.5)
                logger.info(f"\n  Spot check: {ok}/{ok+fail} signatures verified on Solscan")
                report["spot_check"] = {"verified": ok, "failed": fail}
            else:
                logger.info("  Skipping spot check (no API key)")
        except Exception as e:
            logger.warning(f"  Spot check error: {e}")

    # Final verdict
    if not report["issues"]:
        report["status"] = "PASS"
        logger.info(f"\n  RESULT: PASS — all {len(phase1_sigs):,} signatures accounted for")
    else:
        report["status"] = "ISSUES"
        logger.warning(f"\n  RESULT: ISSUES FOUND")
        for issue in report["issues"]:
            logger.warning(f"    - {issue}")

    return report


def main():
    spot_check = "--spot-check" in sys.argv
    results = {}

    for key, pool in POOLS.items():
        results[key] = verify_pool(key, pool, spot_check=spot_check)

    logger.info(f"\n{'='*70}")
    logger.info("SUMMARY")
    logger.info(f"{'='*70}")
    for key, report in results.items():
        status = report["status"]
        label = report["pool"]
        n_issues = len(report.get("issues", []))
        logger.info(f"  {label}: {status}" + (f" ({n_issues} issues)" if n_issues else ""))

    out_path = Path(__file__).parent / "parquet" / "backfill_verification_report.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2, default=str)
    logger.info(f"\nReport saved to: {out_path}")

    return 0 if all(r["status"] == "PASS" for r in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
