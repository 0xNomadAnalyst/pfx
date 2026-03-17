# ONyc DEX Pools — Historical Backfill

**Pools**: Orca Whirlpool ONyc-USDC, Raydium CLMM USDG-ONyc
**Programs**: Orca Whirlpool (`whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc`), Raydium CLMM (`CAMMCzo5YL8w4VFF8KVHr7wifJDrdMapkBEgnoSkgN3G`)
**Window**: 2025-05-19 → 2026-03-07
**Source**: Solscan Pro API v2

## Pools Covered

| Pool | Address | Protocol | Token Pair | Date Range | Transactions |
|------|---------|----------|------------|------------|-------------|
| ONyc-USDC | `7jhhyxPUKpu42hPGSYwgMXbR2dtVJHKhs8DW3sAAgAvX` | Orca Whirlpool | ONyc (9 dec) / USDC (6 dec) | 2025-05-19 → 2026-03-07 | 433,691 |
| USDG-ONyc | `A9RdNEf4T9x1eNPnEHFX1ABHS7J4e9kxBm43S3o5r9Kw` | Raydium CLMM | USDG (6 dec) / ONyc (9 dec) | 2025-07-07 → 2026-03-07 | 125,614 |

## Data Quality Summary

| Metric | Orca | Raydium | Combined |
|--------|------|---------|----------|
| Total signatures | 433,691 | 125,614 | 559,305 |
| Tx details fetched | 433,691 (100%) | 125,614 (100%) | 559,305 (100%) |
| Missing details | 0 | 0 | 0 |
| Duplicate rows | 0 | 0 | 0 |
| All status=1 (success) | ✓ | ✓ | ✓ |

## Folder Structure

```
data/
  transaction_details_orca_*.parquet      ← Solscan raw detail, Orca pool (142 MB)
  transaction_details_raydium_*.parquet   ← Solscan raw detail, Raydium pool (2.0 GB)
  defi_activities_orca_*.parquet          ← DeFi activity records, Orca (124 MB)
  defi_activities_raydium_*.parquet       ← DeFi activity records, Raydium (37 MB)
  src_tx_events_*.parquet                 ← UPLOAD TARGET (pending processing)

metadata/
  signatures_orca_*.json          ← 433,691 unique tx signatures
  signatures_raydium_*.json       ← 125,614 unique tx signatures
  activities_summary_orca_*.json  ← Orca activity type breakdown
  activities_summary_raydium_*.json ← Raydium activity type breakdown

config/
  pools_config_onyc.json          ← pool addresses, token mints, decimals

scripts/
  refetch_missing.py              ← gap-fill tool for missing signatures
  verify_backfill_completeness.py ← data integrity verification

qa/
  onyc_qa_batch_summary.json      ← combined batch QA summary
  qa_onyc_summary_12h_mar13.json  ← 12h ingestion-vs-Solscan test (Mar 12-13)
  qa_onyc_0000_0430.json          ← 5× 4.5h window QA tests (Mar 6)
  qa_onyc_0430_0900.json
  qa_onyc_0900_1330.json
  qa_onyc_1330_1800.json
  qa_onyc_1800_2230.json
```

## Collection Notes

- Orca pool deployment detected at May 19, 2025; Raydium at Jul 7, 2025
  (via Solscan `/account/defi/activities` — RPC history window was too short).
- Initial Orca collection ran ~7h before Solscan API credits exhausted at
  batch 5,001/7,994. New API key minted, resumed via checkpointing.
- Power outage during Orca fetch caused DNS resolution hang at batch 674;
  process killed and restarted, resumed cleanly from checkpoint.
- Post-collection verification found 94,304 Orca + 1,850 Raydium signatures
  missing (429-error batches marked as fetched in checkpoint). All recovered
  via targeted refetch. Final 336 Orca sigs recovered in a second pass.
- All data verified 2026-03-09: 0 gaps, 0 duplicates, 100% coverage.

## Next Steps

1. Process raw transactions into structured `src_tx_events`:
   ```bash
   BACKFILL_POOLS_CONFIG=pfx/pools_config_onyc.json \
   python dexes/backfill-qa/process_transactions.py \
     --input-dir pfx/backfill-onyc-dex-20250519-20260307/data \
     --output-dir pfx/backfill-onyc-dex-20250519-20260307/data
   ```
2. Run QA balance reconstruction checks
3. Upload to DB: `data/src_tx_events_*.parquet` → `{schema}.src_tx_events`

**Do NOT upload until QA reconstruction checks pass.**
