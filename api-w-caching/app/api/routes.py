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


@router.get("/api/v1/health-status")
def health_status(svc: DataService = Depends(get_data_service)) -> dict[str, object]:
    """Lightweight master health check consumed by the global header indicator."""
    def _as_bool(val: object) -> bool:
        if isinstance(val, bool):
            return val
        if val is None:
            return False
        if isinstance(val, (int, float)):
            return val != 0
        if isinstance(val, str):
            s = val.strip().lower()
            if s in {"true", "t", "1", "yes", "y", "on"}:
                return True
            if s in {"false", "f", "0", "no", "n", "off", ""}:
                return False
        return bool(val)

    try:
        rows = svc.get_health_master_status()
        if not rows:
            return {"is_green": None}

        master_row = next((r for r in rows if str(r.get("domain", "")).upper() == "MASTER"), None)
        if master_row is not None:
            return {"is_green": not _as_bool(master_row.get("is_red"))}

        # Fallback if upstream view shape changes and MASTER row is absent.
        return {"is_green": not any(_as_bool(r.get("is_red")) for r in rows)}
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
    mkt1: Annotated[str, Query()] = "",
    mkt2: Annotated[str, Query()] = "",
    health_schema: Annotated[str, Query()] = "dexes",
    health_attribute: Annotated[str, Query()] = "Write Rate",
    health_base_schema: Annotated[str, Query()] = "dexes",
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
    }
    try:
        payload = svc.get_widget_data(page=page, widget_id=widget, params=params)
        return WidgetResponse(**payload)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - defensive path
        raise HTTPException(status_code=500, detail=f"Widget query failed: {exc}") from exc
