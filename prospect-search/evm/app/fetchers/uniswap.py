"""
Uniswap v3 fetcher — via DefiLlama yields API.

GET https://yields.llama.fi/pools
Filter client-side: project == "uniswap-v3", chain in TARGET_CHAINS.
Splits pair symbols to emit two rows per pool (one per token).
"""

import logging

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Uniswap"
VENUE_TYPE = "dex"

_CHAIN_REMAP = {
    "Ethereum": "ethereum",
    "Arbitrum": "arbitrum",
    "Base": "base",
    "Optimism": "optimism",
    "Polygon": "polygon",
}


def fetch() -> pd.DataFrame:
    try:
        resp = requests.get(
            config.DEFILLAMA_POOLS_URL,
            timeout=config.REQUEST_TIMEOUT_S,
        )
        resp.raise_for_status()
        data = resp.json().get("data", [])
    except Exception:
        log.exception("DefiLlama pools fetch failed")
        return pd.DataFrame()

    target_set = set(config.TARGET_CHAINS)
    rows: list[dict] = []

    for pool in data:
        if pool.get("project") != "uniswap-v3":
            continue

        chain_raw = pool.get("chain", "")
        chain = _CHAIN_REMAP.get(chain_raw, chain_raw.lower())
        if chain not in target_set:
            continue

        tvl = _float(pool.get("tvlUsd"))
        if tvl is None or tvl < config.MIN_TVL_USD:
            continue

        volume = _float(pool.get("volumeUsd1d")) or 0.0
        pool_id = pool.get("pool", "")
        pair_symbol = pool.get("symbol", "")
        underlying = pool.get("underlyingTokens") or []

        parts = [s.strip() for s in pair_symbol.split("-")]
        if len(parts) < 2:
            parts = [s.strip() for s in pair_symbol.split("/")]

        for i, sym in enumerate(parts):
            addr = underlying[i] if i < len(underlying) else ""
            rows.append({
                "token_symbol": sym,
                "token_address": addr.lower() if addr else "",
                "chain_id": chain,
                "protocol": PROTOCOL,
                "venue_type": VENUE_TYPE,
                "tvl_usd": tvl / max(len(parts), 1),
                "volume_usd": volume,
                "pool_id": pool_id,
                "pool_name": pair_symbol,
            })

    log.info("Uniswap: %d token-pool rows", len(rows))
    return pd.DataFrame(rows)


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
