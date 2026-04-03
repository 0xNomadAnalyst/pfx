"""
Orca Whirlpool fetcher.
GET https://api.orca.so/v2/solana/pools  (paginated)

Returns a normalised DataFrame with two rows per pool (one per token in the pair).
"""

import logging
import time

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Orca"
VENUE_TYPE = "dex"


def fetch() -> pd.DataFrame:
    rows: list[dict] = []
    cursor: str | None = None

    while True:
        params: dict = {
            "sortBy": "tvl",
            "sortDirection": "desc",
            "minTvl": str(config.MIN_TVL_USD),
            "size": 100,
            "stats": "24h",
        }
        if cursor:
            params["next"] = cursor

        try:
            resp = requests.get(
                config.ORCA_POOLS_URL,
                params=params,
                timeout=config.REQUEST_TIMEOUT_S,
            )
            resp.raise_for_status()
            body = resp.json()
        except Exception:
            log.exception("Orca fetch failed (cursor=%s)", cursor)
            break

        pools = body.get("data", [])
        if not pools:
            break

        for pool in pools:
            tvl = _float(pool.get("tvlUsdc"))
            if tvl is None or tvl < config.MIN_TVL_USD:
                continue

            volume = _volume_24h(pool)
            pool_addr = pool.get("address", "")

            token_a = pool.get("tokenA", {})
            token_b = pool.get("tokenB", {})
            pool_name = f"{token_a.get('symbol', '?')}/{token_b.get('symbol', '?')}"

            for tok, half_tvl in [(token_a, tvl / 2), (token_b, tvl / 2)]:
                rows.append({
                    "token_symbol": tok.get("symbol", ""),
                    "token_mint": tok.get("address", ""),
                    "protocol": PROTOCOL,
                    "venue_type": VENUE_TYPE,
                    "tvl_usd": half_tvl,
                    "volume_usd": volume,
                    "pool_id": pool_addr,
                    "pool_name": pool_name,
                })

        meta = body.get("meta") or {}
        cursor_obj = meta.get("cursor") or meta
        cursor = cursor_obj.get("next")
        if not cursor:
            break
        time.sleep(config.REQUEST_DELAY_S)

    log.info("Orca: fetched %d token-pool rows from %d pages", len(rows), max(1, len(rows) // 200 + 1))
    return pd.DataFrame(rows)


def _volume_24h(pool: dict) -> float:
    stats = pool.get("stats") or {}
    day = stats.get("24h") or stats.get("1d") or {}
    return _float(day.get("volume")) or 0.0


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
