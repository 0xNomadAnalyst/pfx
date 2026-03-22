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

1. Queue-type classification dependence.
If a queue is misclassified (state-like vs event-like), thresholds can still be too strict or too loose.

2. Threshold constants still exist.
Even with dynamic caps/deadband, absolute bounds can still be overly sensitive in rare market regimes.

3. Mixed-stream aggregation artifacts.
Aggregating different source behaviors into one queue line can still produce edge-case noise.

4. Warning taxonomy drift.
If warning text format changes upstream, stale-warning suppression patterns may need updates.

5. Dormant-to-active transition spikes.
When a long-dormant stream resumes, first-write timing can look abrupt and needs careful interpretation.

---

## Potential Next Steps (Avenues for Improvement)

These are future options to reduce dependence on fixed thresholds while avoiding the original P95 desensitization trap.

1. Regime-aware baselines.
Maintain separate adaptive baselines for idle (`queue_size=0`) and active (`queue_size>0`) regimes.

2. Contamination-resistant baseline updates.
Exclude samples from known anomaly periods when refreshing benchmark distributions.

3. Quantile-confidence scoring.
Move from fixed severity cutoffs to confidence-weighted rarity scoring over rolling windows.

4. Persistence gating.
Require sustained abnormality across multiple windows before escalation to `HIGH/ANOMALY`.

5. Per-service decomposition before rollup.
Compute service-level health first, then roll up to queue-level to reduce mixed-stream masking/noise.

6. Diagnostic vs restart split.
Keep richer anomaly classes for dashboards, but use stricter liveness predicates for self-exit/restart actions.

7. Backtest harness before promotion.
Replay historical data, quantify precision/recall of anomaly rules, and tune against measured false-positive rates.
