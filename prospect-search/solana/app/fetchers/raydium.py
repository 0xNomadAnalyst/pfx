"""
Raydium fetcher.
GET https://api-v3.raydium.io/pools/info/list  (paginated)

Returns a normalised DataFrame with two rows per pool (one per token in pair).
"""

import logging
import time

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Raydium"
VENUE_TYPE = "dex"
PAGE_SIZE = 1000  # max allowed by API


def fetch() -> pd.DataFrame:
    rows: list[dict] = []
    page = 1

    while True:
        params = {
            "poolType": "all",
            "poolSortField": "liquidity",
            "sortType": "desc",
            "pageSize": PAGE_SIZE,
            "page": page,
        }

        try:
            resp = requests.get(
                config.RAYDIUM_POOLS_URL,
                params=params,
                timeout=config.REQUEST_TIMEOUT_S,
            )
            resp.raise_for_status()
            body = resp.json()
        except Exception:
            log.exception("Raydium fetch failed (page=%d)", page)
            break

        data = body.get("data", body)
        pools = data.get("data", []) if isinstance(data, dict) else data
        if not pools:
            break

        below_threshold = 0
        for pool in pools:
            tvl = _float(pool.get("tvl") or pool.get("liquidity"))
            if tvl is None or tvl < config.MIN_TVL_USD:
                below_threshold += 1
                continue

            volume = _float(pool.get("volume24h") or pool.get("day", {}).get("volume")) or 0.0
            pool_id = pool.get("id", "")

            mint_a = pool.get("mintA", {})
            mint_b = pool.get("mintB", {})
            sym_a = mint_a.get("symbol", "") if isinstance(mint_a, dict) else ""
            sym_b = mint_b.get("symbol", "") if isinstance(mint_b, dict) else ""
            addr_a = mint_a.get("address", "") if isinstance(mint_a, dict) else str(mint_a)
            addr_b = mint_b.get("address", "") if isinstance(mint_b, dict) else str(mint_b)
            pool_name = f"{sym_a}/{sym_b}"

            for sym, addr, half_tvl in [
                (sym_a, addr_a, tvl / 2),
                (sym_b, addr_b, tvl / 2),
            ]:
                rows.append({
                    "token_symbol": sym,
                    "token_mint": addr,
                    "protocol": PROTOCOL,
                    "venue_type": VENUE_TYPE,
                    "tvl_usd": half_tvl,
                    "volume_usd": volume,
                    "pool_id": pool_id,
                    "pool_name": pool_name,
                })

        # Sorted by liquidity desc; once the majority are below threshold, stop.
        if below_threshold > len(pools) * 0.8:
            break

        has_more = data.get("hasNextPage", None)
        if has_more is False:
            break
        if len(pools) < PAGE_SIZE and has_more is None:
            break

        page += 1
        time.sleep(config.REQUEST_DELAY_S)

    log.info("Raydium: fetched %d token-pool rows across %d pages", len(rows), page)
    return pd.DataFrame(rows)


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
