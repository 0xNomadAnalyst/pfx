# Resilience, Recovery, and Monitoring

This document covers the platform's approach to failure recovery, health monitoring, and operational visibility. The architecture follows a deliberate philosophy: **in-service recovery is short-lived and time-bounded; persistent failures are handed off to the hosting platform via failed health checks (Kubernetes probes where available, or a self-exit watchdog on platforms without continuous probes)**.

Related companion documents:

- **01-INGESTION.md** -- Python ingestion services and shared modules.
- **02-DATABASE.md** -- in-database ETL, CAGGs, view functions.
- **05-DEPENDENCIES.md** -- external service/API dependencies, hosting, credentials.

---

## Recovery Architecture Overview

The platform uses a three-tier recovery model. Each tier has a bounded time budget; if recovery fails, control escalates to the next tier.

```
Tier 1: Internal Reconnect (seconds)
  gRPC watchdog, DB @with_reconnect decorator
  Short-lived — exponential backoff, limited retries
          │
          ▼  (fails)
Tier 2: Automatic Thread Restart (minutes)
  monitor_txn_stream() restarts dead subscription threads
  Up to 5 restarts with 60s cooldown between attempts
          │
          ▼  (fails, or GRPC_MAX_RECOVERY_TIME_S exceeded)
Tier 3: Platform Restart (Kubernetes probe or self-exit watchdog)
  /health returns 503 â†’ liveness probe fails â†’ pod restart
  Clean restart with fresh connections and state
```

The total recovery time budget defaults to **300 seconds** (5 minutes) from the last successful data callback (`GRPC_MAX_RECOVERY_TIME_S`). Once exceeded, the service reports unhealthy regardless of whether internal recovery is still attempting, ensuring platform-level restart logic intervenes promptly.

---

## Tier 1: In-Service Reconnect

### gRPC Stream Recovery (`shared/yellowstone_grpc_client`)

The `YellowstoneClient` includes a stream health watchdog and reconnect loop:

- **Watchdog thread** -- a daemon thread checks every 30 seconds whether updates have been received within `stream_timeout_seconds` (default: 300s). After two consecutive timeout warnings, it marks the stream as dead and forcibly closes the gRPC channel to unblock the blocking stream iterator.
- **`subscribe_blocks_with_reconnect()`** -- wraps the raw block subscription in a reconnect loop with:
  - Exponential backoff: 5s initial, 2x multiplier, capped at 300s (5 min).
  - Consecutive failure counter (default max: 10). Resets on any successful data receipt.
  - Respects a `running_flag` callable for graceful shutdown coordination.
  - Raises `RuntimeError` when max consecutive failures are exhausted.
- **`subscribe_combined()`** (used for combined transaction + account streams) -- starts the watchdog on entry. On each stream update, calls `touch_stream_health()` to reset the watchdog timer. The watchdog sets a `StreamTimeoutError` which the iterator checks and raises to trigger reconnection at the caller level.
- **Dynamic subscription updates** -- account and transaction filters can be added to a live stream via a thread-safe queue (`add_account_subscriptions()`, `add_transaction_subscriptions()`). The request iterator yields cumulative subscription updates without dropping the connection.

**Design intent:** gRPC reconnects are short-lived. The shared client handles transient network blips and provider restarts. Persistent gRPC failures (provider outage, credential expiry) should be resolved at the container level, not by indefinite retry loops.

### Database Reconnect (`shared/timescaledb_client`)

The `TimescaleDBClient` provides automatic reconnection at the connection and operation level:

- **`@with_reconnect` decorator** -- wraps database operations with retry logic:
  - Pre-checks connection health (`check_connection()` via `SELECT 1`).
  - On `InterfaceError` or `OperationalError`: reconnects with exponential backoff (1s, 2s, 4s) up to 3 retries.
  - Non-connection errors propagate immediately (no retry).
- **Connection pooling** -- `ThreadedConnectionPool` (psycopg2) with configurable min/max connections (default: 3-10). Pool recreation on reconnect.
- **TCP keepalives** -- configured on all connections (`keepalives_idle=30`, `keepalives_interval=10`, `keepalives_count=5`) for early detection of dropped connections.
- **`safe_rollback()`** -- handles rollback on already-closed connections gracefully, preventing cascading exceptions during error recovery.

**Design intent:** database reconnects handle transient connection drops (network blips, connection pool exhaustion, TimescaleDB maintenance windows). The `@with_reconnect` decorator is applied to write queue handler functions, so individual write failures trigger reconnection transparently.

### Write Queue Recovery (`shared/db_write_queue`)

Each `DatabaseWriteQueue` has its own escalating recovery:

- **Per-failure tracking** -- consecutive failure counter resets on any successful write.
- **Recovery cycles** -- after `max_consecutive_failures` (default: 10) consecutive failures, the queue enters a recovery cycle:
  - Escalating backoff: 5s, 10s, 20s, 40s, ... capped at 60s.
  - After the pause, the consecutive failure counter resets and the worker retries.
  - Up to `_max_recovery_cycles` (default: 10) cycles (~5-10 min of persistent DB outage).
- **Fatal state** -- after exhausting all recovery cycles, `_db_fatal` is set to `True`. The health check detects this and reports unhealthy, triggering a Kubernetes restart.
- **Bounded queue** -- `maxsize=10000` prevents unbounded memory growth during outages.

---

## Tier 2: Automatic Thread Restart

The `monitor_txn_stream()` function (in `shared/healthcheck/common_checks.py`) is called from each service's main poll loop on every cycle. It implements automatic restart of dead gRPC subscription threads:

1. **Thread alive, data flowing** -- no-op. Resets restart counter if it was elevated from a previous recovery.
2. **Thread alive, no data for >5 min** -- logs a stall warning (throttled to every 10th poll).
3. **Thread dead, within restart budget** -- spawns a replacement thread via the service's `_create_txn_subscription_thread` factory. Up to 5 restarts with 60-second cooldown between attempts.
4. **Thread dead, restarts exhausted or recovery budget expired** -- logs `CRITICAL` and does not restart. The health check reports unhealthy, handing off to Kubernetes.

---

## Tier 3: Platform Restart (Kubernetes + non-K8s)

### Service Health Endpoint (`/health`)

Each service runs a lightweight HTTP health check server (`shared/healthcheck/healthcheck_server.py`) on port 8080 (configurable via `HEALTHCHECK_PORT`). The server uses Python's built-in `http.server` (no external dependencies) and runs in a daemon thread alongside the main service.

**Response format:**

```json
{
  "status": "healthy",
  "service": "exponent",
  "timestamp": "2026-02-11T04:30:00+00:00",
  "uptime_seconds": 43200.0,
  "components": {
    "app":          { "healthy": true, "running": true, "uptime_seconds": 43200.0 },
    "database":     { "healthy": true, "connected": true },
    "grpc":         { "healthy": true, "mode": "grpc_enabled", "txn_stream_thread": "alive" },
    "polling":      { "healthy": true, "poll_count": 1440 },
    "write_queues": { "healthy": true, "queues_monitored": 5, "workers_alive": 5 }
  }
}
```

Returns `200` when all components are healthy; `503` when any component is unhealthy. Every component returns its own `healthy` boolean plus diagnostic details.

### Check Function Library (`common_checks.py`)

All check functions follow a uniform signature: `check_*(app) -> (is_healthy: bool, details: dict)`. The `app` argument is the service's main poller/app instance. All attribute access uses `getattr` with fallbacks, so checks never crash if a service doesn't expose a particular attribute.

| Check Function | What It Inspects | Reports Unhealthy When |
|---|---|---|
| `check_running(app)` | `app.running` flag, `app.start_time` | Never -- reports `"initializing"` during startup, healthy otherwise. Includes uptime and configurable stat counters. |
| `check_database(app)` | `app.db_client.conn` (psycopg2 connection) | Connection is `None` or `conn.closed == True`. |
| `check_write_queues(app)` | All queues in `app.queue_health_monitor` | Any worker thread is dead while `queue.running=True`, or any queue has entered `_db_fatal` state (recovery cycles exhausted). Activity level is intentionally **not** checked -- write-on-difference logic skips writes when data is unchanged, so idle queues are healthy. |
| `check_grpc_wrapper(app)` | gRPC wrapper client channels + subscription thread | Channel(s) missing, or `grpc_txn_subscription_thread` is dead, or `GRPC_MAX_RECOVERY_TIME_S` recovery budget expired. Used by Exponent, Kamino, and Solstice. |
| `check_grpc_direct(app)` | Direct `YellowstoneClient` channel + consecutive failure counter + data staleness | Channel missing, or `_grpc_consecutive_failures >= 3` (stream in active reconnect loop), or `_last_grpc_data_time` exceeds `GRPC_MAX_RECOVERY_TIME_S` (silent stream stall -- channel connected but no data arriving). Used by DEXes. |
| `check_polling(app)` | `app.poll_count`, `app.error_count`, `app.last_poll_time` | Never -- purely informational (poll counter and freshness). |

### Per-Service Check Registration

Each service has a thin local wrapper (`<service>/core/healthcheck.py`) that imports shared checks and registers service-specific ones:

| Check | DEXes | Exponent | Kamino | Solstice |
|---|---|---|---|---|
| `check_running` (app) | yes | yes | yes | yes |
| `check_database` | yes | yes | yes | yes |
| `check_write_queues` | yes | yes | yes | yes |
| `check_grpc_direct` | yes | -- | -- | -- |
| `check_grpc_wrapper` | -- | yes | yes | yes |
| `check_polling` | -- | yes | yes | -- |
| `check_poller` (service-specific) | yes (pool-state poller thread) | -- | -- | -- |
| `check_account_poller` (service-specific) | -- | -- | -- | yes (RPC account-state poller thread) |
| `monitor_txn_stream` (poll-loop call) | -- | yes | yes | yes |

### gRPC Check Variants

Two gRPC check variants exist because services wrap the Yellowstone client differently:

**`check_grpc_wrapper`** (Exponent, Kamino, Solstice) -- these services use protocol-specific gRPC wrapper classes (`ExponentGrpcClient`, `KaminoGrpcClient`, `USXGrpcClient`) that store the `YellowstoneClient` as `.client`. The check verifies:
1. Channel existence on the inner client (`.client.channel`).
2. Subscription thread liveness (`grpc_txn_subscription_thread.is_alive()`).
3. Recovery budget (`GRPC_MAX_RECOVERY_TIME_S` seconds since last data callback).
4. Supports both separate-client mode (`grpc_txn_client` + `grpc_account_client`) and combined-client mode (`grpc_client`).

**`check_grpc_direct`** (DEXes) -- the DEXes service uses `YellowstoneClient` directly (channel is a direct attribute). The check monitors two failure signals: (1) `_grpc_consecutive_failures` to detect when the main-thread reconnect loop is actively failing -- reports unhealthy at `>= 3` consecutive failures, well before the 10-failure process crash, giving the container orchestrator time to intervene; and (2) `_last_grpc_data_time` staleness -- if no data callback has fired within `GRPC_MAX_RECOVERY_TIME_S` (default 300s), the check returns UNHEALTHY even when the failure counter is zero. This catches a failure mode where the gRPC channel stays connected but silently stops delivering data. When triggered, the response includes `data_stale: true` and `recovery_budget_expired: true`.

### Key Design Decisions

- Health is based on **process/thread liveness**, not data activity. Write-on-difference logic intentionally skips writes when data is unchanged -- idle queues are healthy.
- During initialisation (discovery phases can take minutes), all checks report healthy with an `"initializing"` note so the container orchestrator does not prematurely restart the service.
- No external dependencies -- uses Python's `http.server` stdlib module.
- Failure logging is throttled to once per 60 seconds to balance visibility with noise in container logs.
- Each component's diagnostic details are included in the JSON response, providing actionable context when a check fails (e.g. `"dead_workers": {"CriticalQueue": "..."}`, `"recovery_budget_expired": true`).

### Dockerfile HEALTHCHECK

Each Dockerfile includes a Docker-level health check that calls the `/health` endpoint:

```dockerfile
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1
```

- **30s interval** -- checked frequently enough to detect failures promptly.
- **60s start period** -- allows time for service initialisation and market/reserve discovery.
- **3 retries** -- prevents restart on transient health check failures.


### Non-Kubernetes Hosting: Self-Exit Watchdog

For environments that do not provide continuous liveness probing (for example Railway), `HealthCheckServer.start()` supports `enable_self_exit=True`.

When enabled, a watchdog thread polls `get_health()` at a fixed interval. If health remains UNHEALTHY for N consecutive polls, it force-terminates the process with `os._exit(1)`. The hosting platform restart policy (`ON_FAILURE`) then restarts the service.

This provides bounded recovery behavior in non-K8s hosting environments, aligning with the same restart intent used by Kubernetes liveness probes.

| Environment variable | Default | Purpose |
|---|---|---|
| `HEALTHCHECK_SELF_EXIT` | `0` | Set `1` to enable watchdog self-exit behavior |
| `HEALTHCHECK_SELF_EXIT_FAILURES` | `10` | Consecutive UNHEALTHY polls before `os._exit(1)` |
| `HEALTHCHECK_SELF_EXIT_INTERVAL_S` | `30` | Watchdog poll interval in seconds |

With defaults (`30s` interval, `10` failures), self-exit occurs after ~5 minutes of continuous unhealthy state.

| Platform | Recommended setting |
|---|---|
| Kubernetes | `HEALTHCHECK_SELF_EXIT=0` (liveness probe handles restart) |
| Railway / no continuous probes | `HEALTHCHECK_SELF_EXIT=1` with restart-on-failure policy |

### Kubernetes Deployment (Placeholder)

> **Note for cloud engineer:** Kubernetes deployment configuration (liveness/readiness probes, restart policies, resource limits, replica counts, pod disruption budgets) should be documented here once the production cluster configuration is finalised.
>
> The services are designed to work with a standard Kubernetes liveness probe pointing at `GET /health:8080`. Recommended probe configuration:
>
> ```yaml
> livenessProbe:
>   httpGet:
>     path: /health
>     port: 8080
>   initialDelaySeconds: 60
>   periodSeconds: 30
>   timeoutSeconds: 10
>   failureThreshold: 3
> ```
>
> Each service handles `SIGTERM` for graceful shutdown (queue flushing, gRPC disconnection, DB connection cleanup) before the Kubernetes termination grace period expires.

---

## Graceful Shutdown

All four services register `SIGTERM` and `SIGINT` signal handlers. On shutdown:

1. Set `running = False` to stop poll loops and subscription threads.
2. Stop the health check server.
3. Stop the queue health monitor.
4. **Flush all write queues** -- each queue's `stop(timeout=5.0)` method drains remaining items and waits for the worker thread to finish. This prevents data loss for items already queued.
5. Disconnect gRPC clients (closes channels gracefully; `CANCELLED` status is expected and handled).
6. Disconnect database (close connection pool or single connection).
7. Log final statistics.

---

## DB-Side Pipeline Health Dashboard

Beyond the `/health` endpoint (which serves the container orchestrator), a second monitoring layer provides **human-facing operational visibility** via database-side health views and a marimo dashboard.

### Health Schema (`health/`)

The `health` PostgreSQL schema contains views and functions that monitor the full data pipeline by querying the data itself. These views are deployed via `python health/deploy_health_views.py`.

| View / Function | What it monitors |
|---|---|
| `v_health_queue_table` | Per-queue health: size, utilization, write rate, staleness vs 7-day P95 baselines, consecutive failures. Severity levels: NORMAL / ELEVATED / HIGH / ANOMALY per dimension (gap, utilization, failures). Injects synthetic ANOMALY rows for historically known queues that are absent from recent data (dead process detection -- if a service dies, it stops writing to `queue_health` and the queue would otherwise silently disappear from the view). |
| `v_health_base_table` | Source table activity: latest timestamp, row counts (1h, 24h), hourly averages, frequency-based staleness detection. Gap ratio determines severity: Active (â‰¤2x), Check (2-3x), Stale (3-5x), ANOMALY (>5x). Also triggers immediate ANOMALY if `rows_last_hour = 0` for a table that normally averages â‰¥10 rows/hour. |
| `v_health_cagg_table` | CAGG refresh health: compares CAGG bucket times to source table times across all 21 CAGGs. Statuses: Refresh OK (â‰¤5 min lag), Refresh Delayed (5-15 min), Source Stale (source age >2x expected gap), Refresh Broken (>15 min behind a fresh source). Fires `is_red` when source is critically stale (>5x expected gap or NULL), not only when refresh lags behind a fresh source. |
| `v_health_trigger_table` | Trigger function health (DEXes only): checks whether `trg_fill_raydium_pre_price` and `trg_calculate_swap_impact` are populating derived columns. Compares trigger-populated row counts against all-swap row counts. |
| `v_health_master_table` | Binary summary: one row per domain + one MASTER row. RED if any critical indicator in any section; GREEN otherwise (tolerates ELEVATED and HIGH). |
| `v_health_base_chart()` | Parameterised function: time-bucketed row counts for source tables by domain, lookback, and interval. Categories: Transaction Events vs Account Updates. |
| `v_health_queue_chart()` | Parameterised function: time-bucketed queue health metrics (size, write rate, gap, failures) per domain. |

### Dashboard (`health/tempviz/health_page_sql.py`)

A [marimo](https://marimo.io) notebook that queries the health views and renders an interactive monitoring UI. Sections:

- **Queue Health** -- write rates, staleness vs P95 baselines, failure counts, utilization.
- **CAGG Refresh** -- whether the external CAGG refresh cronjob is running and all 21 CAGGs are keeping up with their source tables.
- **Source Table Activity** -- row counts and recency per source table vs historical benchmarks.
- **Trigger Health** -- DEXes trigger functions producing derived columns.
- **Activity Benchmarks** -- hourly event/state counts vs 24h rolling averages.
- **Queue Trends** -- hourly aggregated operations, failure rates, utilization (90-day lookback).

### Service Alive Signal

The `queue_health` hypertable in each domain schema receives a write every ~60 seconds from the `QueueHealthMonitor`, regardless of data activity. The recency of `MAX(time)` from `{schema}.queue_health` is the most reliable DB-derived signal for whether a service process is running.

### How the Two Layers Complement Each Other

| Concern | `/health` endpoint | DB dashboard |
|---|---|---|
| "Is the container alive?" | Sub-second answer | Minutes of detection lag |
| "Should the platform restart it?" | Yes (automated) | No (informational only) |
| "Why did data stop flowing?" | Component-level hint | Rich root cause analysis |
| "Is this queue behaving abnormally?" | No | Yes (statistical baselines) |
| "Are CAGGs / triggers working?" | No | Yes |
| "What are the long-term trends?" | No | Yes (7-day / 90-day) |

---

## Queue Health Telemetry

The `QueueHealthMonitor` (`shared/db_write_queue/queue_health_monitor.py`) runs as a daemon thread in each service, collecting metrics from all registered write queues every 60 seconds:

- **Queue state** -- size, utilization percentage, max capacity.
- **Operation counts** -- total successes, total failures, consecutive failures.
- **Rate metrics** -- write rate/min, failure rate/min, queue growth rate/min.
- **Freshness** -- seconds since last successful write (staleness detection).
- **Health classification** -- warning levels (ok / warning / critical / degraded) based on configurable thresholds: 50% utilization (warning), 80% (critical), 120s write staleness (warning), 5+ consecutive failures (degraded).

Metrics are persisted to the `{schema}.queue_health` hypertable via a registered callback, making them available to the DB-side health views and dashboard.

---

## TimescaleDB High Availability

TimescaleDB Cloud (the hosting platform) offers HA replica services with automatic failover. These are available at additional cost and **have not been enabled at the time of handover**. If HA is required for production, it can be enabled through the Timescale Cloud console without application changes -- the connection string remains the same and failover is transparent to clients.

Further details on the database hosting platform will be covered in **05-DEPENDENCIES.md**.

---

## Data Gap Recovery (Backfill)

The three-tier recovery model above prevents data loss going forward by restarting services quickly. However, any data missed during the downtime window itself (between failure and successful recovery) represents a gap in the time-series. These gaps are recovered using **offline backfill utilities**.

Each service includes a `backfill-qa/` directory with scripts that:

1. **Fetch** historical transactions from the [Solscan Pro API](https://solscan.io/) for the affected time range.
2. **Process** raw Solscan data through the same decode and enrichment logic used by the live ingestion pipeline, producing records that match the service's `src_*` table schemas.
3. **Upload** processed records to the database (upsert, so re-running is safe).
4. **Validate** completeness via balance reconstruction QA -- independently re-deriving account balances from events and comparing against known on-chain snapshots.

| Service | Backfill Directory |
|---|---|
| DEXes | `dexes/backfill-qa/` |
| Exponent | `exponent/backfill-qa/` |
| Kamino | `kamino/backfill-qa/` |
| Solstice | `solstice-prop/backfill-qa/` |
| Shared helpers | `shared/backfill-qa-solscan/` |

The Solscan Pro API ($200/month at time of writing) is required for the transaction fetch step. The subscription can be activated on-demand since backfill is an occasional recovery activity. See **05-DEPENDENCIES.md** for full details on external dependencies including Solscan.

Continuous aggregates (CAGGs) automatically pick up backfilled data on their next refresh cycle -- no manual CAGG intervention is needed after an upload.

---

## Configuration Reference

| Parameter | Default | Location | Purpose |
|---|---|---|---|
| `GRPC_MAX_RECOVERY_TIME_S` | 300 | env var / `common_checks.py` | Max seconds from last data callback before handing to K8s |
| `_MAX_TXN_THREAD_RESTARTS` | 5 | `common_checks.py` | Max automatic thread restarts before falling through to K8s |
| `_TXN_THREAD_RESTART_COOLDOWN_S` | 60 | `common_checks.py` | Min seconds between restart attempts |
| `stream_timeout_seconds` | 300 | `YellowstoneClient` | gRPC stream inactivity timeout (watchdog) |
| `max_consecutive_failures` (gRPC) | 10 | `subscribe_blocks_with_reconnect()` | gRPC reconnect loop failure limit |
| `max_consecutive_failures` (queue) | 10 | `DatabaseWriteQueue` | Write failures before entering recovery cycle |
| `_max_recovery_cycles` | 10 | `DatabaseWriteQueue` | Recovery cycles before fatal state |
| `@with_reconnect max_retries` | 3 | `TimescaleDBClient` | DB operation retry count |
| `HEALTHCHECK_ENABLED` | `true` | env var | Enable/disable health check server |
| `HEALTHCHECK_PORT` | `8080` | env var | Health check HTTP port |
| `HEALTHCHECK_SELF_EXIT` | `0` | env var | Enable process self-exit watchdog for non-K8s hosting |
| `HEALTHCHECK_SELF_EXIT_FAILURES` | `10` | env var | Consecutive unhealthy checks before `os._exit(1)` |
| `HEALTHCHECK_SELF_EXIT_INTERVAL_S` | `30` | env var | Seconds between self-exit watchdog health polls |

---

## Where to Go Next

- **`shared/healthcheck/README.md`** -- detailed health check module documentation with Kubernetes probe configuration.
- **`health/README.md`** -- deploying and maintaining the DB-side health views.
- **`health/tempviz/health_page_sql.py`** -- the marimo monitoring dashboard.
- **`shared/db_write_queue/`** -- write queue and health monitor implementation.
- **`shared/yellowstone_grpc_client/`** -- gRPC client with watchdog and reconnect.
- **`shared/timescaledb_client/`** -- database client with connection pooling and reconnect.
- **01-INGESTION.md** -- shared service architecture and module reference.
- **05-DEPENDENCIES.md** -- external service dependencies and hosting platform details.


