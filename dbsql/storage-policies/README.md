# Storage Policies — ONyc Pipeline

Automated storage optimization for the ONyc pipeline database using TimescaleDB Hypercore.

## Policy Summary

| Policy Type | Count | Description |
|---|---|---|
| Columnstore (compression) | 52 | Converts cooled chunks to columnar storage |
| Tiered Storage (S3) | 49 | Moves old compressed chunks to object storage |
| Retention | 47 | Drops chunks beyond the retention window |
| CAGG Refresh | 18 | Prerequisite for CAGG columnstore policies |

## Files

| File | Purpose |
|---|---|
| `00_cagg_refresh_policies.sql` | Lightweight CAGG refresh policies (prerequisite for columnstore) |
| `01_source_columnstore.sql` | Columnstore settings for 14 source hypertables |
| `02_cagg_columnstore.sql` | Columnstore settings for 18 continuous aggregates |
| `03_mat_columnstore.sql` | Columnstore settings for 8 mat_* intermediate tables |
| `04_tiered_storage.sql` | Tiered storage policies (local SSD → S3) |
| `05_retention_policies.sql` | Data retention policies (drop old chunks) |

## Deployment Order

Run in numbered order. All scripts are idempotent (`if_not_exists`).

```bash
psql "$CONN" -f 00_cagg_refresh_policies.sql
psql "$CONN" -f 01_source_columnstore.sql
psql "$CONN" -f 02_cagg_columnstore.sql
psql "$CONN" -f 03_mat_columnstore.sql
psql "$CONN" -f 04_tiered_storage.sql
psql "$CONN" -f 05_retention_policies.sql
```

## Design Decisions

### Columnstore — segmentby strategy

Every hypertable uses its primary entity identifier as `segmentby` where one exists:

| Domain | segmentby column | Approx. cardinality |
|---|---|---|
| Dexes | `pool_address` | 2 |
| Exponent | `vault_address` / `market_address` / `mint_sy` | 1–3 |
| Kamino | `reserve_address` / `market_address` / `symbol` | 2–5 |
| Health | `schema_name` | 3–5 |

Low cardinality on segmentby yields excellent compression ratios (86%+ observed on `src_acct_vaults`) and enables segment-skip pruning where queries filter on the entity — which is the common access pattern for all frontend views.

All tables use `orderby = '<time_col> DESC'` to align with the descending-time access pattern of dashboard queries.

### Compression timing

| Layer | compress_after | Rationale |
|---|---|---|
| Source hypertables | 12 hours | Balance freshness for CAGG refresh reads vs. compression savings |
| CAGGs | 1 day | CAGGs are refreshed from source; 1-day lag is safe |
| Mat tables | 1 day | Active chunk stays in rowstore for fast upserts during 30s refresh |
| Queue health / hourly | 1–7 days | Low-volume operational data |

### Tiered storage schedule

| Layer | move_after | Rationale |
|---|---|---|
| Source tables | 30 days | Raw ingestion data cools fast; mat tables serve frontend |
| CAGGs | 60 days | Beyond 30D frontend lookback; still queryable from S3 |
| Mat tables | 60 days | 90D frontend lookback uses 1-day aggregation; tiered tail is slower but acceptable |

### Retention

| Layer | drop_after | Rationale |
|---|---|---|
| Source tables | 180 days | Double the max frontend lookback (90D); safety margin for backfill |
| CAGGs | 180 days | Matches source retention |
| Queue health | 90 days | Operational monitoring; 90D sufficient |
| Mat tables | 90 days | Matches max frontend lookback |

### Tables excluded from time-based policies

- `dexes.src_acct_tickarray_tokendist` — integer-partitioned (query_id), not time
- `kamino_lend.src_obligations` — integer-partitioned (query_id), not time

These need manual or integer-based cleanup.
