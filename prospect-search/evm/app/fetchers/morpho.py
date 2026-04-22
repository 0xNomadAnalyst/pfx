"""
Morpho Blue lending fetcher — native GraphQL API.

POST https://blue-api.morpho.org/graphql
Queries markets with loanAsset + collateralAsset details.
Emits two rows per market (one for loanAsset, one for collateralAsset).
"""

import logging
import time

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Morpho"
VENUE_TYPE = "lending"

# Per-market TVL cap — some Morpho markets (e.g. GMORPHO reward vaults)
# report inflated supplyAssetsUsd that exceed the entire protocol's real TVL.
_MAX_MARKET_TVL = 5_000_000_000  # $5B

_QUERY = """
query GetMarkets($chainIds: [Int!], $first: Int!, $skip: Int!) {
  markets(
    where: {chainId_in: $chainIds}
    first: $first
    skip: $skip
  ) {
    items {
      uniqueKey
      loanAsset {
        address
        symbol
        name
      }
      collateralAsset {
        address
        symbol
        name
      }
      state {
        supplyAssetsUsd
        borrowAssetsUsd
      }
      morphoBlue {
        chain {
          id
        }
      }
    }
    pageInfo {
      countTotal
    }
  }
}
"""


def fetch() -> pd.DataFrame:
    chain_ids = [config.CHAIN_ID_MAP[c] for c in config.TARGET_CHAINS if c in config.CHAIN_ID_MAP]
    rows: list[dict] = []
    skip = 0
    page_size = 1000

    while True:
        payload = {
            "query": _QUERY,
            "variables": {
                "chainIds": chain_ids,
                "first": page_size,
                "skip": skip,
            },
        }

        try:
            resp = requests.post(
                config.MORPHO_GRAPHQL_URL,
                json=payload,
                timeout=config.REQUEST_TIMEOUT_S,
            )
            resp.raise_for_status()
            body = resp.json()
        except Exception:
            log.exception("Morpho fetch failed (skip=%d)", skip)
            break

        items = ((body.get("data") or {}).get("markets") or {}).get("items") or []
        if not items:
            break

        for market in items:
            state = market.get("state") or {}
            tvl = _float(state.get("supplyAssetsUsd")) or 0.0
            if tvl < config.MIN_TVL_USD:
                continue
            if tvl > _MAX_MARKET_TVL:
                continue

            market_id = market.get("uniqueKey", "")
            chain_obj = (market.get("morphoBlue") or {}).get("chain") or {}
            chain_num = chain_obj.get("id", 0)
            chain = config.CHAIN_ID_TO_NAME.get(chain_num, str(chain_num))

            loan = market.get("loanAsset") or {}
            collateral = market.get("collateralAsset") or {}

            loan_sym = loan.get("symbol", "")
            coll_sym = collateral.get("symbol", "")
            pool_name = f"{coll_sym}/{loan_sym}"

            for asset, role in [(loan, "loan"), (collateral, "collateral")]:
                sym = asset.get("symbol", "")
                addr = (asset.get("address") or "").lower()
                if not sym:
                    continue
                rows.append({
                    "token_symbol": sym,
                    "token_address": addr,
                    "chain_id": chain,
                    "protocol": PROTOCOL,
                    "venue_type": VENUE_TYPE,
                    "tvl_usd": tvl / 2,
                    "volume_usd": 0.0,
                    "pool_id": market_id,
                    "pool_name": pool_name,
                })

        if len(items) < page_size:
            break
        skip += page_size
        time.sleep(config.REQUEST_DELAY_S)

    log.info("Morpho: %d token-market rows", len(rows))
    return pd.DataFrame(rows)


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
