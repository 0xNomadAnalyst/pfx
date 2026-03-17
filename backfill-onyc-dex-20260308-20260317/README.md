# ONyc DEX Backfill (Incremental Window)

Window: `2026-03-08` to `2026-03-17` (UTC)

This folder mirrors the prior ONyc DEX pull layout:

- `config/`: pool config used for collection
- `data/`: parquet artifacts and transaction detail outputs
- `metadata/`: signatures and activity summaries
- `scripts/`: helper scripts copied from the prior run

Protocols targeted:

- Raydium pool key: `raydium_clmm_usdg_onyc`
- Orca pool key: `orca_whirlpool_onyc_usdc`

Notes:

- Raydium collection completed successfully.
- Orca collection is running and writing checkpointed batch files in `data/`.
