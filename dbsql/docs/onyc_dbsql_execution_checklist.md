# ONyc DBSQL Execution Checklist

This checklist implements the cost-first rollout model for ONyc DBSQL changes while preserving Solstice-compatible interfaces.

## 1) Baseline + Contract

1. Run compatibility checks in each pipeline DB:
   - `pfx/dbsql/validation/compatibility_contract_checks.sql`
2. Capture baseline metrics and gate targets:
   - `pfx/dbsql/validation/perf_baseline_and_gates.sql`
3. Run index quick wins (idempotent):
   - `pfx/dbsql/validation/index_quickwins.sql`

## 2) Cost/Performance Gates

- p95 widget latency must improve or remain neutral.
- Refresh job runtime must not regress.
- DB CPU/IO during refresh windows must not materially increase.
- If distribution impact calls at real API settings (`p_buckets=10`) are cheap, skip precompute complexity.
- If Phase 2.5 tick-dist substitution reaches target latency, skip deeper tick-dist rewrites.

## 3) Rollback Criteria

Rollback phase changes if any of:

- Any compatibility check fails.
- p95 latency regresses beyond tolerance.
- Refresh runtime/freshness SLA regresses.
- DB load increases without commensurate user-visible benefit.

Rollback is done by restoring prior SQL function/procedure definitions in deployment order:

1. Frontend view functions (`get_view_*`)
2. Mid-level refresh procedures (`refresh_mat_*`)
3. Optional index additions may remain if harmless

## 4) Pipeline Validation

Validate both pipelines with representative widgets:

- `_pipeline=onyc`: expected ONyc behavior and defaults.
- `_pipeline=solstice`: interface compatibility (shape/keys/types) with no regressions.

## 5) SSL Source-of-Truth Validation

The runtime should resolve SSL mode from:

1. `DB_SSLMODE` (preferred app-level variable)
2. `PGSSLMODE` fallback (libpq-compatible)
3. default `require`

Confirm both `.env` credential sets produce equivalent SSL behavior.
