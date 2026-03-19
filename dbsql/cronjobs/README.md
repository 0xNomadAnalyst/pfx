# ONyc Pipeline Refresh Cronjob

Continuous-loop service that refreshes the mid-level ETL pipeline: TimescaleDB
continuous aggregates (CAGGs), materialized summary tables, auxiliary/discovery
tables, health monitoring, and risk analytics.

Runs as a standalone Docker container (`postgres:16-alpine` + `bash`) with no
Python dependencies — all work is done via `psql` against the shared
TimescaleDB instance.

## Tiered Refresh Model

| Tier | Cadence | What it refreshes |
|---|---|---|
| **Tier 1** | Every cycle (default 30s) | All 21 CAGGs + all domain mat tables + health mat tables + cross-protocol mat tables |
| **Tier 2** | Every 10 cycles (~5 min) | Auxiliary/discovery tables (Kamino `aux_market_reserve_tokens`, Exponent `aux_key_relations`, Dexes `pool_tokens_reference`) |
| **Tier 3** | Every 60 cycles (~30 min) | Health check (CAGG status, mat table freshness) |
| **Risk** | Every 60 cycles (~30 min) | `risk_pvalues` refresh |
| **Daily** | Midnight UTC | Retention cleanup (delete + vacuum mat data older than `MAT_RETENTION_DAYS`) |

## Parallel Execution

CAGG and mat table refreshes are parallelized by domain to keep cycle time
under the target interval. Each domain gets its own `psql` session.

### CAGG refresh (3 parallel sessions)

```
Session 1: dexes       (4 CAGGs)  ─┐
Session 2: kamino      (3 CAGGs)  ─┼─ wait all ─→ done
Session 3: exponent    (8 CAGGs)  ─┘
```

Wall-clock time = slowest domain, not the sum. Previously all 21 CAGGs ran
sequentially in a single session (~60-90s), which was the primary source of
multi-minute CAGG lag.

### Mat table refresh (4 parallel sessions + 1 sequential)

```
Phase 1 (parallel):
  Session 1: dexes      (timeseries_1m, ohlcv_1m, last)  ─┐
  Session 2: kamino     (timeseries_1m, last, config)     ─┼─ wait all
  Session 3: exponent   (timeseries_1m, last)             ─┤
  Session 4: health     (refresh_mat_health_all)          ─┘
                                                            │
Phase 2 (sequential, depends on phase 1):                   ▼
  cross_protocol.refresh_mat_xp_all()
```

Cross-protocol must run after domain mat tables because it reads from them.

## CAGG Refresh Window

Each CAGG refresh call specifies a time window:

```sql
CALL refresh_continuous_aggregate('schema.cagg',
    NOW() - INTERVAL '30 minutes',   -- lookback (start)
    NOW() - INTERVAL '10 seconds'    -- upper bound (end)
);
```

### Lookback (30 minutes)

Every bucket within the last 30 minutes is re-materialized on **every cycle**.
This provides a safety net for:

- **Late-arriving data** — rows inserted after their bucket's time range has
  passed are picked up on the next refresh.
- **Partial materialization** — if a bucket was materialized with incomplete
  data in one cycle, the next cycle recomputes it with the full data.
- **Catch-up after downtime** — if the cronjob is down for up to 30 minutes,
  the first cycle after restart covers the entire gap. Downtime longer than 30
  minutes will leave unmaterialized buckets that require a manual wider refresh.

### Upper bound (10 seconds)

Controls how **recent** the latest materialized bucket can be. Set to 10
seconds (2x the 5-second bucket size) to avoid materializing a bucket that is
still being written to by the ingestion service. This is separate from the
lookback — the lookback determines which older buckets get re-checked, while
the upper bound determines freshness of the newest bucket.

| Upper bound | Latest CAGG bucket age | Trade-off |
|---|---|---|
| 1 minute | ~60s behind source | Conservative; guaranteed no partial-bucket edge cases |
| 10 seconds | ~10s behind source | Fresher data; safe for 5s buckets since 10s > bucket width |

## Configuration

All parameters are overridable via environment variables.

| Variable | Default | Purpose |
|---|---|---|
| `MAT_REFRESH_INTERVAL_S` | `30` | Seconds between cycles |
| `CAGG_REFRESH_WINDOW` | `30 minutes` | CAGG lookback window |
| `AUX_REFRESH_MULT` | `10` | Aux table sync every N cycles |
| `HEALTH_CHECK_MULT` | `60` | Health check every N cycles |
| `RISK_REFRESH_MULT` | `60` | Risk analytics every N cycles |
| `MAT_RETENTION_DAYS` | `100` | Days of mat data to retain |
| `MAX_CONSECUTIVE_FAILURES` | `10` | Consecutive cycle failures before exit |
| `ONYC_SINGLE_RUN` | `0` | Set to `1` for one-shot mode (one full cycle then exit) |

Database connection uses standard `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
`DB_PASSWORD` env vars (with fallbacks to `TIMESCALEDB_*` and `PG*` variants).

## Running

**Continuous (default):**

```bash
docker build -t onyc-refresh -f Dockerfile .
docker run --env-file ../../.env.pfx.core onyc-refresh
```

**One-shot** (single cycle, useful for manual catch-up):

```bash
docker run --env-file ../../.env.pfx.core -e ONYC_SINGLE_RUN=1 onyc-refresh
# or
docker run --env-file ../../.env.pfx.core onyc-refresh ./onyc_refresh.sh --once
```

**Manual wide refresh** (after extended downtime >30 min, override the window):

```bash
docker run --env-file ../../.env.pfx.core \
    -e CAGG_REFRESH_WINDOW="4 hours" \
    -e ONYC_SINGLE_RUN=1 \
    onyc-refresh
```

## Failure Handling

- Each cycle that fails increments a consecutive failure counter.
- A successful cycle resets the counter to zero.
- After `MAX_CONSECUTIVE_FAILURES` (default 10) consecutive failures, the
  script exits with code 1. The container restart policy (Railway `ON_FAILURE`
  or Kubernetes `restartPolicy: Always`) handles restart.
- Aux table sync and risk analytics failures are non-fatal — they log a warning
  and the cycle continues.

## Cycle Timing

The script measures elapsed wall-clock time per cycle and only sleeps for the
remainder of the target interval. If a cycle takes longer than the interval, the
next cycle starts immediately (no sleep). Cycle duration is logged as
`Cycle #N completed in Xs` for monitoring.

## What Each Tier Refreshes

### Tier 1: CAGGs (21 total)

| Domain | CAGGs |
|---|---|
| Dexes (4) | `cagg_events_5s`, `cagg_vaults_5s`, `cagg_poolstate_5s`, `cagg_tickarrays_5s` |
| Kamino (3) | `cagg_activities_5s`, `cagg_reserves_5s`, `cagg_obligations_agg_5s` |
| Exponent (8) | `cagg_vaults_5s`, `cagg_market_twos_5s`, `cagg_sy_meta_account_5s`, `cagg_sy_token_account_5s`, `cagg_vault_yield_position_5s`, `cagg_vault_yt_escrow_5s`, `cagg_base_token_escrow_5s`, `cagg_tx_events_5s` |

### Tier 1: Materialized Tables

| Domain | Procedures |
|---|---|
| Dexes | `refresh_mat_dex_timeseries_1m`, `refresh_mat_dex_ohlcv_1m`, `refresh_mat_dex_last` |
| Kamino | `refresh_mat_klend_timeseries_1m`, `refresh_mat_klend_last`, `refresh_mat_klend_config` |
| Exponent | `refresh_mat_exp_timeseries_1m`, `refresh_mat_exp_last` |
| Health | `refresh_mat_health_all` (base activity, CAGG status, queue benchmarks, trigger stats, base hourly) |
| Cross-protocol | `refresh_mat_xp_all` (runs after all domain tables) |

### Tier 2: Auxiliary Tables

- **Kamino** `aux_market_reserve_tokens` — latest reserve metadata per reserve address.
- **Exponent** `aux_key_relations` — vault-to-market-to-SY relationship mapping.
- **Dexes** `pool_tokens_reference` — pool token pair metadata.

### Daily: Retention Cleanup

Deletes mat table rows older than `MAT_RETENTION_DAYS` and runs `VACUUM ANALYZE`
on cleaned tables. Runs once at midnight UTC.
