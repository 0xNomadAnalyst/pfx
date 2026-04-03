"""
Exponent yield-tokenisation fetcher.
GET https://web-api.exponent.finance/api/markets

Returns one row per market, keyed on the underlying asset (vault.mintAsset).

Symbol resolution strategy (in priority order):
  1. vault.underlyingSymbol / vault.assetSymbol  (rarely present)
  2. Extracted from metadata.ptTicker  (e.g. "PT-mUSDC" -> "mUSDC")
  3. Extracted from metadata.ptName    (e.g. "PT-xSOL-14JUN25" -> "xSOL")
  4. Cross-fetcher backfill in main.py (Orca/Raydium/Meteora/Kamino data)
  5. Falls back to empty string — the aggregator resolves from other protocols

Many newer Exponent markets ship with empty ptTicker/ptName.  The cross-fetcher
backfill (step 4) is the main mechanism that resolves these, using the mint→symbol
mapping already available from the DEX and lending fetchers.
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

    # Pass 1: collect all markets and build a mint→symbol map from those that
    # DO have ptTicker, so we can share it with markets that don't.
    mint_symbol_map: dict[str, str] = {}
    for mkt in markets:
        vault = mkt.get("vault", {})
        metadata = mkt.get("metadata", {})
        mint = vault.get("mintAsset") or vault.get("quoteMint") or ""
        sym = (
            vault.get("underlyingSymbol")
            or vault.get("assetSymbol")
            or _symbol_from_metadata(metadata)
            or ""
        )
        if mint and sym and mint not in mint_symbol_map:
            mint_symbol_map[mint] = sym

    # Pass 2: build rows, using the map for markets missing symbols.
    rows: list[dict] = []
    for mkt in markets:
        vault = mkt.get("vault", {})
        stats = mkt.get("stats", {})
        metadata = mkt.get("metadata", {})

        tvl = _float(stats.get("liquidityPoolTvl"))
        if tvl is not None:
            tvl = tvl / (10 ** (vault.get("decimals", 6)))
        if tvl is None or tvl < config.MIN_TVL_USD:
            continue

        volume_raw = _float(stats.get("totalVolumeInAsset")) or 0.0
        volume = volume_raw / (10 ** (vault.get("decimals", 6)))

        underlying_mint = vault.get("mintAsset") or vault.get("quoteMint") or ""
        underlying_symbol = (
            vault.get("underlyingSymbol")
            or vault.get("assetSymbol")
            or _symbol_from_metadata(metadata)
            or mint_symbol_map.get(underlying_mint, "")
        )

        platform = vault.get("platform", "")
        market_name = _build_market_name(metadata, vault, underlying_symbol, platform)

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

    log.info("Exponent: fetched %d market rows (%d with symbol, %d without)",
             len(rows),
             sum(1 for r in rows if r["token_symbol"]),
             sum(1 for r in rows if not r["token_symbol"]))
    return pd.DataFrame(rows)


def _symbol_from_metadata(metadata: dict) -> str | None:
    """Extract underlying symbol from ptTicker or ptName."""
    pt_ticker = metadata.get("ptTicker", "")
    if pt_ticker.startswith("PT-"):
        return pt_ticker[3:]

    pt_name = metadata.get("ptName", "")
    if pt_name.startswith("PT-"):
        # "PT-xSOL-14JUN25" -> "xSOL"
        parts = pt_name[3:].split("-")
        if parts:
            return parts[0]

    return None


def _build_market_name(metadata: dict, vault: dict, symbol: str, platform: str) -> str:
    """
    Build an informative market name even when ptName/ptTicker are empty.
    """
    pt_name = metadata.get("ptName") or metadata.get("ptTicker") or ""
    if pt_name:
        return f"{pt_name} ({platform})" if platform else pt_name

    nice_name = vault.get("niceName", "")
    if nice_name:
        return f"{nice_name} ({platform})" if platform else nice_name

    # Fallback: construct from symbol and platform
    if symbol and platform:
        return f"{symbol} yield ({platform})"
    if platform:
        return f"yield ({platform})"
    return ""


def _float(val) -> float | None:
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
