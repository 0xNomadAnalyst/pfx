import os
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from dotenv import load_dotenv

from app.pages.playbook_liquidity import (
    DEFAULT_PAIR,
    DEFAULT_PROTOCOL,
    PAGE_TITLE,
    WIDGETS,
    build_widget_endpoint,
)

PROJECT_ROOT = Path(__file__).resolve().parents[1]
load_dotenv(PROJECT_ROOT / ".env", override=True)
API_BASE_URL = os.getenv("API_BASE_URL", "http://localhost:8001")

app = FastAPI(
    title="HTMX Risk Dashboard",
    description="Server-rendered dashboard using HTMX + ECharts.",
    version="0.1.0",
)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
templates = Jinja2Templates(directory="app/templates")


@app.get("/", include_in_schema=False)
def home() -> RedirectResponse:
    return RedirectResponse(url="/playbook-liquidity")


@app.get("/playbook-liquidity")
def playbook_liquidity(request: Request):
    widget_ids_filter = [item.strip() for item in os.getenv("DASHBOARD_WIDGET_IDS", "").split(",") if item.strip()]
    widgets = [widget for widget in WIDGETS if not widget_ids_filter or widget.id in widget_ids_filter]
    widget_bindings = [
        {
            "id": widget.id,
            "title": widget.title,
            "kind": widget.kind,
            "refresh_interval_seconds": widget.refresh_interval_seconds,
            "endpoint": build_widget_endpoint(API_BASE_URL, widget.id),
            "css_class": widget.css_class,
            "load_delay_seconds": index * 1.2,
        }
        for index, widget in enumerate(widgets)
    ]
    return templates.TemplateResponse(
        request=request,
        name="base.html",
        context={
            "page_title": PAGE_TITLE,
            "widgets": widget_bindings,
            "protocol": DEFAULT_PROTOCOL,
            "pair": DEFAULT_PAIR,
            "last_window": "24h",
            "api_base_url": API_BASE_URL,
        },
    )


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8002"))
    uvicorn.run("app.main:app", host="0.0.0.0", port=port, reload=True)
