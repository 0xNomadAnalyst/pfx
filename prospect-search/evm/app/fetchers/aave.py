"""
Aave v3 lending fetcher.

Two data sources, joined client-side:
  1. Community REST JSON (reserve metadata — rates, caps, flags):
     GET https://th3nolo.github.io/aave-v3-data/aave_v3_data.json
  2. DefiLlama pools (TVL in USD):
     GET https://yields.llama.fi/pools  filtered to project=="aave-v3"

The community JSON provides per-chain reserve details but lacks USD TVL.
DefiLlama provides TVL but lacks reserve-level metadata.
We join on (chain, symbol) to get the best of both.
"""

import logging

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Aave"
VENUE_TYPE = "lending"

_LLAMA_CHAIN_REMAP = {
    "Ethereum": "ethereum",
    "Arbitrum": "arbitrum",
    "Base": "base",
    "Optimism": "optimism",
    "Polygon": "polygon",
}

_COMMUNITY_CHAIN_KEYS = {
    "ethereum": ["ethereum", "eth", "mainnet"],
    "arbitrum": ["arbitrum", "arbitrum_one"],
    "base": ["base"],
    "optimism": ["optimism"],
    "polygon": ["polygon", "matic"],
}


def fetch() -> pd.DataFrame:
    llama_tvl = _fetch_defillama_tvl()
    community_reserves = _fetch_community_json()

    rows: list[dict] = []
    target_set = set(config.TARGET_CHAINS)

    for reserve in community_reserves:
        chain = reserve.get("chain", "")
        if chain not in target_set:
            continue

        symbol = reserve.get("symbol", "")
        address = (reserve.get("asset_address") or "").lower()

        tvl = llama_tvl.get((chain, symbol.upper()), 0.0)
        if tvl < config.MIN_TVL_USD:
            continue

        pool_id = f"aave-v3-{chain}-{address}"

        rows.append({
            "token_symbol": symbol,
            "token_address": address,
            "chain_id": chain,
            "protocol": PROTOCOL,
            "venue_type": VENUE_TYPE,
            "tvl_usd": tvl,
            "volume_usd": 0.0,
            "pool_id": pool_id,
            "pool_name": f"Aave v3 {symbol} ({chain})",
        })

    if not community_reserves:
        log.warning("Community JSON unavailable; falling back to DefiLlama-only")
        for (chain, sym), tvl in llama_tvl.items():
            if tvl < config.MIN_TVL_USD:
                continue
            rows.append({
                "token_symbol": sym,
                "token_address": "",
                "chain_id": chain,
                "protocol": PROTOCOL,
                "venue_type": VENUE_TYPE,
                "tvl_usd": tvl,
                "volume_usd": 0.0,
                "pool_id": f"aave-v3-{chain}-{sym.lower()}",
                "pool_name": f"Aave v3 {sym} ({chain})",
            })

    log.info("Aave: %d reserve rows", len(rows))
    return pd.DataFrame(rows)


def _fetch_defillama_tvl() -> dict[tuple[str, str], float]:
    """Return {(chain, SYMBOL_UPPER): tvl_usd} from DefiLlama aave-v3 pools."""
    tvl_map: dict[tuple[str, str], float] = {}
    try:
        resp = requests.get(config.DEFILLAMA_POOLS_URL, timeout=config.REQUEST_TIMEOUT_S)
        resp.raise_for_status()
        pools = resp.json().get("data", [])
    except Exception:
        log.exception("DefiLlama pools fetch failed for Aave TVL")
        return tvl_map

    target_set = set(config.TARGET_CHAINS)

    for pool in pools:
        if pool.get("project") != "aave-v3":
            continue
        chain_raw = pool.get("chain", "")
        chain = _LLAMA_CHAIN_REMAP.get(chain_raw, chain_raw.lower())
        if chain not in target_set:
            continue

        tvl = pool.get("tvlUsd") or 0.0
        symbol = pool.get("symbol", "").strip().upper()
        if not symbol:
            continue

        key = (chain, symbol)
        tvl_map[key] = tvl_map.get(key, 0.0) + float(tvl)

    return tvl_map


def _fetch_community_json() -> list[dict]:
    """Parse th3nolo community Aave v3 JSON into flat reserve records."""
    reserves: list[dict] = []
    try:
        resp = requests.get(config.AAVE_DATA_URL, timeout=config.REQUEST_TIMEOUT_S)
        resp.raise_for_status()
        data = resp.json()
    except Exception:
        log.exception("Aave community JSON fetch failed")
        return reserves

    networks = data if isinstance(data, dict) else {}
    if "networks" in networks:
        networks = networks["networks"]

    target_set = set(config.TARGET_CHAINS)

    for chain_key, chain_reserves in networks.items():
        chain = _resolve_chain(chain_key.lower())
        if chain not in target_set:
            continue
        if not isinstance(chain_reserves, list):
            continue

        for r in chain_reserves:
            r["chain"] = chain
            reserves.append(r)

    return reserves


def _resolve_chain(raw: str) -> str:
    for canonical, aliases in _COMMUNITY_CHAIN_KEYS.items():
        if raw in aliases or raw == canonical:
            return canonical
    return raw
