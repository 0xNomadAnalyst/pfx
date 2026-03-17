"""
Targeted re-fetch of missing transaction signatures from Solscan.
Reads missing_signatures.json, fetches in batches, saves to parquet,
then merges with existing merged parquet to produce a complete dataset.
"""
import os, sys, json, time, logging
from pathlib import Path
from typing import List, Dict, Any

import pandas as pd
import requests
from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).parent.parent
load_dotenv(PROJECT_ROOT / '.env')
load_dotenv(PROJECT_ROOT / 'solscan' / '.env', override=True)

API_KEY = os.getenv('BACKFILL_SOLSCAN_API_KEY') or os.getenv('SOLSCAN_API_KEY', '')
HEADERS = {'token': API_KEY, 'Accept': 'application/json'}
BASE_URL = 'https://pro-api.solscan.io/v2.0'
BATCH_SIZE = 50
MAX_RETRIES = 5
INITIAL_BACKOFF = 10


def fetch_batch(sigs: List[str]) -> List[Dict[str, Any]]:
    """Fetch a batch of transaction details with retry logic."""
    url = f"{BASE_URL}/transaction/detail/multi"
    params = [("tx", s) for s in sigs]

    for attempt in range(MAX_RETRIES):
        try:
            resp = requests.get(url, headers=HEADERS, params=params, timeout=60)
            if resp.status_code == 429:
                wait = INITIAL_BACKOFF * (2 ** attempt)
                logger.warning(f"  Rate limit (429), waiting {wait}s (attempt {attempt+1}/{MAX_RETRIES})")
                time.sleep(wait)
                continue
            resp.raise_for_status()
            result = resp.json()
            if result.get("success") and result.get("data"):
                return result["data"]
            logger.warning(f"  API returned success={result.get('success')}, data length={len(result.get('data', []))}")
            return result.get("data", [])
        except requests.exceptions.RequestException as e:
            wait = INITIAL_BACKOFF * (2 ** attempt)
            logger.error(f"  Request error: {e}, retrying in {wait}s (attempt {attempt+1}/{MAX_RETRIES})")
            time.sleep(wait)

    logger.error(f"  Failed after {MAX_RETRIES} retries")
    return []


def save_parquet(details: List[Dict], path: Path):
    """Save transaction details to parquet."""
    df = pd.DataFrame(details)
    for col in df.columns:
        if df[col].apply(lambda x: isinstance(x, (dict, list))).any():
            df[col] = df[col].apply(lambda x: json.dumps(x) if isinstance(x, (dict, list)) else x)
        elif df[col].apply(type).nunique() > 1:
            df[col] = df[col].astype(str)
    df.to_parquet(path, index=False)


def refetch_missing(data_dir: Path, label: str):
    """Refetch all missing signatures for a dataset."""
    missing_file = data_dir / 'missing_signatures.json'
    if not missing_file.exists():
        logger.info(f"[{label}] No missing_signatures.json found, skipping")
        return

    missing_sigs = json.load(open(missing_file))
    logger.info(f"[{label}] {len(missing_sigs):,} missing signatures to fetch")

    if not missing_sigs:
        return

    refetch_dir = data_dir / 'refetch'
    refetch_dir.mkdir(exist_ok=True)

    checkpoint_file = refetch_dir / 'checkpoint.json'
    fetched_set = set()
    if checkpoint_file.exists():
        cp = json.load(open(checkpoint_file))
        fetched_set = set(cp.get('fetched', []))
        logger.info(f"  Resuming: {len(fetched_set):,} already refetched")

    to_fetch = [s for s in missing_sigs if s not in fetched_set]
    logger.info(f"  Remaining: {len(to_fetch):,} signatures")

    all_details = []
    file_num = len(list(refetch_dir.glob('batch_*.parquet')))
    total_batches = (len(to_fetch) + BATCH_SIZE - 1) // BATCH_SIZE
    still_missing = []

    for i in range(0, len(to_fetch), BATCH_SIZE):
        batch = to_fetch[i:i + BATCH_SIZE]
        batch_num = i // BATCH_SIZE + 1
        if batch_num % 50 == 1 or batch_num == total_batches:
            logger.info(f"  [{label}] Batch {batch_num}/{total_batches}")

        details = fetch_batch(batch)
        if details:
            all_details.extend(details)
            returned_sigs = {d.get('tx_hash', d.get('txHash', '')) for d in details}
            fetched_set.update(returned_sigs)
            batch_missing = set(batch) - returned_sigs
            if batch_missing:
                still_missing.extend(batch_missing)
        else:
            still_missing.extend(batch)

        if len(all_details) >= 1000:
            file_num += 1
            save_parquet(all_details, refetch_dir / f'batch_{file_num:04d}.parquet')
            all_details = []
            with open(checkpoint_file, 'w') as f:
                json.dump({'fetched': list(fetched_set)}, f)

        time.sleep(0.3)

    if all_details:
        file_num += 1
        save_parquet(all_details, refetch_dir / f'batch_{file_num:04d}.parquet')
        with open(checkpoint_file, 'w') as f:
            json.dump({'fetched': list(fetched_set)}, f)

    logger.info(f"[{label}] Refetch complete: {len(fetched_set):,} recovered, {len(still_missing):,} still missing")
    if still_missing:
        with open(refetch_dir / 'still_missing.json', 'w') as f:
            json.dump(still_missing, f)


def rebuild_merged(data_dir: Path, label: str, merged_glob: str = 'transaction_details_1*.parquet'):
    """Merge refetched data with existing merged parquet, deduplicate."""
    merged_files = sorted(data_dir.glob(merged_glob))
    if not merged_files:
        merged_files = sorted(data_dir.glob('transaction_details_*_1*.parquet'))
    if not merged_files:
        logger.warning(f"[{label}] No merged parquet found")
        return

    merged_path = merged_files[0]
    refetch_dir = data_dir / 'refetch'
    refetch_batches = sorted(refetch_dir.glob('batch_*.parquet'))

    if not refetch_batches:
        logger.info(f"[{label}] No refetch batches to merge")
        return

    logger.info(f"[{label}] Loading existing merged parquet...")
    df_main = pd.read_parquet(merged_path)
    col = 'tx_hash' if 'tx_hash' in df_main.columns else 'txHash'
    orig_sigs = set(df_main[col].unique())
    logger.info(f"  Existing: {len(df_main):,} rows, {len(orig_sigs):,} unique sigs")

    # Also load any leftover batch files from main dir
    stale_batches = sorted(data_dir.glob('transaction_details_batch_*.parquet'))
    logger.info(f"  Stale batch files in main dir: {len(stale_batches)}")

    frames = [df_main]
    for bf in refetch_batches:
        frames.append(pd.read_parquet(bf))

    df_all = pd.concat(frames, ignore_index=True)
    before_dedup = len(df_all)
    df_all = df_all.drop_duplicates(subset=[col, 'block_id'], keep='first')
    after_dedup = len(df_all)
    new_sigs = set(df_all[col].unique())

    logger.info(f"  After merge: {before_dedup:,} -> {after_dedup:,} rows (deduped {before_dedup - after_dedup:,})")
    logger.info(f"  Unique sigs: {len(orig_sigs):,} -> {len(new_sigs):,} (+{len(new_sigs) - len(orig_sigs):,})")

    backup = merged_path.with_suffix('.parquet.bak')
    if backup.exists():
        backup.unlink()
    merged_path.rename(backup)
    logger.info(f"  Backed up original to {backup.name}")

    for c in df_all.columns:
        if df_all[c].apply(lambda x: isinstance(x, (dict, list))).any():
            df_all[c] = df_all[c].apply(lambda x: json.dumps(x) if isinstance(x, (dict, list)) else x)
        elif df_all[c].apply(type).nunique() > 1:
            df_all[c] = df_all[c].astype(str)

    df_all.to_parquet(merged_path, index=False)
    logger.info(f"  Wrote new merged parquet: {merged_path.name} ({len(df_all):,} rows)")

    # Cleanup stale batch files
    for bf in stale_batches:
        bf.unlink()
    logger.info(f"  Deleted {len(stale_batches)} stale batch files from main dir")

    # Check against ground truth — also check parent metadata/ dir
    sigs_files = sorted(data_dir.glob('signatures_*.json'))
    if not sigs_files:
        meta_dir = data_dir.parent / 'metadata'
        if meta_dir.exists():
            sigs_files = sorted(meta_dir.glob(f'signatures_{label.lower()}_*.json'))
            if not sigs_files:
                sigs_files = sorted(meta_dir.glob('signatures_*.json'))
    if sigs_files:
        ground_truth = set(json.load(open(sigs_files[0])))
        final_missing = ground_truth - new_sigs
        logger.info(f"  Final gap vs ground truth: {len(final_missing):,} still missing out of {len(ground_truth):,}")


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--dataset', choices=['orca', 'raydium', 'both'], default='both')
    parser.add_argument('--merge-only', action='store_true', help='Skip fetch, just merge')
    args = parser.parse_args()

    BACKFILL_DIR = PROJECT_ROOT / 'pfx' / 'backfill-onyc-dex-20250519-20260307'
    ORCA_DIR = BACKFILL_DIR / 'data'
    RAY_DIR = BACKFILL_DIR / 'data'

    datasets = []
    if args.dataset in ('orca', 'both'):
        datasets.append((ORCA_DIR, 'Orca'))
    if args.dataset in ('raydium', 'both'):
        datasets.append((RAY_DIR, 'Raydium'))

    for data_dir, label in datasets:
        if not args.merge_only:
            refetch_missing(data_dir, label)
        rebuild_merged(data_dir, label)
