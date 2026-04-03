"""
Meteora DLMM fetcher.
GET https://dlmm.datapi.meteora.ag/pools  (paginated, 1-based)

Returns a normalised DataFrame with two rows per pool (one per token in pair).

Note: Meteora has ~100k+ pools. We cannot sort by TVL server-side, so we
fetch pages until the fraction below threshold is high enough to stop, or
until a reasonable page cap is reached.
"""

import logging
import time

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Meteora"
VENUE_TYPE = "dex"
PAGE_SIZE = 500
API_URL = "https://dlmm.datapi.meteora.ag/pools"
MAX_PAGES = 40  # safety cap; 500 * 40 = 20k pools scanned


def fetch() -> pd.DataFrame:
    rows: list[dict] = []
    page = 1

    while page <= MAX_PAGES:
        params: dict = {
            "page": page,
            "limit": PAGE_SIZE,
        }

        try:
            resp = requests.get(
                API_URL,
                params=params,
                timeout=config.REQUEST_TIMEOUT_S,
            )
            resp.raise_for_status()
            body = resp.json()
        except Exception:
            log.exception("Meteora fetch failed (page=%d)", page)
            break

        pools = body.get("data", [])
        total_pages = body.get("pages", 1)
        if not pools:
            break

        below_threshold = 0
        for pool in pools:
            tvl = _float(pool.get("tvl"))
            if tvl is None or tvl < config.MIN_TVL_USD:
                below_threshold += 1
                continue

            vol_obj = pool.get("volume") or {}
            volume = _float(vol_obj.get("24h")) or 0.0 if isinstance(vol_obj, dict) else _float(vol_obj) or 0.0

            pool_addr = pool.get("address", "")
            pool_name = pool.get("name", "")

            tok_x = pool.get("token_x") or {}
            tok_y = pool.get("token_y") or {}

            for tok, half_tvl in [(tok_x, tvl / 2), (tok_y, tvl / 2)]:
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

        if page >= total_pages:
            break

        # Early exit: if 95%+ of pools on this page are below threshold, stop
        if len(pools) > 0 and below_threshold / len(pools) > 0.95:
            log.info("Meteora: stopping early at page %d (%.0f%% below threshold)",
                     page, 100 * below_threshold / len(pools))
            break

        page += 1
        time.sleep(config.REQUEST_DELAY_S)

    log.info("Meteora: fetched %d token-pool rows across %d pages", len(rows), page)
    return pd.DataFrame(rows)


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
