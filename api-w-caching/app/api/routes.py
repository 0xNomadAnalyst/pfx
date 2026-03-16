from __future__ import annotations

import threading
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from app.api.schemas import WidgetResponse
from app.services.data_service import DataService
from app.services import pipeline_config
from app.services.sql_adapter import SqlAdapter

router = APIRouter()
_service = DataService(SqlAdapter())
_pipeline_switch_lock = threading.Lock()


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


# ── Pipeline switcher (dev only, gated by ENABLE_PIPELINE_SWITCHER=1) ────────

class _SwitchRequest(BaseModel):
    pipeline: str


class _WarmupRequest(BaseModel):
    targets: list[dict[str, object]] = []
    base_params: dict[str, object] = {}
    budget_seconds: float = 30.0
    max_jobs: int = 20
    concurrency: int = 3

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
        raise HTTPException(status_code=500, detail=f"Meta query failed: {str(exc)[:200]}") from exc


@router.get("/api/v1/{page}/{widget}", response_model=WidgetResponse)
@router.get("/api/v1/pages/{page}/widgets/{widget}", response_model=WidgetResponse)
def get_widget(
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
) -> WidgetResponse:
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
        payload = svc.get_widget_data(page=page, widget_id=widget, params=params)
        return WidgetResponse(**payload)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)[:200]) from exc
    except Exception as exc:  # pragma: no cover - defensive path
        short = str(exc)[:200]
        raise HTTPException(status_code=500, detail=f"Widget query failed: {short}") from exc


@router.post("/api/v1/warmup")
def warmup_targets(body: _WarmupRequest, svc: DataService = Depends(get_data_service)) -> dict[str, object]:
    try:
        stats = svc.warmup_targets(
            targets=body.targets,
            base_params=body.base_params,
            budget_seconds=body.budget_seconds,
            max_jobs=body.max_jobs,
            concurrency=body.concurrency,
        )
        return {"status": "ok", "stats": stats}
    except Exception as exc:
        short = str(exc)[:200]
        raise HTTPException(status_code=500, detail=f"Warmup failed: {short}") from exc
