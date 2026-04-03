"""
Kamino Lending fetcher.

Step 1: GET /v2/kamino-market  -> list of lending markets
Step 2: GET /kamino-market/{pubkey}/reserves/metrics  per market

Returns one row per reserve (one token per reserve).
"""

import logging
import time

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Kamino"
VENUE_TYPE = "lending"


def fetch() -> pd.DataFrame:
    markets = _fetch_markets()
    if not markets:
        log.warning("Kamino: no markets returned")
        return pd.DataFrame()

    rows: list[dict] = []
    for mkt in markets:
        pubkey = mkt.get("lendingMarket", "")
        market_name = mkt.get("name", "")
        if not pubkey:
            continue

        reserves = _fetch_reserves(pubkey)
        for res in reserves:
            total_supply_usd = _float(res.get("totalSupplyUsd")) or 0.0
            if total_supply_usd < config.MIN_TVL_USD:
                continue

            rows.append({
                "token_symbol": res.get("liquidityToken", ""),
                "token_mint": res.get("liquidityTokenMint", ""),
                "protocol": PROTOCOL,
                "venue_type": VENUE_TYPE,
                "tvl_usd": total_supply_usd,
                "volume_usd": 0.0,  # lending reserves don't have a volume metric
                "pool_id": res.get("reserve", ""),
                "pool_name": f"{res.get('liquidityToken', '?')} ({market_name})",
            })

        time.sleep(config.REQUEST_DELAY_S)

    log.info("Kamino: fetched %d reserve rows across %d markets", len(rows), len(markets))
    return pd.DataFrame(rows)


def _fetch_markets() -> list[dict]:
    try:
        resp = requests.get(
            config.KAMINO_MARKETS_URL,
            timeout=config.REQUEST_TIMEOUT_S,
        )
        resp.raise_for_status()
        return resp.json()
    except Exception:
        log.exception("Kamino markets list failed")
        return []


def _fetch_reserves(pubkey: str) -> list[dict]:
    url = config.KAMINO_RESERVES_URL.format(pubkey=pubkey)
    try:
        resp = requests.get(url, timeout=config.REQUEST_TIMEOUT_S)
        resp.raise_for_status()
        return resp.json()
    except Exception:
        log.exception("Kamino reserves fetch failed for market %s", pubkey)
        return []


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
