import os
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from dotenv import load_dotenv

# load_dotenv MUST run before any app imports that trigger
# pipeline_config._load_pipelines(), which reads DB_HOST to detect
# the current pipeline.
PROJECT_ROOT = Path(__file__).resolve().parents[1]
load_dotenv(PROJECT_ROOT / ".env")


def _seed_dash_refresh_derived_env() -> None:
    """Derive API pacing defaults from DASH_REFRESH_INTERVAL_SECONDS.

    Explicit API_* env vars remain authoritative and are never overridden.
    """
    raw = os.getenv("DASH_REFRESH_INTERVAL_SECONDS", "").strip()
    if not raw:
        return
    try:
        dash_seconds = max(5.0, min(3600.0, float(raw)))
    except Exception:
        return

    os.environ.setdefault("API_CACHE_TTL_SECONDS", str(dash_seconds))
    os.environ.setdefault("API_CACHE_SWR_SECONDS", str(max(5.0, round(dash_seconds * 0.5, 3))))
    os.environ.setdefault("API_PREWARM_MAX_SECONDS", str(max(15.0, min(120.0, dash_seconds))))
    os.environ.setdefault("HEALTH_STATUS_TTL_SECONDS", str(max(5.0, min(30.0, dash_seconds))))


_seed_dash_refresh_derived_env()

from fastapi import FastAPI  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402
from fastapi.responses import ORJSONResponse  # noqa: E402
from starlette.middleware.gzip import GZipMiddleware  # noqa: E402

from app.api.routes import get_data_service, router  # noqa: E402
from app.services.cache_config import API_CACHE_CONFIG  # noqa: E402
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
    mode = os.getenv("API_CACHE_MODE", "balanced")
    logger.info("API_CACHE_MODE=%s resolved_config=%s", mode, API_CACHE_CONFIG)
    try:
        service.warmup()
    except Exception as exc:  # pragma: no cover - startup best effort
        logger.warning("DataService warmup skipped due to error: %s", exc)
    yield
    service.close()


_cors_raw = os.getenv("CORS_ALLOWED_ORIGINS", "")
_cors_origins = [o.strip() for o in _cors_raw.split(",") if o.strip()] if _cors_raw.strip() else []

app = FastAPI(
    title="Dashboard Widget API",
    description="Frontend-agnostic widget API for the HTMX dashboard.",
    version="0.1.0",
    lifespan=lifespan,
    default_response_class=ORJSONResponse,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
app.add_middleware(GZipMiddleware, minimum_size=1000)
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)
app.include_router(router)


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8001"))
    uvicorn.run("app.main:app", host="0.0.0.0", port=port, reload=True)
