# ONyc Kamino Lend — Historical Backfill

**Market**: `47tfyEG9SsdEnUm9cw5kY9BXngQGqu3LBoop9j5uTAv8`
**Program**: Kamino Lend (`KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD`)
**Window**: 2025-07-15 → 2026-03-05 (epoch 1752537600–1772755199)
**Source**: Solscan Pro API v2

## Reserves Covered

| Reserve | Address | Symbol | Decimals | Start Date |
|---------|---------|--------|----------|------------|
| USDC | `AYL4LMc4ZCVyq3Z7XPJGWDM4H9PiWjqXAAuuHBEGVR2Z` | USDC | 6 | 2025-07-24 |
| USDG | `JBmLCoKqjdKSStK45onRqe6U6sxVgSpdXoeXe4h7NwJw` | USDG | 6 | 2025-08-04 |
| ONyc | `6ZxkBSJEqsXA3Kdm2PDAzHLUdPTPUK93Lf4bAezec1UQ` | ONyc | 9 | 2025-07-24 |
| USDS | `3yDc9ARvtPLhYxZLgucZGuBtZ9bHshBvXTwHxGe3nhmC` | USDS | 6 | 2025-09-12 |
| AUSD | `3JmDtKLsCmBsns4e5svC1tpxEEd79Bk2SpoYFwVGxqwU` | AUSD | 6 | 2025-08-04 |

## Data Quality Summary

| Metric | Value |
|--------|-------|
| Total signatures | 526,854 |
| Tx details fetched | 526,854 (100%) |
| Missing details | 0 |
| Decoded events | 200,587 |
| Failed transactions | 3,963 (2.0%) |
| Unknown instructions | 0 |
| Instruction types | 16 |

## Folder Structure

```
data/
  src_txn_events_*.parquet   ← UPLOAD TARGET: decoded Kamino instruction events (58 MB)
  src_txn_*.parquet          ← UPLOAD TARGET: raw transaction records (2.2 GB)
  transaction_details_*.parquet  ← Solscan raw detail data, for reference (2.8 GB)
  account_transactions_*.parquet ← Solscan account-level tx index (61 MB)

metadata/
  account_coverage_*.json    ← per-reserve collection coverage stats
  signatures_*.json          ← 526,854 unique tx signatures
  tracked_accounts_*.json    ← 5 tracked reserve accounts

config/
  discovery_config_onyc_kamino.json  ← reserve addresses, mints, vaults

scripts/
  run_onyc_kamino_backfill.py   ← main collection runner
  repair_usdc_gap.py            ← USDC gap repair (Oct 14 cursor resume)
```

## Collection Notes

- Initial collection ran ~15h (Mar 7–8, 2026). USDC sig walkback hit a Solscan
  502 at Oct 14 2025, leaving a Jul–Oct gap with only cross-account captures.
- Ran out of Solscan API credits at batch 5,095/10,443 during detail fetch.
  New API key minted, resumed with checkpointing code.
- USDC gap repaired via cursor-based resume from oldest known sig, adding 5,118
  new tx details. Verified: daily USDC events at Oct 14 went from 47 → 149
  (smooth transition, no discontinuity).
- AUSD (Aug 4) and USDS (Sep 12) start dates are genuine reserve deployment
  dates, confirmed by first-event analysis.
- 12 zero-event days for USDC in Jul–Aug are genuine low-activity in the
  early post-deployment period (market had 2 events on its first day).

## Upload Targets

For backfilling to the pfx TimescaleDB:
- `data/src_txn_events_1752537600_1772755199.parquet` → `{schema}.src_txn_events`
- `data/src_txn_1752537600_1772755199.parquet` → `{schema}.src_txn`
