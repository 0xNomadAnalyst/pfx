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

from fastapi import FastAPI  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402
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


app = FastAPI(
    title="Dashboard Widget API",
    description="Frontend-agnostic widget API for the HTMX dashboard.",
    version="0.1.0",
    lifespan=lifespan,
)
app.add_middleware(GZipMiddleware, minimum_size=1000)
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
