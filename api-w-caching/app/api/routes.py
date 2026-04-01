from __future__ import annotations

import os
import threading
from typing import Annotated

import logging

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import ORJSONResponse
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

from app.services.cache_config import API_CACHE_CONFIG
from app.services.data_service import DataService
from app.services import pipeline_config
from app.services.sql_adapter import SqlAdapter

router = APIRouter()
_service = DataService(SqlAdapter())
_pipeline_switch_lock = threading.Lock()

_raw_stats = os.getenv("API_CACHE_STATS_ENABLED")
_CACHE_STATS_ENABLED = (_raw_stats == "1") if _raw_stats is not None else bool(API_CACHE_CONFIG.get("API_CACHE_STATS_ENABLED", False))
_TELEMETRY_ENABLED = os.getenv("API_TELEMETRY_ENABLED", "0") == "1"


def get_data_service() -> DataService:
    return _service


def _ensure_pipeline_for_request(requested: str) -> None:
    """Best-effort guard: make API serve from requested pipeline when provided.

    This prevents UI state and API process state from drifting after refresh/nav.
    """
    requested_id = (requested or "").strip()
    if not requested_id or not pipeline_config.is_enabled():
        return
    if pipeline_config.get_current() == requested_id:
        return
    with _pipeline_switch_lock:
        if pipeline_config.get_current() == requested_id:
            return
        if not pipeline_config.switch_to(requested_id):
            raise HTTPException(status_code=400, detail=f"Unknown pipeline '{requested_id}'")
        _service.sql.reset_pool()
        _service.flush_caches()


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/api/v1/cache-stats")
def cache_stats(svc: DataService = Depends(get_data_service)) -> dict[str, object]:
    if not _CACHE_STATS_ENABLED:
        raise HTTPException(status_code=404, detail="Cache stats endpoint is disabled")
    return svc.get_cache_stats()


@router.get("/api/v1/telemetry")
def telemetry(svc: DataService = Depends(get_data_service)) -> dict[str, object]:
    if not _TELEMETRY_ENABLED:
        raise HTTPException(status_code=404, detail="Telemetry endpoint is disabled")
    return svc.get_telemetry_snapshot()


@router.post("/api/v1/telemetry/reset")
def telemetry_reset(svc: DataService = Depends(get_data_service)) -> dict[str, object]:
    if not _TELEMETRY_ENABLED:
        raise HTTPException(status_code=404, detail="Telemetry endpoint is disabled")
    return {"status": "ok", "telemetry": svc.reset_telemetry()}


# ── Pipeline switcher (dev only, gated by ENABLE_PIPELINE_SWITCHER=1) ────────

class _SwitchRequest(BaseModel):
    pipeline: str


class _WarmupRequest(BaseModel):
    targets: list[dict[str, object]] = []
    base_params: dict[str, object] = {}
    budget_seconds: float = Field(30.0, ge=1, le=60)
    max_jobs: int = Field(20, ge=1, le=40)
    concurrency: int = Field(3, ge=1, le=6)
    include_payloads: bool = False
    max_payload_bytes: int = Field(2_000_000, ge=1, le=5_000_000)
    max_payload_count: int = Field(20, ge=1, le=50)

@router.get("/api/v1/pipeline")
def get_pipeline() -> dict[str, object]:
    if not pipeline_config.is_enabled():
        raise HTTPException(status_code=404, detail="Pipeline switcher is disabled")
    return {
        "current": pipeline_config.get_current(),
        "available": pipeline_config.get_available(),
        "defaults": pipeline_config.get_defaults(),
    }

@router.post("/api/v1/pipeline")
def switch_pipeline(body: _SwitchRequest) -> dict[str, object]:
    if not pipeline_config.is_enabled():
        raise HTTPException(status_code=404, detail="Pipeline switcher is disabled")
    if not pipeline_config.switch_to(body.pipeline):
        raise HTTPException(status_code=400, detail=f"Unknown pipeline '{body.pipeline}'")
    _service.sql.reset_pool()
    _service.flush_caches()
    return {
        "status": "switched",
        "current": pipeline_config.get_current(),
        "defaults": pipeline_config.get_defaults(),
    }


@router.get("/api/v1/health-status")
def health_status(svc: DataService = Depends(get_data_service)) -> dict[str, object]:
    """Lightweight master health check consumed by the global header indicator."""
    try:
        # Prioritize dashboard widget/page traffic over header polling by avoiding
        # blocking waits when a refresh is already in flight.
        status = svc.get_health_indicator_status(
            non_blocking=True,
            allow_stale_on_lock_contention=True,
        )
        return {"is_green": status}
    except Exception:
        return {"is_green": None}


@router.get("/api/v1/widgets")
def list_widgets(page: Annotated[str, Query()] = "playbook-liquidity") -> dict[str, list[str]]:
    return {"widgets": _service.list_widgets(page=page)}


@router.get("/api/v1/meta")
def get_meta(
    _pipeline: Annotated[str, Query(alias="_pipeline")] = "",
) -> dict[str, object]:
    try:
        _ensure_pipeline_for_request(_pipeline)
        return _service.get_meta()
    except Exception as exc:  # pragma: no cover - defensive path
        logger.error("Meta query failed: %s", exc)
        raise HTTPException(status_code=500, detail="Meta query failed") from exc


@router.get("/api/v1/{page}/{widget}")
@router.get("/api/v1/pages/{page}/widgets/{widget}")
def get_widget(
    request: Request,
    page: str,
    widget: str,
    protocol: Annotated[str, Query()] = "raydium",
    pair: Annotated[str, Query()] = "USX-USDC",
    last_window: Annotated[str, Query()] = "24h",
    lookback: Annotated[str, Query()] = "1 day",
    interval: Annotated[str, Query()] = "5 minutes",
    rows: Annotated[int, Query(ge=1, le=500)] = 120,
    tick_delta_time: Annotated[str, Query()] = "1 hour",
    impact_mode: Annotated[str, Query()] = "size",
    flow_mode: Annotated[str, Query()] = "usx",
    distribution_mode: Annotated[str, Query()] = "sell-order",
    ohlcv_interval: Annotated[str, Query()] = "1d",
    ohlcv_rows: Annotated[int, Query(ge=1, le=1000)] = 180,
    mkt1: Annotated[str, Query()] = "",
    mkt2: Annotated[str, Query()] = "",
    health_schema: Annotated[str, Query()] = "dexes",
    health_attribute: Annotated[str, Query()] = "Write Rate",
    health_base_schema: Annotated[str, Query()] = "dexes",
    risk_event_type: Annotated[str, Query()] = "Single Swaps",
    risk_interval: Annotated[str, Query()] = "5 minutes",
    risk_liq_source: Annotated[str, Query()] = "all",
    risk_stress_collateral: Annotated[str, Query()] = "",
    risk_stress_debt: Annotated[str, Query()] = "",
    risk_cascade_pool: Annotated[str, Query()] = "weighted",
    risk_cascade_model_mode: Annotated[str, Query()] = "protocol",
    risk_cascade_bonus_mode: Annotated[str, Query()] = "blended",
    price_basis: Annotated[str, Query()] = "default",
    _pipeline: Annotated[str, Query(alias="_pipeline")] = "",
    svc: DataService = Depends(get_data_service),
) -> ORJSONResponse:
    _ensure_pipeline_for_request(_pipeline)
    params = {
        "protocol": protocol,
        "pair": pair,
        "last_window": last_window,
        "lookback": lookback,
        "interval": interval,
        "rows": rows,
        "tick_delta_time": tick_delta_time,
        "impact_mode": impact_mode,
        "flow_mode": flow_mode,
        "distribution_mode": distribution_mode,
        "ohlcv_interval": ohlcv_interval,
        "ohlcv_rows": ohlcv_rows,
        "mkt1": mkt1,
        "mkt2": mkt2,
        "health_schema": health_schema,
        "health_attribute": health_attribute,
        "health_base_schema": health_base_schema,
        "risk_event_type": risk_event_type,
        "risk_interval": risk_interval,
        "risk_liq_source": risk_liq_source,
        "risk_stress_collateral": risk_stress_collateral,
        "risk_stress_debt": risk_stress_debt,
        "risk_cascade_pool": risk_cascade_pool,
        "risk_cascade_model_mode": risk_cascade_model_mode,
        "risk_cascade_bonus_mode": risk_cascade_bonus_mode,
        "price_basis": price_basis,
        "_pipeline": _pipeline,
    }
    try:
        trace_ctx = {
            "nav_trace_id": request.headers.get("X-Riskdash-Nav-Trace", ""),
            "request_id": request.headers.get("X-Riskdash-Request-Id", ""),
            "widget_id": request.headers.get("X-Riskdash-Widget-Id", ""),
            "current_path": request.headers.get("X-Riskdash-Current-Path", ""),
        }
        payload = svc.get_widget_data(page=page, widget_id=widget, params=params, trace_ctx=trace_ctx)
        return ORJSONResponse(content=payload)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="Widget not found") from exc
    except Exception as exc:
        logger.error("Widget query failed page=%s widget=%s: %s", page, widget, exc)
        raise HTTPException(status_code=500, detail="Widget query failed") from exc


@router.post("/api/v1/warmup")
def warmup_targets(body: _WarmupRequest, svc: DataService = Depends(get_data_service)) -> dict[str, object]:
    try:
        result = svc.warmup_targets(
            targets=body.targets,
            base_params=body.base_params,
            budget_seconds=body.budget_seconds,
            max_jobs=body.max_jobs,
            concurrency=body.concurrency,
            include_payloads=body.include_payloads,
            max_payload_bytes=body.max_payload_bytes,
            max_payload_count=body.max_payload_count,
        )
        return {"status": "ok", **result}
    except Exception as exc:
        logger.error("Warmup failed: %s", exc)
        raise HTTPException(status_code=500, detail="Warmup failed") from exc
