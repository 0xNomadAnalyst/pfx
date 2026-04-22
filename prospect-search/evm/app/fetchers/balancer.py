"""
Balancer v3 DEX fetcher — native GraphQL API.

POST https://api-v3.balancer.fi/
Query: poolGetPools per chain with minTvl filter.
Emits one row per poolToken per pool.
"""

import logging
import time

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Balancer"
VENUE_TYPE = "dex"

_QUERY = """
query GetPools($chain: [GqlChain!]!, $skip: Int!, $first: Int!, $minTvl: Float) {
  poolGetPools(
    where: {chainIn: $chain, minTvl: $minTvl}
    first: $first
    skip: $skip
    orderBy: totalLiquidity
    orderDirection: desc
  ) {
    id
    name
    chain
    poolTokens {
      address
      symbol
      name
    }
    dynamicData {
      totalLiquidity
      volume24h
    }
  }
}
"""

_BALANCER_CHAIN_TO_INTERNAL = {v: k for k, v in config.BALANCER_CHAIN_MAP.items()}


def fetch() -> pd.DataFrame:
    rows: list[dict] = []

    for chain in config.TARGET_CHAINS:
        bal_chain = config.BALANCER_CHAIN_MAP.get(chain)
        if not bal_chain:
            continue

        log.info("  Balancer [%s] ...", chain)
        skip = 0
        page_size = 100

        while True:
            payload = {
                "query": _QUERY,
                "variables": {
                    "chain": [bal_chain],
                    "skip": skip,
                    "first": page_size,
                    "minTvl": float(config.MIN_TVL_USD),
                },
            }

            try:
                resp = requests.post(
                    config.BALANCER_GRAPHQL_URL,
                    json=payload,
                    timeout=config.REQUEST_TIMEOUT_S,
                )
                resp.raise_for_status()
                body = resp.json()
            except Exception:
                log.exception("  Balancer fetch failed for %s (skip=%d)", chain, skip)
                break

            pools = (body.get("data") or {}).get("poolGetPools") or []
            if not pools:
                break

            for pool in pools:
                dyn = pool.get("dynamicData") or {}
                pool_tvl = _float(dyn.get("totalLiquidity")) or 0.0
                volume_24h = _float(dyn.get("volume24h")) or 0.0
                pool_id = pool.get("id", "")
                pool_name = pool.get("name", "")
                tokens = pool.get("poolTokens") or []

                n_tokens = max(len(tokens), 1)
                for tok in tokens:
                    symbol = tok.get("symbol", "")
                    address = (tok.get("address") or "").lower()

                    rows.append({
                        "token_symbol": symbol,
                        "token_address": address,
                        "chain_id": chain,
                        "protocol": PROTOCOL,
                        "venue_type": VENUE_TYPE,
                        "tvl_usd": pool_tvl / n_tokens,
                        "volume_usd": volume_24h,
                        "pool_id": pool_id,
                        "pool_name": pool_name,
                    })

            if len(pools) < page_size:
                break
            skip += page_size
            time.sleep(config.REQUEST_DELAY_S)

        time.sleep(config.REQUEST_DELAY_S)

    log.info("Balancer: %d token-pool rows", len(rows))
    return pd.DataFrame(rows)


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
