# Health Views

This directory contains SQL objects used by the frontend health dashboard.

## Files

- `v_health_master_table.sql`: binary RED/GREEN summary per domain plus `MASTER`.
- `v_health_queue_table.sql`: queue-level health with severity breakdown.
- `v_health_queue_chart.sql`: chart function for queue metrics over time.
- `v_health_trigger_table.sql`: trigger freshness and status.
- `v_health_base_table.sql`: base table freshness and status.
- `v_health_base_chart.sql`: chart function for base table freshness.
- `v_health_cagg_table.sql`: CAGG freshness and lag status.

## Domain Mapping

The health layer currently evaluates these domains:

- `dexes`
- `exponent`
- `kamino_lend`
- `solstice_proprietary` (queue table function includes this domain)

`v_health_master_table` currently renders rows for:

- `dexes`
- `exponent`
- `kamino_lend`
- `MASTER`

## Queue Health Model

Queue health is produced by `health.v_health_queue_table` (backed by `health._fn_queue_table()`).

### Inputs

- Latest row per queue from `<schema>.queue_health` in the last 1 hour.
- 7-day per-queue P95 benchmarks from `health.mat_health_queue_benchmarks`:
  - `p95_staleness_7d`
  - `p95_utilization_pct_7d`
  - `p95_consecutive_failures_7d`

Benchmarks are refreshed by:

- `health.refresh_mat_health_queue_benchmarks()`

### Severity Dimensions

Each queue gets 3 severities in range `0..3`:

- `gap_severity`
- `util_severity`
- `fail_severity`

`summary_severity = GREATEST(gap_severity, util_severity, fail_severity)`.

`is_red = summary_severity >= 3`.

### Hybrid Gap Severity (Anti-Desensitization)

Gap severity is not pure P95 anymore. It is now the maximum of:

1. Dynamic baseline severity from `staleness_ratio`.
2. Absolute wall-clock threshold severity.
3. Raw warning passthrough from queue `warning_level`.

#### Dynamic baseline

`staleness_ratio = seconds_since_last_write / min(p95_staleness_7d, cap)`

`cap` is queue-type aware:

- event/txn/CriticalQueue patterns: `86400s` (24h)
- all other queues: `3600s` (1h)

Dynamic levels:

- `<= 1.25`: severity `0` (deadband to avoid edge jitter)
- `<= 3.0`: severity `1`
- `<= 10.0`: severity `2`
- `> 10.0`: severity `3`

Queue-specific caps prevent very large historical P95 values from permanently reducing sensitivity.

#### Absolute thresholds

Absolute thresholds enforce floor sensitivity even when historical baseline is noisy.

For event/txn/CriticalQueue patterns:

- warn: `>= 86400s` (1d) -> severity `1`
- high: `>= 172800s` (2d) -> severity `2`
- anomaly: `>= 345600s` (4d) -> severity `3`

For all other queues:

- warn: `>= 300s` (5m) -> severity `1`
- high: `>= 900s` (15m) -> severity `2`
- anomaly: `>= 3600s` (1h) -> severity `3`

#### Warning passthrough

Queue warning levels also contribute directly:

- `warning` -> severity `1` (except idle stale-warning suppression, see below)
- `degraded` -> severity `2`
- `critical` -> severity `3`
- `ok`/null -> severity `0`

#### Idle-safe suppression

For write-on-difference queues, gap severity is forced to `NORMAL` when all are true:

- `queue_size = 0`
- `consecutive_failures = 0`
- queue is **not** event/txn/CriticalQueue pattern
- warning is absent/non-critical, or it's the specific stale message pattern:
  `No writes for ... - queue may be stalled` with `write_rate_per_min = 0`

This avoids false positives from idle workers while preserving event-driven sensitivity.

### Why warnings can still be GREEN

`v_health_master_table` is binary. It is RED only when at least one component row has `is_red=true` (severity 3).

So:

- `ELEVATED`/`HIGH` severities (`1` or `2`) are intentionally still GREEN at the master level.
- Only `ANOMALY` (`3`) flips RED.

## Synthetic Missing-Queue Detection

`v_health_queue_table` inserts synthetic rows for known historical queues that have no recent data.

If a queue disappears from the last-hour snapshot but exists in benchmark history, it gets:

- `snapshot_time = NULL`
- severity forced to `3` in all dimensions
- `is_red = true`

This catches dead/stopped ingestion processes that no longer write queue metrics.

## Operational Queries

### Current queue status (dexes)

```sql
SELECT domain, queue_name, seconds_since_last_write, p95_staleness_7d,
       gap_severity, util_severity, fail_severity, summary_severity,
       summary_status, is_red, snapshot_time
FROM health.v_health_queue_table
WHERE domain = 'dexes'
ORDER BY queue_name;
```

### Master health

```sql
SELECT domain, domain_label, queue_red, trigger_red, base_red, cagg_red, is_red, status
FROM health.v_health_master_table
ORDER BY CASE WHEN domain = 'MASTER' THEN 0 ELSE 1 END, domain;
```

### Latest raw queue metrics

```sql
SELECT queue_name, time, seconds_since_last_write, queue_utilization_pct,
       consecutive_failures, warning_level, warning_message
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY queue_name ORDER BY time DESC) AS rn
    FROM dexes.queue_health
    WHERE time > NOW() - INTERVAL '6 hours'
) t
WHERE rn = 1
ORDER BY queue_name;
```

## Change Log Notes

As of 2026-03-22, queue gap logic was hardened to avoid P95 drift desensitization by:

- queue-type-aware dynamic caps (1h for state/write-on-diff, 24h for event/txn/Critical),
- deadband at 1.25x baseline,
- wider absolute thresholds for sparse event/txn queues (1d/2d/4d),
- idle-safe suppression for write-on-difference queues,
- and warning passthrough with stale-warning suppression for zero-backlog idle rows.
