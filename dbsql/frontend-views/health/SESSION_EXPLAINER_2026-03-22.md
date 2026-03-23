# Health Sensitivity Remediation Session (2026-03-22)

## Scope

This document summarizes what changed in this session across:

1. Core health SQL (`health/dbsql/*`)
2. PFX health SQL (`pfx/dbsql/mid-level-tables/health/*` and `pfx/dbsql/frontend-views/health/*`)
3. Deployment and cascade-recovery steps
4. Follow-up refinement for quiet CAGG streams that were misclassified as `No data`

This document is issue-first, with each update area explicitly mapped to the issue(s) it fixes.

---

## Issue Timeline

## Issue A: P95 desensitization drift

Original problem:

- Queue gap severity depended heavily on historical P95.
- Extreme incidents inflated P95 for long periods.
- Later degradations were under-detected because the baseline was polluted.

Failure mode:

- The system became progressively less sensitive after major incidents.
- Gap-only regressions could hide behind elevated P95 history.

## Issue B: Follow-up oversensitivity after anti-drift hardening

After A was addressed, a second failure mode became visible in production screenshots and table outputs.

Observed symptoms:

- Many `HIGH/ELEVATED/ANOMALY` rows despite normal utilization and zero failures.
- Idle write-on-difference queues flagged as unhealthy during economically quiet periods.
- Repeated "No writes for Xs" warning text could dominate status even when there was no backlog.
- Small oscillations around baseline thresholds caused status churn.
- Some sparse event streams were judged too aggressively by thresholds better suited to state/update queues.

Why this happened:

- Pure anti-drift tightening removed desensitization but increased sensitivity to benign inactivity.
- Queue semantics were mixed: write-on-difference (long expected silence) versus event-driven (activity-dependent).
- Warning-message passthrough was treated as equivalent to hard evidence of processing blockage.

## Issue C: Quiet CAGG streams shown as `No data`

For low-activity streams (example: `usx_events`), CAGG health used a strict 24h recency window.

- If both source and CAGG had no rows in that 24h window, both latest timestamps were null.
- Output became `No data`.
- This conflated "quiet but aligned" with "missing/unknown." 

---

## Screenshot Context

The in-thread screenshot showed widespread red/yellow statuses while queue size, utilization, and failures remained healthy. That evidence specifically drove the Issue B follow-up tuning.

---

## Issue-to-Change Map

| Issue | Primary symptom | Change family | Goal |
|---|---|---|---|
| A | Post-incident insensitivity | Hybrid baseline + dynamic caps | Keep anti-drift sensitivity without unlimited baseline inflation |
| B | False positives in idle/quiet periods | Idle-safe suppression + stale-warning suppression + deadband | Remove benign noise while preserving true blockage signals |
| B | Sparse-event over-alerting | Queue-type-aware thresholds | Respect different activity patterns by queue type |
| B | Inconsistent sensitivity by schema | Include all active schemas in benchmark refresh | Align benchmark quality across domains |
| C | Quiet stream shown as `No data` | Dormant-state model + preserved historical last-seen | Distinguish inactivity from unknown/missing data |

---

## Change Area 1: Core queue health function

File:

- `health/dbsql/v_health_queue_table.sql`

### Update 1.1

Issue addressed:

- **B** (stale warning passthrough on healthy-idle rows)

Change made:

- Brought `warning_message` into current queue staging and evaluation pipeline.

Why this fixes it:

- Enables rule-level filtering of warning text when there is no supporting evidence of blockage.

### Update 1.2

Issue addressed:

- **B** (write-on-difference idle false positives)

Change made:

- Added idle-safe suppression when `queue_size = 0`, `failure_rate = 0`, and write rate indicates inactivity.

Why this fixes it:

- Distinguishes expected inactivity from processing failure.

### Update 1.3

Issue addressed:

- **B** (warning noise dominating status)

Change made:

- Added stale-warning pattern suppression for `No writes for ...` class warnings when queue evidence indicates healthy idle.

Why this fixes it:

- Prevents warning-text-only elevation from overriding actual queue condition.

### Update 1.4

Issue addressed:

- **A** (baseline drift) and **B** (edge jitter)

Change made:

- Added queue-type-aware dynamic cap and a 1.25 deadband around baseline transitions.

Why this fixes it:

- Cap limits runaway baseline inflation.
- Deadband reduces threshold flapping near P95 edges.

### Update 1.5

Issue addressed:

- **B** (sparse event streams over-penalized)

Change made:

- Widened absolute thresholds for event/transaction-driven queues.

Why this fixes it:

- Event streams are bursty; wider windows reduce false-positive escalation during normal quiet periods.

Deployment:

- `python health/deploy_health_views.py -y`

Validation summary:

- `dexes` core queue outputs normalized.
- Gap-only noise reduced without weakening failure/utilization checks.

---

## Change Area 2: PFX queue health function

File:

- `pfx/dbsql/frontend-views/health/v_health_queue_table.sql`

### Update 2.1

Issue addressed:

- **A** and **B**

Change made:

- Ported the core fixes: warning capture, idle-safe suppression, stale-warning suppression, dynamic cap, deadband, and queue-type thresholding.

Why this fixes it:

- Ensures PFX behavior matches hardened core logic and avoids split-brain sensitivity across environments.

### Update 2.2

Issue addressed:

- **B** (operational stability of downstream dashboards)

Change made:

- Kept summary/status contract intact while changing internals.

Why this fixes it:

- Reduced alert noise without breaking consumer expectations or frontend query contracts.

---

## Change Area 3: PFX queue benchmark refresh source

File:

- `pfx/dbsql/mid-level-tables/health/mat_health_queue_benchmarks.sql`

### Update 3.1

Issue addressed:

- **B** (benchmark representativeness mismatch)

Change made:

- Added `solstice_proprietary` domain into benchmark refresh loop.

Why this fixes it:

- Prevents under-represented schema baselines that can produce unstable sensitivity.

**Superseded (2026-03-23):** `solstice_proprietary` was subsequently removed from the ONyc benchmark refresh loop — the ONyc pipeline does not ingest solstice-prop data and the schema has no `queue_health` table on that DB. The exception handler (Update 3.2) masked this silently. See Change Area 6.

### Update 3.2

Issue addressed:

- **B** (refresh fragility during churn)

Change made:

- Added `undefined_table` exception handling in refresh loop.

Why this fixes it:

- Keeps benchmark updates resilient during partial redeploy states.

---

## Change Area 4: PFX CAGG quiet-stream handling

Files:

- `pfx/dbsql/mid-level-tables/health/mat_health_cagg_status.sql`
- `pfx/dbsql/frontend-views/health/v_health_cagg_table.sql`

### Update 4.1

Issue addressed:

- **C** (24h-window null collapse)

Change made:

- Mid-level refresh now preserves previously known non-null `source_latest` and `cagg_latest` when current 24h scan returns null.

Why this fixes it:

- Retains "last seen" evidence for streams that are inactive but not broken.

### Update 4.2

Issue addressed:

- **C** (ambiguous `No data` status)

Change made:

- Frontend status model now distinguishes:
  - `No data ever`
  - `Dormant (expected)`
  - `Dormant (lagging)`

Why this fixes it:

- Separates unknown-history, expected quiet, and real lag conditions.

### Update 4.3

Issue addressed:

- **C** (incorrect severity semantics)

Change made:

- Severity mapping changed so:
  - `Dormant (expected)` -> non-red
  - `Dormant (lagging)` -> red
  - `No data ever` -> informational/non-red

Why this fixes it:

- Red now indicates actionable lag, not mere inactivity.

---

## Change Area 5: Documentation updates

Files:

- `pfx/dbsql/frontend-views/health/README.md`
- `pfx/dbsql/frontend-views/health/SESSION_EXPLAINER_2026-03-22.md`

### Update 5.1

Issue addressed:

- **A** and **B** (operator explainability)

Change made:

- Documented queue logic evolution: anti-drift controls, idle-safe suppression, stale-warning filtering, deadband, and queue-type thresholding.

Why this fixes it:

- Operators can now trace why alerts changed and which false-positive classes were targeted.

### Update 5.2

Issue addressed:

- **C** (interpretation ambiguity)

Change made:

- Documented dormant/no-data semantics for CAGG health.

Why this fixes it:

- Clarifies when "quiet" is healthy versus when it indicates lag.

---

## Deployment Order and Cascade Recovery

Target env used for PFX deployment:

- `pfx/.env.pfx.core`

Execution order used:

1. Mid-level health SQL
2. Frontend health SQL (all health views/functions)
3. `CALL health.refresh_mat_health_all();`

Why this order:

- Frontend objects depend on mid-level objects.
- Frontend scripts include `DROP ... CASCADE`; full-chain redeploy restores dropped dependents (including `v_health_master_table`).

---

## Net Effect

1. Reduced post-incident desensitization.
2. Reduced oversensitivity in idle write-on-difference queues.
3. Reduced warning-text-driven false positives.
4. Reduced near-threshold jitter noise.
5. Improved handling for sparse event streams.
6. Replaced ambiguous CAGG `No data` with actionable dormant semantics.
7. Restored object completeness safely after cascade-prone deploys.

---

## Remaining Follow-Up Risks (Oversensitivity)

Even after these fixes, some sensitivity risks remain and should be tracked:

1. **Queue-type classification dependence.**
If a queue is misclassified (state-like vs event-like), thresholds can still be too strict or too loose.
The classification relies on `LIKE '%transaction%'`, `LIKE '%event%'` name patterns. Current queues
are correctly covered after the 2026-03-23 renames, but any future queue with an atypical name will
silently fall into the default bucket. No guard prevents this.

2. **Threshold constants still exist.**
Even with dynamic caps/deadband, absolute bounds can still be overly sensitive in rare market regimes.
Note: this is less a reason to automate thresholds away (dynamic thresholds have their own failure
modes) and more a reason to periodically review constants after major market regime changes. The
original P95 desensitization problem was addressed; fixed thresholds are acceptable if reviewed.

3. **Mixed-stream aggregation artifacts** *(reduced — lower priority post-2026-03-23 cleanup).*
Aggregating different source behaviors into one queue line can still produce edge-case noise.
Dead queues have been removed and naming is now aligned one-worker-per-queue, significantly
reducing cross-stream contamination. Residual risk is from queues with highly variable activity
patterns (e.g. StateQueue in low-volume market conditions).

4. **Warning taxonomy drift** *(highest silent failure risk).*
The health SQL suppresses certain warning classes by text pattern matching on `warning_message`
content generated by service code (e.g. `LIKE 'No writes for%'`). If any service changes its
warning message format — even minor wording — suppression silently stops working. No error is
raised; idle-healthy rows begin escalating again. Any service-side refactor of warning strings
must be cross-checked against the health SQL suppression patterns.

5. **Dormant-to-active transition spikes.**
When a long-dormant stream resumes, first-write timing can look abrupt and needs careful
interpretation. The deadband reduces jitter near baseline edges but does not gate on persistence
across multiple intervals. Mitigated if persistence gating (see below) is implemented.

---

## Recommended Next Steps

### High priority

**Contamination-resistant baseline updates.**
The current `refresh_mat_health_queue_benchmarks` procedure computes PERCENTILE_CONT over all
samples in the 7-day window, including samples from incident periods. This re-introduces the
desensitization drift that Issue A was meant to fix, just more slowly. A simple improvement:
filter to `WHERE consecutive_failures = 0` (or `WHERE is_healthy = TRUE`) before computing P95.
This excludes contaminating samples without any structural change. Highest value-to-effort ratio
of any item on this list.

**Persistence gating.**
Require sustained abnormality across N consecutive intervals before escalating to `HIGH`/`ANOMALY`.
This directly eliminates dormant-to-active transition spikes (Risk 5) and reduces single-sample
noise escalations. Standard practice in production alerting. The health function is stateless, so
persistence state needs a small auxiliary table or an extra column in `mat_health_queue_benchmarks`.
Moderate effort, high signal quality improvement.

### Medium priority

**Regime-aware baselines.**
Maintain separate P95 benchmarks for idle (`queue_size=0`) and active (`queue_size>0`) regimes.
The current idle-safe suppression handles the clearest idle case, but the P95 baseline itself is
still polluted by idle samples when computing thresholds for active-regime evaluation. Would require
a second benchmark row per queue (one per regime). Worthwhile if false positives persist after
contamination filtering is applied first.

**Per-service decomposition before rollup.**
`dexes.queue_health` already tracks `service_id`. The health function currently rolls up across all
service instances per queue name, which can mask divergence when one instance is degraded while
others are healthy. Computing per-service health first, then rolling up to queue level, would expose
this. Not urgent unless multi-instance deployments become common.

### Low priority / conditional

**Diagnostic vs restart split.**
Only relevant if health output drives automated restart or self-exit decisions. If the system
remains dashboard-only with human-in-the-loop response, this adds complexity without benefit.
Revisit if automated remediation is planned.

**Manual spot-check discipline instead of a full backtest harness.**
A formal backtest harness (labeled incidents, replay tooling, CI integration) has high overhead
for a small team. More practical near-term alternative: after each rule change, manually review
the last 2–3 real incidents against the new output and confirm true positives are preserved.

### Removed

**Quantile-confidence scoring** has been removed. Replacing discrete severity tiers with
continuous confidence scores adds implementation complexity and makes output harder for operators
to act on. The current tier model (NORMAL / ELEVATED / HIGH / ANOMALY) is appropriately expressive
for human-readable dashboards.

---

## Queue Rename and Dead Queue Cleanup Session (2026-03-23)

### Session Scope

Follow-up session covering dead queue removal and queue rename across all four pipeline services
(dexes, exponent, kamino, solstice-prop), with full ONyc DB cleanup including compressed/tiered
historical chunks and cagg rebuilds.

---

## Issue D: Dead EventsQueue infrastructure and misaligned queue names

### Background

`EventsQueue` (and `USX_EventsQueue` / `eUSX_EventsQueue` in solstice-prop) was scaffolded across
all services as a separate write path for `src_tx_events*` tables. Before it was ever wired up,
`insert_transaction_with_events` atomic bundles were introduced as a data quality fix — bundling
transaction + events in a single commit to prevent orphaned rows. This made the EventsQueue
permanently dead (no `.put()` call in any service).

Additionally, `CriticalQueue` (dexes) and `AggregatesQueue` (kamino) were misaligned names relative
to all other services, which use `TransactionsQueue` for the equivalent worker.

Decision: keep the atomic bundle, delete dead EventsQueues, rename to align:

- dexes: `CriticalQueue` → `TransactionsQueue`
- kamino: `AggregatesQueue` → `TransactionsQueue`
- exponent / solstice-prop: delete EventsQueues only (their transaction queues were already named correctly)

---

## Issue E: `solstice_proprietary` schema present in ONyc benchmark refresh

ONyc does not ingest solstice-prop data. The `solstice_proprietary.queue_health` table does not
exist on the ONyc DB. The exception handler added in Update 3.2 was masking this silently. The
schema entry in the refresh loop was dead weight and a source of confusion.

---

## Issue-to-Change Map (2026-03-23)

| Issue | Primary symptom | Change | Goal |
| --- | --- | --- | --- |
| D | Dead queues held in all services | Delete EventsQueue from main.py across all services | Remove dead infrastructure |
| D | `CriticalQueue` / `AggregatesQueue` name mismatch | Rename to `TransactionsQueue` | Align naming across pipelines |
| D | CriticalQueue hardcoded in ONyc health SQL | Remove 5 `OR queue_name = 'CriticalQueue'` literals | `%transaction%` pattern covers it automatically |
| D | Historical queue_health rows under old names | Rename/delete via untier+decompress+UPDATE/DELETE | Preserve P95 baseline under correct names |
| D | Caggs still materialised under old names | Full cagg refresh after raw data rename | Dashboard charts show correct queue labels |
| E | `solstice_proprietary` in ONyc benchmark loop | Remove from schema list in benchmarks and health function | Removes dead entry; no silent skips needed |

---

## Change Area 6: Service code — dead queue removal and renames

Files:

- `dexes/main.py`, `dexes/config.py`
- `exponent/main.py`
- `kamino/main.py`
- `solstice-prop/main.py`

### Update 6.1 — Delete dead EventsQueues

- Removed `DatabaseWriteQueue` instantiation, handler registration, health monitor registration,
  and start/stop calls for `EventsQueue` (exponent), `USX_EventsQueue` and `eUSX_EventsQueue`
  (solstice-prop), and `EventsQueue` (dexes).
- No producer ever called `.put()` on any of these queues.

### Update 6.2 — Rename CriticalQueue → TransactionsQueue (dexes)

- `self.critical_write_queue` → `self.transactions_write_queue` throughout `main.py`.
- `name="CriticalQueue"` → `name="TransactionsQueue"`.
- `QUEUE_TABLE_MAPPING` key updated in `config.py`; `EventsQueue` entry removed entirely.

### Update 6.3 — Rename AggregatesQueue → TransactionsQueue (kamino)

- `self.analytics_write_queue` → `self.transactions_write_queue` throughout `main.py`.
- `name="AggregatesQueue"` → `name="TransactionsQueue"`.
- `register_queue` call updated to match.

---

## Change Area 7: PFX queue health SQL — CriticalQueue literal removal and schema cleanup

Files:

- `pfx/dbsql/frontend-views/health/v_health_queue_table.sql`
- `pfx/dbsql/mid-level-tables/health/mat_health_queue_benchmarks.sql`

### Update 7.1 — Remove CriticalQueue hardcodes

Removed 5 instances of `OR COALESCE(c.queue_name, '') = 'CriticalQueue'` from staleness threshold
CASE blocks. `TransactionsQueue` matches the existing `LIKE '%transaction%'` pattern and receives
identical treatment automatically.

Also removed 3 dead `WHEN m.queue_name = 'EventsQueue' THEN ...` CASE blocks that were computed
in intermediate CTEs but never referenced in the severity output.

### Update 7.2 — Remove solstice_proprietary from ONyc health processing

Removed `solstice_proprietary` from the schema loop in both the health function
(`v_health_queue_table.sql`) and the benchmark refresh procedure
(`mat_health_queue_benchmarks.sql`). The `queue_health` table and all dependent views were also
dropped from the ONyc DB (`DROP TABLE solstice_proprietary.queue_health CASCADE`).

---

## Change Area 8: ONyc DB historical record cleanup

### Update 8.1 — Rename/delete across compressed and tiered chunks

Plain `UPDATE`/`DELETE` on TimescaleDB hypertables silently skips compressed chunks and cannot
touch tiered (OSM/S3) chunks at all. The correct sequence:

1. Remove tiering policy (`remove_tiering_policy`)
2. Untier all OSM chunks (`CALL untier_chunk(chunk_name)`)
3. Run `UPDATE`/`DELETE` (now reaches all chunks)
4. Re-enable tiering policy (`add_tiering_policy`)
5. Compression policy reapplies on schedule (no manual step needed)

Deadlock errors during bulk `untier_chunk` are transient (background platform job conflict) — retry
with a short pause.

Rows affected:

- `dexes.queue_health`: 54,272 `CriticalQueue` → `TransactionsQueue`; 54,272 `EventsQueue` deleted
- `exponent.queue_health`: 55,551 `EventsQueue` deleted
- `kamino_lend.queue_health`: 54,223 `AggregatesQueue` → `TransactionsQueue`

### Update 8.2 — Cagg full refresh after rename

`UPDATE` on hypertable rows does not automatically invalidate already-materialised cagg buckets.
After renaming raw data, each affected cagg must be fully refreshed:

```sql
CALL refresh_continuous_aggregate('dexes.queue_health_hourly', NULL, NULL);
CALL refresh_continuous_aggregate('exponent.queue_health_hourly', NULL, NULL);
CALL refresh_continuous_aggregate('kamino_lend.queue_health_hourly', NULL, NULL);
```

`NULL, NULL` forces a full history recompute from the (now-renamed) underlying rows.

### Update 8.3 — Benchmark ghost row cleanup

After the raw data rename, the benchmarks cronjob re-ran mid-session and re-introduced old queue
names (it does a full `TRUNCATE` + re-insert from `queue_health`). Ghost ANOMALY rows appeared in
the health table for `CriticalQueue`, `AggregatesQueue`, and `EventsQueue` because the view injects
synthetic rows for any benchmark entry absent from current data.

Fix: run `CALL health.refresh_mat_health_queue_benchmarks()` after the raw data rename and cagg
refresh are complete. This re-reads the now-clean `queue_health` tables and produces only correct
queue names in the benchmark table.

**Sequencing rule:** always complete the full raw-data rename before calling the benchmark refresh.
Running it mid-rename will re-seed old names and require a second pass.

### Update 8.4 — v_health_master_table missing from ONyc DB

`health.v_health_master_table` was absent from the ONyc DB (dropped by an earlier `DROP ... CASCADE`
from a previous redeploy that was not fully recovered). Deployed from
`pfx/dbsql/frontend-views/health/v_health_master_table.sql`.

**Deployment note:** the full redeploy sequence (mid-level → frontend → `refresh_mat_health_all`)
documented in the 2026-03-22 session includes `DROP ... CASCADE` statements that can silently drop
`v_health_master_table` if it depends on a view being recreated. Always verify the master table
exists after a full redeploy.

---

## Solstice Pipeline — Deferred

The equivalent DB record cleanup for Solstice is deferred until Solstice services are redeployed
with the new queue names. The Solstice health SQL (`health/dbsql/v_health_queue_table.sql`) still
contains the `CriticalQueue` literal and must not be updated until then.

Full checklist: `handover-docs-260300/SOLSTICE_QUEUE_RENAME_TODO.md`

Key difference from ONyc: Solstice has no tiered storage. Chunk decompression is the only
prerequisite before `UPDATE`/`DELETE`. No benchmark table on Solstice — P95 is computed inline.
