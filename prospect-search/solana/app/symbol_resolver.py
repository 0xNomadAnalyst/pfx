"""
Solana token symbol resolution via on-chain Metaplex metadata.

Standalone module with no dependencies outside the Python standard library
plus ``requests`` and ``solders``.  Designed as a self-contained fallback for
tokens whose symbols cannot be determined from protocol APIs alone (e.g.
newer Exponent yield markets that ship with empty ptTicker / ptName).

Usage:
    from symbol_resolver import resolve_metaplex_symbols

    result = resolve_metaplex_symbols(["mintAddr1", "mintAddr2"])
    # -> {"mintAddr1": {"symbol": "FOO", "name": "Foo Token"}, ...}
"""

import base64
import logging
import struct

import requests
from solders.pubkey import Pubkey  # type: ignore[import-untyped]

log = logging.getLogger(__name__)

_TOKEN_METADATA_PROGRAM = Pubkey.from_string(
    "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"
)

_DEFAULT_RPC = "https://api.mainnet-beta.solana.com"


def resolve_metaplex_symbols(
    mint_addresses: list[str],
    rpc_url: str = _DEFAULT_RPC,
    timeout: int = 10,
) -> dict[str, dict[str, str]]:
    """
    Resolve token symbols and names from on-chain Metaplex Token Metadata PDAs.

    Requires only a public Solana JSON-RPC endpoint (no API key).

    Args:
        mint_addresses: Token mint addresses to look up.
        rpc_url: Solana JSON-RPC endpoint.
        timeout: Per-request timeout in seconds.

    Returns:
        ``{mint: {"symbol": ..., "name": ...}}`` for successfully resolved
        mints.  Mints that cannot be resolved are silently omitted.
    """
    results: dict[str, dict[str, str]] = {}

    for mint_str in mint_addresses:
        try:
            mint_pk = Pubkey.from_string(mint_str)
            pda, _ = Pubkey.find_program_address(
                [b"metadata", bytes(_TOKEN_METADATA_PROGRAM), bytes(mint_pk)],
                _TOKEN_METADATA_PROGRAM,
            )

            payload = {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "getAccountInfo",
                "params": [str(pda), {"encoding": "base64"}],
            }
            resp = requests.post(rpc_url, json=payload, timeout=timeout)
            resp.raise_for_status()

            value = resp.json().get("result", {}).get("value")
            if not value or not value.get("data"):
                continue

            raw = base64.b64decode(value["data"][0])
            symbol, name = _parse_metaplex_metadata(raw)
            if symbol:
                results[mint_str] = {"symbol": symbol, "name": name}

        except Exception as exc:
            log.debug("Metaplex resolve failed for %s: %s", mint_str[:20], exc)

    log.info(
        "Metaplex symbol resolution: %d/%d mints resolved",
        len(results),
        len(mint_addresses),
    )
    return results


def _parse_metaplex_metadata(raw: bytes) -> tuple[str, str]:
    """
    Parse name and symbol from a raw Metaplex Token Metadata account.

    Layout:  key(1) + update_authority(32) + mint(32) = 65 byte header,
    then borsh-serialised string fields: name (len-prefixed u32),
    symbol (len-prefixed u32), uri (len-prefixed u32).
    """
    offset = 65  # skip header

    name_len = struct.unpack_from("<I", raw, offset)[0]
    offset += 4
    name = raw[offset : offset + name_len].decode("utf-8", errors="ignore").rstrip("\x00").strip()
    offset += name_len

    symbol_len = struct.unpack_from("<I", raw, offset)[0]
    offset += 4
    symbol = raw[offset : offset + symbol_len].decode("utf-8", errors="ignore").rstrip("\x00").strip()

    return symbol, name
