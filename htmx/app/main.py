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
_health_proxy_lock = threading.Lock()
_health_proxy_cache: dict[str, object] = {"value": None, "expires_at": 0.0}

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
    widget_ids_filter = []
    if page.widget_filter_env_var:
        widget_ids_filter = [item.strip() for item in os.getenv(page.widget_filter_env_var, "").split(",") if item.strip()]

    widgets = [widget for widget in page.widgets if not widget_ids_filter or widget.id in widget_ids_filter]
    kpi_index = 0
    non_kpi_index = 0
    last_chart_delay = 0.0
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
    pipeline_info = _get_pipeline_info() if show_pipeline else None
    protocol = page.default_protocol
    pair = page.default_pair
    if pipeline_info and pipeline_info.get("defaults"):
        defaults = pipeline_info["defaults"]
        if defaults.get("protocol"):
            protocol = defaults["protocol"]
        if defaults.get("pair"):
            pair = defaults["pair"]

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
            "render_price_basis_select": page.show_price_basis_filter,
            "show_price_basis_filter": page.show_price_basis_filter and SHOW_PRICE_BASIS,
            "default_price_basis": DEFAULT_PRICE_BASIS,
            "content_template": page.content_template or "",
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
