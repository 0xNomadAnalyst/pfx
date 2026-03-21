# Ingestion Services

This document covers the data ingestion layer of the platform: the four protocol-specific Python services that capture on-chain Solana data and persist it as normalized time-series records to TimescaleDB.

Each service lives in its own top-level directory and follows a shared set of architectural conventions while implementing protocol-specific parsing, decoding, and discovery logic. Per-service README files (`<service>/README.md`) remain the authoritative deep-dive references; this document focuses on cross-cutting patterns and a summary of what each service covers.

Related topics covered in companion documents:

- **02-DATABASE.md** -- in-DB ETL (views, continuous aggregates, functions), schema design.
- **04-RESILIENCE.md** -- monitoring, reconnect/recovery, health checks, queue health telemetry, data integrity guards, graceful shutdown.
- **05-DEPENDENCIES.md** -- external service/API dependencies (RPC, gRPC, GraphQL, protocol APIs), credentials, deployment config.

---

## Services at a Glance

| Directory | Protocol Domain | Key Data | Account Types |
|---|---|---|---|
| `dexes/` | Orca Whirlpool, Raydium CLMM | Pool state, token vaults, tick arrays, liquidity depth, LP positions, swap/liquidity events | Pool, SPL token vault, tick array, position |
| `exponent/` | Exponent (PT/YT yield markets) | Vault snapshots, market snapshots, YT positions, SY metadata, escrow balances, trade events | Vault, MarketTwo, YieldTokenPosition, SyMeta, SPL token |
| `kamino/` | Kamino Lending | Lending market state, reserve metrics, obligation positions, lending instruction events | LendingMarket, Reserve, Obligation |
| `solstice-prop/` | Solstice USX / eUSX | Controller state, depository snapshots, yield pool/vesting state, mint/redeem events | Controller, StableDepository, YieldPool, VestingSchedule |

All four services write to isolated schemas within a shared TimescaleDB instance.

---

## Shared Architectural Patterns

Every ingestion service follows the same high-level design. The patterns below are implemented consistently across all four.

### 1. Dual-Channel Ingestion (gRPC + RPC)

Each service supports two complementary data channels, configurable per deployment:

- **Yellowstone gRPC streams** (via `shared/yellowstone_grpc_client`) -- real-time transaction and account-update subscriptions from a Geyser plugin endpoint. Supports block-mode and transaction-mode subscriptions, and separate or combined clients for transaction vs account streams.
- **RPC polling** (via `shared/solana_rpc_client`) -- periodic `getMultipleAccounts` calls for account state snapshots. Serves as the primary channel in polling-only mode and as a redundancy layer alongside gRPC in hybrid mode.

The ingestion mode is runtime-configurable via environment variables, allowing the same codebase to run as RPC-only, gRPC-only, or hybrid without code changes. The DEXes service takes this further with production-deployed stream separation (one instance for account polling, another for gRPC transaction capture).

### 2. Module Structure Convention

Each service follows a consistent directory layout:

```
<service>/
  config.py            # Env contract, feature flags, tracked accounts/assets
  main.py              # Entrypoint, lifecycle orchestration, queue dispatch
  data/
    tx_events.py       # Protocol-specific instruction/event decode registry
    data_structs.py    # Discriminators, typed dataclasses, schema authority
    account_updates.py # Account-type parsing, Borsh decode, DB insert prep
    protocol_config.py # Tracked account sets for filtering
  core/
    ...                # Service-specific pollers, gRPC wrappers, discovery
  dbsql/
    ...                # SQL schema definitions (authoritative schema reference)
```

`config.py` is always the centralized environment contract. `data_structs.py` is always the single source of truth for discriminators and typed schemas -- no other module redefines discriminator values.

### 3. Transaction Parsing Pipeline

Transaction parsing follows a uniform flow orchestrated by `shared/solana_utils/transaction_parser.py`:

1. **Filter** -- gRPC delivers transactions matching program ID filters; the shared parser further checks for tracked account involvement in instruction account lists.
2. **Resolve** -- build unified account keys array (static keys + loaded address lookup table addresses).
3. **Discriminator match** -- extract instruction discriminator bytes and look up in the service's `PROTOCOL_REGISTRY` (defined in `tx_events.py`).
4. **Decode** -- based on extraction flags per discriminator, decode instruction args and/or event/return-value payloads using typed dataclass schemas from `data_structs.py`.
5. **Enrich** -- protocol-specific enrichment (e.g. fee reconstruction from balance deltas for Orca, transfer-based flow deltas for Exponent, activity type classification for Kamino).
6. **Persist decision** -- `should_persist_event()` applies context-aware filtering (tracked reserve check, pool address match, etc.) before queueing.
7. **Queue** -- accepted records are dispatched to the appropriate `DatabaseWriteQueue`.

Each service implements its own `tx_events.py` that plugs into this shared pipeline by providing:
- `PROTOCOL_REGISTRY` -- maps program IDs to handler metadata.
- Discriminator maps with per-discriminator extraction policy flags.
- `parse_idl_instruction()` / `parse_idl_event()` -- protocol-specific decoders.
- `should_persist_event()` -- persistence filter logic.
- `extract_additional_data()` / `extract_key_economic_data()` -- enrichment functions.

### 4. Account State Polling and Change Detection

All services poll account state via batched `getMultipleAccounts` RPC calls, decode raw bytes using Borsh deserialization (via `shared/solana_utils`), and prepare DB-ready insert tuples.

To reduce write noise under steady-state conditions, every service implements **write-on-difference** controls:

- On each poll, a hash of key economic fields is compared to the previous snapshot.
- If unchanged, the write is suppressed.
- A **max-stale bypass** forces a write after a configurable period (typically hours) regardless of change, preventing dashboard staleness in LOCF (last observation carried forward) scenarios.
- These controls are independently togglable per account type via environment flags (e.g. `DEXES_POOL_STATE_WRITE_ON_DIFFERENCE_ONLY`, `KAMINO_RESERVE_WRITE_ON_DIFFERENCE_ONLY`).

### 5. Queue-Isolated Database Writes

All services use `shared/db_write_queue/DatabaseWriteQueue` for asynchronous, thread-safe writes:

- Each service registers multiple **named, specialized write queues** (3--9 depending on the service), isolating different data categories so a slow or failing write path for one table does not block others.
- Queues are bounded with configurable max sizes to prevent unbounded memory growth.
- Handlers are registered per task type; the queue worker thread dispatches to the correct handler.
- Statistics tracking (success/failure counts) is built in.

Queue health monitoring (utilization, staleness, alerting thresholds) is covered in **04-RESILIENCE.md**.

### 6. Dynamic Discovery

Three of the four services implement runtime discovery to automatically expand their monitored account sets without manual configuration changes:

| Service | Discovery Mechanism | Trigger |
|---|---|---|
| `exponent/` | API-based market detection + on-chain account graph expansion (vaults, escrows, SyMeta, token mints) | Startup + periodic interval |
| `kamino/` | DB-driven reserve discovery from obligation aggregate data + GraphQL obligation sourcing | Startup + post-write cycles |
| `solstice-prop/` | On-chain `getProgramAccounts` scan for StableDepository discriminator | Startup + periodic interval |

Discovery outputs update in-memory configuration, tracked account sets, and gRPC subscription filters at runtime. The DEXes service uses a static pool configuration (pools are specified via environment variables) since the tracked pool set is curated by Trade Ops rather than protocol-driven.

### 7. Configuration via Environment

Every service uses a `config.py` that reads all runtime parameters from environment variables with sensible defaults. This covers:

- Ingestion mode selection (polling, hybrid, gRPC-only).
- Polling intervals and iteration limits.
- Per-table write enable/disable toggles.
- Write-on-difference flags and staleness thresholds.
- Discovery feature flags and intervals.
- gRPC client topology (combined vs separate transaction/account clients, block vs transaction subscription mode).
- Database schema target.

Production values are injected via `.env.prod.<service>` files at deployment time. The same codebase supports multiple deployment profiles without branching (e.g. the DEXes service runs two profiles side-by-side for stream separation).

---

## Shared Module Library (`shared/`)

All services delegate cross-cutting infrastructure to a shared package at `shared/`. No protocol-specific logic lives here.

| Module | Purpose |
|---|---|
| `shared/solana_utils/` | Borsh decode helpers, annotated types for decode compatibility, Anchor discriminator computation, system program constants |
| `shared/solana_utils/transaction_parser.py` | Shared transaction parse pipeline (filter, resolve, discriminator match, decode dispatch) -- consumes protocol-specific registries from each service |
| `shared/solana_utils/event_parser.py` | Event log parsing helpers |
| `shared/yellowstone_grpc_client/` | Yellowstone gRPC client (`YellowstoneClient`), subscription management, generated protobuf stubs (Geyser plugin protocol) |
| `shared/solana_rpc_client/` | RPC client abstraction, config, batched account fetch utilities |
| `shared/graphql_client/` | GraphQL client with pagination integrity tracking (used by Kamino for obligation data) |
| `shared/db_write_queue/` | `DatabaseWriteQueue` (async queue workers) and `QueueHealthMonitor` (utilization/staleness metrics) |
| `shared/timescaledb_client/` | TimescaleDB connection, reconnect, and base client (each service wraps this with its own DB client) |
| `shared/healthcheck/` | Reusable HTTP health server and common check functions |

The `transaction_parser.py` module uses a plugin-style integration pattern: it imports protocol-specific symbols (`PROTOCOL_REGISTRY`, `TRACKED_ACCOUNTS`, discriminator maps, parse/persist functions) from the calling service's `config` and `data.tx_events` modules at runtime. This allows a single shared parser to drive all four services without protocol knowledge in the shared layer.

---

## Per-Service Notes

Brief notes on what distinguishes each service. For full detail, refer to the in-directory README.

### DEXes (`dexes/`)

- Tracks **Orca Whirlpool** and **Raydium CLMM** concentrated liquidity pools.
- Handles shared instruction discriminators between the two protocols by resolving via program ID.
- Unique data: tick array snapshots, liquidity depth distributions, price impact metrics, LP position snapshots (via GraphQL indexer).
- Pre-DB sensitivity calculations (sell impact, peg spread, active spread) run in `config.py` and are applied during write preparation.
- Production runs two complementary instances (account-only via RPC polling, transaction-only via gRPC) for stream-separated fault isolation.
- Six write queues: Critical, Events, State, Tick, Analytics, Position.

### Exponent (`exponent/`)

- Tracks two on-chain programs: **Exponent Core** and **Generic Wrap**.
- Most complex discovery: full account graph expansion from market seeds through vaults, escrows, SyMeta, token mints, and underlying escrows.
- Handles 256-bit fixed-point exchange rate decoding.
- Dynamic market discovery with test-market filtering (liquidity depth thresholds) to exclude dummy deployments.
- Expired market handling with configurable grace period for late redemption capture.
- Nine write queues covering seven account snapshot types plus transactions and events.

### Kamino Lending (`kamino/`)

- Tracks a single **Kamino lending market** and its connected reserve/obligation graph.
- Obligations sourced entirely from **GraphQL** (indexer API), not individual RPC calls -- eliminates the scaling problem of fetching thousands of obligation accounts individually.
- Kamino does not emit on-chain events; all economic data is extracted from instruction parameters using 8-byte Anchor discriminators.
- Activity type classification follows a Solscan-compatible taxonomy (deposit, withdraw, borrow, repay, liquidate, flash loan, combined, maintenance).
- Reserve discovery driven by obligation aggregate data (DB-sourced), not on-chain program scans.
- Three write queues: Market, Obligations, Analytics/Events.

### Solstice Proprietary (`solstice-prop/`)

- Tracks two proprietary programs: **USX** (stablecoin) and **eUSX** (yield vault).
- PDA-based account derivation from bootstrap collateral symbols using seed constants in `data/pda_seeds.py`.
- Handles discriminator collision between USX and eUSX Controller accounts (resolved via owner program ID).
- Derived metric computation during account decode: depository solvency ratio, yield pool exchange rate, vesting progress percentage.
- Nine write queues spanning both USX and eUSX data categories.

---

## Running the Services

Each service is run as a Python module from the repository root:

```bash
python -m dexes.main
python -m exponent.main
python -m kamino.main
python solstice-prop/main.py
```

Note the `solstice-prop` service uses direct script execution rather than module mode due to the hyphenated directory name.

Environment variables must be loaded before startup (via `.env` files or deployment environment injection). Each service's `config.py` searches multiple `.env` locations automatically.

---

## Backfill and QA Utilities

Each service includes a `backfill-qa/` directory with scripts for recovering historical data after ingestion gaps (downtime, restarts, gRPC disconnects) and for validating data quality:

| Directory | Contents |
|---|---|
| `dexes/backfill-qa/` | Solscan-based transaction backfill, transaction processing/decode, upload to DB, validation, liquidity/vault reconstruction QA |
| `exponent/backfill-qa/` | Solscan backfill, RPC-based backfill (alternative), upload, validation, balance reconstruction, LP flow analysis |
| `kamino/backfill-qa/` | Solscan backfill, upload, validation, balance reconstruction (DB vs Solscan comparison), multi-period QA |
| `solstice-prop/backfill-qa/` | Solscan backfill, schema-aligned processing (USX + eUSX), upload, validation, balance reconstruction |

A shared helper module (`shared/backfill-qa-solscan/`) provides common utilities for environment merging, subprocess orchestration, and database connectivity used by all four pipelines.

**Typical backfill workflow:**

1. **Collect** -- `backfill_solscan.py` fetches raw transaction data from the Solscan Pro API for a specified address and time range, writing to Parquet.
2. **Process** -- service-specific scripts transform Solscan's response format into the service's `src_*` table schemas (field mapping, decode, enrichment).
3. **Upload** -- `upload_backfill.py` upserts processed data into the database.
4. **Validate** -- `validate_backfill.py` and QA scripts verify completeness and correctness, including balance reconstruction tests that cross-check DB-sourced events against independently fetched Solscan events.

The Solscan Pro API subscription ($200/month) is required for backfill. See **05-DEPENDENCIES.md** for details on this and other external dependencies.

---

## Where to Go Next

- **Per-service README** (`dexes/README.md`, `exponent/README.md`, `kamino/README.md`, `solstice-prop/README.md`) -- module-level detail, full env var reference, deployment profiles.
- **SQL schema files** (`<service>/dbsql/`) -- authoritative table/column definitions with inline documentation.
- **02-DATABASE.md** -- in-DB ETL layer (views, continuous aggregates, functions).
- **04-RESILIENCE.md** -- operational resilience (reconnect, health monitoring, integrity guards, shutdown, data gap recovery).
- **05-DEPENDENCIES.md** -- external dependencies, API endpoints, credential management.
