"""
Aggregator: merge fetcher DataFrames, normalise token identity by mint,
filter exclusions, and compute feature-rich handoff columns.
"""

import logging
from collections import Counter

import pandas as pd

import config

log = logging.getLogger(__name__)

PROTOCOLS = ["Orca", "Raydium", "Meteora", "Kamino", "Exponent"]
VENUE_TYPES = ["dex", "lending", "yield"]


def aggregate(raw: pd.DataFrame) -> pd.DataFrame:
    """
    Takes the concatenated output of all fetchers and returns one row per
    unique token mint with feature-rich handoff columns.
    """
    if raw.empty:
        log.warning("Aggregator received empty input")
        return pd.DataFrame()

    df = raw.copy()

    # --- normalise token identity ---
    df["token_mint"] = df["token_mint"].astype(str).str.strip()
    df = df[df["token_mint"].str.len() > 0]

    # --- filter exclusions ---
    df = df[~df["token_mint"].isin(config.EXCLUDED_TOKEN_MINTS)]
    df = df[~df["token_symbol"].str.upper().isin(config.EXCLUDED_TOKEN_SYMBOLS)]

    if df.empty:
        log.warning("All rows excluded after filtering")
        return pd.DataFrame()

    # Resolve canonical symbol per mint (most frequent non-empty symbol)
    symbol_map = _canonical_symbols(df)

    grouped = df.groupby("token_mint", sort=False)

    records: list[dict] = []
    for mint, grp in grouped:
        rec: dict = {}

        # --- identity ---
        rec["token_mint"] = mint
        rec["token_symbol"] = symbol_map.get(mint, "")

        # --- aggregate totals ---
        rec["total_tvl_usd"] = grp["tvl_usd"].sum()
        rec["total_volume_usd"] = grp["volume_usd"].sum()
        rec["total_pool_count"] = len(grp["pool_id"].unique())

        # --- per-protocol presence flags & counts ---
        proto_pools = grp.groupby("protocol")["pool_id"].nunique()
        for p in PROTOCOLS:
            key = p.lower()
            count = int(proto_pools.get(p, 0))
            rec[f"has_{key}"] = count > 0
            suffix = "reserve_count" if p == "Kamino" else ("market_count" if p == "Exponent" else "pool_count")
            rec[f"{key}_{suffix}"] = count

        # --- per-domain breakdowns ---
        for vt in VENUE_TYPES:
            vt_rows = grp[grp["venue_type"] == vt]
            rec[f"{vt}_tvl_usd"] = vt_rows["tvl_usd"].sum()
            if vt == "dex":
                rec["dex_volume_usd"] = vt_rows["volume_usd"].sum()
                rec["dex_pool_count"] = len(vt_rows["pool_id"].unique())
                rec["dex_protocol_count"] = vt_rows["protocol"].nunique()

        # --- cross-domain signals ---
        rec["protocol_count"] = grp["protocol"].nunique()
        rec["venue_type_count"] = grp["venue_type"].nunique()
        rec["has_lending_and_yield"] = bool(
            (grp["venue_type"] == "lending").any() and (grp["venue_type"] == "yield").any()
        )

        present_protocols = sorted(grp["protocol"].unique())
        present_venues = sorted(grp["venue_type"].unique())
        rec["protocols_list"] = ", ".join(present_protocols)
        rec["venue_types_list"] = ", ".join(present_venues)

        # --- counterpart context (DEX only) ---
        rec["top_dex_counterparts"] = _top_counterparts(grp, mint)

        records.append(rec)

    result = pd.DataFrame(records)
    log.info("Aggregator: %d unique tokens after filtering", len(result))
    return result


def _canonical_symbols(df: pd.DataFrame) -> dict[str, str]:
    """Pick the most-frequent non-empty symbol for each mint."""
    mapping: dict[str, str] = {}
    for mint, grp in df.groupby("token_mint"):
        syms = grp["token_symbol"].dropna()
        syms = syms[syms.str.len() > 0]
        if syms.empty:
            mapping[mint] = ""
        else:
            mapping[mint] = Counter(syms).most_common(1)[0][0]
    return mapping


def _top_counterparts(grp: pd.DataFrame, mint: str) -> str:
    """
    From DEX rows, find the most common counterpart tokens paired with this
    mint.  Returns a comma-separated string of up to 5 counterpart symbols.
    """
    dex = grp[grp["venue_type"] == "dex"]
    if dex.empty:
        return ""

    counter: Counter = Counter()
    for _, row in dex.iterrows():
        pool_name = row.get("pool_name", "")
        parts = [p.strip() for p in pool_name.split("/")]
        own_sym = row["token_symbol"]
        for p in parts:
            if p and p != own_sym:
                counter[p] += 1

    return ", ".join(sym for sym, _ in counter.most_common(5))
