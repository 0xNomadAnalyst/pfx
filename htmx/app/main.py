import importlib
import json
import os
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from dotenv import load_dotenv

from app.pages.common import PageConfig, build_widget_endpoint

# ── Load env BEFORE page imports so PAGE_* flags are available ───────
PROJECT_ROOT = Path(__file__).resolve().parents[1]
load_dotenv(PROJECT_ROOT / ".env", override=False)

# Internal address used for server-side proxy calls (health, pipeline, etc.)
API_BASE_URL = os.getenv("API_BASE_URL", "http://localhost:8001")
# Base URL embedded in page HTML for browser HTMX widget fetches.
# Defaults to "" (relative URLs) so the browser calls the UI host, which
# proxies to the internal API.  Override only if the API is publicly exposed.
BROWSER_API_BASE_URL = os.getenv("BROWSER_API_BASE_URL", "")
APP_TITLE = "Solana DeFi Ecosystem Dashboard"
ENABLE_PIPELINE_SWITCHER = os.getenv("ENABLE_PIPELINE_SWITCHER", "0") == "1"
DEFAULT_PIPELINE = os.getenv("DEFAULT_PIPELINE", "")
SHOW_PRICE_BASIS = os.getenv("SHOW_PRICE_BASIS", "1") == "1"
DEFAULT_PRICE_BASIS = os.getenv("DEFAULT_PRICE_BASIS", "default")
SHOW_ASSET_FILTER = os.getenv("SHOW_ASSET_FILTER", "1") == "1"
HEALTH_PROXY_TIMEOUT_SECONDS = float(os.getenv("HTMX_HEALTH_STATUS_TIMEOUT_SECONDS", "3"))
HEALTH_PROXY_TTL_SECONDS = float(os.getenv("HTMX_HEALTH_STATUS_CACHE_TTL_SECONDS", "5"))
META_PROXY_TTL_SECONDS = float(os.getenv("HTMX_META_CACHE_TTL_SECONDS", "300"))
WARMUP_WIDGETS_PER_PAGE = int(os.getenv("HTMX_WARMUP_WIDGETS_PER_PAGE", "8"))
WARMUP_BUDGET_SECONDS = int(os.getenv("HTMX_WARMUP_BUDGET_SECONDS", "30"))
WARMUP_MAX_JOBS = int(os.getenv("HTMX_WARMUP_MAX_JOBS", "20"))
WARMUP_CONCURRENCY = int(os.getenv("HTMX_WARMUP_CONCURRENCY", "3"))
HTMX_HEALTH_TABLE_BASE_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_TABLE_BASE_DELAY_SECONDS", "0.08"))
HTMX_HEALTH_TABLE_STEP_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_TABLE_STEP_DELAY_SECONDS", "0.12"))
HTMX_HEALTH_CHART_BASE_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_CHART_BASE_DELAY_SECONDS", "0.35"))
HTMX_HEALTH_CHART_STEP_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_CHART_STEP_DELAY_SECONDS", "0.18"))
HTMX_SOFT_NAV_SHELL_REFRESH_DELAY_MS = int(os.getenv("HTMX_SOFT_NAV_SHELL_REFRESH_DELAY_MS", "3000"))
HTMX_VIEWPORT_POLL_STALE_MS = int(os.getenv("HTMX_VIEWPORT_POLL_STALE_MS", "45000"))
HTMX_CRITICAL_CACHE_MAX_AGE_MS = int(os.getenv("HTMX_CRITICAL_CACHE_MAX_AGE_MS", "60000"))
HTMX_DEFAULT_CACHE_MAX_AGE_MS = int(os.getenv("HTMX_DEFAULT_CACHE_MAX_AGE_MS", "300000"))
HTMX_CLIENT_PERF_METRICS = os.getenv("HTMX_CLIENT_PERF_METRICS", "0") == "1"
_health_proxy_lock = threading.Lock()
_health_proxy_cache: dict[str, object] = {"value": None, "expires_at": 0.0}
_meta_proxy_lock = threading.Lock()
_meta_proxy_cache: dict[str, tuple[float, dict]] = {}

# ── Conditional page loading ────────────────────────────────────────
# Each entry: (PAGE_* env var, python module path, default "1"=on / "0"=off)
# When a page is OFF its module is never imported — zero resources allocated.
_PAGE_MODULES: list[tuple[str, str, str]] = [
    ("PAGE_COVER",            "app.pages.cover",                   "0"),
    ("PAGE_GLOBAL_ECOSYSTEM", "app.pages.global",                   "1"),
    ("PAGE_RISK_ANALYSIS",    "app.pages.risk_analysis",           "1"),
    ("PAGE_GLOBAL_SOLSTICE",  "app.pages.global_solstice_version", "0"),
    ("PAGE_DEX_LIQUIDITY",    "app.pages.dex_liquidity",           "0"),
    ("PAGE_DEX_SWAPS",        "app.pages.dex_swaps",               "0"),
    ("PAGE_DEXES",            "app.pages.dexes",                   "1"),
    ("PAGE_KAMINO",           "app.pages.kamino",                  "1"),
    ("PAGE_EXPONENT_YIELD",   "app.pages.exponent",                "1"),
    ("PAGE_SYSTEM_HEALTH",    "app.pages.health",                  "1"),
]

PAGES: list[PageConfig] = []

for _env_key, _mod_path, _default in _PAGE_MODULES:
    if os.getenv(_env_key, _default) == "1":
        try:
            _mod = importlib.import_module(_mod_path)
        except ModuleNotFoundError as exc:
            # Allow optional pages to be toggled on in env without hard-failing
            # startup when their module file is not present in this checkout.
            if exc.name == _mod_path:
                print(f"[WARN] Skipping missing page module: {_mod_path}")
                continue
            raise
        PAGES.append(_mod.PAGE_CONFIG)

PAGES_BY_SLUG: dict[str, PageConfig] = {page.slug: page for page in PAGES}

app = FastAPI(
    title="HTMX Risk Dashboard",
    description="Server-rendered dashboard using HTMX + ECharts.",
    version="0.1.0",
)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
templates = Jinja2Templates(directory="app/templates")


@app.on_event("startup")
def _apply_default_pipeline():
    """If DEFAULT_PIPELINE is set, tell the API server to switch on boot."""
    if not DEFAULT_PIPELINE:
        return
    try:
        body = json.dumps({"pipeline": DEFAULT_PIPELINE}).encode()
        req = urllib.request.Request(
            f"{API_BASE_URL}/api/v1/pipeline",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            payload = json.loads(resp.read())
            _pipeline_cache["value"] = payload
            _pipeline_cache["expires_at"] = time.time() + 5.0
    except Exception:
        pass


@app.middleware("http")
async def add_no_cache_html(request: Request, call_next):
    response = await call_next(request)
    ct = response.headers.get("content-type", "")
    if "text/html" in ct:
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
        response.headers["Pragma"] = "no-cache"
    return response


@app.get("/favicon.ico", include_in_schema=False)
def favicon():
    return Response(status_code=204)


@app.get("/", include_in_schema=False)
def home() -> RedirectResponse:
    return RedirectResponse(url=f"/{PAGES[0].slug}")


if "dex-liquidity" in PAGES_BY_SLUG:
    @app.get("/playbook-liquidity", include_in_schema=False)
    def legacy_playbook_liquidity() -> RedirectResponse:
        return RedirectResponse(url="/dex-liquidity")


def render_page(request: Request, page: PageConfig):
    def _is_secondary_lane(widget: object) -> bool:
        css = str(getattr(widget, "css_class", "") or "").lower()
        wid = str(getattr(widget, "id", "") or "").lower()
        proto = str(getattr(widget, "protocol_override", "") or "").lower()
        return (
            "dx-ray-" in css
            or "mkt2" in css
            or "-right" in css
            or wid.endswith("-mkt2")
            or wid.endswith("-ray")
            or "-ray-" in wid
            or proto in {"ray", "mkt2", "mkt2-sy"}
        )

    def _lane_group_key(widget: object) -> str:
        css = str(getattr(widget, "css_class", "") or "")
        tokens = [tok for tok in css.split() if tok]
        normalized: list[str] = []
        for tok in tokens:
            key = tok
            key = key.replace("dx-ray-", "dx-orca-")
            key = key.replace("-ray-", "-orca-")
            if key.endswith("-ray"):
                key = f"{key[:-4]}-orca"
            key = key.replace("mkt2", "mkt1")
            key = key.replace("right", "left")
            normalized.append(key)
        normalized.sort()
        return f"{getattr(widget, 'kind', '')}|{' '.join(normalized)}"

    widget_ids_filter = []
    if page.widget_filter_env_var:
        widget_ids_filter = [item.strip() for item in os.getenv(page.widget_filter_env_var, "").split(",") if item.strip()]

    widgets = [widget for widget in page.widgets if not widget_ids_filter or widget.id in widget_ids_filter]
    kpi_index = 0
    non_kpi_index = 0
    last_chart_delay = 0.0
    dual_pool_pages = {"risk-analysis", "dexes", "exponent-yield"}
    lane_delay_by_group: dict[str, float] = {}
    health_table_index = 0
    health_chart_index = 0
    health_queue_pair_delay: float | None = None
    widget_bindings = []
    for widget in widgets:
        if widget.kind == "kpi":
            load_delay_seconds = kpi_index * 0.15
            kpi_index += 1
        else:
            is_right = "chart-right" in (widget.css_class or "") or "-mkt2" in (widget.css_class or "")
            if is_right:
                load_delay_seconds = last_chart_delay
            else:
                load_delay_seconds = 1.5 + non_kpi_index * 0.6
                non_kpi_index += 1
            last_chart_delay = load_delay_seconds

        if page.slug in dual_pool_pages and widget.kind in {"kpi", "chart", "table", "table-split"}:
            lane_key = _lane_group_key(widget)
            if _is_secondary_lane(widget) and lane_key in lane_delay_by_group:
                # Promote the second lane to load alongside its first-lane counterpart.
                load_delay_seconds = lane_delay_by_group[lane_key]
            elif lane_key:
                lane_delay_by_group[lane_key] = load_delay_seconds

        if page.slug == "system-health":
            # Health is operational telemetry; prioritize visible first paint over
            # broad staggering even when caches are warm.
            if widget.kind in {"table", "table-split"}:
                health_delay = (
                    HTMX_HEALTH_TABLE_BASE_DELAY_SECONDS
                    + health_table_index * HTMX_HEALTH_TABLE_STEP_DELAY_SECONDS
                )
                load_delay_seconds = min(load_delay_seconds, health_delay)
                health_table_index += 1
            elif widget.kind == "chart":
                if widget.id == "health-queue-chart-2" and health_queue_pair_delay is not None:
                    load_delay_seconds = min(load_delay_seconds, health_queue_pair_delay)
                else:
                    health_delay = (
                        HTMX_HEALTH_CHART_BASE_DELAY_SECONDS
                        + health_chart_index * HTMX_HEALTH_CHART_STEP_DELAY_SECONDS
                    )
                    load_delay_seconds = min(load_delay_seconds, health_delay)
                    if widget.id == "health-queue-chart":
                        health_queue_pair_delay = load_delay_seconds
                    health_chart_index += 1

        if widget.kind == "kpi":
            refresh_interval_seconds = int(os.getenv("HTMX_REFRESH_KPI_SECONDS", str(widget.refresh_interval_seconds)))
        elif widget.kind in {"table", "table-split"}:
            refresh_interval_seconds = int(os.getenv("HTMX_REFRESH_TABLE_SECONDS", "90"))
        else:
            refresh_interval_seconds = int(os.getenv("HTMX_REFRESH_CHART_SECONDS", "60"))

        endpoint_page = widget.source_page_id or page.api_page_id
        endpoint_wid = widget.source_widget_id or widget.id
        widget_bindings.append(
            {
                "id": widget.id,
                "title": widget.title,
                "kind": widget.kind,
                "refresh_interval_seconds": max(15, refresh_interval_seconds),
                "endpoint": build_widget_endpoint(BROWSER_API_BASE_URL, endpoint_page, endpoint_wid),
                "css_class": widget.css_class,
                "expandable": widget.expandable if widget.kind == "chart" else False,
                "load_delay_seconds": load_delay_seconds,
                "tooltip": widget.tooltip,
                "detail_table_endpoint": build_widget_endpoint(BROWSER_API_BASE_URL, endpoint_page, widget.detail_table_id) if widget.detail_table_id else "",
                "source_widget_id": widget.source_widget_id,
                "protocol_override": widget.protocol_override,
            }
        )
    page_options = [{"slug": cfg.slug, "label": cfg.label, "path": f"/{cfg.slug}"} for cfg in PAGES]
    current_index = next((idx for idx, cfg in enumerate(PAGES) if cfg.slug == page.slug), 0)
    warmup_pages = PAGES[current_index + 1 :] + PAGES[:current_index]
    warmup_manifest = []
    warmup_exclude_kinds = {"section-header", "section-subheader", "placeholder"}
    for idx, cfg in enumerate(warmup_pages):
        targets: list[dict[str, object]] = []
        candidate_targets: list[dict[str, object]] = []
        seen_widget_ids: set[str] = set()
        for widget in cfg.widgets:
            if widget.kind in warmup_exclude_kinds:
                continue
            endpoint_widget_id = widget.source_widget_id or widget.id
            target_params: dict[str, str] = {}
            if widget.protocol_override:
                proto = widget.protocol_override
                if proto == "ray":
                    proto = "raydium"
                target_params["protocol"] = proto
            target_key = f"{endpoint_widget_id}::{target_params.get('protocol', '')}"
            if target_key in seen_widget_ids:
                continue
            seen_widget_ids.add(target_key)
            target_payload: dict[str, object] = {"widget_id": endpoint_widget_id, "kind": widget.kind}
            if target_params:
                target_payload["params"] = target_params
            # Prefer operationally-critical tables/charts first on system-health.
            if cfg.slug == "system-health":
                priority_map = {
                    "health-master": 0,
                    "health-queue-table": 1,
                    "health-trigger-table": 2,
                    "health-base-table": 3,
                    "health-cagg-table": 4,
                    "health-queue-chart": 5,
                    "health-queue-chart-2": 6,
                    "health-base-chart-events": 7,
                    "health-base-chart-accounts": 8,
                }
                target_payload["priority"] = priority_map.get(endpoint_widget_id, 100)
            candidate_targets.append(target_payload)

        if cfg.slug == "system-health":
            candidate_targets.sort(key=lambda item: int(item.get("priority", 100)))
        for target_payload in candidate_targets:
            targets.append(target_payload)
            if len(targets) >= max(1, WARMUP_WIDGETS_PER_PAGE):
                break
        if targets:
            warmup_manifest.append(
                {
                    "slug": cfg.slug,
                    "page_id": cfg.api_page_id,
                    "order": idx,
                    "targets": targets,
                }
            )

    page_action_bindings = [
        {
            "id": action.id,
            "label": action.label,
            "icon": action.icon,
            "modal_kind": action.modal_kind,
            "endpoint": build_widget_endpoint(BROWSER_API_BASE_URL, page.api_page_id, action.endpoint) if action.endpoint else "",
        }
        for action in page.page_actions
    ]
    show_pipeline = ENABLE_PIPELINE_SWITCHER and page.show_pipeline_switcher
    pipeline_info = _get_pipeline_info() if ENABLE_PIPELINE_SWITCHER else None
    protocol = page.default_protocol
    pair = page.default_pair
    if pipeline_info and pipeline_info.get("defaults"):
        defaults = pipeline_info["defaults"]
        if defaults.get("protocol"):
            protocol = defaults["protocol"]
        if defaults.get("pair"):
            pair = defaults["pair"]

    current_pipeline = pipeline_info.get("current", "") if isinstance(pipeline_info, dict) else ""

    return templates.TemplateResponse(
        request=request,
        name="base.html",
        context={
            "app_title": APP_TITLE,
            "page_title": page.label,
            "page_options": page_options,
            "current_page_slug": page.slug,
            "widgets": widget_bindings,
            "page_actions": page_action_bindings,
            "show_protocol_pair_filters": page.show_protocol_pair_filters,
            "show_asset_filter": page.show_asset_filter and SHOW_ASSET_FILTER,
            "show_market_selectors": page.show_market_selectors,
            "api_page_id": page.api_page_id,
            "protocol": protocol,
            "pair": pair,
            "asset": page.default_asset,
            "last_window": "7d",
            "api_base_url": BROWSER_API_BASE_URL,
            "show_pipeline_switcher": show_pipeline,
            "pipeline_info": pipeline_info,
            "current_pipeline": current_pipeline,
            "render_price_basis_select": page.show_price_basis_filter,
            "show_price_basis_filter": page.show_price_basis_filter and SHOW_PRICE_BASIS,
            "default_price_basis": DEFAULT_PRICE_BASIS,
            "content_template": page.content_template or "",
            "warmup_manifest": warmup_manifest,
            "warmup_defaults": {
                "budget_seconds": max(1, WARMUP_BUDGET_SECONDS),
                "max_jobs": max(1, WARMUP_MAX_JOBS),
                "concurrency": max(1, WARMUP_CONCURRENCY),
            },
            "nav_tuning": {
                "soft_nav_shell_refresh_delay_ms": max(500, min(20000, HTMX_SOFT_NAV_SHELL_REFRESH_DELAY_MS)),
                "viewport_poll_stale_ms": max(5000, min(300000, HTMX_VIEWPORT_POLL_STALE_MS)),
                "critical_cache_max_age_ms": max(5000, min(300000, HTMX_CRITICAL_CACHE_MAX_AGE_MS)),
                "default_cache_max_age_ms": max(10000, min(1800000, HTMX_DEFAULT_CACHE_MAX_AGE_MS)),
                "perf_metrics_enabled": HTMX_CLIENT_PERF_METRICS,
            },
        },
    )


def _make_page_handler(slug: str):
    def _handler(request: Request):
        return render_page(request, PAGES_BY_SLUG[slug])
    _handler.__name__ = slug.replace("-", "_")
    return _handler


for _page in PAGES:
    app.get(f"/{_page.slug}")(_make_page_handler(_page.slug))


@app.get("/chart-export", include_in_schema=False)
def chart_export(request: Request):
    """Private utility page for exporting charts as image assets."""
    chart_catalogue: list[dict] = []
    for page in PAGES:
        for widget in page.widgets:
            if widget.kind != "chart":
                continue
            chart_catalogue.append({
                "page_label": page.label,
                "page_id": page.api_page_id,
                "widget_id": widget.id,
                "widget_title": widget.title,
                "endpoint": build_widget_endpoint(BROWSER_API_BASE_URL, page.api_page_id, widget.id),
                "show_protocol_pair": page.show_protocol_pair_filters,
                "show_markets": page.show_market_selectors,
            })
    pipeline_info = _get_pipeline_info() if ENABLE_PIPELINE_SWITCHER else None
    return templates.TemplateResponse(
        request=request,
        name="export.html",
        context={
            "app_title": APP_TITLE,
            "chart_catalogue": chart_catalogue,
            "api_base_url": BROWSER_API_BASE_URL,
            "show_pipeline_switcher": ENABLE_PIPELINE_SWITCHER,
            "pipeline_info": pipeline_info,
        },
    )


_pipeline_cache: dict[str, object] = {"value": None, "expires_at": 0.0}

def _get_pipeline_info() -> dict | None:
    """Fetch pipeline state from the API server.  Cached for 5s."""
    now = time.time()
    if now < float(_pipeline_cache.get("expires_at", 0.0)):
        cached = _pipeline_cache.get("value")
        if isinstance(cached, dict):
            return cached

    try:
        req = urllib.request.Request(f"{API_BASE_URL}/api/v1/pipeline")
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read())
            _pipeline_cache["value"] = data
            _pipeline_cache["expires_at"] = time.time() + 5.0
            return data
    except Exception:
        return _pipeline_cache.get("value") if isinstance(_pipeline_cache.get("value"), dict) else None


@app.get("/api/pipeline-info")
def pipeline_info_proxy():
    """Client-side hydration endpoint for when server-side fetch missed."""
    info = _get_pipeline_info()
    if info:
        return JSONResponse(content=info)
    return JSONResponse(content={"current": None, "available": []}, status_code=503)


@app.post("/api/switch-pipeline")
def switch_pipeline_proxy(request: Request):
    """Same-origin proxy to avoid CORS for the pipeline switch POST."""
    import urllib.error
    try:
        body = json.dumps({"pipeline": dict(request.query_params).get("pipeline", "")})
        req = urllib.request.Request(
            f"{API_BASE_URL}/api/v1/pipeline",
            data=body.encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            payload = json.loads(resp.read())
            _pipeline_cache["value"] = payload
            _pipeline_cache["expires_at"] = time.time() + 5.0
            _health_proxy_cache["value"] = None
            _health_proxy_cache["expires_at"] = 0.0
            with _meta_proxy_lock:
                _meta_proxy_cache.clear()
            return JSONResponse(content=payload)
    except urllib.error.HTTPError as exc:
        return JSONResponse(content={"error": str(exc)}, status_code=exc.code)
    except Exception as exc:
        return JSONResponse(content={"error": str(exc)}, status_code=502)


@app.api_route("/api/v1/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
async def api_v1_proxy(path: str, request: Request):
    """Forward all /api/v1/* widget requests to the internal API server.

    Widget endpoint URLs are rendered into the page HTML and fetched by the
    browser, so they must resolve via the public UI host.  The internal API
    listens only on 127.0.0.1 and is not directly reachable by browsers.
    """
    qs = request.url.query
    target = f"{API_BASE_URL}/api/v1/{path}"
    if qs:
        target = f"{target}?{qs}"

    if request.method.upper() == "GET" and path == "meta":
        now = time.time()
        with _meta_proxy_lock:
            cached = _meta_proxy_cache.get(qs)
            if cached and cached[0] > now:
                return JSONResponse(content=cached[1], headers={"Cache-Control": "no-store"})

    body: bytes | None = None
    method = request.method.upper()
    if method in ("POST", "PUT", "PATCH"):
        body = await request.body()

    req = urllib.request.Request(target, data=body or None, method=method)
    req.add_header("Content-Type", request.headers.get("content-type", "application/json"))
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            content = resp.read()
            ct = resp.headers.get("content-type", "application/json")
            if request.method.upper() == "GET" and path == "meta":
                try:
                    payload = json.loads(content)
                    with _meta_proxy_lock:
                        _meta_proxy_cache[qs] = (time.time() + META_PROXY_TTL_SECONDS, payload)
                except Exception:
                    pass
            return Response(
                content=content, media_type=ct, status_code=resp.status,
                headers={"Cache-Control": "no-store"},
            )
    except urllib.error.HTTPError as exc:
        return JSONResponse(content={"error": str(exc)}, status_code=exc.code)
    except Exception as exc:
        return JSONResponse(content={"error": str(exc)}, status_code=502)


@app.get("/api/health-status")
def health_status_proxy():
    """Same-origin proxy so the header indicator avoids cross-origin fetch."""
    now = time.time()
    if now < float(_health_proxy_cache.get("expires_at", 0.0)):
        cached = _health_proxy_cache.get("value")
        if isinstance(cached, dict):
            return JSONResponse(content=cached)

    with _health_proxy_lock:
        now = time.time()
        if now < float(_health_proxy_cache.get("expires_at", 0.0)):
            cached = _health_proxy_cache.get("value")
            if isinstance(cached, dict):
                return JSONResponse(content=cached)

        cached_before = _health_proxy_cache.get("value")
        if not isinstance(cached_before, dict):
            cached_before = None

    try:
        req = urllib.request.Request(f"{API_BASE_URL}/api/v1/health-status")
        with urllib.request.urlopen(req, timeout=HEALTH_PROXY_TIMEOUT_SECONDS) as resp:
            payload = json.loads(resp.read())
            with _health_proxy_lock:
                _health_proxy_cache["value"] = payload
                _health_proxy_cache["expires_at"] = time.time() + HEALTH_PROXY_TTL_SECONDS
            return JSONResponse(content=payload)
    except Exception:
        if isinstance(cached_before, dict):
            return JSONResponse(content=cached_before)
        return JSONResponse(content={"is_green": None})


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8002"))
    uvicorn.run("app.main:app", host="0.0.0.0", port=port, reload=True)
