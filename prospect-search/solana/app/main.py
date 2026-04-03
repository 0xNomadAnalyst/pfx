"""
Prospect Search — candidate-generation engine.

Fetches token presence data from 5 Solana DeFi protocol APIs, aggregates by
token, scores for interestingness, and exports feature-rich CSVs designed for
downstream enrichment.

Run from repo root:
    python pfx/prospect-search/solana/app/main.py

Or from the app/ directory:
    cd pfx/prospect-search/solana/app && python main.py
"""

import logging
import sys
import time
from pathlib import Path

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
    # 2. Cross-fetcher symbol backfill
    # ------------------------------------------------------------------
    _backfill_exponent_symbols(raw_frames)

    # ------------------------------------------------------------------
    # 3. Export per-protocol raw tables
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
    # 4. Aggregate
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
    # 5. Score
    # ------------------------------------------------------------------
    prospects = scorer.score(prospects)
    prospects.sort_values("interest_score", ascending=False, inplace=True)
    prospects.reset_index(drop=True, inplace=True)

    # ------------------------------------------------------------------
    # 6. Export handoff CSV
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
            "total_tvl_usd", "protocol_count", "venue_type_count",
            "symbol_confidence"]
    cols = [c for c in cols if c in prospects.columns]
    print(prospects.head(10)[cols].to_string(index=False))
    print()


# ======================================================================
# Symbol backfill
# ======================================================================

def _backfill_exponent_symbols(raw_frames: dict[str, pd.DataFrame]) -> None:
    """
    Patch missing token_symbol values in the Exponent DataFrame.

    Resolution layers (applied in order):
      1. Cross-fetcher lookup — DEX and lending protocols provide
         authoritative mint→symbol mappings for most underlying tokens.
      2. On-chain Metaplex metadata — for mints that exist only on
         Exponent (via symbol_resolver module, no external imports).

    Also patches pool_name values that were built without a symbol.
    """
    exp_df = raw_frames.get("exponent")
    if exp_df is None or exp_df.empty:
        return

    missing_mask = exp_df["token_symbol"].isna() | (exp_df["token_symbol"] == "")
    n_missing = missing_mask.sum()
    if n_missing == 0:
        return

    # --- Layer 1: cross-fetcher lookup ---
    mint_to_symbol: dict[str, str] = {}
    for name, df in raw_frames.items():
        if name == "exponent" or df.empty:
            continue
        if "token_mint" not in df.columns or "token_symbol" not in df.columns:
            continue
        for _, row in df[["token_mint", "token_symbol"]].drop_duplicates().iterrows():
            mint = row["token_mint"]
            sym = row["token_symbol"]
            if mint and sym and pd.notna(sym) and mint not in mint_to_symbol:
                mint_to_symbol[mint] = sym

    filled_cross = _apply_symbol_map(exp_df, missing_mask, mint_to_symbol)
    log.info(
        "Exponent symbol backfill (cross-fetcher): %d/%d resolved",
        filled_cross, n_missing,
    )

    # --- Layer 2: Metaplex on-chain metadata ---
    missing_mask = exp_df["token_symbol"].isna() | (exp_df["token_symbol"] == "")
    still_missing = missing_mask.sum()
    if still_missing == 0:
        return

    remaining_mints = list(exp_df.loc[missing_mask, "token_mint"].unique())
    metaplex_map: dict[str, str] = {}
    try:
        from symbol_resolver import resolve_metaplex_symbols
        resolved = resolve_metaplex_symbols(remaining_mints)
        metaplex_map = {mint: info["symbol"] for mint, info in resolved.items()}
    except Exception as exc:
        log.warning("Metaplex fallback failed: %s", exc)

    filled_metaplex = _apply_symbol_map(exp_df, missing_mask, metaplex_map)
    log.info(
        "Exponent symbol backfill (Metaplex): %d/%d resolved",
        filled_metaplex, still_missing,
    )


def _apply_symbol_map(
    df: pd.DataFrame,
    mask: pd.Series,
    mint_to_symbol: dict[str, str],
) -> int:
    """Apply a mint→symbol map to rows matching *mask*. Returns count filled."""
    filled = 0
    for idx in df.index[mask]:
        mint = df.at[idx, "token_mint"]
        sym = mint_to_symbol.get(mint)
        if sym:
            df.at[idx, "token_symbol"] = sym
            pool_name = df.at[idx, "pool_name"]
            if pool_name and "yield (" in pool_name and not pool_name.startswith(sym):
                df.at[idx, "pool_name"] = pool_name.replace("yield (", f"{sym} yield (")
            filled += 1
    return filled


if __name__ == "__main__":
    main()
