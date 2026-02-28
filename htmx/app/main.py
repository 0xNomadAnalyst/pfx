import json
import os
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

PROJECT_ROOT = Path(__file__).resolve().parents[1]
load_dotenv(PROJECT_ROOT / ".env", override=False)
API_BASE_URL = os.getenv("API_BASE_URL", "http://localhost:8001")
APP_TITLE = "Solana DeFi Ecosystem Dashboard"

# Keep page registration centralized so the shared header view selector
# is consistent across all routes.
PAGES: list[PageConfig] = [DEX_LIQUIDITY_PAGE, DEX_SWAPS_PAGE, KAMINO_PAGE, EXPONENT_PAGE, HEALTH_PAGE]
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
                "endpoint": build_widget_endpoint(API_BASE_URL, page.api_page_id, widget.id),
                "css_class": widget.css_class,
                "expandable": widget.expandable if widget.kind == "chart" else False,
                "load_delay_seconds": load_delay_seconds,
                "tooltip": widget.tooltip,
                "detail_table_endpoint": build_widget_endpoint(API_BASE_URL, page.api_page_id, widget.detail_table_id) if widget.detail_table_id else "",
            }
        )
    page_options = [{"slug": cfg.slug, "label": cfg.label, "path": f"/{cfg.slug}"} for cfg in PAGES]
    page_action_bindings = [
        {
            "id": action.id,
            "label": action.label,
            "icon": action.icon,
            "modal_kind": action.modal_kind,
            "endpoint": build_widget_endpoint(API_BASE_URL, page.api_page_id, action.endpoint) if action.endpoint else "",
        }
        for action in page.page_actions
    ]
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
            "protocol": page.default_protocol,
            "pair": page.default_pair,
            "last_window": "7d",
            "api_base_url": API_BASE_URL,
        },
    )


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


@app.get("/api/health-status")
def health_status_proxy():
    """Same-origin proxy so the header indicator avoids cross-origin fetch."""
    try:
        req = urllib.request.Request(f"{API_BASE_URL}/api/v1/health-status")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return JSONResponse(content=json.loads(resp.read()))
    except Exception:
        return JSONResponse(content={"is_green": None})


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8002"))
    uvicorn.run("app.main:app", host="0.0.0.0", port=port, reload=True)
