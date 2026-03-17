# Storage Policies — ONyc Pipeline

Automated storage optimization for the ONyc pipeline database using TimescaleDB Hypercore.

## Policy Summary

| Policy Type | Count | Description |
|---|---|---|
| Columnstore (compression) | 52 | Converts cooled chunks to columnar storage |
| Tiered Storage (S3) | 49 | Moves old compressed chunks to object storage |
| Retention | 22 | Drops chunks beyond the retention window (CAGGs, mat tables, queue health only) |
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
| `src_acct_tickarray_tokendist` | 25000 query_ids (~8 days) | Integer-partitioned; heatmap needs 7D of prior snapshots locally |

### Database-level tiered read setting

Tiered reads must be enabled globally so that SQL functions can transparently
query S3-stored chunks:

```sql
ALTER DATABASE tsdb SET timescaledb.enable_tiered_reads = true;
```

Without this, queries against tiered chunks silently return empty results.
This is already applied on the ONyc pipeline database.

### Retention

| Layer | drop_after | Rationale |
|---|---|---|
| Source tables | **none** | Deferred until a long-term warehousing solution is decided; compression + tiered storage keeps disk manageable |
| CAGGs | 90 days | Matches the longest dashboard lookback window |
| Queue health | 90 days | Operational monitoring; 90D sufficient |
| Mat tables | 90 days | Matches max frontend lookback |

### Tables with integer-based tiering

These tables use query_id (integer) as their partition dimension and cannot use
the standard `add_tiering_policy()` which expects an INTERVAL. They are managed
via custom `policy_movechunk_to_s3` jobs configured with `alter_job()`.

| Table | move_after | Notes |
|---|---|---|
| `dexes.src_acct_tickarray_tokendist` | 25000 query_ids (~8 days) | Heatmap delta widget needs 7D of prior snapshots locally |
| `kamino_lend.src_obligations` | *(manual cleanup)* | No automated policy yet |

See `04_tiered_storage.sql` for operational commands to inspect and update these jobs.
