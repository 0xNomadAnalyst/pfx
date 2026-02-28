from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query

from app.api.schemas import WidgetResponse
from app.services.data_service import DataService
from app.services.sql_adapter import SqlAdapter

router = APIRouter()
_service = DataService(SqlAdapter())


def get_data_service() -> DataService:
    return _service


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/api/v1/widgets")
def list_widgets(page: Annotated[str, Query()] = "playbook-liquidity") -> dict[str, list[str]]:
    return {"widgets": _service.list_widgets(page=page)}


@router.get("/api/v1/meta")
def get_meta() -> dict[str, object]:
    try:
        return _service.get_meta()
    except Exception as exc:  # pragma: no cover - defensive path
        raise HTTPException(status_code=500, detail=f"Meta query failed: {exc}") from exc


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
    }
    try:
        payload = svc.get_widget_data(page=page, widget_id=widget, params=params)
        return WidgetResponse(**payload)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - defensive path
        raise HTTPException(status_code=500, detail=f"Widget query failed: {exc}") from exc
