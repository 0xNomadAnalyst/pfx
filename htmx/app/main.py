import os
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from dotenv import load_dotenv

from app.pages.common import PageConfig, build_widget_endpoint
from app.pages.dex_liquidity import PAGE_CONFIG as DEX_LIQUIDITY_PAGE
from app.pages.dex_swaps import PAGE_CONFIG as DEX_SWAPS_PAGE

PROJECT_ROOT = Path(__file__).resolve().parents[1]
load_dotenv(PROJECT_ROOT / ".env", override=True)
API_BASE_URL = os.getenv("API_BASE_URL", "http://localhost:8001")
APP_TITLE = "DeFi Ecosystem Dashboard"

PAGES: list[PageConfig] = [DEX_LIQUIDITY_PAGE, DEX_SWAPS_PAGE]
PAGES_BY_SLUG: dict[str, PageConfig] = {page.slug: page for page in PAGES}

app = FastAPI(
    title="HTMX Risk Dashboard",
    description="Server-rendered dashboard using HTMX + ECharts.",
    version="0.1.0",
)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
templates = Jinja2Templates(directory="app/templates")


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
    widget_bindings = [
        {
            "id": widget.id,
            "title": widget.title,
            "kind": widget.kind,
            "refresh_interval_seconds": widget.refresh_interval_seconds,
            "endpoint": build_widget_endpoint(API_BASE_URL, page.api_page_id, widget.id),
            "css_class": widget.css_class,
            "expandable": widget.expandable if widget.kind == "chart" else False,
            "load_delay_seconds": index * 0.5,
        }
        for index, widget in enumerate(widgets)
    ]
    page_options = [{"slug": cfg.slug, "label": cfg.label, "path": f"/{cfg.slug}"} for cfg in PAGES]
    return templates.TemplateResponse(
        request=request,
        name="base.html",
        context={
            "app_title": APP_TITLE,
            "page_title": page.label,
            "page_options": page_options,
            "current_page_slug": page.slug,
            "widgets": widget_bindings,
            "show_protocol_pair_filters": page.show_protocol_pair_filters,
            "protocol": page.default_protocol,
            "pair": page.default_pair,
            "last_window": "24h",
            "api_base_url": API_BASE_URL,
        },
    )


@app.get("/dex-liquidity")
def dex_liquidity(request: Request):
    return render_page(request, PAGES_BY_SLUG["dex-liquidity"])


@app.get("/dex-swaps")
def dex_swaps(request: Request):
    return render_page(request, PAGES_BY_SLUG["dex-swaps"])


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8002"))
    uvicorn.run("app.main:app", host="0.0.0.0", port=port, reload=True)
