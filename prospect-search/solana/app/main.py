"""
Prospect Search — candidate-generation engine.

Fetches token presence data from 5 Solana DeFi protocol APIs, aggregates by
token, scores for interestingness, and exports feature-rich CSVs designed for
downstream enrichment.

Run from repo root:
    python pfx/prospect-search/app/main.py

Or from the app/ directory:
    cd pfx/prospect-search/app && python main.py
"""

import logging
import sys
import time
from pathlib import Path

# Ensure the app directory is on sys.path so internal imports resolve.
_APP_DIR = Path(__file__).resolve().parent
if str(_APP_DIR) not in sys.path:
    sys.path.insert(0, str(_APP_DIR))

import pandas as pd  # noqa: E402

import config  # noqa: E402
import aggregator  # noqa: E402
import scorer  # noqa: E402
from fetchers import orca, raydium, meteora, kamino, exponent  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("prospect-search")

OUTPUT_DIR = _APP_DIR / "output"


def main() -> None:
    OUTPUT_DIR.mkdir(exist_ok=True)
    t0 = time.time()

    # ------------------------------------------------------------------
    # 1. Fetch from each protocol
    # ------------------------------------------------------------------
    fetcher_modules = {
        "orca": orca,
        "raydium": raydium,
        "meteora": meteora,
        "kamino": kamino,
        "exponent": exponent,
    }

    raw_frames: dict[str, pd.DataFrame] = {}
    for name, mod in fetcher_modules.items():
        log.info("Fetching %s ...", name)
        try:
            df = mod.fetch()
            raw_frames[name] = df
            log.info("  -> %d rows", len(df))
        except Exception:
            log.exception("  -> FAILED")
            raw_frames[name] = pd.DataFrame()

    # ------------------------------------------------------------------
    # 2. Export per-protocol raw tables
    # ------------------------------------------------------------------
    proto_file_names = {
        "orca": "orca_tokens.csv",
        "raydium": "raydium_tokens.csv",
        "meteora": "meteora_tokens.csv",
        "kamino": "kamino_reserves.csv",
        "exponent": "exponent_markets.csv",
    }
    for name, df in raw_frames.items():
        if df.empty:
            continue
        out_path = OUTPUT_DIR / proto_file_names[name]
        df_sorted = df.sort_values("tvl_usd", ascending=False)
        df_sorted.to_csv(out_path, index=False)
        log.info("Wrote %s  (%d rows)", out_path.name, len(df_sorted))

    # ------------------------------------------------------------------
    # 3. Aggregate
    # ------------------------------------------------------------------
    combined = pd.concat(raw_frames.values(), ignore_index=True)
    if combined.empty:
        log.error("No data fetched from any protocol — exiting")
        return

    prospects = aggregator.aggregate(combined)
    if prospects.empty:
        log.error("Aggregation produced no results — exiting")
        return

    # ------------------------------------------------------------------
    # 4. Score
    # ------------------------------------------------------------------
    prospects = scorer.score(prospects)
    prospects.sort_values("interest_score", ascending=False, inplace=True)
    prospects.reset_index(drop=True, inplace=True)

    # ------------------------------------------------------------------
    # 5. Export handoff CSV
    # ------------------------------------------------------------------
    out_path = OUTPUT_DIR / "prospects.csv"
    prospects.to_csv(out_path, index=False)
    log.info("Wrote %s  (%d tokens)", out_path.name, len(prospects))

    elapsed = time.time() - t0
    log.info("Done in %.1fs", elapsed)

    print(f"\n{'='*60}")
    print(f"  Prospect Search complete — {len(prospects)} candidate tokens")
    print(f"  Output: {OUTPUT_DIR}")
    print(f"  Top 10 by interestingness:")
    print(f"{'='*60}")
    cols = ["token_symbol", "token_mint", "interest_score",
            "total_tvl_usd", "protocol_count", "venue_type_count"]
    cols = [c for c in cols if c in prospects.columns]
    print(prospects.head(10)[cols].to_string(index=False))
    print()


if __name__ == "__main__":
    main()
