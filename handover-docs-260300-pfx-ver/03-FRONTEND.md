# Frontend Services

The dashboard frontend is implemented as two coordinated FastAPI services:

1. **HTMX UI service** (`pfx/htmx`) -- server-rendered Jinja pages, HTMX widget updates, soft navigation, and client-side runtime caching controls.
2. **Widget API + caching service** (`pfx/api-w-caching`) -- frontend-agnostic JSON API that queries database view/functions and applies server-side cache, SWR, and warmup strategies.

This implementation replaces the earlier React/Express split. The UI does not query SQL directly. All widget data is fetched through the API service.

Related companion documents:

- **01-INGESTION.md** -- ingestion services and source data flow.
- **02-DATABASE.md** -- SQL view/functions consumed by the API service.
- **04-RESILIENCE.md** -- platform/runtime health and recovery model.
- **05-DEPENDENCIES.md** -- hosting, database, and external dependencies.

---

## Architecture Overview

```
Browser
  -> HTMX UI (FastAPI + Jinja templates + HTMX + charts.js)
      -> Same-origin proxy routes (/api/v1/*, /api/health-status, /api/switch-pipeline)
          -> Widget API (FastAPI)
              -> DataService page modules
                  -> SQL adapter
                      -> Timescale/Tiger Data view functions
```

### Separation of responsibilities

- **`pfx/htmx`** owns page layout, widget orchestration, user interactions, client cache behavior, and same-origin proxying.
- **`pfx/api-w-caching`** owns widget payload generation, SQL calls, cache policy, prewarm strategy, and pipeline-scoped data access.

---

## HTMX UI Service (`pfx/htmx`)

A server-rendered UI host with no JS framework build pipeline.

### Technology

| Category | Implementation |
|---|---|
| Runtime | Python + FastAPI |
| Templates | Jinja2 |
| Interaction model | HTMX widget requests + browser-side rendering helpers |
| Static assets | `app/static/` (`theme.css`, `charts.js`, `theme.js`) |
| Compression | `GZipMiddleware` |

### Primary routes

| Route | Purpose |
|---|---|
| `/` | Redirects to first enabled page |
| `/{page-slug}` | Full dashboard pages from enabled `PageConfig` modules |
| `/playbook-liquidity` | Legacy redirect to `/dex-liquidity` when that page is enabled |
| `/chart-export` | Internal chart export utility page |
| `/api/v1/{path:path}` | Same-origin proxy to API service widget/meta/warmup endpoints |
| `/api/health-status` | Same-origin proxy for the global header health indicator |
| `/api/pipeline-info` | Client hydration endpoint for current pipeline state |
| `/api/switch-pipeline` | Same-origin pipeline switch proxy |

### Page modules and conditional enablement

Pages are imported conditionally using `PAGE_*` environment flags. Current defaults in `app/main.py` enable:

- `global-ecosystem`
- `dexes`
- `kamino`
- `exponent-yield`
- `risk-analysis`
- `system-health`

Optional modules (`cover`, `dex-liquidity`, `dex-swaps`, alternate global) are available but disabled by default.

### Frontend cache modes

`HTMX_CACHE_MODE` defines client behavior profiles:

- `conservative` -- freshness-first, short TTL/refresh, no speculative prefetch.
- `balanced` -- default baseline behavior.
- `aggressive` -- speed-first, longer cache horizons, prefetch and render optimizations.

Individual `HTMX_*` environment variables override any profile key.

### Built-in frontend performance features

Implemented in `app/main.py` and `app/static/js/charts.js`:

- Soft navigation shell caching (page HTML shell cache).
- Widget response caching keyed by widget + filter signature.
- Optional warmup orchestration (`POST /api/v1/warmup`) after first interaction.
- Viewport-aware poll suppression.
- Optional aggressive-mode features (hover prefetch, batched reveal, adaptive dial-down, concurrency caps, skeleton timing).
- Optional localStorage cache persistence (`HTMX_PERSIST_CACHE_ENABLED`).

### Pipeline switcher integration

When enabled (`ENABLE_PIPELINE_SWITCHER=1`), the UI reads active pipeline info and proxies pipeline switch operations to the API service. A startup hook can auto-apply `DEFAULT_PIPELINE`.

### Key environment variables (UI)

- `API_BASE_URL` (internal API URL used by server-side proxy)
- `BROWSER_API_BASE_URL` (optional direct browser API base; default relative)
- `PORT` (default `8002`)
- `HTMX_CACHE_MODE` + targeted `HTMX_*` overrides
- `ENABLE_PIPELINE_SWITCHER`, `DEFAULT_PIPELINE`
- `PAGE_*` flags for page inclusion

---

## Widget API + Caching Service (`pfx/api-w-caching`)

A frontend-agnostic widget API with server-side caching and prewarm support.

### Technology

| Category | Implementation |
|---|---|
| Runtime | Python + FastAPI |
| Core coordinator | `DataService` |
| SQL access | `SqlAdapter` |
| Compression | `GZipMiddleware` |
| CORS | Open (`allow_origins=["*"]`) |

### Supported page IDs

- `playbook-liquidity` / `dex-liquidity`
- `dex-swaps`
- `dexes`
- `kamino`
- `exponent`
- `health`
- `global-ecosystem`
- `risk-analysis`

### API endpoints

| Endpoint | Purpose |
|---|---|
| `GET /health` | API process health |
| `GET /api/v1/{page}/{widget}` | Canonical widget payload route |
| `GET /api/v1/pages/{page}/widgets/{widget}` | Alias route shape |
| `GET /api/v1/widgets` | List available widgets for a page |
| `GET /api/v1/meta` | Shared metadata payload |
| `GET /api/v1/health-status` | Lightweight header indicator status |
| `POST /api/v1/warmup` | Targeted cache warmup for widget manifests |
| `GET /api/v1/pipeline` | Current/available pipelines (if enabled) |
| `POST /api/v1/pipeline` | Pipeline switch (if enabled) |
| `GET /api/v1/cache-stats` | Cache internals (when enabled) |

### Cache implementation

`QueryCache` (`app/services/shared/cache_store.py`) provides:

- TTL cache with LRU eviction (`max_entries`).
- Singleflight deduplication (`_inflight` waiters) to collapse concurrent cache misses per key.
- Stale-While-Revalidate (`cached_swr`) with bounded background refresh workers.
- TTL jitter to reduce synchronized expiration spikes.
- Optional stats reporting (`hits`, `misses`, `stale_served`, `bg_refresh_started`, etc.).

`API_CACHE_MODE` profiles (`fresh`, `balanced`, `speed`) provide baseline cache settings, with explicit `API_*` env vars as overrides.

### Startup warmup and runtime warmup

- **Startup warmup (`DataService.warmup`)** preloads selected heavy widgets across Kamino, DEX, Exponent, Health, and Global pages, bounded by `API_PREWARM_MAX_SECONDS`.
- **Runtime warmup (`POST /api/v1/warmup`)** accepts a target manifest from the UI and warms cache entries with configurable budget, concurrency, and optional payload return limits.

### Pipeline switching behavior

When `ENABLE_PIPELINE_SWITCHER=1`, the API can switch DB credentials between configured pipelines (`solstice` / `onyc`) at runtime:

- Pipeline switch flushes service caches.
- SQL pool is reset after switch.
- Request-level `_pipeline` guard keeps API state aligned with requested UI pipeline.

### Key environment variables (API)

- DB credentials: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
- `PORT` (default `8001`)
- `API_CACHE_MODE` and `API_CACHE_*` overrides
- `API_PREWARM_*` controls for startup warmup scope/order/budget
- `ENABLE_PIPELINE_SWITCHER`
- optional observability toggles (`API_CACHE_STATS_ENABLED`, slow query/widget logging flags)

---

## Service Interaction and Deployment

### Local default ports

- UI: `http://localhost:8002`
- API: `http://localhost:8001`

### Request path

1. Browser loads a page from the UI service.
2. Widget endpoints in page config resolve to `/api/v1/...` (same origin by default).
3. UI proxy forwards to API service.
4. API service returns cached or freshly queried widget payload.
5. HTMX updates individual widget containers.

This split keeps page delivery and UX logic in one process, while concentrating query/caching logic in a reusable API layer.

---

## Where to Go Next

- **`pfx/htmx/README.md`** -- quick start for UI service.
- **`pfx/htmx/docs/frontend-caching.md`** -- detailed frontend cache modes and feature flags.
- **`pfx/api-w-caching/README.md`** -- API startup, benchmark tooling, and cache tuning.
- **02-DATABASE.md** -- SQL contracts consumed by API page services.
- **04-RESILIENCE.md** -- runtime health/recovery model for both services and ingestion dependencies.

