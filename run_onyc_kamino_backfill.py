#!/usr/bin/env python3
"""
Collect historical Kamino Lend event data for the ONyc lending market
from Solscan and decode to local parquet files.

Market: 47tfyEG9SsdEnUm9cw5kY9BXngQGqu3LBoop9j5uTAv8
Reserves: USDC, USDG, ONyc, USDS, AUSD
Window: market deployment (Jul 15 2025) → DB ingestion start (Mar 5 2026)

Does NOT upload to DB.  Output lands in pfx/parquet/backfill_full/.
"""

import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BACKFILL_SCRIPT = REPO_ROOT / "kamino" / "backfill-qa" / "backfill_solscan.py"
CONFIG_PATH = REPO_ROOT / "pfx" / "discovery_config_onyc_kamino.json"
OUTPUT_DIR = (REPO_ROOT / "pfx" / "parquet" / "backfill_full").resolve()
ENV_FILE = REPO_ROOT / "pfx" / ".env.pfx.core"
COLLECT_ENV_FILE = REPO_ROOT / ".env"

START_DATE = "2025-07-15"
END_DATE = "2026-03-05"


def run_backfill():
    os.environ["KAMINO_BACKFILL_CONFIG"] = str(CONFIG_PATH)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    cmd = [
        sys.executable,
        str(BACKFILL_SCRIPT),
        "--start-date", START_DATE,
        "--end-date", END_DATE,
        "--env-file", str(ENV_FILE),
        "--collect-env-file", str(COLLECT_ENV_FILE),
        "--output-dir", str(OUTPUT_DIR),
        "--reserves-only",
        "--skip-obligations",
    ]

    print(f"Start: {START_DATE}  End: {END_DATE}")
    print(f"Config: {CONFIG_PATH}")
    print(f"Output: {OUTPUT_DIR}")
    print(f"Running: {' '.join(cmd[-6:])}")
    print("=" * 80)

    result = subprocess.run(cmd, cwd=str(BACKFILL_SCRIPT.parent))
    return result.returncode


if __name__ == "__main__":
    sys.exit(run_backfill())
