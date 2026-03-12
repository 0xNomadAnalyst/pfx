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
from app.pages.dex_liquidity import PAGE_CONFIG as DEX_LIQUIDITY_PAGE
from app.pages.dex_swaps import PAGE_CONFIG as DEX_SWAPS_PAGE
from app.pages.exponent import PAGE_CONFIG as EXPONENT_PAGE
from app.pages.health import PAGE_CONFIG as HEALTH_PAGE
from app.pages.kamino import PAGE_CONFIG as KAMINO_PAGE

import importlib as _il
_ge_mod = _il.import_module("app.pages.global")
GLOBAL_ECOSYSTEM_PAGE: PageConfig = _ge_mod.PAGE_CONFIG

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
HEALTH_PROXY_TIMEOUT_SECONDS = float(os.getenv("HTMX_HEALTH_STATUS_TIMEOUT_SECONDS", "3"))
HEALTH_PROXY_TTL_SECONDS = float(os.getenv("HTMX_HEALTH_STATUS_CACHE_TTL_SECONDS", "5"))
_health_proxy_lock = threading.Lock()
_health_proxy_cache: dict[str, object] = {"value": None, "expires_at": 0.0}

# Keep page registration centralized so the shared header view selector
# is consistent across all routes.
PAGES: list[PageConfig] = [GLOBAL_ECOSYSTEM_PAGE, DEX_LIQUIDITY_PAGE, DEX_SWAPS_PAGE, KAMINO_PAGE, EXPONENT_PAGE, HEALTH_PAGE]
PAGES_BY_SLUG: dict[str, PageConfig] = {page.slug: page for page in PAGES}

app = FastAPI(
    title="HTMX Risk Dashboard",
    description="Server-rendered dashboard using HTMX + ECharts.",
    version="0.1.0",
)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
templates = Jinja2Templates(directory="app/templates")


@app.get("/favicon.ico", include_in_schema=False)
def favicon():
    return Response(status_code=204)


@app.get("/", include_in_schema=False)
def home() -> RedirectResponse:
    return RedirectResponse(url=f"/{DEX_LIQUIDITY_PAGE.slug}")


@app.get("/playbook-liquidity", include_in_schema=False)
def legacy_playbook_liquidity() -> RedirectResponse:
    return RedirectResponse(url=f"/{DEX_LIQUIDITY_PAGE.slug}")


def render_page(request: Request, page: PageConfig):
    widget_ids_filter = []
    if page.widget_filter_env_var:
        widget_ids_filter = [item.strip() for item in os.getenv(page.widget_filter_env_var, "").split(",") if item.strip()]

    widgets = [widget for widget in page.widgets if not widget_ids_filter or widget.id in widget_ids_filter]
    kpi_index = 0
    non_kpi_index = 0
    widget_bindings = []
    for widget in widgets:
        if widget.kind == "kpi":
            load_delay_seconds = kpi_index * 0.15
            kpi_index += 1
        else:
            # Stagger heavier widgets to reduce request bursts on initial load.
            load_delay_seconds = 1.5 + non_kpi_index * 0.6
            non_kpi_index += 1

        if widget.kind == "kpi":
            refresh_interval_seconds = int(os.getenv("HTMX_REFRESH_KPI_SECONDS", str(widget.refresh_interval_seconds)))
        elif widget.kind in {"table", "table-split"}:
            refresh_interval_seconds = int(os.getenv("HTMX_REFRESH_TABLE_SECONDS", "90"))
        else:
            refresh_interval_seconds = int(os.getenv("HTMX_REFRESH_CHART_SECONDS", "60"))

        widget_bindings.append(
            {
                "id": widget.id,
                "title": widget.title,
                "kind": widget.kind,
                "refresh_interval_seconds": max(15, refresh_interval_seconds),
                "endpoint": build_widget_endpoint(BROWSER_API_BASE_URL, page.api_page_id, widget.id),
                "css_class": widget.css_class,
                "expandable": widget.expandable if widget.kind == "chart" else False,
                "load_delay_seconds": load_delay_seconds,
                "tooltip": widget.tooltip,
                "detail_table_endpoint": build_widget_endpoint(BROWSER_API_BASE_URL, page.api_page_id, widget.detail_table_id) if widget.detail_table_id else "",
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
    pipeline_info = _get_pipeline_info() if ENABLE_PIPELINE_SWITCHER else None
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
            "show_market_selectors": page.show_market_selectors,
            "api_page_id": page.api_page_id,
            "protocol": protocol,
            "pair": pair,
            "last_window": "7d",
            "api_base_url": BROWSER_API_BASE_URL,
            "show_pipeline_switcher": ENABLE_PIPELINE_SWITCHER,
            "pipeline_info": pipeline_info,
        },
    )


@app.get("/global-ecosystem")
def global_ecosystem(request: Request):
    return render_page(request, PAGES_BY_SLUG["global-ecosystem"])


@app.get("/dex-liquidity")
def dex_liquidity(request: Request):
    return render_page(request, PAGES_BY_SLUG["dex-liquidity"])


@app.get("/dex-swaps")
def dex_swaps(request: Request):
    return render_page(request, PAGES_BY_SLUG["dex-swaps"])


@app.get("/kamino")
def kamino(request: Request):
    return render_page(request, PAGES_BY_SLUG["kamino"])


@app.get("/exponent-yield")
def exponent_yield(request: Request):
    return render_page(request, PAGES_BY_SLUG["exponent-yield"])


@app.get("/system-health")
def system_health(request: Request):
    return render_page(request, PAGES_BY_SLUG["system-health"])


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
            _pipeline_cache["value"] = None
            _pipeline_cache["expires_at"] = 0.0
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
            return Response(content=content, media_type=ct, status_code=resp.status)
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
