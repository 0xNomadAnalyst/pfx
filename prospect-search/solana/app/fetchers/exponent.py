"""
Exponent yield-tokenisation fetcher.
GET https://web-api.exponent.finance/api/markets

Returns one row per market, keyed on the underlying asset (vault.mintAsset).
"""

import logging

import pandas as pd
import requests

import config

log = logging.getLogger(__name__)

PROTOCOL = "Exponent"
VENUE_TYPE = "yield"


def fetch() -> pd.DataFrame:
    try:
        resp = requests.get(
            config.EXPONENT_MARKETS_URL,
            timeout=config.REQUEST_TIMEOUT_S,
        )
        resp.raise_for_status()
        body = resp.json()
    except Exception:
        log.exception("Exponent fetch failed")
        return pd.DataFrame()

    markets = body.get("data", body) if isinstance(body, dict) else body
    if not isinstance(markets, list):
        log.warning("Exponent: unexpected response type %s", type(markets))
        return pd.DataFrame()

    rows: list[dict] = []
    for mkt in markets:
        vault = mkt.get("vault", {})
        stats = mkt.get("stats", {})
        metadata = mkt.get("metadata", {})

        tvl = _float(stats.get("liquidityPoolTvl"))
        if tvl is not None:
            tvl = tvl / (10 ** (vault.get("decimals", 6)))  # raw -> normalised
        if tvl is None or tvl < config.MIN_TVL_USD:
            continue

        volume_raw = _float(stats.get("totalVolumeInAsset")) or 0.0
        volume = volume_raw / (10 ** (vault.get("decimals", 6)))

        underlying_mint = vault.get("mintAsset") or vault.get("quoteMint") or ""
        underlying_symbol = (
            vault.get("underlyingSymbol")
            or vault.get("assetSymbol")
            or _symbol_from_pt_ticker(metadata.get("ptTicker", ""))
            or ""
        )

        market_name = metadata.get("ptName") or metadata.get("ptTicker") or vault.get("niceName") or ""
        platform = vault.get("platform", "")
        if platform:
            market_name = f"{market_name} ({platform})"

        rows.append({
            "token_symbol": underlying_symbol,
            "token_mint": underlying_mint,
            "protocol": PROTOCOL,
            "venue_type": VENUE_TYPE,
            "tvl_usd": tvl,
            "volume_usd": volume,
            "pool_id": mkt.get("id", ""),
            "pool_name": market_name,
        })

    log.info("Exponent: fetched %d market rows", len(rows))
    return pd.DataFrame(rows)


def _symbol_from_pt_ticker(pt_ticker: str) -> str | None:
    """Extract underlying symbol from PT ticker like 'PT-mUSDC' -> 'mUSDC'."""
    if pt_ticker.startswith("PT-"):
        return pt_ticker[3:]
    return None


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
