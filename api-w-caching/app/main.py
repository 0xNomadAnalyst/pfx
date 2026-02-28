from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from fastapi import FastAPI, HTTPException, Request

from app.services.pages.dex_liquidity import DexLiquidityPageService
from app.services.pages.dex_swaps import DexSwapsPageService
from app.services.pages.kamino import KaminoPageService


def _to_int(value: str | None, default: int) -> int:
    if value is None or value == "":
        return default
    try:
        return int(value)
    except ValueError:
        return default


def _request_params(request: Request) -> dict[str, Any]:
    params = dict(request.query_params)
    params["rows"] = _to_int(params.get("rows"), _to_int(params.get("limit"), 20))
    params["page"] = _to_int(params.get("page"), 1)
    return params


app = FastAPI(
    title="Risk Dashboard API",
    description="Widget payload API for HTMX dashboard pages.",
    version="0.1.0",
)

dex_liquidity_service = DexLiquidityPageService()
dex_swaps_service = DexSwapsPageService()
kamino_service = KaminoPageService()

SERVICES_BY_PAGE_ID = {
    dex_liquidity_service.page_id: dex_liquidity_service,
    dex_swaps_service.page_id: dex_swaps_service,
    kamino_service.page_id: kamino_service,
}


@app.get("/api/v1/meta")
def get_meta():
    try:
        data = dex_liquidity_service.get_meta()
        return {"status": "success", "data": data}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.get("/api/v1/pages/{page_id}/widgets/{widget_id}")
def get_widget(page_id: str, widget_id: str, request: Request):
    service = SERVICES_BY_PAGE_ID.get(page_id)
    if service is None:
        raise HTTPException(status_code=404, detail=f"Unknown page id '{page_id}'")

    params = _request_params(request)
    try:
        payload = service.get_widget_payload(widget_id, params)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    return {
        "status": "success",
        "data": payload,
        "metadata": {
            "page_id": page_id,
            "widget_id": widget_id,
            "generated_at": datetime.now(UTC).isoformat(),
        },
    }


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
import os
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv

from app.api.routes import get_data_service, router

PROJECT_ROOT = Path(__file__).resolve().parents[1]
load_dotenv(PROJECT_ROOT / ".env")
logger = logging.getLogger(__name__)


def _validate_env() -> None:
    required = ["DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"]
    missing = [key for key in required if not os.getenv(key)]
    if missing:
        joined = ", ".join(missing)
        raise RuntimeError(f"Missing required environment variables: {joined}")


@asynccontextmanager
async def lifespan(_: FastAPI):
    _validate_env()
    service = get_data_service()
    try:
        service.warmup()
    except Exception as exc:  # pragma: no cover - startup best effort
        logger.warning("DataService warmup skipped due to error: %s", exc)
    yield
    service.close()


app = FastAPI(
    title="Dashboard Widget API",
    description="Frontend-agnostic widget API for the HTMX dashboard.",
    version="0.1.0",
    lifespan=lifespan,
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(router)


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8001"))
    uvicorn.run("app.main:app", host="0.0.0.0", port=port, reload=True)
