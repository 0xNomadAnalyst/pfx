# ONyc Exponent — Historical Backfill

**Token**: ONyc (wONyc SY mint `G1qbuP11CdquJCzuDjruWqatQAHroajmxhLfeQVgHosF`)
**Program**: Exponent Core (`expJNkiTqnQaxGCTZfRi3GNPxSZkpSoamiutqHqVzWL`)
**Window**: 2025-08-18 → 2026-03-08 (epoch 1755475200–1772841600)
**Source**: Solscan Pro API v2

## Vaults Covered

| Vault | Address | Market | Status | Period | Protocol Events |
|-------|---------|--------|--------|--------|-----------------|
| V1 | `4qprmHpgscYUDfUKBEs52TZe1sZCGpBUvNeitaNTCCAU` | `68mFWWL25B5uGjpZJwJh84WnaDXyhjA68RN3R3hssPH5` | Expired | Aug 27 2025 – Jan 25 2026 | 26,245 |
| V2 | `J2apQJvzq1yuhBoa1mVwAXr3P5oEzFaCVohq1GQMcW2c` | `8QJRc12BDXHRLghZXFyPtYtAQeRwnZGKMJQa3G2NVQoC` | Active  | Jan 12 2026 – ongoing     | 10,241 |

## Data Quality Summary

| Metric | Value |
|--------|-------|
| Total signatures | 26,753 |
| Tx details fetched | 26,753 (100%) |
| Missing details | 0 |
| Protocol events | 103,940 |
| Failed transactions | 0 (0.0%) |
| Instruction types | 13 |
| Non-Exponent SPL transfers | 822 |

## Folder Structure

```
data/
  src_tx_events_*.parquet          ← UPLOAD TARGET: decoded Exponent events (16 MB)
  src_txns_*.parquet               ← UPLOAD TARGET: raw transaction records (250 MB)
  transaction_details_*.parquet    ← Solscan raw detail data, for reference (285 MB)

metadata/
  account_coverage_*.json          ← per-mint collection coverage stats
  signatures_*.json                ← 26,753 unique tx signatures
  tracked_accounts_*.json          ← 11 tracked vault/market/mint accounts

config/
  discovery_config_onyc_exponent.json  ← vault addresses, mints, base token
```

## Collection Notes

- Signatures collected from Solscan `token/transfer` endpoint for all 8 mints
  (SY, PT×2, YT×2, LP×2) across both vaults.
- Initial collection used SY mint transfers (25,424 sigs). QA review discovered
  1,329 additional signatures from PT/YT/LP mint scans not visible via SY.
  Of these, 522 were Exponent protocol txns (adding 2,476 events, predominantly
  LP deposit/withdraw) and 807 were pure SPL token transfers.
- Power cut during detail fetch required resume with checkpointing; 15 single-tx
  recoveries via the individual detail endpoint, all confirmed as non-protocol
  SPL transfers.
- Early period (Aug 18 – Sep 4, 2025) has genuine multi-day gaps — V1 vault had
  just launched with minimal TVL (28 txns in first 10 days).
- V2 vault opened Jan 12 2026, shortly before V1 matured Jan 25 2026.

## Upload Targets

For backfilling to the pfx TimescaleDB:
- `data/src_tx_events_1755475200_1772841600.parquet` → `exponent.src_tx_events`
- `data/src_txns_1755475200_1772841600.parquet` → `exponent.src_txns`
