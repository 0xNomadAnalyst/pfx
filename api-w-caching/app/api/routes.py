from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from app.api.schemas import WidgetResponse
from app.services.data_service import DataService
from app.services import pipeline_config
from app.services.sql_adapter import SqlAdapter

router = APIRouter()
_service = DataService(SqlAdapter())


def get_data_service() -> DataService:
    return _service


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


# ── Pipeline switcher (dev only, gated by ENABLE_PIPELINE_SWITCHER=1) ────────

class _SwitchRequest(BaseModel):
    pipeline: str

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
def get_meta() -> dict[str, object]:
    try:
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
    risk_liq_scenario: Annotated[str, Query()] = "25",
    risk_stress_collateral: Annotated[str, Query()] = "",
    risk_stress_debt: Annotated[str, Query()] = "",
    svc: DataService = Depends(get_data_service),
) -> WidgetResponse:
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
        "risk_liq_scenario": risk_liq_scenario,
        "risk_stress_collateral": risk_stress_collateral,
        "risk_stress_debt": risk_stress_debt,
    }
    try:
        payload = svc.get_widget_data(page=page, widget_id=widget, params=params)
        return WidgetResponse(**payload)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)[:200]) from exc
    except Exception as exc:  # pragma: no cover - defensive path
        short = str(exc)[:200]
        raise HTTPException(status_code=500, detail=f"Widget query failed: {short}") from exc
