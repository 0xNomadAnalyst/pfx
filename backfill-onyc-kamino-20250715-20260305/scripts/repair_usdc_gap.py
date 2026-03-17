#!/usr/bin/env python3
"""
Repair USDC signature gap and re-fetch 400 missing tx details.

The initial backfill had USDC sig collection fail (502) at Oct 14 2025,
leaving Jul 15 - Oct 14 uncovered. This script:
  1. Collects USDC sigs for the gap period (Jul 15 - Oct 14 2025)
  2. Merges with existing signatures
  3. Re-fetches details for all missing sigs (new USDC + 400 originally missing)
  4. Merges details into existing parquet
  5. Re-decodes all events from the merged details
"""

import json
import os
import sys
import time
from pathlib import Path
from datetime import datetime, timezone

import pandas as pd
from dotenv import load_dotenv

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "shared"))
sys.path.insert(0, str(REPO_ROOT / "kamino"))
sys.path.insert(0, str(REPO_ROOT / "kamino" / "backfill-qa"))
sys.path.insert(0, str(REPO_ROOT))

OUTPUT_DIR = REPO_ROOT / "pfx" / "parquet" / "backfill_full"
FROM_TIME = 1752537600   # Jul 15, 2025
TO_TIME   = 1772755199   # Mar 5, 2026 23:59:59

USDC_RESERVE = "AYL4LMc4ZCVyq3Z7XPJGWDM4H9PiWjqXAAuuHBEGVR2Z"
USDC_OLDEST_SIG = "5t4jCJ577paNoTR1Jsa9YKzkp6QngtY6ZexosHG9udu19HVRFzmQLRyiVhVZY4z4iX5tdEvxNfst4dmx1QSSNtp2"


def main():
    import sys as _sys
    _sys.stdout.reconfigure(line_buffering=True)

    print("Loading environment...", flush=True)
    load_dotenv(str(REPO_ROOT / ".env"), override=True)
    load_dotenv(str(REPO_ROOT / "pfx" / ".env.pfx.core"), override=True)

    os.environ["KAMINO_BACKFILL_CONFIG"] = str(
        REPO_ROOT / "pfx" / "discovery_config_onyc_kamino.json"
    )

    print("Importing modules...", flush=True)
    from backfill_solscan import SolscanBackfillClient, KaminoBackfillProcessor
    from backfill_config import load_solscan_api_key, load_tracked_accounts_config, reserve_metadata_by_address
    from config import KAMINO_PROGRAM_ID

    print("Creating client...", flush=True)
    api_key = load_solscan_api_key()
    client = SolscanBackfillClient(api_key)
    processor = KaminoBackfillProcessor(
        db_config={
            "host": os.environ.get("DB_HOST", ""),
            "port": os.environ.get("DB_PORT", "5432"),
            "database": os.environ.get("DB_NAME", ""),
            "user": os.environ.get("DB_USER", ""),
            "password": os.environ.get("DB_PASSWORD", ""),
        },
        db_schema=os.environ.get("DB_SCHEMA", "public"),
    )

    print("Loading existing signatures...", flush=True)
    sig_path = OUTPUT_DIR / f"signatures_{FROM_TIME}_{TO_TIME}.json"
    with open(sig_path) as f:
        existing_sigs = set(json.load(f))
    print(f"Existing signatures: {len(existing_sigs)}", flush=True)

    # --- Step 1: Collect USDC sigs for gap period ---
    # Resume from the oldest known USDC sig (Oct 14 2025), walk back to Jul 15
    print("=" * 80, flush=True)
    print(f"Step 1: Collecting USDC sigs for gap Jul 15 - Oct 14 2025", flush=True)
    print(f"  USDC reserve: {USDC_RESERVE}", flush=True)
    print(f"  Resuming from cursor: {USDC_OLDEST_SIG[:20]}...", flush=True)
    print("=" * 80, flush=True)

    new_sigs = set()
    before = USDC_OLDEST_SIG
    page = 0
    oldest_seen = None

    while True:
        page += 1
        result = client.get_account_transactions(
            address=USDC_RESERVE, limit=40, before=before,
        )
        if not result.get("success"):
            print(f"  ERROR on page {page}: {result}", flush=True)
            break

        rows = result.get("data") or []
        if not rows:
            print(f"  No more rows at page {page}", flush=True)
            break

        stop = False
        for row in rows:
            bt = row.get("block_time")
            sig = row.get("tx_hash") or row.get("signature") or row.get("trans_id")
            if bt and isinstance(bt, (int, float)):
                if oldest_seen is None or bt < oldest_seen:
                    oldest_seen = bt
                if bt < FROM_TIME:
                    stop = True
                    break
                if sig:
                    new_sigs.add(sig)

        last_sig = None
        for key in ("tx_hash", "signature", "trans_id"):
            v = rows[-1].get(key)
            if isinstance(v, str) and v:
                last_sig = v
                break

        if stop or not last_sig:
            break
        before = last_sig

        if page % 100 == 0:
            ot = datetime.fromtimestamp(oldest_seen, tz=timezone.utc).isoformat() if oldest_seen else "?"
            print(f"  Page {page}: {len(new_sigs)} new sigs, oldest={ot}", flush=True)

        time.sleep(0.2)

    truly_new = new_sigs - existing_sigs
    print(f"\n  USDC gap sigs collected: {len(new_sigs)}", flush=True)
    print(f"  Truly new (not in existing set): {len(truly_new)}", flush=True)

    # --- Step 2: Merge signatures ---
    merged_sigs = sorted(existing_sigs | new_sigs)
    with open(sig_path, "w") as f:
        json.dump(merged_sigs, f, indent=2)
    print(f"\n  Merged signature count: {len(merged_sigs)} (was {len(existing_sigs)})")

    # --- Step 3: Find all missing details ---
    details_path = OUTPUT_DIR / f"transaction_details_{FROM_TIME}_{TO_TIME}.parquet"
    print("Loading existing tx details (tx_hash column only)...", flush=True)
    df_existing = pd.read_parquet(details_path, columns=["tx_hash"])
    fetched_set = set(df_existing["tx_hash"].tolist())
    del df_existing
    missing = [s for s in merged_sigs if s not in fetched_set]
    print(f"  Missing tx details to fetch: {len(missing)}", flush=True)

    if not missing:
        print("  Nothing to fetch — skipping to decode")
    else:
        # --- Step 4: Fetch missing details with checkpointing ---
        print("=" * 80)
        print(f"Step 2: Fetching {len(missing)} missing tx details")
        print("=" * 80)

        checkpoint_path = OUTPUT_DIR / "repair_checkpoint.parquet"
        new_details = client.get_transaction_details_multi(
            missing,
            batch_size=50,
            checkpoint_path=checkpoint_path,
            checkpoint_every=50,
        )

        if new_details:
            df_new = pd.DataFrame(new_details)
            for col in df_new.columns:
                if df_new[col].apply(lambda x: isinstance(x, (dict, list))).any():
                    df_new[col] = df_new[col].apply(
                        lambda x: json.dumps(x) if isinstance(x, (dict, list)) else x
                    )
                elif df_new[col].apply(type).nunique() > 1:
                    df_new[col] = df_new[col].astype(str)

            print("Loading full existing details for merge (this is 3.5GB, may take a minute)...", flush=True)
            df_full_existing = pd.read_parquet(details_path)
            print(f"  Loaded {len(df_full_existing)} existing rows, merging...", flush=True)
            df_merged = pd.concat([df_full_existing, df_new], ignore_index=True)
            df_merged = df_merged.drop_duplicates(subset=["tx_hash"], keep="last")
            df_merged.to_parquet(details_path, index=False)
            print(f"  Merged details: {len(df_merged)} total (was {len(df_full_existing)})", flush=True)
            del df_full_existing, df_merged

            if checkpoint_path.exists():
                checkpoint_path.unlink()
        else:
            print("  WARNING: No new details fetched")

    # --- Step 5: Re-decode all events ---
    print("=" * 80)
    print("Step 3: Re-decoding all events from merged details")
    print("=" * 80)

    tracked_cfg = load_tracked_accounts_config()
    reserve_addrs = set(tracked_cfg.get("reserve_addresses", []))
    with open(REPO_ROOT / "pfx" / "discovery_config_onyc_kamino.json") as f:
        disc_cfg = json.load(f)
    reserve_meta = reserve_metadata_by_address(disc_cfg)

    processor.process_transactions_to_parquet(
        details_path=details_path,
        output_dir=OUTPUT_DIR,
        from_time=FROM_TIME,
        to_time=TO_TIME,
        tracked_reserves=reserve_addrs,
        reserve_meta=reserve_meta,
    )
    print("\nDone! Re-decoded events written.")


if __name__ == "__main__":
    main()
