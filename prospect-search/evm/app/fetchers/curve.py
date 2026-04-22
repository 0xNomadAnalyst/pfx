"""
Curve DEX fetcher.

GET https://api.curve.finance/v1/getPools/all/{chain}
for each target chain.  Emits one row per coin per pool.
"""

import logging
import time

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Curve"
VENUE_TYPE = "dex"

_CURVE_CHAIN_IDS = {
    "ethereum": "ethereum",
    "arbitrum": "arbitrum",
    "base": "base",
    "optimism": "optimism",
    "polygon": "polygon",
}


def fetch() -> pd.DataFrame:
    rows: list[dict] = []

    for chain in config.TARGET_CHAINS:
        chain_slug = _CURVE_CHAIN_IDS.get(chain, chain)
        url = config.CURVE_POOLS_URL.format(chain=chain_slug)
        log.info("  Curve [%s] ...", chain)

        try:
            resp = requests.get(url, timeout=config.REQUEST_TIMEOUT_S)
            resp.raise_for_status()
            body = resp.json()
        except Exception:
            log.exception("  Curve fetch failed for %s", chain)
            time.sleep(config.REQUEST_DELAY_S)
            continue

        pool_data = (body.get("data") or {}).get("poolData") or []

        for pool in pool_data:
            pool_tvl = _float(pool.get("usdTotal")) or 0.0
            if pool_tvl < config.MIN_TVL_USD:
                continue

            pool_id = pool.get("address", pool.get("id", ""))
            pool_name = pool.get("name", "")
            coins = pool.get("coins", [])
            volume_raw = _float(pool.get("volumeUSD")) or 0.0

            for coin in coins:
                symbol = coin.get("symbol", "")
                address = (coin.get("address") or "").lower()
                decimals = int(coin.get("decimals", 18))
                balance_raw = _float(coin.get("poolBalance")) or 0.0
                usd_price = _float(coin.get("usdPrice")) or 0.0

                token_tvl = (balance_raw / (10 ** decimals)) * usd_price if decimals else 0.0

                rows.append({
                    "token_symbol": symbol,
                    "token_address": address,
                    "chain_id": chain,
                    "protocol": PROTOCOL,
                    "venue_type": VENUE_TYPE,
                    "tvl_usd": token_tvl,
                    "volume_usd": volume_raw,
                    "pool_id": pool_id,
                    "pool_name": pool_name or f"Curve pool {pool_id[:10]}",
                })

        time.sleep(config.REQUEST_DELAY_S)

    log.info("Curve: %d token-pool rows across %d chains", len(rows), len(config.TARGET_CHAINS))
    return pd.DataFrame(rows)


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
