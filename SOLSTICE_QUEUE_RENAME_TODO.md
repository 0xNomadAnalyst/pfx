# Solstice Pipeline — Queue Rename Deferred Tasks

These tasks must be completed **after** the updated service code is deployed to the Solstice pipeline.
The ONyc pipeline equivalent changes have already been applied.

---

## Background

All service code (dexes, exponent, kamino, solstice-prop) has been updated:
- `CriticalQueue` renamed to `TransactionsQueue` in dexes
- `AggregatesQueue` renamed to `TransactionsQueue` in kamino
- Dead `EventsQueue` / `USX_EventsQueue` / `eUSX_EventsQueue` deleted from all services

The Solstice health SQL was intentionally NOT updated yet — the old `CriticalQueue` literal must remain
until services are deployed, otherwise old queue_health rows lose their lenient staleness treatment.

---

## Step 1: Deploy updated services to Solstice pipeline

Ensure all four services are running with the new queue names. Confirm in logs:
- dexes: `TransactionsQueue started`
- kamino: `TransactionsQueue started`
- exponent: no `EventsQueue started`
- solstice-prop: no `USX_EventsQueue started`, no `eUSX_EventsQueue started`

---

## Step 2: Update Solstice health SQL

File: `health/dbsql/v_health_queue_table.sql`

Remove the 5 instances of `OR COALESCE(c.queue_name, '') = 'CriticalQueue'` at lines ~139, ~166, ~191, ~198, ~205.

`TransactionsQueue` already matches the `LIKE '%transaction%'` pattern and receives the correct
staleness treatment automatically — no other changes needed.

Redeploy this SQL to the Solstice database.

---

## Step 3: Clean up Solstice database historical records

**Important — compressed chunks:** Solstice has no tiered storage, but `queue_health` tables are
compressed after 1 day (`compress_after => INTERVAL '1 day'`). Plain `UPDATE`/`DELETE` silently
skips compressed chunks. You must decompress first, rename/delete, then let the compression policy
recompress on schedule.

Use psycopg2 (no `psql` available) with `conn.autocommit = True`.

### 3a: Decompress, rename, delete

For each affected schema (`dexes`, `exponent`, `kamino_lend`, `solstice_proprietary`):

```python
# Decompress all chunks for a table
cur.execute("""
    SELECT chunk_schema, chunk_name
    FROM timescaledb_information.chunks
    WHERE hypertable_schema = %s AND hypertable_name = 'queue_health' AND is_compressed = TRUE
""", (schema,))
for chunk_schema, chunk_name in cur.fetchall():
    cur.execute(f"SELECT decompress_chunk('{chunk_schema}.{chunk_name}')")
```

Then run the rename/delete SQL:

```sql
-- dexes: rename CriticalQueue, delete EventsQueue
UPDATE dexes.queue_health SET queue_name = 'TransactionsQueue' WHERE queue_name = 'CriticalQueue';
DELETE FROM dexes.queue_health WHERE queue_name = 'EventsQueue';

-- exponent: delete EventsQueue
DELETE FROM exponent.queue_health WHERE queue_name = 'EventsQueue';

-- kamino_lend: rename AggregatesQueue
UPDATE kamino_lend.queue_health SET queue_name = 'TransactionsQueue' WHERE queue_name = 'AggregatesQueue';

-- solstice_proprietary: delete events queues
DELETE FROM solstice_proprietary.queue_health WHERE queue_name IN ('USX_EventsQueue', 'eUSX_EventsQueue');
```

Chunks will be recompressed by the policy on their next scheduled run (within ~1 day). No need to
manually recompress unless you want them compressed immediately.

**Why rename instead of delete:** Renaming historical rows preserves the 7-day P95 baseline used by
the health monitor for staleness comparisons. Deleting would reset the baseline, giving weaker alerts
for ~7 days. Run these statements immediately after confirming services are live with the new names.

### 3b: Refresh the queue_health_hourly caggs

After renaming the raw rows, the continuous aggregates must be fully refreshed — renaming does not
automatically invalidate pre-computed cagg buckets.

```sql
CALL refresh_continuous_aggregate('dexes.queue_health_hourly', NULL, NULL);
CALL refresh_continuous_aggregate('exponent.queue_health_hourly', NULL, NULL);
CALL refresh_continuous_aggregate('kamino_lend.queue_health_hourly', NULL, NULL);
CALL refresh_continuous_aggregate('solstice_proprietary.queue_health_hourly', NULL, NULL);
```

Each `NULL, NULL` forces a full history refresh. These are small tables so this completes quickly.

---

## Step 4: Verify

1. Confirm no old names remain in any queue_health table:

   ```sql
   SELECT queue_name, COUNT(*) FROM dexes.queue_health GROUP BY queue_name;
   SELECT queue_name, COUNT(*) FROM exponent.queue_health GROUP BY queue_name;
   SELECT queue_name, COUNT(*) FROM kamino_lend.queue_health GROUP BY queue_name;
   SELECT queue_name, COUNT(*) FROM solstice_proprietary.queue_health GROUP BY queue_name;
   ```

2. Confirm caggs show only new names:

   ```sql
   SELECT DISTINCT queue_name FROM dexes.queue_health_hourly;
   SELECT DISTINCT queue_name FROM kamino_lend.queue_health_hourly;
   ```

3. Query `health.v_health_queue_table` — dexes shows `TransactionsQueue` with NORMAL severity, no
   ghost ANOMALY rows for `CriticalQueue`, `AggregatesQueue`, or `EventsQueue`.
4. Query `health.v_health_master_table` — check it exists and returns results. If missing, deploy
   `health/dbsql/v_health_master_table.sql` (was found missing on ONyc and needed redeployment).

---

## Notes from ONyc execution

- **Compressed chunks silently ignore UPDATE/DELETE** — this was the root cause of ghost ANOMALY
  rows persisting in the health table after the initial cleanup. Always decompress before modifying.
- **Cagg refresh is required after renames** — dropping and recreating the cagg (or calling
  `refresh_continuous_aggregate(..., NULL, NULL)`) is needed; a plain `UPDATE` on the hypertable
  does not trigger cagg invalidation for already-materialized buckets.
- **Solstice has no `mat_health_queue_benchmarks`** — the ONyc pipeline has a pre-computed
  benchmarks table refreshed by cronjob; Solstice computes P95 inline in the health function.
  No benchmark table cleanup is needed on Solstice.
- **Run cleanup SQL only after all chunks are decompressed** — on ONyc, the initial UPDATE ran
  while older chunks were still compressed/tiered, requiring a second pass. Do decompression first,
  then a single UPDATE/DELETE pass.

---

## Deferred: Deploy trigger S3-tiering fixes to Solstice

Two BEFORE INSERT triggers on `dexes.src_tx_events` were found to cause 30s+ INSERT times on ONyc
due to unbounded queries scanning into S3-tiered storage. Both triggers are identical on Solstice.

**Solstice is not currently affected** because its `src_tx_events` and `src_acct_pool` tables do
not yet have S3 tiering policies. However, if tiering is ever added to Solstice, the same failure
mode will occur immediately. Deploy these fixes to Solstice proactively before that happens.

### What was fixed on ONyc

**File: `dexes/dbsql/functions/trigger_fill_last_swap_price_raydium.sql`**

`trg_fill_raydium_pre_price` has a two-pass lookup for the previous Raydium swap price. The
fallback (second) query had no lower time bound, causing it to scan all of `src_tx_events` history
backwards. With `src_tx_events` tiered to S3 after 30 days, this caused 30s+ waits whenever the
30-second bounded primary query returned no result (e.g., when draining a backlog of queued events
after a service gap — the timestamps are historical so the bounded query always misses).

Fix: added `AND meta_block_time >= NEW.meta_block_time - INTERVAL '7 days'` to the fallback query.
Well within the 30-day tiering window and generous enough to cover any realistic gap in Raydium
activity.

**File: `dexes/dbsql/functions/trigger_calculate_swap_impact.sql`**

`trg_calculate_swap_impact` calls `get_token_type_from_pool()`, which looks up token mints from
`src_acct_pool` with no time bound. On ONyc, `src_acct_pool` tiers to S3 after just **1 day**,
so almost the entire table history was in object storage. The unbounded scan was the primary cause
of 30s mean / 81s max INSERT times on `dexes.src_tx_events` (vs 3ms on Solstice without tiering).

Fix: added `AND time > NOW() - INTERVAL '2 days'` to the `src_acct_pool` lookup. Active pools
always have data within the last 2 days; the fallback to `pool_tokens_reference` handles any that
do not.

### Deploy to Solstice database

Run the updated SQL files against the Solstice DB (`.env.prod.core`):

```bash
psql $SOLSTICE_DB -f dexes/dbsql/functions/trigger_fill_last_swap_price_raydium.sql
psql $SOLSTICE_DB -f dexes/dbsql/functions/trigger_calculate_swap_impact.sql
```

Or deploy via psycopg2 using `.env.prod.core` credentials. Both files are idempotent
(`CREATE OR REPLACE FUNCTION` + `DROP TRIGGER IF EXISTS` / `CREATE TRIGGER`).

### Verify

```sql
-- Check trigger functions contain the bounds
SELECT prosrc FROM pg_proc WHERE proname = 'fill_raydium_pre_price_trigger'
  AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'dexes');
-- Should contain: meta_block_time >= NEW.meta_block_time - INTERVAL '7 days'

SELECT prosrc FROM pg_proc WHERE proname = 'get_token_type_from_pool'
  AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'dexes');
-- Should contain: time > NOW() - INTERVAL '2 days'
```
