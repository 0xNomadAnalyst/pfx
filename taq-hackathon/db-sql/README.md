# Hackathon DB-SQL

All database DDL for the TAQ hackathon app lives in this folder. The hackathon app reads from the same TimescaleDB instance that ingests the ONyc ecosystem, but every object it *creates* is isolated from the production substrate.

## Hard rules

1. **The hackathon app is read-only against production schemas.** `dexes`, `kamino_lend`, `exponent`, `health`, and their CAGGs, source tables, view functions, and auxiliary tables are never written to, altered, or migrated from this project. Read-only means read-only: no `CREATE`, no `ALTER`, no `INSERT`, no `REFRESH MATERIALIZED VIEW` against them.

2. **Everything the hackathon app creates lives in a dedicated `hackathon` schema.** Views, functions, materialised views, tables, types — all of it. No hackathon object is created outside the `hackathon` schema. No production object is shadowed, extended, or replaced.

3. **DDL source of truth lives in this folder.** Every object in the `hackathon` schema has a corresponding `.sql` file in this directory tree. An object that exists in the database but not in a file here is an error.

4. **Connection credentials come from `../../.env.pfx.core`** (i.e. `D:\dev\mano\risk_dash\pfx\.env.pfx.core`). The hackathon app does not carry its own DB credentials; it reuses the core `pfx` env contract.

## Schema bootstrap

The first DDL applied should create the schema if it does not exist:

```sql
CREATE SCHEMA IF NOT EXISTS hackathon;
```

All subsequent DDL references `hackathon.*` explicitly — no `SET search_path` tricks, no unqualified names.

## Folder layout

Start light and split as the build uncovers need. Reasonable buckets mirroring the production `<service>/dbsql/` convention:

```
db-sql/
  00_schema.sql           # CREATE SCHEMA IF NOT EXISTS hackathon;
  views/                  # CREATE OR REPLACE VIEW hackathon.*
  functions/              # CREATE OR REPLACE FUNCTION hackathon.*
  tables/                 # CREATE TABLE IF NOT EXISTS hackathon.* (only if stateful storage is needed)
```

Add subfolders only when the flat layout starts to hurt.

## Idempotency

All DDL must be safe to re-run. Prefer:

- `CREATE OR REPLACE VIEW` / `CREATE OR REPLACE FUNCTION`
- `CREATE TABLE IF NOT EXISTS` for stateful tables
- `CREATE INDEX IF NOT EXISTS`
- `DROP ... IF EXISTS` before `CREATE` where replacement semantics differ (e.g. changing a function's return type)

A deploy script applied against a fresh DB and an already-provisioned DB must produce identical end-state.

## Naming

- Objects follow `snake_case` (consistent with production).
- Views start with `v_*` where the production convention calls for it; view functions use `get_view_*` only if they mirror a production function's shape.
- Computed / derived columns are prefixed `c_` where raw-vs-derived distinction matters (consistent with production).
- Every non-trivial object carries a `COMMENT ON` explaining purpose, inputs, and any non-obvious behaviour. The hackathon schema follows the same "schema-as-documentation" discipline as the production substrate — this is not optional, it is a demo asset.

## Teardown

The entire hackathon footprint must be removable with:

```sql
DROP SCHEMA hackathon CASCADE;
```

Nothing the hackathon app creates lives outside this schema, so this statement is a complete teardown. Verify this invariant before every deploy.
