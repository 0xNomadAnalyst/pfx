# Solstice Risk Management System — Platform Overview

This repository contains a real-time data ingestion, ETL, monitoring, and analysis platform built for the Solstice protocol's risk management team. It captures on-chain Solana data across multiple DeFi protocols, processes it into time-series analytics within a PostgreSQL/TimescaleDB database, and serves it through two dashboard applications.

The platform was developed under contract and this documentation set is prepared for handover.

---

## Handover Documentation

| Document | Scope |
|---|---|
| **00-GENERAL.md** | This file — platform overview, architecture, repository map. |
| [**01-INGESTION.md**](01-INGESTION.md) | Data ingestion layer: four protocol-specific Python services, shared architectural patterns (dual-channel ingestion, transaction parsing, account polling, write queues, dynamic discovery), shared module library, backfill/QA utilities. |
| [**02-DATABASE.md**](02-DATABASE.md) | In-database ETL: schema isolation, multi-layer processing pipeline (source tables → triggers → continuous aggregates → view functions), domain-specific SQL functions, risk tables, queue health monitoring, CAGG refresh service. |
| [**03-FRONTEND.md**](03-FRONTEND.md) | Frontend services: main React + Express dashboard (all domains, Clerk auth, health panel) and lightweight FastAPI DEX liquidity dashboard (server-rendered, low-latency). |
| [**04-RESILIENCE.md**](04-RESILIENCE.md) | Resilience and monitoring: three-tier recovery model (in-service reconnect → thread restart → container restart), health check endpoints, graceful shutdown, DB-side pipeline health dashboard, queue telemetry, data gap recovery via backfill. |
| [**05-DEPENDENCIES.md**](05-DEPENDENCIES.md) | External dependencies: Shyft (gRPC, GraphQL, RPC), Tiger Data (database), Exponent API, Solscan, Clerk, Railway/GCP hosting, Solana program addresses. |

Each service directory also contains its own README and, where applicable, a `dbsql/README.md` and `backfill-qa/README.md` for deeper service-level detail.

---

## Platform Architecture

```
                         ┌──────────────────────────────────────────────┐
                         │            Solana Blockchain                 │
                         └────────┬──────────────┬─────────────────────┘
                                  │              │
                     Yellowstone gRPC        Solana RPC
                      (Shyft)               (Shyft)
                      real-time              polling
                         │              ┌────────┤
                         ▼              ▼        ▼
              ┌──────────────────────────────────────────────┐
              │          Ingestion Services (Python)          │
              │                                              │
              │   dexes/     exponent/   kamino/   solstice-prop/
              │   (Orca,     (PT/YT     (Kamino   (USX,
              │    Raydium)   yields)    Lending)   eUSX)
              │                                              │
              │   shared/ ← common modules (gRPC client,     │
              │              RPC client, GraphQL client,      │
              │              write queues, healthcheck,       │
              │              Borsh decode, DB client)         │
              └──────────────────┬───────────────────────────┘
                                 │
                        async write queues
                                 │
                                 ▼
              ┌──────────────────────────────────────────────┐
              │        Tiger Data (TimescaleDB Cloud)         │
              │                                              │
              │  src_* tables ──► triggers ──► cagg_*_5s     │
              │  (raw data)      (enrich)     (rollups)      │
              │                                              │
              │  aux_* tables    risk_*       queue_health   │
              │  (lookups)       (policies)   (telemetry)    │
              │                                              │
              │  get_view_*() ← parameterised SQL functions  │
              │  (frontend-facing, non-materialised)         │
              │                                              │
              │  Schemas: dexes | exponent | kamino_lend     │
              │           | solstice_proprietary | health    │
              └───────┬──────────────────────────┬──────────┘
                      │                          │
                      ▼                          ▼
     ┌────────────────────────────┐  ┌───────────────────────┐
     │     Main Dashboard         │  │  Lightweight Dashboard │
     │                            │  │                        │
     │  React SPA + Express API   │  │  FastAPI (Python)      │
     │  Clerk auth                │  │  Server-rendered HTML  │
     │  All domains + risk +      │  │  DEX liquidity only    │
     │  health monitoring         │  │  15–30s refresh        │
     └────────────────────────────┘  └───────────────────────┘
```

### Data Flow Summary

1. **Ingest** — four Python services subscribe to Solana validator data via Yellowstone gRPC (real-time streaming) and supplement with RPC polling and GraphQL indexer queries (Shyft). Each service handles protocol-specific Borsh deserialization, discriminator-based instruction parsing, and change-detection filtering.

2. **Store** — decoded records are written to protocol-isolated schemas in Tiger Data (TimescaleDB Cloud) via asynchronous, queue-isolated write paths. Source tables (`src_*`) are hypertables partitioned by block time.

3. **Transform** — in-database ETL aggregates source data into 5-second continuous aggregates (CAGGs), enriches records via triggers, and maintains auxiliary lookup and risk policy tables. An external CAGG refresh service (Railway cron) drives the 5-second refresh cycle.

4. **Serve** — parameterised SQL view functions (`get_view_*()`) combine CAGGs, auxiliary tables, and domain-specific functions (price impact, risk sensitivity, AMM pricing) into query-ready results. Two frontend services call these functions to deliver dashboards.

5. **Monitor** — each service exposes a `/health` endpoint for container orchestrator liveness probes. A separate DB-side health layer provides human-facing operational visibility via health schema views and a Marimo dashboard.

### Key Design Principles

- **Schema as documentation** — SQL files (`dbsql/`) contain extensive inline `COMMENT ON` annotations and are the authoritative reference for table structures, column semantics, and processing rules.
- **Single source of truth per concern** — discriminators in `data_structs.py`, environment contract in `config.py`, table schemas in `dbsql/`, view functions in SQL.
- **Queue isolation** — each data category has its own write queue so a slow or failing write path does not block others.
- **Bounded recovery** — in-service reconnect is time-limited; persistent failures escalate to container restart rather than retrying indefinitely.
- **Write-on-difference** — account state polling suppresses unchanged writes to reduce DB load, with max-stale bypass to prevent dashboard staleness.
- **Platform-agnostic containers** — Dockerfiles and health endpoints work on Railway (development) and GCP (production) with only environment variable changes.

---

## Monitored Protocols

| Protocol | Domain | What's Monitored |
|---|---|---|
| **Orca Whirlpool** | DEX (concentrated liquidity) | Pool state, token vaults, tick arrays, liquidity depth, LP positions, swap/liquidity events |
| **Raydium CLMM** | DEX (concentrated liquidity) | Pool state, token vaults, tick arrays, liquidity depth, LP positions, swap/liquidity events |
| **Exponent** | Yield trading (PT/YT markets) | Vault snapshots, market snapshots, YT positions, SY metadata, escrow balances, trade events |
| **Kamino Lending** | Lending protocol | Lending market state, reserve metrics, obligation positions, lending instruction events |
| **Solstice USX** | Stablecoin | Controller state, depository snapshots, mint/redeem events |
| **Solstice eUSX** | Yield vault | Controller state, yield pool/vesting state, wrap/unwrap events |

---

## Repository Structure

```
risk_dash/
│
├── dexes/                      # DEX ingestion service (Orca Whirlpool + Raydium CLMM)
│   ├── config.py               #   Environment contract, pool config, feature flags
│   ├── main.py                 #   Service entrypoint
│   ├── data/                   #   Protocol decode (discriminators, structs, events)
│   ├── core/                   #   Pollers, gRPC wrappers, GraphQL position poller
│   ├── dbsql/                  #   SQL schemas, CAGGs, triggers, views, functions
│   ├── backfill-qa/            #   Solscan backfill + QA scripts
│   └── README.md
│
├── exponent/                   # Exponent ingestion service (PT/YT yield markets)
│   ├── config.py
│   ├── main.py
│   ├── data/                   #   Market/vault decode, PDA derivation
│   ├── core/                   #   Discovery, RPC, gRPC wrappers
│   ├── dbsql/                  #   SQL schemas, CAGGs, views (Pendle AMM pricing)
│   ├── backfill-qa/
│   └── README.md
│
├── kamino/                     # Kamino Lending ingestion service
│   ├── config.py
│   ├── main.py
│   ├── data/                   #   Reserve/obligation decode, activity classification
│   ├── core/                   #   GraphQL obligation loader, RPC, discovery
│   ├── dbsql/                  #   SQL schemas, CAGGs, views (risk sensitivity)
│   ├── backfill-qa/
│   └── README.md
│
├── solstice-prop/              # Solstice proprietary ingestion (USX + eUSX)
│   ├── config.py
│   ├── main.py
│   ├── data/                   #   Controller/depository decode, PDA seeds
│   ├── core/                   #   Discovery, RPC, gRPC wrappers
│   ├── dbsql/                  #   SQL schemas, CAGGs, views
│   ├── backfill-qa/
│   └── README.md
│
├── shared/                     # Shared Python modules (no protocol-specific logic)
│   ├── yellowstone_grpc_client/#   gRPC client, protobuf stubs, watchdog, reconnect
│   ├── solana_rpc_client/      #   Solana JSON-RPC client
│   ├── graphql_client/         #   Shyft GraphQL client (Kamino obligations, DEX positions)
│   ├── solana_utils/           #   Borsh decode, transaction parser, discriminators
│   ├── db_write_queue/         #   Async write queues + queue health monitor
│   ├── timescaledb_client/     #   DB connection, reconnect, pooling
│   ├── healthcheck/            #   HTTP health server + common checks
│   └── backfill-qa-solscan/    #   Shared backfill helpers
│
├── frontend/
│   ├── main/                   # Main dashboard
│   │   ├── api/                #   Express.js API backend (TypeScript)
│   │   └── ui/                 #   React SPA (Vite, Tailwind, shadcn/ui, D3.js)
│   ├── lightweight/            # Lightweight DEX liquidity dashboard (FastAPI)
│   └── README.md
│
├── health/                     # Pipeline health monitoring
│   ├── dbsql/                  #   Health schema views (queue, base table, CAGG, trigger)
│   ├── tempviz/                #   Marimo monitoring dashboard
│   ├── deploy_health_views.py  #   View deployment script
│   └── README.md
│
├── dbsql/
│   └── storage-compression-policies/  # TimescaleDB compression + retention policies (deploy.py)
│
├── cronjobs/
│   └── cagg_refresh/           # External CAGG refresh service (5-second cycle, Railway)
│
├── depeg-251225/               # USX-USDC depeg event analysis (Dec 2025, Marimo report)
│
├── handover-docs-260300/       # This documentation set
│
├── Dockerfile.*                # Per-service Dockerfiles (dexes, exponent, kamino, etc.)
└── railway.*.json              # Railway deployment configs
```

---

## Technology Stack

| Layer | Technology |
|---|---|
| Blockchain data | Yellowstone gRPC (Geyser plugin), Solana JSON-RPC, Shyft GraphQL indexer |
| Ingestion services | Python 3.13, gRPC (protobuf), psycopg2, Borsh deserialization |
| Database | Tiger Data (TimescaleDB Cloud) — PostgreSQL with hypertables, CAGGs, PL/pgSQL |
| CAGG refresh | Bash cron on Railway (PostgreSQL 16 Alpine container) |
| Main dashboard API | Node.js 18, Express.js, TypeScript |
| Main dashboard UI | React 18, Vite, Tailwind CSS, shadcn/ui, D3.js, TanStack Query |
| Lightweight dashboard | Python, FastAPI, server-rendered HTML/JS |
| Authentication | Clerk (main dashboard only) |
| Monitoring dashboards | Marimo (health dashboard, depeg report) |
| Container hosting | Railway (development), GCP (production) |
| Backfill / QA | Solscan Pro API, Polars, Parquet |

---

## Getting Started

### Prerequisites

- Python 3.13+
- Node.js 18+ (for main dashboard)
- Docker (for containerised deployment)
- Access to Shyft (gRPC/RPC/GraphQL endpoints and tokens)
- Access to Tiger Data (database credentials)
- Clerk account (for main dashboard auth)

### Running Ingestion Services

Each service is run from the repository root with environment variables loaded:

```bash
python -m dexes.main
python -m exponent.main
python -m kamino.main
python solstice-prop/main.py     # direct execution (hyphenated directory)
```

Environment variables must be set before startup — each service's `config.py` searches `.env` files automatically. See per-service READMEs and **05-DEPENDENCIES.md** for the full environment variable reference.

### Running Frontend Services

```bash
# Lightweight dashboard
cd frontend/lightweight
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000

# Main dashboard API
cd frontend/main/api
npm install && npm run dev

# Main dashboard UI
cd frontend/main/ui
npm install && npm run dev
```

### Deploying via Docker

Each service has a Dockerfile in the repository root. Build and run any service:

```bash
docker build -f Dockerfile.dexes -t dexes .
docker run --env-file .env.prod.dexes dexes
```

Railway deployment uses the `railway.*.json` configs. Production deployment on GCP uses the same Dockerfiles — see **05-DEPENDENCIES.md** for hosting details.

---

## Where to Go Next

Start with the document most relevant to your role:

- **Operations / cloud engineering** → [04-RESILIENCE.md](04-RESILIENCE.md), [05-DEPENDENCIES.md](05-DEPENDENCIES.md)
- **Backend / data engineering** → [01-INGESTION.md](01-INGESTION.md), [02-DATABASE.md](02-DATABASE.md)
- **Frontend development** → [03-FRONTEND.md](03-FRONTEND.md)
- **Protocol-specific deep dive** → Service READMEs (`dexes/`, `exponent/`, `kamino/`, `solstice-prop/`)
- **Database schema reference** → SQL files in `<service>/dbsql/` (inline `COMMENT ON` annotations are the authoritative source)
