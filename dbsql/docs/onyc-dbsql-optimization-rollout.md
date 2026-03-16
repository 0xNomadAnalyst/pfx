# ONyc DBSQL Optimization Rollout (Cost-First)

## Purpose

This document records the latest ONyc-focused DBSQL optimization rollout, including:

- what changed,
- why it improves compute efficiency and/or correctness,
- what was validated and deployed,
- what was intentionally deferred.

Scope is ONyc DBSQL (`pfx/dbsql`) with interface compatibility preserved for dashboard-facing API/view contracts.

## What Changed in This Rollout

## 1) Validation + rollout guardrails added

New scripts:

- `pfx/dbsql/validation/compatibility_contract_checks.sql`
- `pfx/dbsql/validation/perf_baseline_and_gates.sql`
- `pfx/dbsql/validation/index_quickwins.sql`
- `pfx/dbsql/validation/src_tx_events_numeric_columns.sql` (optional)

Operational checklist:

- `pfx/dbsql/docs/onyc_dbsql_execution_checklist.md`

Key updates:

- Validation probes now auto-select a live sample protocol/pair from `dexes.pool_tokens_reference` (prefers ONyc pairs), avoiding hardcoded USX/EUSX assumptions.
- Scripts verify function/signature compatibility and run baseline probes on actual ONyc ecosystem data.

## 2) `mat_dex_last` refresh moved to staging + atomic publish

Updated:

- `pfx/dbsql/mid-level-tables/dexes/mat_dex_last.sql`

Before:

- `TRUNCATE` target table, then loop per pool with per-iteration inserts.
- Risk: temporary empty-table visibility during refresh window.

After:

- Build full snapshot in a staging temp table.
- Lock + publish atomically into `mat_dex_last`.

Benefits:

- Correctness: removes empty-table exposure window.
- Compute: reduces procedural overhead from per-pool loop orchestration at publish stage.

## 3) `mat_dex_timeseries_1m` event scan consolidation

Updated:

- `pfx/dbsql/mid-level-tables/dexes/mat_dex_timeseries_1m.sql`

Before:

- Separate `swap_1m` and `lp_1m` scans from `cagg_events_5s`.

After:

- Single `events_1m` scan using `FILTER` aggregates for both swap and LP paths.

Benefits:

- Compute/I/O reduction on refresh path (single source pass instead of two).
- Lower planner/executor overhead in hot refresh routine.

## 4) Tick distribution switched to CAGG vault source + set-based prior lookup

Updated:

- `pfx/dbsql/frontend-views/dexes/get_view_tick_dist_simple.sql`

Changes:

- Replaced raw `src_acct_vaults` lateral lookups with `dexes.cagg_vaults_5s`.
- Reworked prior-query resolution to a set-based candidate selection (`DISTINCT ON`) instead of per-row lateral lookup.
- Removed avoidable `LOWER(column)` predicate patterns and switched to canonical direct comparisons.

Benefits:

- Lower random I/O and per-row lookup overhead.
- Better index-friendliness and reduced CPU from function-wrapped predicates.

## 5) Predicate canonicalization quick wins

Updated:

- `pfx/dbsql/frontend-views/dexes/get_view_sell_swaps_distribution.sql`
- `pfx/dbsql/frontend-views/dexes/get_view_dex_table_ranked_events.sql`
- `pfx/dbsql/frontend-views/dexes/get_view_tick_dist_simple.sql`
- `pfx/dbsql/frontend-views/dexes/get_view_liquidity_depth_table.sql`

Changes:

- Replaced `LOWER(column) = LOWER(param)` style filters with canonical comparisons where safe.

Benefits:

- Removes unnecessary per-row function cost.
- Improves index usage probability on protocol/pair filters.

## 6) Distribution impact calls gated to non-empty buckets

Updated:

- `pfx/dbsql/frontend-views/dexes/get_view_sell_swaps_distribution.sql`
- `pfx/dbsql/frontend-views/dexes/get_view_sell_pressure_t0_distribution.sql`

Change:

- `impact_bps_from_qsell_latest(...)` now called only for buckets with data (`swap_count > 0` or `interval_count > 0`).

Benefit:

- Avoids needless function calls for empty histogram buckets while preserving outputs.

## 7) Ranked-events numeric parsing path made upgrade-aware

Updated:

- `pfx/dbsql/frontend-views/dexes/get_view_dex_table_ranked_events.sql`

Change:

- Function now checks for optional typed numeric columns (`*_num`) in `src_tx_events` and uses them when available.
- Falls back to regex parsing when not available.

Benefit:

- Ready for ingestion-time numeric normalization without breaking current deployments.

## 8) API-side compatibility and SSL handling hardening

Updated:

- `pfx/api-w-caching/app/services/sql_adapter.py`
- `pfx/api-w-caching/app/services/pipeline_config.py`
- `pfx/api-w-caching/app/services/data_service.py`

Changes:

- SSL mode resolves via `DB_SSLMODE`, then `PGSSLMODE`, then default.
- Pipeline loader maps `PGSSLMODE` into `DB_SSLMODE` when needed.
- Startup DBSQL contract check added (soft by default, strict mode optional via env).

Benefits:

- Reduces environment drift risk across pipeline credential formats.
- Surfaces contract mismatches earlier.

## Deployment + Validation Status (Latest Cycle)

Executed against ONyc DB credentials (`pfx/.env.pfx.core`):

- Compatibility checks: passed.
- Index quick wins: applied where permitted (with expected Timescale tiered-data notices).
- Baseline/gate probes: completed successfully.
- Updated DBSQL function/procedure definitions: deployed successfully.
- Post-deploy compatibility + baseline probes: passed.

Validation probes now run on ONyc-relevant sample pair(s) from live metadata and returned non-zero rows in latest run.

## Feature Comparison vs Prior Solstice-Style Pattern

| Area | Prior pattern (baseline style) | Current ONyc rollout | Expected effect |
|---|---|---|---|
| `mat_dex_last` publish | `TRUNCATE` then per-pool loop insert | stage full snapshot then atomic publish | Removes empty-table exposure; steadier reads during refresh |
| `mat_dex_timeseries_1m` event aggregation | separate swap and LP passes over `cagg_events_5s` | single-pass `events_1m` with `FILTER` aggregates | Lower refresh scan/aggregation cost |
| Tick distribution reserve lookup | raw `src_acct_vaults` lateral latest lookup | `cagg_vaults_5s` latest lookup | Lower random I/O and better cache locality |
| Tick distribution prior snapshot | per-row lateral prior-query resolution | set-based candidate + `DISTINCT ON` | Less repeated lookup overhead |
| Pair/protocol filtering | `LOWER(column)=LOWER(param)` patterns | canonical direct comparisons where safe | Better index usage probability and lower CPU |
| Distribution impact calls | impact function called for all buckets | impact function called only for non-empty buckets | Fewer expensive calls with identical output semantics |
| Ranked-events numeric parsing | regex parsing only at query time | optional typed numeric columns preferred, fallback retained | Ready for ingestion-time compute reduction without breakage |
| Validation probes | hardcoded USX/EUSX sample params | auto-select live ONyc pair from metadata | Real ecosystem validation coverage |

## How the Improvements Create Benefits

- **Atomic publish for snapshots**: correctness-first. Readers never observe an empty `mat_dex_last` caused by in-progress refresh.
- **Single-pass event aggregation**: compute-first. Consolidating swap/LP aggregation reduces repeated scans and planner overhead in refresh routines.
- **CAGG-backed reserve reads**: I/O-first. Replacing raw latest lookups with cagg-backed latest values reduces expensive point lookups on raw streams.
- **Set-based prior selection**: scale-first. Pool-level prior resolution avoids repeated per-row lateral lookups as row counts grow.
- **Canonical predicates**: index-first. Removing function-wrapped column predicates reduces per-row CPU and allows normal B-tree access patterns more often.
- **Bucket gating for impact calls**: function-cost-first. Expensive impact calls are skipped where buckets carry no data; output shape remains unchanged.
- **Contract and gate scripts**: safety-first. Makes interface compatibility and cost checks explicit before/after deployment.

## Quantitative Estimates (This Rollout)

### Observed in latest ONyc validation run

- Compatibility and probe suite executed successfully after deployment.
- Probe outputs returned non-zero rows for ONyc sample pair selection:
  - ranked events probe: `10` rows
  - sell swaps distribution probe: `10` rows
  - sell pressure distribution probe: `10` rows
  - tick distribution probe: `395` rows

### Estimated performance impact vs prior approach

These are engineering estimates from query-shape changes, not full A/B benchmark deltas:

| Change | Conservative estimate |
|---|---|
| `mat_dex_timeseries_1m` swap+LP pass consolidation | ~15-35% less event-aggregation work in refresh path |
| Tick distribution raw-vault -> cagg-vault substitution | material reduction in lookup latency variance; typically 2x+ faster latest-balance lookup path |
| Set-based prior-query resolution in tick distribution | ~20-50% lower prior-lookup overhead on larger result sets |
| Canonical predicate replacement (`LOWER(...)` removal) | noticeable CPU drop on filtered scans; index usage likelihood improves where data is already canonical |
| Empty-bucket impact-call gating | impact-call count reduced in proportion to empty buckets (often significant when distributions are sparse) |
| Atomic staging publish for `mat_dex_last` | correctness gain (eliminates empty-window reads), plus modest refresh orchestration efficiency gains |

### Cost-model interpretation

- Biggest near-term wins come from **I/O and function-call reduction**, not from adding new heavy precompute pipelines.
- Deferred generated-column path (Option A) means ranked-event regex parsing remains as fallback; this keeps rollout low-risk and low-ops-complexity.

## Deferred Improvement (Intentionally Put Aside for Now)

Deferred item (Option A selected):

- `pfx/dbsql/validation/src_tx_events_numeric_columns.sql`

Reason:

- Timescale constraint on current hypertable mode (`src_tx_events` with columnstore enabled) blocks adding generated constrained columns directly.

Decision:

- Keep current fallback behavior (no schema mutation on hypertable for now).
- Revisit only if profiling shows regex parse cost remains a dominant contributor.

Potential future path (if needed):

- Sidecar parsed-numerics table + join strategy (columnstore-compatible), benchmarked behind a gate.

## Summary of Cost-First Impact

This rollout prioritizes low-risk, low-compute wins:

- fewer repeated scans in refresh paths,
- fewer expensive per-row or per-bucket function calls,
- better index-friendly filtering,
- safer snapshot publish semantics,
- stronger compatibility/validation controls.

Together these changes improve DB efficiency and correctness without introducing heavy new background pipelines.

