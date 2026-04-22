"""
Aggregator: merge fetcher DataFrames, normalise token identity by symbol,
filter exclusions, and compute feature-rich handoff columns.

Key difference from Solana: groups by token_symbol (uppercased) instead of
token_mint, because EVM tokens have different addresses on different chains.
Adds chain-level fields (chains_list, chain_count, token_addresses).
"""

import json
import logging
from collections import Counter

import pandas as pd

import config

log = logging.getLogger(__name__)

PROTOCOLS = ["Uniswap", "Curve", "Balancer", "Aave", "Morpho", "Pendle"]
VENUE_TYPES = ["dex", "lending", "yield"]


def aggregate(raw: pd.DataFrame) -> pd.DataFrame:
    """
    Takes the concatenated output of all fetchers and returns one row per
    unique token symbol with feature-rich handoff columns.
    """
    if raw.empty:
        log.warning("Aggregator received empty input")
        return pd.DataFrame()

    df = raw.copy()

    # --- normalise token identity ---
    df["token_symbol"] = df["token_symbol"].astype(str).str.strip()
    df.loc[df["token_symbol"].isin(["nan", "", "None"]), "token_symbol"] = ""
    df["token_symbol_upper"] = df["token_symbol"].str.upper()
    df["token_address"] = df["token_address"].astype(str).str.strip().str.lower()
    df.loc[df["token_address"].isin(["nan", ""]), "token_address"] = ""

    df = df[df["token_symbol_upper"].str.len() > 0]

    # --- filter exclusions ---
    df = df[~df["token_symbol_upper"].isin(config.EXCLUDED_TOKEN_SYMBOLS)]

    if df.empty:
        log.warning("All rows excluded after filtering")
        return pd.DataFrame()

    symbol_map = _canonical_symbols(df)
    symbol_stats = _symbol_quality_stats(df)

    grouped = df.groupby("token_symbol_upper", sort=False)

    records: list[dict] = []
    for sym_upper, grp in grouped:
        rec: dict = {}

        # --- identity ---
        rec["token_symbol"] = symbol_map.get(sym_upper, sym_upper)

        # --- addresses per chain ---
        addr_map: dict[str, str] = {}
        for _, row in grp[["chain_id", "token_address"]].drop_duplicates().iterrows():
            ch = row["chain_id"]
            addr = row["token_address"]
            if ch and addr and addr not in ("", "nan"):
                addr_map[ch] = addr
        rec["token_addresses"] = json.dumps(addr_map) if addr_map else ""

        # --- chain presence ---
        chains = sorted(grp["chain_id"].dropna().unique())
        rec["chains_list"] = ", ".join(str(c) for c in chains)
        rec["chain_count"] = len(chains)

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
            suffix = (
                "reserve_count" if p == "Aave"
                else "market_count" if p in ("Morpho", "Pendle")
                else "pool_count"
            )
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
            (grp["venue_type"] == "lending").any()
            and (grp["venue_type"] == "yield").any()
        )

        present_protocols = sorted(grp["protocol"].unique())
        present_venues = sorted(grp["venue_type"].unique())
        rec["protocols_list"] = ", ".join(present_protocols)
        rec["venue_types_list"] = ", ".join(present_venues)

        # --- counterpart context (DEX only) ---
        rec["top_dex_counterparts"] = _top_counterparts(grp, sym_upper)

        # --- symbol quality ---
        stats = symbol_stats.get(sym_upper, {})
        rec["source_count_with_symbol"] = stats.get("source_count", 0)
        rec["symbol_confidence"] = _classify_symbol_confidence(
            symbol=rec["token_symbol"],
            source_count=stats.get("source_count", 0),
            symbols_agree=stats.get("symbols_agree", True),
        )
        rec["has_complete_metadata"] = _has_complete_metadata(rec)

        records.append(rec)

    result = pd.DataFrame(records)
    log.info("Aggregator: %d unique tokens after filtering", len(result))
    return result


# ======================================================================
# Helpers
# ======================================================================

def _canonical_symbols(df: pd.DataFrame) -> dict[str, str]:
    """Pick the most-frequent non-empty original-case symbol for each upper key."""
    mapping: dict[str, str] = {}
    for sym_upper, grp in df.groupby("token_symbol_upper"):
        syms = grp["token_symbol"].dropna()
        syms = syms[syms.str.len() > 0]
        if syms.empty:
            mapping[sym_upper] = sym_upper
        else:
            mapping[sym_upper] = Counter(syms).most_common(1)[0][0]
    return mapping


def _symbol_quality_stats(df: pd.DataFrame) -> dict[str, dict]:
    """
    For each symbol key, compute:
      - source_count: number of distinct protocols that provided a non-empty
        symbol for this token.
      - symbols_agree: True if every non-empty symbol string matches after
        uppercasing/stripping.
    """
    stats: dict[str, dict] = {}
    for sym_upper, grp in df.groupby("token_symbol_upper"):
        with_symbol = grp.dropna(subset=["token_symbol"])
        with_symbol = with_symbol[with_symbol["token_symbol"].str.len() > 0]

        source_count = with_symbol["protocol"].nunique()
        unique_symbols = set(
            with_symbol["token_symbol"].str.strip().str.upper().unique()
        )
        symbols_agree = len(unique_symbols) <= 1

        stats[sym_upper] = {
            "source_count": source_count,
            "symbols_agree": symbols_agree,
        }
    return stats


def _classify_symbol_confidence(
    symbol: str,
    source_count: int,
    symbols_agree: bool,
) -> str:
    """
    Classify symbol trustworthiness for downstream filtering.

    EVM tokens generally have reliable symbols from APIs, so most will be
    high or medium.  The low/none tiers exist for consistency with the
    Solana app interface.
    """
    if not symbol:
        return "none"
    if source_count >= 2 and symbols_agree:
        return "high"
    if source_count >= 1:
        return "medium"
    return "low"


def _has_complete_metadata(rec: dict) -> bool:
    """
    Whether this token has enough structured data for downstream processing
    without manual inspection.

    Requires a resolved symbol + either multi-protocol presence OR $100K+ TVL.
    """
    if not rec["token_symbol"] or rec["symbol_confidence"] == "none":
        return False
    return rec["protocol_count"] >= 2 or rec["total_tvl_usd"] >= 100_000


def _top_counterparts(grp: pd.DataFrame, sym_upper: str) -> str:
    """
    From DEX rows, find the most common counterpart tokens paired with this
    token.  Returns a comma-separated string of up to 5 counterpart symbols.
    """
    dex = grp[grp["venue_type"] == "dex"]
    if dex.empty:
        return ""

    counter: Counter = Counter()
    for _, row in dex.iterrows():
        pool_name = row.get("pool_name", "")
        delim = "-" if "-" in pool_name else "/"
        parts = [p.strip().upper() for p in pool_name.split(delim)]
        for p in parts:
            if p and p != sym_upper:
                counter[p] += 1

    return ", ".join(sym for sym, _ in counter.most_common(5))
