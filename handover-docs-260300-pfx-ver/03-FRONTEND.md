# Frontend Services

The platform has two separate frontend services, each optimised for a different use case:

1. **Main Dashboard** (`frontend/main/`) -- full-featured React SPA with Express API backend, covering all protocol domains, risk analytics, and pipeline health monitoring. Authenticated via Clerk.
2. **Lightweight DEX Dashboard** (`frontend/lightweight/`) -- server-rendered FastAPI service focused exclusively on DEX liquidity and price-impact data where low-latency refresh is critical. Authenticated via Clerk (same user pool as the main dashboard). No JS framework, zero build step.

Both services query the same Tiger Data database, calling the SQL view functions documented in **02-DATABASE.md**. Neither service performs writes -- all data flows from the ingestion pipeline and in-DB ETL.

Related companion documents:

- **01-INGESTION.md** -- data ingestion services that feed the database.
- **02-DATABASE.md** -- in-DB ETL, view functions, and continuous aggregates that the frontend queries.
- **04-RESILIENCE.md** -- pipeline health views surfaced in the main dashboard's health panel.
- **05-DEPENDENCIES.md** -- external service dependencies including Tiger Data, Clerk, and hosting.

---

## Main Dashboard (`frontend/main/`)

A two-tier web application: a React SPA for the UI and an Express.js API backend that acts as a query gateway to the database.

### Architecture

```
Browser
  → React SPA (Vite build, Tailwind + shadcn/ui + D3.js)
      → Clerk authentication
      → TanStack Query (data fetching + caching)
          → Express.js API Backend
              → Clerk auth middleware
              → TimescaleDB query client
                  → SQL view functions (dexes, kamino_lend, exponent, solstice_proprietary, health)
```

### UI (`frontend/main/ui/`)

| Category | Technology |
|---|---|
| Framework | React 18 + TypeScript |
| Build | Vite |
| Styling | Tailwind CSS |
| Components | Radix UI + shadcn/ui |
| Charts | D3.js (custom `BaseD3Chart` wrapper) |
| Data Fetching | TanStack Query (React Query) |
| Routing | React Router DOM v7 |
| Auth | Clerk |

**Dashboard screens:**

| Route | Screen | Domain |
|---|---|---|
| `/dashboard/risk-management` | Risk Management | Cross-domain risk analysis |
| `/dashboard/global-ecosystem` | Global Ecosystem | Ecosystem overview, supply distribution, TVL |
| `/dashboard/usx-raydium-liquidity` | Raydium Liquidity | USX Raydium pool liquidity depth |
| `/dashboard/usx-raydium-activity` | Raydium Activity | USX Raydium swap events and volumes |
| `/dashboard/usx-orca-liquidity` | Orca Liquidity | USX Orca pool liquidity depth |
| `/dashboard/usx-orca-activity` | Orca Activity | USX Orca swap events and volumes |
| `/dashboard/eusx-dex-liquidity` | eUSX DEX Liquidity | eUSX DEX pool liquidity |
| `/dashboard/eusx-dex-activity` | eUSX DEX Activity | eUSX DEX swap events and volumes |
| `/dashboard/kamino-activity` | Kamino Activity | Kamino lending activity and sensitivities |
| `/dashboard/exponent` | Exponent Activity | Exponent protocol metrics and yield data |

**Global controls:**

- **Time range selector** -- global time period picker (2h, 4h, 1d, 7d, 30d, 90d) applied across all chart widgets. Each period maps to an appropriate query interval/grain (e.g. 2h → 2m, 7d → 3h, 90d → 1d) via `period-interval-map.json`.
- **Health indicator** -- sidebar component that shows a live pipeline health summary (green/red master status) with a slide-out health panel covering queue health, CAGG refresh, source table activity, and trigger health. These components query the `health` schema views documented in **04-RESILIENCE.md**.

**Environment variables:**

- `VITE_API_URL` / `VITE_API_BASE_URL` -- API backend URL.
- `VITE_CLERK_PUBLISHABLE_KEY` -- Clerk publishable key.
- `VITE_ENV` -- environment identifier (controls `hideInProduction` nav items).

### API Backend (`frontend/main/api/`)

| Category | Technology |
|---|---|
| Runtime | Node.js 18 + TypeScript |
| Framework | Express.js |
| Database | TimescaleDB via `pg` connection pool |
| Auth | Clerk middleware |
| Testing | Vitest |

The API backend is a thin query gateway -- it does not contain business logic beyond parameter validation and result formatting. All analytical computation happens in the database view functions.

**Key endpoint groups:**

| Endpoint Pattern | Schema | Purpose |
|---|---|---|
| `/api/charts/get-dex-timeseries` | `dexes` | DEX time-series (pool metrics, VWAP) |
| `/api/charts/get-dex-last` | `dexes` | Latest DEX snapshot |
| `/api/charts/get-tick-dist` | `dexes` | Tick distribution / liquidity depth |
| `/api/charts/get-dex-ranked-events` | `dexes` | Ranked swap/liquidity events |
| `/api/charts/get_view_sell_swaps_distribution` | `dexes` | Sell swap size distribution |
| `/api/charts/get_view_klend_timeseries` | `kamino_lend` | Kamino lending time-series |
| `/api/charts/get_view_klend_sensitivities` | `kamino_lend` | Kamino risk sensitivities |
| `/api/charts/get_view_exponent_timeseries` | `exponent` | Exponent time-series |
| `/api/charts/v_exponent_last` | `exponent` | Latest Exponent snapshot |
| `/api/charts/get_view_prop_timeseries` | `solstice_proprietary` | Solstice time-series |
| `/api/charts/get_view_prop_last_interval` | `solstice_proprietary` | Latest Solstice interval |
| `/api/funcs/:func` | dynamic | Generic SQL function caller |
| `/api/tables/:table` | dynamic | Generic table data query |
| `/health` | -- | Server health check (no auth) |
| `/api/monitoring/connections` | -- | DB connection pool status |

All chart and table endpoints require Clerk authentication (`Authorization: Bearer <token>`). Auth can be disabled for local development via `DISABLE_BACKEND_AUTH=true`.

**Environment variables:**

- `PORT` -- server port (default `3001`).
- `TIMESCALE_CONNECTION_STRING` -- full PostgreSQL connection string.
- `TIMESCALE_MAX_CONNECTIONS` -- connection pool size (default `22`).
- `CLERK_PUBLISHABLE_KEY`, `CLERK_SECRET_KEY` -- Clerk auth credentials.
- `DISABLE_BACKEND_AUTH` -- bypass auth for local development.

### Dockerfiles

- `frontend/main/api/Dockerfile` -- Node 18 Alpine, production build, exposes port 3001.
- `frontend/main/ui/Dockerfile` -- Node 22 Alpine, Vite production build with build-time env vars (`VITE_CLERK_PUBLISHABLE_KEY`, `VITE_API_BASE_URL`, `VITE_ENV`), serves via `npm run preview`.
- `frontend/main/ui/Dockerfile.dev` -- development variant with hot-reload on port 5173.

---

## Lightweight DEX Dashboard (`frontend/lightweight/`)

A standalone FastAPI service that delivers server-rendered HTML dashboards with embedded JavaScript for DEX liquidity data. Designed for the most time-sensitive use case: monitoring real-time liquidity depth and price impact across the monitored pools.

### Why a Separate Service

The main dashboard uses a React SPA that goes through an Express API layer, TanStack Query caching, and client-side rendering. For DEX liquidity monitoring -- where the client needs sub-minute refresh of price-impact grids and position-level detail -- the lightweight service eliminates that overhead by:

- Querying database view functions directly from Python (no API gateway layer).
- Server-rendering HTML with embedded JS (no client-side framework, no build step).
- Short TTL in-memory caching (15--30 seconds) with startup pre-warming.

### Authentication

The lightweight dashboard uses the same Clerk project and user pool as the main dashboard. Authentication is implemented in `clerk_auth.py` using the `clerk-backend-api` Python SDK:

- **API endpoints** (JSON) -- protected via a `require_auth` FastAPI dependency that validates Clerk session tokens from the `__session` cookie or `Authorization` header. Returns HTTP 401 on failure.
- **HTML views** -- check `validate_session()` on each request. Unauthenticated visitors are shown a Clerk sign-in page (rendered via Clerk's JS SDK loaded from the Frontend-API domain). On successful sign-in, the user is redirected to `/flexible/`.
- **Authenticated pages** -- a Clerk `UserButton` widget is injected before `</body>` for session management (sign out, account switching).
- **Local development** -- set `DISABLE_AUTH=true` to bypass all authentication checks.

### Views

| View | Path | Refresh | Purpose |
|---|---|---|---|
| Impact Table | `/impact/` | 30s auto | Fixed BPS-step grid: swap size needed to move price by each basis-point increment. Four pools. |
| Flexible Depth | `/flexible/` | 5--30s toggle | Interactive explorer: pair, protocol, market actors, price bounds, tick step. Band-level liquidity and required swap quantities. |
| Liquidity Positions | `/positions/` | on-demand | Per-position view: tick ranges, token composition, market actor filters, on-chain address clipboard. |

All three views cross-link to each other and share JSON API endpoints alongside the HTML views.

### Data Source

All queries call parameterised SQL functions in the `dexes` schema:

| SQL Function | View |
|---|---|
| `dexes.get_view_liquidity_depth_table(protocol, pair)` | Impact Table |
| `dexes.get_view_liquidity_depth_table_flexible(...)` | Flexible Depth |
| `dexes.get_view_dex_table_liquidity_positions(...)` | Positions |

A Python/Polars reimplementation (`calc_flexible_depth.py`) is retained for benchmarking and experimentation but is not the production path.

### Caching

In-memory TTL cache (`db.TTLCache`) sits in front of every query:

- Impact tables -- 30s TTL per protocol/pair.
- Flexible / positions -- 15s TTL, keyed on full query parameters.
- Metadata -- 300s TTL.

A background thread pre-warms metadata and impact caches at startup so `/health` responds immediately.

### Environment Variables

**Required:** `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY`

**Optional:** `PORT` (default `8000`), `CACHE_TTL_SECONDS` (default `30`), `DB_POOL_MIN` (default `1`), `DB_POOL_MAX` (default `8`), `DISABLE_AUTH` (default `false`), `CORS_ORIGINS` (comma-separated allowed origins)

### Deployment

Deployed on Railway via `railway.toml` with `/health` healthcheck. See **05-DEPENDENCIES.md** for hosting details.

### Validation Scripts

Scripts under `validation/` compare the dashboard's numbers against external sources (Jupiter API, Raydium/Orca pool APIs) to verify correctness of depth and impact calculations.

---

## How the Two Services Relate

| Aspect | Main Dashboard | Lightweight Dashboard |
|---|---|---|
| Scope | All domains (DEX, Kamino, Exponent, Solstice, risk, health) | DEX liquidity only |
| Latency priority | Standard (React Query caching) | High (15--30s TTL, server-rendered) |
| Auth | Clerk (React SDK + Express middleware) | Clerk (Python SDK, same user pool) |
| Tech stack | React + Express + TypeScript | FastAPI + Python |
| Data path | Browser → Express API → SQL functions | Browser → FastAPI → SQL functions |
| Rendering | Client-side SPA | Server-rendered HTML |
| Build step | Vite build required | None |
| Deployment | Two containers (API + UI) | Single container |

The main dashboard provides the comprehensive analytical interface for all protocol domains. The lightweight service exists because the DEX liquidity monitoring use case demands the fastest possible data refresh with minimum latency -- it was purpose-built for the client's operational monitoring workflow.

---

## Where to Go Next

- **`frontend/main/ui/README.md`** -- UI folder structure, tech stack, screen detail.
- **`frontend/main/api/README.md`** -- API backend routes, controllers, middleware.
- **`frontend/lightweight/README.md`** -- lightweight service endpoints, caching, validation.
- **02-DATABASE.md** -- SQL view functions that both frontends query.
- **04-RESILIENCE.md** -- health views surfaced in the main dashboard's health panel.
- **05-DEPENDENCIES.md** -- Clerk auth, Tiger Data, and hosting dependencies.
