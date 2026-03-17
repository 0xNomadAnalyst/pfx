# Temporary Untiering for Backfills (Remote/API-Driven)

This runbook documents how to temporarily untier Exponent source tables so historical backfills can be inserted, then restore normal tiering policy after load.

The process was executed remotely against the DB in `pfx/.env.pfx.core` using SQL over a regular Postgres connection (Python `psycopg2`), which is equivalent to any remote SQL API that can run the same statements.

## Why this is needed

Backfill inserts can fail with errors like:

- `Cannot insert into tiered chunk range ...`
- `Hypertable has tiered data with time range that overlaps the insert`

When this happens, chunk ranges must be untiered and table tiering temporarily disabled for the affected tables.

## Target tables (Exponent ONyc flow)

- `exponent.src_txns`
- `exponent.src_tx_events`
- `exponent.src_vaults`
- `exponent.src_market_twos`

## Important technical nuance

`untier_chunk()` is a **procedure** and must be called with:

```sql
CALL untier_chunk('<chunk_name>');
```

Not `SELECT untier_chunk(...)`.

Also, the procedure expects chunk names from `_osm_catalog.chunk_map` (e.g. `_hyper_17_4915_chunk`), not `schema.chunk` references.

---

## Step 0: Connect remotely

Any remote SQL mechanism is fine. We used Python:

```python
import os
import psycopg2
from dotenv import load_dotenv

load_dotenv("D:/dev/mano/risk_dash/pfx/.env.pfx.core", override=True)
conn = psycopg2.connect(
    host=os.getenv("DB_HOST"),
    port=os.getenv("DB_PORT"),
    dbname=os.getenv("DB_NAME", "tsdb"),
    user=os.getenv("DB_USER"),
    password=os.getenv("DB_PASSWORD"),
)
conn.autocommit = True
```

---

## Step 1: Remove active tiering policies on target tables

```sql
SELECT remove_tiering_policy('exponent.src_txns'::regclass, if_exists => true);
SELECT remove_tiering_policy('exponent.src_tx_events'::regclass, if_exists => true);
SELECT remove_tiering_policy('exponent.src_vaults'::regclass, if_exists => true);
SELECT remove_tiering_policy('exponent.src_market_twos'::regclass, if_exists => true);
```

---

## Step 2: Discover OSM chunk names in backfill window

Use `_osm_catalog.chunk_map` + `_osm_catalog.table_map` and convert ranges with `_osm_internal.dimension_pg_usec_to_timestamp(...)`.

```sql
SELECT
  tmap.hypertable_schema || '.' || tmap.hypertable_name AS hypertable,
  chmap.chunk_name,
  _osm_internal.dimension_pg_usec_to_timestamp(chmap.range_start) AS chunk_start,
  _osm_internal.dimension_pg_usec_to_timestamp(chmap.range_end)   AS chunk_end
FROM _osm_catalog.chunk_map chmap
JOIN _osm_catalog.table_map tmap ON tmap.osm_table_id = chmap.osm_table_id
WHERE tmap.hypertable_schema = 'exponent'
  AND tmap.hypertable_name IN ('src_txns','src_tx_events','src_vaults','src_market_twos')
  AND _osm_internal.dimension_pg_usec_to_timestamp(chmap.range_end) > '2026-02-06T00:00:00Z'::timestamptz
  AND _osm_internal.dimension_pg_usec_to_timestamp(chmap.range_start) < '2026-03-17T23:59:59Z'::timestamptz
ORDER BY hypertable, chunk_start;
```

---

## Step 3: Untier each returned chunk

For each `chunk_name` from step 2:

```sql
CALL untier_chunk('<chunk_name>');
```

Example loop in Python:

```python
for hypertable, chunk_name, chunk_start, chunk_end in rows:
    cur.execute("CALL untier_chunk(%s);", (chunk_name,))
```

---

## Step 4: Disable tiering at hypertable level

After untiering target ranges:

```sql
SELECT disable_tiering('exponent.src_txns'::regclass);
SELECT disable_tiering('exponent.src_tx_events'::regclass);
SELECT disable_tiering('exponent.src_vaults'::regclass);
SELECT disable_tiering('exponent.src_market_twos'::regclass);
```

---

## Step 5: Run backfill + reconstruction while untiered

Typical command pattern used:

```bash
python exponent/backfill-qa/upload_backfill.py \
  --env-file pfx/.env.pfx.core \
  --input-dir "<backfill-folder>" \
  --confirm

python exponent/backfill-qa/reconstruct_balances_from_events.py \
  --env-file pfx/.env.pfx.core \
  --gap-start "<start-iso>" \
  --gap-end "<end-iso>" \
  --events-parquet "<src_tx_events parquet path>" \
  --genesis-mode \
  --confirm
```

---

## Step 6: Reapply tiering policies

Restore original policy definitions:

```sql
SELECT add_tiering_policy('exponent.src_txns'::regclass, move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_tx_events'::regclass, move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_vaults'::regclass, move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_market_twos'::regclass, move_after => INTERVAL '30 days', if_not_exists => true);
```

---

## Step 7: Verify policies are active again

```sql
SELECT
  job_id,
  proc_name,
  hypertable_schema || '.' || hypertable_name AS hypertable,
  schedule_interval
FROM timescaledb_information.jobs
WHERE proc_name = 'policy_movechunk_to_s3'
  AND hypertable_schema = 'exponent'
  AND hypertable_name IN ('src_txns','src_tx_events','src_vaults','src_market_twos')
ORDER BY hypertable_name;
```

Expected: 4 rows, one for each target table.

---

## Operational notes

- If inserts still fail after untiering, rerun Steps 2-4 for the exact failing range from the error message.
- Untiering can create new OSM chunk names over time; always query the catalog fresh.
- Keep the untier window as narrow as practical for safety and cost control.

---

## Generalized one-shot script (any schema/tables)

This pattern is reusable for other domains (`dexes`, `kamino_lend`, etc.).

Inputs:

- `TARGET_TABLES`: fully-qualified hypertables (`schema.table`)
- `START_TS`, `END_TS`: untier window
- `MOVE_AFTER`: reapply tiering horizon after load

```python
import os
import psycopg2
from dotenv import load_dotenv

load_dotenv("D:/dev/mano/risk_dash/pfx/.env.pfx.core", override=True)

TARGET_TABLES = [
    "exponent.src_txns",
    "exponent.src_tx_events",
    "exponent.src_vaults",
    "exponent.src_market_twos",
]
START_TS = "2026-02-06T00:00:00+00:00"
END_TS = "2026-03-17T23:59:59+00:00"
MOVE_AFTER = "30 days"

conn = psycopg2.connect(
    host=os.getenv("DB_HOST"),
    port=os.getenv("DB_PORT"),
    dbname=os.getenv("DB_NAME", "tsdb"),
    user=os.getenv("DB_USER"),
    password=os.getenv("DB_PASSWORD"),
)
conn.autocommit = True
cur = conn.cursor()

# 1) remove existing tiering policy jobs
for tbl in TARGET_TABLES:
    cur.execute("SELECT remove_tiering_policy(%s::regclass, if_exists => true);", (tbl,))
    print("removed policy:", tbl)

# 2) untier overlapping OSM chunks
schema_groups = {}
for tbl in TARGET_TABLES:
    s, t = tbl.split(".", 1)
    schema_groups.setdefault(s, []).append(t)

for schema, table_names in schema_groups.items():
    cur.execute(
        """
        SELECT
          tmap.hypertable_schema || '.' || tmap.hypertable_name AS hypertable,
          chmap.chunk_name
        FROM _osm_catalog.chunk_map chmap
        JOIN _osm_catalog.table_map tmap ON tmap.osm_table_id = chmap.osm_table_id
        WHERE tmap.hypertable_schema = %s
          AND tmap.hypertable_name = ANY(%s)
          AND _osm_internal.dimension_pg_usec_to_timestamp(chmap.range_end) > %s::timestamptz
          AND _osm_internal.dimension_pg_usec_to_timestamp(chmap.range_start) < %s::timestamptz
        ORDER BY hypertable, chmap.range_start;
        """,
        (schema, table_names, START_TS, END_TS),
    )
    for hypertable, chunk_name in cur.fetchall():
        cur.execute("CALL untier_chunk(%s);", (chunk_name,))
        print("untiered:", hypertable, chunk_name)

# 3) disable tiering at hypertable level
for tbl in TARGET_TABLES:
    cur.execute("SELECT disable_tiering(%s::regclass);", (tbl,))
    print("disabled tiering:", tbl)

# -- run backfill/reconstruction writes here --

# 4) restore tiering policies
for tbl in TARGET_TABLES:
    cur.execute(
        f"SELECT add_tiering_policy(%s::regclass, move_after => INTERVAL '{MOVE_AFTER}', if_not_exists => true);",
        (tbl,),
    )
    print("restored policy:", tbl)

cur.close()
conn.close()
```

## General pattern for other tables

- For **source hypertables**, use the same process exactly.
- For **CAGGs/mat tables**, process is similar, but only untier/disable where writes are required.
- If your write job fails with a tiered-range error, use the error window as `START_TS/END_TS` and rerun untiering for that narrower interval.
- Always re-enable policies after writes; otherwise cost/performance drift over time.
