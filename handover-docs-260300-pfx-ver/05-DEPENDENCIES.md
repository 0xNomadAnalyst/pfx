# External Service and API Dependencies

This document catalogues the external services and APIs that the platform depends on, selection rationale, current configuration, and cost considerations at the time of handover.

Related companion documents:

- **01-INGESTION.md** -- how these services are used within the ingestion layer.
- **02-DATABASE.md** -- in-database ETL built on Tiger Data.
- **03-FRONTEND.md** -- frontend services that consume database views and use Clerk auth.
- **04-RESILIENCE.md** -- reconnection, health checks, and failure recovery for each dependency.

---

## Shyft (Yellowstone gRPC + GraphQL Indexer + Solana RPC)

**Provider:** [Shyft](https://shyft.to/)
**Services used:** Yellowstone gRPC streaming, GraphQL account indexer, Solana JSON-RPC

Shyft is the primary Solana infrastructure provider for this platform. It was selected for being the most cost-competitive Yellowstone gRPC provider at the time of evaluation, with high-quality documentation and responsive technical support during integration.

### Yellowstone gRPC (Geyser Plugin)

The platform's primary real-time data channel. Yellowstone gRPC provides a streaming interface to Solana validator data via the Geyser plugin protocol, delivering transaction and account state updates with low latency at the `CONFIRMED` commitment level.

**Used by:** All four ingestion services (DEXes, Exponent, Kamino, Solstice).

**Capabilities consumed:**
- Transaction subscriptions filtered by program account addresses.
- Account subscriptions filtered by specific account addresses or owner programs.
- Block subscriptions with embedded transactions (for native `block_time`).
- Combined (multiplexed) transaction + account + block subscriptions on a single connection.
- Dynamic subscription updates -- adding new account/transaction filters to a live stream without reconnecting.

**Shared module:** `shared/yellowstone_grpc_client/` wraps the gRPC channel, authentication, subscription management, stream health watchdog, and reconnect logic. Protobuf stubs are generated at Docker build time from bundled `.proto` files.

**Environment variables:**
- `GRPC_ENDPOINT` -- gRPC server endpoint URL (required).
- `GRPC_TOKEN` -- authentication token (required).

### GraphQL Account Indexer

Shyft provides a GraphQL indexer that indexes all active accounts owned by specific Solana programs. This is used as an alternative to expensive `getProgramAccounts` RPC calls for discovering and polling large account sets.

**Used by:**
- **Kamino** -- primary source for obligation data. The indexer returns all obligation accounts owned by the Kamino Lending program, with safe pagination tracking. This replaces individual RPC calls for ~2,600+ obligation accounts, which would be prohibitively slow and expensive.
- **DEXes** -- LP position polling. Queries all LP positions in monitored pools, optionally filtered to tracked market-maker addresses.

**Shared module:** `shared/graphql_client/` provides `ShyftGraphQLClient` with automatic retry, exponential backoff, and `FetchResult` status tracking for pagination integrity validation.

**Environment variables:**
- `GRAPHQL_ENDPOINT` -- GraphQL endpoint URL (default: `https://programs.shyft.to/v0/graphql/`).
- `GRAPHQL_API_KEY` -- API key (falls back to `RPC_API_KEY` -- Shyft uses the same key across services).
- `GRAPHQL_NETWORK` -- Solana network (default: `mainnet-beta`).

### Solana JSON-RPC

Standard Solana RPC is used for account data fetching (polling), transaction detail retrieval, and on-chain account discovery. Shyft provides RPC endpoints using the same API key as the other services.

**Used by:** All four ingestion services for:
- `getMultipleAccounts` -- batch polling of protocol account state (pool state, reserves, controller accounts).
- `getAccountInfo` -- individual account lookups during discovery phases.
- `getProgramAccounts` -- on-chain account scanning (used by Solstice for depository discovery via discriminator filters; used by Kamino for initial reserve discovery on first boot).
- `getSignaturesForAddress` / `getTransaction` -- transaction backfill and detail fetching.
- `getBlock` -- block time resolution when not available from gRPC stream.

**Shared module:** `shared/solana_rpc_client/` provides `SolanaRPCClient` with methods for account info, multiple accounts, program accounts, signatures, and transactions.

**Environment variables:**
- `RPC_ENDPOINT` -- RPC endpoint hostname (required).
- `RPC_API_KEY` -- API key appended as `?api_key=` query parameter (optional but used in production).

---

## Tiger Data (Database Platform)

**Provider:** [Tiger Data](https://www.tigerdata.com/) (formerly Timescale Cloud)
**Service used:** Tiger Cloud -- managed PostgreSQL with TimescaleDB
**Documentation:** [docs.tigerdata.com](https://docs.tigerdata.com/)

### About Tiger Data

Tiger Data is a managed PostgreSQL cloud platform purpose-built for time-series, analytics, and real-time workloads. It extends PostgreSQL with TimescaleDB -- adding hypertables (automatic time-based partitioning), continuous aggregates (incrementally materialised views), columnar compression, and tiered storage (SSD/S3). The platform provides disaggregated compute and storage with independent scaling, multi-AZ high availability with automatic failover (optional), and enterprise security compliance (SOC 2, HIPAA, GDPR).

### Why Tiger Data

The choice of Tiger Data over alternative time-series or analytics databases was driven by several factors:

1. **PostgreSQL function-oriented extensibility** -- the platform's analytics rely heavily on complex SQL functions (price impact simulation via tick traversal, risk sensitivity arrays, borrow rate curve generation, Pendle AMM pricing formulas). PostgreSQL's `CREATE FUNCTION` / PL/pgSQL / dynamic SQL capabilities make it natural to encapsulate these as reusable, composable database functions that are called by view functions and triggers. This level of procedural logic within the database is not supported or is awkward in columnar stores like ClickHouse.

2. **Complex joins on the path to consumption** -- the view functions that serve the frontend combine data from multiple continuous aggregates, auxiliary lookup tables, and domain functions in a single query. These are not simple scans or pre-aggregated rollups -- they involve multi-CTE queries with LATERAL joins, window functions (LOCF), DISTINCT ON, and re-bucketing. The data is continuously being engineered into metrics of interest on its way to the consumer. This rules out high-velocity columnar alternatives that optimise for append-only scans but lack flexible join and function support.

3. **TimescaleDB time-series features** -- hypertables with automatic chunking, continuous aggregates for materialised 5-second rollups, chunk-level compression, and time-bucket functions provide the time-series performance layer without leaving the PostgreSQL ecosystem.

4. **Tiger Data platform additions** -- Tiger Cloud provides managed infrastructure, connection pooling, automated backups, monitoring, and the option for HA replicas and tiered S3 storage, all on a familiar PostgreSQL foundation.

### Current Usage

At the time of handover, the project uses Tiger Data's cloud-hosted service. Key characteristics:

- **Compute-heavy workload** -- the current load is dominated by compute (continuous aggregate refreshes every 5 seconds across 21 CAGGs, complex view function queries, trigger-based price impact calculations). Compute costs predominate the contribution to cloud service costs over storage.
- **Single instance** -- no HA replicas are currently enabled. Tiger Data offers HA replica services with automatic failover, but these are at additional cost and have not been activated. Enabling HA requires no application changes -- failover is transparent to clients.
- **Self-hosting discussions** -- preliminary discussions were had with the Solstice team about self-hosting Tiger Data (or plain TimescaleDB) to reduce ongoing cloud costs. These did not progress further at the handover date. Self-hosting would require managing backups, monitoring, upgrades, and HA independently.

### Environment Variables

- `DB_HOST` -- database hostname.
- `DB_PORT` -- database port (default: `5432`).
- `DB_NAME` -- database name.
- `DB_USER` -- database user.
- `DB_PASSWORD` -- database password (required).

Schema isolation is handled per-service (e.g. `dexes`, `exponent`, `kamino_lend`, `solstice_proprietary`, `health`) -- see **02-DATABASE.md**.

---

## Exponent API (Market Discovery)

**Endpoint:** `https://web-api.exponent.finance/api/markets`
**Documentation:** Not publicly documented.

The Exponent protocol's internal API is used for automated detection and discovery of new market maturities. This API is not part of Exponent's public documentation and was integrated based on direct observation of the protocol's web application.

### How It's Used

The Exponent ingestion service uses this API to discover new yield markets without manual configuration. The discovery process:

1. **Base token as root identifier** -- the service is configured with one or more base token addresses (e.g. eUSX, USX) via `EXP_MARKET_TRACKED_BASE_TOKENS` in config. These represent the underlying assets of interest.
2. **API polling** -- the discovery function (`discover_markets_by_underlying_token()`) fetches all markets from the API, then filters to those where the vault's `mintAsset` or `quoteMint` matches any tracked base token.
3. **Test market filtering** -- markets below a configurable liquidity depth threshold (default: $50K) are filtered as test/dummy deployments that never went live.
4. **In-memory update** -- newly discovered markets are merged into the in-memory `EXPONENT_MARKETS` list and their accounts are added to gRPC subscriptions dynamically.
5. **Periodic re-check** -- discovery runs every N poll cycles (default: 10, configurable via `EXPONENT_MARKET_DISCOVERY_CHECK_INTERVAL`).

### Configuration

- `EXPONENT_ENABLE_DYNAMIC_MARKET_DISCOVERY` -- enable/disable API-based discovery (default: `true`).
- `EXPONENT_MARKET_DISCOVERY_CHECK_INTERVAL` -- polls between API checks (default: `10`).
- `EXPONENT_ENABLE_TEST_MARKET_FILTER` -- filter out low-liquidity test markets (default: `true`).
- `EXPONENT_TEST_MARKET_MIN_DEPTH_RAW` -- minimum PT+SY depth for a market to be considered live (default: `50e9` raw = $50K for 6-decimal tokens).
- `EXPONENT_BASE_TOKENS` -- override base token list via env var (format: `address:symbol:decimals,...`).

### Risk

Since this API is not publicly documented, it may change without notice. The ingestion service falls back gracefully to its seed market list (`EXPONENT_MARKETS` in config) if the API is unavailable -- existing markets continue to be monitored, but new maturities will not be automatically discovered until the API is restored or markets are added manually.

---

## Solscan (Transaction Backfill)

**Provider:** [Solscan](https://solscan.io/)
**Service used:** Solscan Pro API
**Tier required:** Pro ($200/month at time of writing)
**Status:** Optional -- not required for steady-state operation.

### Purpose

Solscan's Pro API is used for **backfilling** -- recovering historical transaction data after interruptions to the ingestion services (downtime, restarts, gRPC disconnects, etc.). During normal operation the platform receives transactions in real time via Yellowstone gRPC; Solscan is only needed when gaps must be filled retroactively.

### How It's Used

Each service has a `backfill-qa/` directory containing backfill and quality-assurance scripts. The shared pattern is:

1. **`backfill_solscan.py`** -- fetches raw transaction data from the Solscan Pro API for a specified address and time range, writing results to Parquet files.
2. **Processing / schema alignment** -- service-specific scripts (e.g. `process_transactions.py`, `process_backfill_to_schema.py`) transform the raw Solscan response format into the service's `src_*` table schemas, handling field mapping differences (e.g. Solscan uses `block_id` for slot, singular `log_message` for logs, `status: 1` for success).
3. **`upload_backfill.py`** -- upserts the processed data into the database.
4. **`validate_backfill.py`** / **QA scripts** -- verify completeness and correctness, including balance reconstruction tests that compare DB-sourced events against Solscan-sourced events.

A shared helper module (`shared/backfill-qa-solscan/`) provides common utilities for environment merging, subprocess orchestration, and database connectivity across all four services' backfill pipelines.

### Why Pro Tier

The free Solscan API has restrictive rate limits and lacks access to the transaction detail endpoints required for bulk historical fetching. The Pro tier ($200/month) provides the throughput and endpoint access needed for backfilling meaningful time ranges. Since backfill is an occasional recovery activity rather than continuous, the subscription can be activated on-demand and cancelled when not in use.

### Environment Variables

- `BACKFILL_SOLSCAN_API_KEY` -- Solscan Pro API key (preferred).
- `SOLSCAN_API_KEY` -- legacy fallback variable name.
- Alternatively, the key can be embedded in the pool/backfill config JSON file (`solscan_api_key` field).

---

## Container Hosting

### Development: Railway

**Provider:** [Railway](https://railway.app/)
**Service used:** Container deployment platform.
**Scope:** Development and contractor-side deployment only.

During development, all services were deployed as Docker containers on Railway. Each service has a corresponding Railway configuration file (`railway.*.json`) and Dockerfile (`Dockerfile.*`) in the repository root.

| Railway Config | Dockerfile | Service |
|---|---|---|
| `railway.dexes.json` | `Dockerfile.dexes` | DEXes ingestion (Orca + Raydium) |
| `railway.exponent.json` | `Dockerfile.exponent` | Exponent ingestion |
| `railway.kamino.json` | `Dockerfile.kamino` | Kamino Lending ingestion |
| `railway.solsticeprop.json` | `Dockerfile.solsticeprop` | Solstice USX/eUSX ingestion |
| `railway.cagg.json` | `Dockerfile.cagg` | CAGG refresh service (5-second cycle) |
| `railway.lightweight-api.json` | `Dockerfile.lightweight-api` | Lightweight FastAPI for DEX liquidity tables |

Railway configuration notes:
- `restartPolicyType: "ON_FAILURE"` with `restartPolicyMaxRetries: 10` -- Railway automatically restarts failed containers.
- Environment variables are configured in the Railway dashboard (not committed to the repository).
- Each ingestion service exposes port 8080 for the `/health` endpoint, used by Docker `HEALTHCHECK` for container-level liveness monitoring.

See **04-RESILIENCE.md** for details on how service health checks and restart policies interact.

### Production: Google Cloud Platform (GCP)

> **Placeholder for Solstice cloud engineer:** Production deployment uses GCP. Please document the GCP project setup, service configuration (GKE / Cloud Run / Compute Engine), networking, IAM roles, secrets management, monitoring integration, and any differences from the Railway development setup described above.
>
> The Dockerfiles and health check endpoints are designed to be platform-agnostic -- the same container images used on Railway should work on GCP with only environment variable changes. See **04-RESILIENCE.md** for Kubernetes probe configuration recommendations if deploying on GKE.

---

## Clerk (Dashboard Authentication)

**Provider:** [Clerk](https://clerk.com/)
**Service used:** Authentication and user management.

The main dashboard (`frontend/main/`) uses Clerk for user authentication. Clerk handles login, session management, and JWT token issuance. The Express API backend validates Clerk JWTs via middleware on all chart and table endpoints.

Both services share the same Clerk project and user pool. The main dashboard uses Clerk's React SDK and Express middleware; the lightweight dashboard uses the `clerk-backend-api` Python SDK to validate the same session tokens.

**Environment variables (main dashboard):**
- `VITE_CLERK_PUBLISHABLE_KEY` -- Clerk publishable key (build-time, UI).
- `CLERK_PUBLISHABLE_KEY`, `CLERK_SECRET_KEY` -- Clerk credentials (API backend).
- `DISABLE_BACKEND_AUTH` -- bypass auth for local development (`true`/`false`).

**Environment variables (lightweight dashboard):**
- `CLERK_PUBLISHABLE_KEY`, `CLERK_SECRET_KEY` -- same Clerk credentials as main dashboard.
- `DISABLE_AUTH` -- bypass auth for local development (`true`/`false`).

See **03-FRONTEND.md** for full frontend architecture and endpoint documentation.

---

## Marimo (Notebook Dashboards)

**Provider:** [Marimo](https://marimo.io/)
**Type:** Python library (open source).

Marimo is a reactive Python notebook framework used for two dashboard/report applications:

- **Pipeline health dashboard** (`health/tempviz/health_page_sql.py`) -- interactive monitoring UI that queries the `health` schema views. Described in **04-RESILIENCE.md**.
- **Depeg event report** (`depeg-251225/depeg_251225.py`) -- comprehensive analysis of the USX-USDC depeg event (December 25--26, 2025), deployed as a read-only public web app on Railway.

Both are standalone applications; they do not affect the ingestion or ETL pipeline. Listed in `requirements.txt` for each respective directory.

---

## Jupiter and Raydium APIs (Validation Only)

**Status:** Used exclusively in validation scripts; not part of the production pipeline.

Validation scripts under `frontend/lightweight/validation/` compare the platform's computed depth and price-impact numbers against external sources to verify correctness:

- **Jupiter Lite API** (`https://lite-api.jup.ag/swap/v1/quote`) -- public, no API key required. Used to compare swap quotes (direct route and best-path) against the platform's tick-traversal price impact calculations.
- **Raydium Swap Compute API** -- Raydium's own server-side simulation endpoint. Used for cross-validation of Raydium CLMM impact numbers.

These are development-time QA tools and are not called by any production service.

---

## Solana On-Chain Program Addresses

For reference, the Solana program IDs that the platform monitors:

| Program | Address | Service |
|---|---|---|
| Raydium CLMM | `CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK` | DEXes |
| Orca Whirlpool | `whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc` | DEXes |
| Exponent Core | `ExponentnaRg3CQbW6dqQNZKXp7gtZ9DGMp1cwC4HAS7` | Exponent |
| Generic Wrap (SY mint/redeem) | `XP1BRLn8eCYSygrd8er5P4GKdzqKbC3DLoSsS5UYVZy` | Exponent |
| Kamino Lending | `KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD` | Kamino |
| Solstice USX | `USXyiSTsPEWz55pSK7sZoUL79ntoVGQbaTDT57tH6bx` | Solstice |
| Solstice eUSX | `eUSXyKoZ6aGejYVbnp3wtWQ1E8zuokLAJPecPxxtgG3` | Solstice |

Transaction filters also include aggregator program IDs to capture routed swaps:

| Aggregator | Address |
|---|---|
| Jupiter | `JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4` |
| OKX DEX | `6m2CDdhRgxpH4WjvdzxAYbGxwdGUz5MziiL5jek2kBma` |

These addresses are defined in each service's `config.py` and are used to construct gRPC transaction subscription filters and discriminator-based instruction parsing.

---

## Dependency Summary

| Dependency | Provider | Purpose | Auth Mechanism |
|---|---|---|---|
| Yellowstone gRPC | Shyft | Real-time transaction + account streaming | `GRPC_ENDPOINT` + `GRPC_TOKEN` |
| GraphQL Indexer | Shyft | Bulk account discovery (obligations, LP positions) | `GRAPHQL_API_KEY` (same as RPC key) |
| Solana RPC | Shyft | Account polling, transaction fetching, discovery | `RPC_ENDPOINT` + `RPC_API_KEY` |
| Database | Tiger Data | Time-series storage, in-DB ETL, analytics | `DB_HOST/PORT/NAME/USER/PASSWORD` |
| Market Discovery | Exponent | New maturity detection | No auth (public endpoint, undocumented) |
| Transaction Backfill | Solscan (Pro) | Historical gap recovery | `BACKFILL_SOLSCAN_API_KEY` |
| Dashboard Auth | Clerk | Main dashboard authentication | `CLERK_PUBLISHABLE_KEY` + `CLERK_SECRET_KEY` |
| Notebook Dashboards | Marimo (open source) | Health dashboard, depeg report | N/A (Python library) |
| Validation APIs | Jupiter Lite / Raydium | Price impact cross-validation (dev only) | None (public endpoints) |
| Container Hosting (dev) | Railway | Development deployment, restart policies | Railway dashboard |
| Container Hosting (prod) | GCP | Production deployment | *Placeholder -- Solstice cloud engineer* |

---

## Where to Go Next

- **01-INGESTION.md** -- how the ingestion services consume Shyft gRPC/RPC/GraphQL.
- **02-DATABASE.md** -- in-database ETL architecture built on Tiger Data.
- **03-FRONTEND.md** -- frontend services architecture, screens, and endpoints.
- **04-RESILIENCE.md** -- reconnection, health monitoring, and failure recovery for each dependency.
- **Service READMEs** (`dexes/`, `exponent/`, `kamino/`, `solstice-prop/`) -- per-service configuration and environment variable reference.
