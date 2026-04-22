"""
Pendle yield-tokenization fetcher — native REST API.

GET https://api-v2.pendle.finance/core/v2/markets/all
Paginated with limit/skip.  Parses underlyingAsset ("chainId-address")
to extract chain and token address.
"""

import logging
import time

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Pendle"
VENUE_TYPE = "yield"

_TARGET_CHAIN_IDS = set(config.CHAIN_ID_MAP.values())


def fetch() -> pd.DataFrame:
    rows: list[dict] = []
    skip = 0
    page_size = 100

    while True:
        params = {"limit": page_size, "skip": skip}
        try:
            resp = requests.get(
                config.PENDLE_MARKETS_URL,
                params=params,
                timeout=config.REQUEST_TIMEOUT_S,
            )
            resp.raise_for_status()
            body = resp.json()
        except Exception:
            log.exception("Pendle fetch failed (skip=%d)", skip)
            break

        results = body.get("results") or body if isinstance(body, list) else body.get("results", [])
        if not results:
            break

        for market in results:
            tvl = _float((market.get("details") or {}).get("totalTvl")) or _float(market.get("liquidity", {}).get("usd")) or 0.0
            if tvl < config.MIN_TVL_USD:
                continue

            underlying_raw = market.get("underlyingAsset", "")
            chain_id_num, token_address = _parse_underlying(underlying_raw)

            if chain_id_num not in _TARGET_CHAIN_IDS:
                continue

            chain = config.CHAIN_ID_TO_NAME.get(chain_id_num, str(chain_id_num))
            symbol = market.get("name", "") or market.get("underlyingAsset", {}) if isinstance(market.get("underlyingAsset"), dict) else ""

            if isinstance(market.get("underlyingAsset"), dict):
                ua = market["underlyingAsset"]
                symbol = ua.get("symbol", "") or ua.get("name", "")
                token_address = (ua.get("address") or "").lower()
                chain_id_raw = ua.get("chainId", 0)
                if isinstance(chain_id_raw, int) and chain_id_raw in _TARGET_CHAIN_IDS:
                    chain_id_num = chain_id_raw
                    chain = config.CHAIN_ID_TO_NAME.get(chain_id_num, str(chain_id_num))

            if not symbol or isinstance(symbol, dict):
                symbol = market.get("name", "")

            market_addr = market.get("address", "")
            pool_name = f"Pendle {symbol}" if symbol else f"Pendle {market_addr[:12]}"

            rows.append({
                "token_symbol": symbol,
                "token_address": token_address,
                "chain_id": chain,
                "protocol": PROTOCOL,
                "venue_type": VENUE_TYPE,
                "tvl_usd": tvl,
                "volume_usd": 0.0,
                "pool_id": market_addr,
                "pool_name": pool_name,
            })

        if len(results) < page_size:
            break
        skip += page_size
        time.sleep(config.REQUEST_DELAY_S)

    log.info("Pendle: %d market rows", len(rows))
    return pd.DataFrame(rows)


def _parse_underlying(raw: str) -> tuple[int, str]:
    """
    Parse Pendle's underlyingAsset string format: "chainId-0xAddress".
    Returns (chain_id_int, lowercase_address).
    """
    if not raw or not isinstance(raw, str) or "-" not in raw:
        return (0, "")
    parts = raw.split("-", 1)
    try:
        chain_id = int(parts[0])
    except ValueError:
        return (0, "")
    address = parts[1].lower() if len(parts) > 1 else ""
    return (chain_id, address)


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
