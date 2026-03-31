import asyncio
import importlib
import json
import os
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    import httpx
except ModuleNotFoundError:
    httpx = None  # type: ignore[assignment]
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.gzip import GZipMiddleware
from dotenv import load_dotenv

from app.pages.common import PageConfig, build_widget_endpoint
from app.shared_families import has_intentional_shared_family_mapping, resolve_shared_data_family

# ── Load env BEFORE page imports so PAGE_* flags are available ───────
PROJECT_ROOT = Path(__file__).resolve().parents[1]
load_dotenv(PROJECT_ROOT / ".env", override=False)

# Internal address used for server-side proxy calls (health, pipeline, etc.)
API_BASE_URL = os.getenv("API_BASE_URL", "http://localhost:8001")
# Base URL embedded in page HTML for browser HTMX widget fetches.
# Defaults to "" (relative URLs) so the browser calls the UI host, which
# proxies to the internal API.  Override only if the API is publicly exposed.
#
# Proxy bypass evaluation (2026-03):
#   Setting BROWSER_API_BASE_URL to the API server directly (e.g.
#   "http://localhost:8001" for local dev) eliminates the UI proxy hop and
#   saves ~5-15ms per widget request.  Requirements for production use:
#     1. API port must be reachable from the browser (currently only port 8002
#        is exposed in the Railway/Docker deployment).
#     2. CORS_ALLOWED_ORIGINS on the API must include the UI origin.
#     3. The pipeline switch POST would need a CORS-safe path on the API.
#   For local development, set both env vars:
#     BROWSER_API_BASE_URL=http://localhost:8001
#     CORS_ALLOWED_ORIGINS=http://localhost:8002
BROWSER_API_BASE_URL = os.getenv("BROWSER_API_BASE_URL", "")
APP_TITLE = "Solana DeFi Ecosystem Dashboard"
ENABLE_PIPELINE_SWITCHER = os.getenv("ENABLE_PIPELINE_SWITCHER", "0") == "1"
DEFAULT_PIPELINE = os.getenv("DEFAULT_PIPELINE", "")
SHOW_PRICE_BASIS = os.getenv("SHOW_PRICE_BASIS", "1") == "1"
DEFAULT_PRICE_BASIS = os.getenv("DEFAULT_PRICE_BASIS", "default")
SHOW_ASSET_FILTER = os.getenv("SHOW_ASSET_FILTER", "1") == "1"
SHOW_REFRESH_BUTTON = os.getenv("SHOW_REFRESH_BUTTON", "1") == "1"
NAV_LAYOUT_SIDEBAR = os.getenv("NAV_LAYOUT_SIDEBAR", "0") == "1"
SHARED_FAMILY_STRICT_INTENT = os.getenv("HTMX_SHARED_FAMILY_STRICT_INTENT", "0") == "1"
SHARED_FAMILY_WARN_INTENT = os.getenv("HTMX_SHARED_FAMILY_WARN_INTENT", "0") == "1"

ALL_LAST_WINDOW_OPTIONS = ["1h", "4h", "6h", "24h", "7d", "30d", "90d"]
_lw_raw = os.getenv("LAST_WINDOW_OPTIONS", "")
LAST_WINDOW_OPTIONS: list[str] = (
    [v.strip() for v in _lw_raw.split(",") if v.strip() in ALL_LAST_WINDOW_OPTIONS]
    if _lw_raw.strip()
    else list(ALL_LAST_WINDOW_OPTIONS)
)
DEFAULT_LAST_WINDOW = os.getenv("DEFAULT_LAST_WINDOW", "7d")
if DEFAULT_LAST_WINDOW not in LAST_WINDOW_OPTIONS:
    DEFAULT_LAST_WINDOW = LAST_WINDOW_OPTIONS[0]
# Root URL `/` redirects here (must match an enabled page slug, e.g. app.pages.global).
DEFAULT_HOME_PAGE_SLUG = os.getenv("DEFAULT_HOME_PAGE_SLUG", "global-ecosystem")
PIPELINE_DEFAULTS: dict[str, dict[str, str]] = {
    "solstice": {"protocol": "raydium", "pair": "USX-USDC", "asset": "USX"},
    "onyc":     {"protocol": "orca",    "pair": "ONyc-USDC", "asset": "ONyc"},
}
# ── Server-side proxy settings (not part of cache mode) ──────────────
HEALTH_PROXY_TIMEOUT_SECONDS = float(os.getenv("HTMX_HEALTH_STATUS_TIMEOUT_SECONDS", "3"))
HEALTH_PROXY_TTL_SECONDS = float(os.getenv("HTMX_HEALTH_STATUS_CACHE_TTL_SECONDS", "5"))
META_PROXY_TTL_SECONDS = float(os.getenv("HTMX_META_CACHE_TTL_SECONDS", "300"))
HTMX_HEALTH_TABLE_BASE_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_TABLE_BASE_DELAY_SECONDS", "0.08"))
HTMX_HEALTH_TABLE_STEP_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_TABLE_STEP_DELAY_SECONDS", "0.12"))
HTMX_HEALTH_CHART_BASE_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_CHART_BASE_DELAY_SECONDS", "0.35"))
HTMX_HEALTH_CHART_STEP_DELAY_SECONDS = float(os.getenv("HTMX_HEALTH_CHART_STEP_DELAY_SECONDS", "0.18"))
HTMX_KPI_STEP_DELAY_SECONDS = float(os.getenv("HTMX_KPI_STEP_DELAY_SECONDS", "0.05"))
HTMX_CHART_BASE_DELAY_SECONDS = float(os.getenv("HTMX_CHART_BASE_DELAY_SECONDS", "0.3"))
HTMX_CHART_STEP_DELAY_SECONDS = float(os.getenv("HTMX_CHART_STEP_DELAY_SECONDS", "0.15"))

# ── Cache mode profiles ──────────────────────────────────────────────
# conservative = freshness-first, no speculation (frequent refresh, no preload)
# balanced     = default optimization profile (navigation-first)
# aggressive   = speed-first, accept staleness (all new features enabled)
#
# HTMX_CACHE_MODE selects a profile.  Individual HTMX_* env vars override
# any key from the profile.  refresh_kpi_seconds=0 means "use widget default".

CACHE_PROFILES: dict[str, dict] = {
    "conservative": {
        "warmup_enabled": False,
        "warmup_budget_seconds": 30,
        "warmup_max_jobs": 20,
        "warmup_concurrency": 3,
        "warmup_widgets_per_page": 8,
        "warmup_return_payloads": False,
        "critical_cache_max_age_ms": 15_000,
        "default_cache_max_age_ms": 30_000,
        "soft_nav_shell_refresh_delay_ms": 500,
        "soft_nav_shell_cache_ttl_ms": 60_000,
        "viewport_poll_stale_ms": 15_000,
        "refresh_kpi_seconds": 15,
        "refresh_chart_seconds": 30,
        "refresh_table_seconds": 45,
        "widget_response_cache_max_entries": 50,
        "widget_response_cache_per_widget_limit": 6,
        "soft_nav_shell_cache_max_entries": 3,
        "persist_cache_max_bytes": 1_572_864,
        "persist_cache_max_entries": 180,
        "persist_cache_widget_max_entries": 140,
        "perf_metrics_enabled": False,
        "hover_prefetch_enabled": False,
        "parallel_shell_prefetch": False,
        "shell_prefetch_concurrency": 1,
        "rewarmup_on_filter_change": False,
        "rewarmup_idle_delay_ms": 0,
        "batched_reveal_enabled": False,
        "batched_reveal_timeout_ms": 0,
        "unified_reveal_coordinator_enabled": False,
        "max_concurrent_widget_requests": 3,
        "offscreen_pause_enabled": False,
        "skeleton_min_display_ms": 0,
        "adaptive_dialdown_enabled": False,
        "adaptive_dialdown_hit_threshold": 0,
        "persist_cache_enabled": False,
    },
    "balanced": {
        "warmup_enabled": False,
        "warmup_budget_seconds": 30,
        "warmup_max_jobs": 30,
        "warmup_concurrency": 3,
        "warmup_widgets_per_page": 10,
        "warmup_return_payloads": True,
        "critical_cache_max_age_ms": 60_000,
        "default_cache_max_age_ms": 300_000,
        "soft_nav_shell_refresh_delay_ms": 3_000,
        "soft_nav_shell_cache_ttl_ms": 3_600_000,
        "viewport_poll_stale_ms": 45_000,
        "refresh_kpi_seconds": 0,
        "refresh_chart_seconds": 60,
        "refresh_table_seconds": 90,
        "widget_response_cache_max_entries": 100,
        "widget_response_cache_per_widget_limit": 8,
        "soft_nav_shell_cache_max_entries": 5,
        "persist_cache_max_bytes": 2_097_152,
        "persist_cache_max_entries": 220,
        "persist_cache_widget_max_entries": 180,
        "perf_metrics_enabled": False,
        "hover_prefetch_enabled": False,
        "parallel_shell_prefetch": False,
        "shell_prefetch_concurrency": 1,
        "rewarmup_on_filter_change": False,
        "rewarmup_idle_delay_ms": 0,
        "batched_reveal_enabled": False,
        "batched_reveal_timeout_ms": 0,
        "unified_reveal_coordinator_enabled": False,
        # Keep balanced mode from flooding the API/DB pool on wide pages.
        # Unlimited bursts can create long queueing tails where related widgets
        # do not settle together even when they share underlying data.
        "max_concurrent_widget_requests": 4,
        "offscreen_pause_enabled": False,
        "skeleton_min_display_ms": 0,
        "adaptive_dialdown_enabled": False,
        "adaptive_dialdown_hit_threshold": 0,
        "persist_cache_enabled": True,
    },
    "aggressive": {
        "warmup_enabled": True,
        "warmup_budget_seconds": 60,
        "warmup_max_jobs": 40,
        "warmup_concurrency": 5,
        "warmup_widgets_per_page": 14,
        "warmup_return_payloads": True,
        "critical_cache_max_age_ms": 120_000,
        "default_cache_max_age_ms": 600_000,
        "soft_nav_shell_refresh_delay_ms": 5_000,
        "soft_nav_shell_cache_ttl_ms": 1_200_000,
        "viewport_poll_stale_ms": 90_000,
        "refresh_kpi_seconds": 90,
        "refresh_chart_seconds": 120,
        "refresh_table_seconds": 120,
        "widget_response_cache_max_entries": 200,
        "widget_response_cache_per_widget_limit": 12,
        "soft_nav_shell_cache_max_entries": 8,
        "persist_cache_max_bytes": 3_145_728,
        "persist_cache_max_entries": 360,
        "persist_cache_widget_max_entries": 300,
        "perf_metrics_enabled": True,
        "hover_prefetch_enabled": True,
        "parallel_shell_prefetch": True,
        "shell_prefetch_concurrency": 3,
        "rewarmup_on_filter_change": True,
        "rewarmup_idle_delay_ms": 3_000,
        "batched_reveal_enabled": True,
        "batched_reveal_timeout_ms": 400,
        "unified_reveal_coordinator_enabled": False,
        "max_concurrent_widget_requests": 5,
        "offscreen_pause_enabled": True,
        "skeleton_min_display_ms": 150,
        "adaptive_dialdown_enabled": True,
        "adaptive_dialdown_hit_threshold": 0.2,
        "persist_cache_enabled": True,
    },
}

_CACHE_ENV_MAP: dict[str, tuple[str, type]] = {
    "warmup_enabled": ("HTMX_WARMUP_ENABLED", bool),
    "warmup_budget_seconds": ("HTMX_WARMUP_BUDGET_SECONDS", int),
    "warmup_max_jobs": ("HTMX_WARMUP_MAX_JOBS", int),
    "warmup_concurrency": ("HTMX_WARMUP_CONCURRENCY", int),
    "warmup_widgets_per_page": ("HTMX_WARMUP_WIDGETS_PER_PAGE", int),
    "warmup_return_payloads": ("HTMX_WARMUP_RETURN_PAYLOADS", bool),
    "critical_cache_max_age_ms": ("HTMX_CRITICAL_CACHE_MAX_AGE_MS", int),
    "default_cache_max_age_ms": ("HTMX_DEFAULT_CACHE_MAX_AGE_MS", int),
    "soft_nav_shell_refresh_delay_ms": ("HTMX_SOFT_NAV_SHELL_REFRESH_DELAY_MS", int),
    "soft_nav_shell_cache_ttl_ms": ("HTMX_SOFT_NAV_SHELL_CACHE_TTL_MS", int),
    "viewport_poll_stale_ms": ("HTMX_VIEWPORT_POLL_STALE_MS", int),
    "refresh_kpi_seconds": ("HTMX_REFRESH_KPI_SECONDS", int),
    "refresh_chart_seconds": ("HTMX_REFRESH_CHART_SECONDS", int),
    "refresh_table_seconds": ("HTMX_REFRESH_TABLE_SECONDS", int),
    "widget_response_cache_max_entries": ("HTMX_WIDGET_RESPONSE_CACHE_MAX_ENTRIES", int),
    "widget_response_cache_per_widget_limit": ("HTMX_WIDGET_RESPONSE_CACHE_PER_WIDGET_LIMIT", int),
    "soft_nav_shell_cache_max_entries": ("HTMX_SOFT_NAV_SHELL_CACHE_MAX_ENTRIES", int),
    "persist_cache_max_bytes": ("HTMX_PERSIST_CACHE_MAX_BYTES", int),
    "persist_cache_max_entries": ("HTMX_PERSIST_CACHE_MAX_ENTRIES", int),
    "persist_cache_widget_max_entries": ("HTMX_PERSIST_CACHE_WIDGET_MAX_ENTRIES", int),
    "perf_metrics_enabled": ("HTMX_CLIENT_PERF_METRICS", bool),
    "hover_prefetch_enabled": ("HTMX_HOVER_PREFETCH_ENABLED", bool),
    "parallel_shell_prefetch": ("HTMX_PARALLEL_SHELL_PREFETCH", bool),
    "shell_prefetch_concurrency": ("HTMX_SHELL_PREFETCH_CONCURRENCY", int),
    "rewarmup_on_filter_change": ("HTMX_REWARMUP_ON_FILTER_CHANGE", bool),
    "rewarmup_idle_delay_ms": ("HTMX_REWARMUP_IDLE_DELAY_MS", int),
    "batched_reveal_enabled": ("HTMX_BATCHED_REVEAL_ENABLED", bool),
    "batched_reveal_timeout_ms": ("HTMX_BATCHED_REVEAL_TIMEOUT_MS", int),
    "unified_reveal_coordinator_enabled": ("HTMX_UNIFIED_REVEAL_COORDINATOR_ENABLED", bool),
    "max_concurrent_widget_requests": ("HTMX_MAX_CONCURRENT_WIDGET_REQUESTS", int),
    "offscreen_pause_enabled": ("HTMX_OFFSCREEN_PAUSE_ENABLED", bool),
    "skeleton_min_display_ms": ("HTMX_SKELETON_MIN_DISPLAY_MS", int),
    "adaptive_dialdown_enabled": ("HTMX_ADAPTIVE_DIALDOWN_ENABLED", bool),
    "adaptive_dialdown_hit_threshold": ("HTMX_ADAPTIVE_DIALDOWN_HIT_THRESHOLD", float),
    "persist_cache_enabled": ("HTMX_PERSIST_CACHE_ENABLED", bool),
}


def _parse_env_bool(raw: str) -> bool:
    return str(raw).strip().lower() in ("1", "true", "yes", "on")


def _read_dash_refresh_interval_seconds(default: int = 30) -> int:
    raw = os.getenv("DASH_REFRESH_INTERVAL_SECONDS")
    if raw is None:
        return default
    try:
        parsed = int(float(raw.strip()))
    except Exception:
        return default
    return max(5, min(3600, parsed))


def resolve_cache_config() -> dict:
    """Resolve cache config: mode profile as baseline, explicit env vars override."""
    mode = os.getenv("HTMX_CACHE_MODE", "balanced").lower().strip()
    profile = CACHE_PROFILES.get(mode, CACHE_PROFILES["balanced"]).copy()
    dash_refresh_seconds = _read_dash_refresh_interval_seconds()

    # Unified refresh cadence baseline. Explicit HTMX_REFRESH_* overrides
    # below still take precedence when set.
    profile["refresh_kpi_seconds"] = dash_refresh_seconds
    profile["refresh_chart_seconds"] = dash_refresh_seconds
    profile["refresh_table_seconds"] = dash_refresh_seconds
    profile["dash_refresh_interval_seconds"] = dash_refresh_seconds

    for key, (env_name, converter) in _CACHE_ENV_MAP.items():
        if env_name not in os.environ:
            continue
        raw = os.environ[env_name]
        if converter is bool:
            profile[key] = _parse_env_bool(raw)
        elif converter is float:
            profile[key] = float(raw)
        else:
            profile[key] = converter(raw)
    profile["cache_mode"] = mode
    return profile


_CACHE_CONFIG = resolve_cache_config()
_health_proxy_lock = threading.Lock()
_health_proxy_cache: dict[str, object] = {"value": None, "expires_at": 0.0}
_meta_proxy_lock = threading.Lock()
_meta_proxy_cache: dict[str, tuple[float, dict]] = {}

# ── Conditional page loading ────────────────────────────────────────
# Each entry: (PAGE_* env var, python module path, default "1"=on / "0"=off)
# When a page is OFF its module is never imported — zero resources allocated.
_PAGE_MODULES: list[tuple[str, str, str]] = [
    ("PAGE_COVER",            "app.pages.cover",                   "0"),
    ("PAGE_GLOBAL_ECOSYSTEM", "app.pages.global",                   "1"),
    ("PAGE_GLOBAL_SOLSTICE",  "app.pages.global_solstice_version", "0"),
    ("PAGE_DEX_LIQUIDITY",    "app.pages.dex_liquidity",           "0"),
    ("PAGE_DEX_SWAPS",        "app.pages.dex_swaps",               "0"),
    ("PAGE_DEXES",            "app.pages.dexes",                   "1"),
    ("PAGE_KAMINO",           "app.pages.kamino",                  "1"),
    ("PAGE_EXPONENT_YIELD",   "app.pages.exponent",                "1"),
    ("PAGE_RISK_ANALYSIS",    "app.pages.risk_analysis",           "1"),
    ("PAGE_SYSTEM_HEALTH",    "app.pages.health",                  "1"),
]

PAGES: list[PageConfig] = []

for _env_key, _mod_path, _default in _PAGE_MODULES:
    if os.getenv(_env_key, _default) == "1":
        try:
            _mod = importlib.import_module(_mod_path)
        except ModuleNotFoundError as exc:
            # Allow optional pages to be toggled on in env without hard-failing
            # startup when their module file is not present in this checkout.
            if exc.name == _mod_path:
                print(f"[WARN] Skipping missing page module: {_mod_path}")
                continue
            raise
        PAGES.append(_mod.PAGE_CONFIG)

PAGES_BY_SLUG: dict[str, PageConfig] = {page.slug: page for page in PAGES}
DEFAULT_COVER_VIDEO_GUIDE_ID = "0wgPh78PwAs"
COVER_VIDEO_GUIDE_ID = (
    PAGES_BY_SLUG["cover"].video_guide_youtube_id
    if "cover" in PAGES_BY_SLUG
    else DEFAULT_COVER_VIDEO_GUIDE_ID
)
MIN_SUPPORTED_VIEWPORT_WIDTH = 882

# Ensure shell cache can hold all page shells (they are embedded in the initial HTML).
if _CACHE_CONFIG["soft_nav_shell_cache_max_entries"] < len(PAGES):
    _CACHE_CONFIG["soft_nav_shell_cache_max_entries"] = len(PAGES)

app = FastAPI(
    title="HTMX Risk Dashboard",
    description="Server-rendered dashboard using HTMX + ECharts.",
    version="0.1.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
app.add_middleware(GZipMiddleware, minimum_size=1000)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
templates = Jinja2Templates(directory="app/templates")


@app.on_event("startup")
def _apply_default_pipeline():
    """If DEFAULT_PIPELINE is set, tell the API server to switch on boot."""
    if DEFAULT_PIPELINE:
        try:
            body = json.dumps({"pipeline": DEFAULT_PIPELINE}).encode()
            req = urllib.request.Request(
                f"{API_BASE_URL}/api/v1/pipeline",
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                payload = json.loads(resp.read())
                _pipeline_cache["value"] = payload
                _pipeline_cache["expires_at"] = time.time() + 5.0
        except Exception:
            pass
    _validate_shared_family_mapping_intent()


def _validate_shared_family_mapping_intent() -> None:
    ignored_kinds = {"section-header", "section-subheader", "placeholder"}
    missing: list[tuple[str, str, str]] = []
    for page in PAGES:
        endpoint_page_id = page.api_page_id
        for widget in page.widgets:
            if widget.kind in ignored_kinds:
                continue
            source_page_id = widget.source_page_id or endpoint_page_id
            source_widget_id = widget.source_widget_id or widget.id
            if not has_intentional_shared_family_mapping(source_page_id, source_widget_id):
                missing.append((page.slug, source_page_id, source_widget_id))
    if not missing:
        return
    unique_missing = sorted(set(missing))
    sample = ", ".join(
        f"{slug}:{page_id}/{wid}" for slug, page_id, wid in unique_missing[:8]
    )
    message = (
        "[WARN] Shared-family intent missing for "
        f"{len(unique_missing)} widget endpoints. "
        "Add entries to SHARED_DATA_FAMILY_HINTS or EXPLICIT_NO_SHARED_FAMILY_HINTS. "
        f"Examples: {sample}"
    )
    if SHARED_FAMILY_WARN_INTENT or SHARED_FAMILY_STRICT_INTENT:
        print(message)
    if SHARED_FAMILY_STRICT_INTENT:
        raise RuntimeError(message)


@app.middleware("http")
async def add_no_cache_html(request: Request, call_next):
    response = await call_next(request)
    ct = response.headers.get("content-type", "")
    if "text/html" in ct:
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
        response.headers["Pragma"] = "no-cache"
    return response


@app.get("/favicon.ico", include_in_schema=False)
def favicon():
    return Response(status_code=204)


@app.get("/", include_in_schema=False)
def home() -> RedirectResponse:
    slug = DEFAULT_HOME_PAGE_SLUG
    if slug not in PAGES_BY_SLUG:
        slug = PAGES[0].slug
    return RedirectResponse(url=f"/{slug}")


if "dex-liquidity" in PAGES_BY_SLUG:
    @app.get("/playbook-liquidity", include_in_schema=False)
    def legacy_playbook_liquidity() -> RedirectResponse:
        return RedirectResponse(url="/dex-liquidity")


def _build_page_context(
    page: PageConfig,
    page_options: list,
    current_pipeline: str,
    pipeline_info: dict | None,
    request_mobile: bool = False,
) -> dict:
    """Build template context for a page (shared between full render and shell embeds)."""

    def _is_secondary_lane(widget: object) -> bool:
        css = str(getattr(widget, "css_class", "") or "").lower()
        wid = str(getattr(widget, "id", "") or "").lower()
        proto = str(getattr(widget, "protocol_override", "") or "").lower()
        return (
            "dx-ray-" in css
            or "mkt2" in css
            or "-right" in css
            or wid.endswith("-mkt2")
            or wid.endswith("-ray")
            or "-ray-" in wid
            or proto in {"ray", "mkt2", "mkt2-sy"}
        )

    def _lane_group_key(widget: object) -> str:
        css = str(getattr(widget, "css_class", "") or "")
        tokens = [tok for tok in css.split() if tok]
        normalized: list[str] = []
        for tok in tokens:
            key = tok
            key = key.replace("dx-ray-", "dx-orca-")
            key = key.replace("-ray-", "-orca-")
            if key.endswith("-ray"):
                key = f"{key[:-4]}-orca"
            key = key.replace("mkt2", "mkt1")
            key = key.replace("right", "left")
            normalized.append(key)
        normalized.sort()
        return f"{getattr(widget, 'kind', '')}|{' '.join(normalized)}"

    widget_ids_filter = []
    if page.widget_filter_env_var:
        widget_ids_filter = [item.strip() for item in os.getenv(page.widget_filter_env_var, "").split(",") if item.strip()]

    widgets = [widget for widget in page.widgets if not widget_ids_filter or widget.id in widget_ids_filter]
    kpi_index = 0
    non_kpi_index = 0
    last_chart_delay = 0.0
    dual_pool_pages = {"risk-analysis", "dexes", "exponent-yield"}
    lane_delay_by_group: dict[str, float] = {}
    health_table_index = 0
    health_chart_index = 0
    health_queue_pair_delay: float | None = None
    widget_bindings = []
    for widget in widgets:
        endpoint_page = widget.source_page_id or page.api_page_id
        endpoint_wid = widget.source_widget_id or widget.id
        shared_data_family = resolve_shared_data_family(endpoint_page, endpoint_wid)

        if widget.kind == "kpi":
            load_delay_seconds = kpi_index * HTMX_KPI_STEP_DELAY_SECONDS
            kpi_index += 1
        else:
            is_right = "chart-right" in (widget.css_class or "") or "-mkt2" in (widget.css_class or "")
            if is_right:
                load_delay_seconds = last_chart_delay
            else:
                load_delay_seconds = HTMX_CHART_BASE_DELAY_SECONDS + non_kpi_index * HTMX_CHART_STEP_DELAY_SECONDS
                non_kpi_index += 1
            last_chart_delay = load_delay_seconds

        # For dual-pool layouts, lane-based delay alignment is only used when
        # the widget does not belong to an explicit shared data family.
        if (
            page.slug in dual_pool_pages
            and widget.kind in {"kpi", "chart", "table", "table-split"}
            and not shared_data_family
        ):
            lane_key = _lane_group_key(widget)
            if _is_secondary_lane(widget) and lane_key in lane_delay_by_group:
                load_delay_seconds = lane_delay_by_group[lane_key]
            elif lane_key:
                lane_delay_by_group[lane_key] = load_delay_seconds

        if page.slug == "system-health":
            if widget.kind in {"table", "table-split"}:
                health_delay = (
                    HTMX_HEALTH_TABLE_BASE_DELAY_SECONDS
                    + health_table_index * HTMX_HEALTH_TABLE_STEP_DELAY_SECONDS
                )
                load_delay_seconds = min(load_delay_seconds, health_delay)
                health_table_index += 1
            elif widget.kind == "chart":
                if widget.id == "health-queue-chart-2" and health_queue_pair_delay is not None:
                    load_delay_seconds = min(load_delay_seconds, health_queue_pair_delay)
                else:
                    health_delay = (
                        HTMX_HEALTH_CHART_BASE_DELAY_SECONDS
                        + health_chart_index * HTMX_HEALTH_CHART_STEP_DELAY_SECONDS
                    )
                    load_delay_seconds = min(load_delay_seconds, health_delay)
                    if widget.id == "health-queue-chart":
                        health_queue_pair_delay = load_delay_seconds
                    health_chart_index += 1

        if widget.kind == "kpi":
            kpi_override = _CACHE_CONFIG["refresh_kpi_seconds"]
            refresh_interval_seconds = kpi_override if kpi_override > 0 else widget.refresh_interval_seconds
        elif widget.kind in {"table", "table-split"}:
            refresh_interval_seconds = _CACHE_CONFIG["refresh_table_seconds"]
        else:
            refresh_interval_seconds = _CACHE_CONFIG["refresh_chart_seconds"]

        widget_bindings.append(
            {
                "id": widget.id,
                "title": widget.title,
                "kind": widget.kind,
                "refresh_interval_seconds": max(5, refresh_interval_seconds),
                "endpoint": build_widget_endpoint(BROWSER_API_BASE_URL, endpoint_page, endpoint_wid),
                "css_class": widget.css_class,
                "expandable": widget.expandable if widget.kind == "chart" else False,
                "load_delay_seconds": load_delay_seconds,
                "tooltip": widget.tooltip,
                "detail_table_endpoint": build_widget_endpoint(BROWSER_API_BASE_URL, endpoint_page, widget.detail_table_id) if widget.detail_table_id else "",
                "source_widget_id": widget.source_widget_id,
                "source_page_id": endpoint_page,
                "protocol_override": widget.protocol_override,
                "shared_data_family": shared_data_family,
            }
        )

    # Backfill final minimum load delay across all members of each shared family.
    # This removes order dependence from the single-pass convergence above.
    family_min_delay: dict[str, float] = {}
    for binding in widget_bindings:
        family = str(binding.get("shared_data_family") or "").strip()
        if not family:
            continue
        family_page = str(binding.get("source_page_id") or page.api_page_id)
        family_key = f"{family_page}::{family}"
        current_delay = float(binding.get("load_delay_seconds") or 0.0)
        if family_key in family_min_delay:
            family_min_delay[family_key] = min(family_min_delay[family_key], current_delay)
        else:
            family_min_delay[family_key] = current_delay
    for binding in widget_bindings:
        family = str(binding.get("shared_data_family") or "").strip()
        if not family:
            continue
        family_page = str(binding.get("source_page_id") or page.api_page_id)
        family_key = f"{family_page}::{family}"
        if family_key in family_min_delay:
            binding["load_delay_seconds"] = family_min_delay[family_key]

    current_index = next((idx for idx, cfg in enumerate(PAGES) if cfg.slug == page.slug), 0)
    warmup_pages = PAGES[current_index + 1 :] + PAGES[:current_index]
    warmup_manifest = []
    warmup_exclude_kinds = {"section-header", "section-subheader", "placeholder"}
    for idx, cfg in enumerate(warmup_pages):
        targets: list[dict[str, object]] = []
        candidate_targets: list[dict[str, object]] = []
        seen_widget_ids: set[str] = set()
        for widget in cfg.widgets:
            if widget.kind in warmup_exclude_kinds:
                continue
            endpoint_widget_id = widget.source_widget_id or widget.id
            target_params: dict[str, str] = {}
            if widget.protocol_override:
                proto = widget.protocol_override
                if proto == "ray":
                    proto = "raydium"
                target_params["protocol"] = proto
            target_key = f"{endpoint_widget_id}::{target_params.get('protocol', '')}"
            if target_key in seen_widget_ids:
                continue
            seen_widget_ids.add(target_key)
            target_payload: dict[str, object] = {"widget_id": endpoint_widget_id, "kind": widget.kind}
            if target_params:
                target_payload["params"] = target_params
            if cfg.slug == "system-health":
                priority_map = {
                    "health-master": 0,
                    "health-queue-table": 1,
                    "health-trigger-table": 2,
                    "health-base-table": 3,
                    "health-cagg-table": 4,
                    "health-queue-chart": 5,
                    "health-queue-chart-2": 6,
                    "health-base-chart-events": 7,
                    "health-base-chart-accounts": 8,
                }
                target_payload["priority"] = priority_map.get(endpoint_widget_id, 100)
            candidate_targets.append(target_payload)

        if cfg.slug == "system-health":
            candidate_targets.sort(key=lambda item: int(item.get("priority", 100)))
        for target_payload in candidate_targets:
            targets.append(target_payload)
            if len(targets) >= max(1, _CACHE_CONFIG["warmup_widgets_per_page"]):
                break
        if targets:
            warmup_manifest.append(
                {
                    "slug": cfg.slug,
                    "page_id": cfg.api_page_id,
                    "order": idx,
                    "targets": targets,
                }
            )

    page_action_bindings = [
        {
            "id": action.id,
            "label": action.label,
            "icon": action.icon,
            "modal_kind": action.modal_kind,
            "endpoint": build_widget_endpoint(BROWSER_API_BASE_URL, page.api_page_id, action.endpoint) if action.endpoint else "",
        }
        for action in page.page_actions
    ]

    show_pipeline = ENABLE_PIPELINE_SWITCHER and page.show_pipeline_switcher
    protocol = page.default_protocol
    pair = page.default_pair
    if pipeline_info and pipeline_info.get("defaults"):
        defaults = pipeline_info["defaults"]
        if defaults.get("protocol"):
            protocol = defaults["protocol"]
        if defaults.get("pair"):
            pair = defaults["pair"]
    elif DEFAULT_PIPELINE and DEFAULT_PIPELINE in PIPELINE_DEFAULTS:
        pl_defaults = PIPELINE_DEFAULTS[DEFAULT_PIPELINE]
        if not protocol and pl_defaults.get("protocol"):
            protocol = pl_defaults["protocol"]
        if not pair and pl_defaults.get("pair"):
            pair = pl_defaults["pair"]

    asset = page.default_asset
    if page.show_asset_filter and DEFAULT_PIPELINE and DEFAULT_PIPELINE in PIPELINE_DEFAULTS:
        asset = PIPELINE_DEFAULTS[DEFAULT_PIPELINE].get("asset", asset)

    return {
        "app_title": APP_TITLE,
        "page_title": page.label,
        "page_options": page_options,
        "current_page_slug": page.slug,
        "widgets": widget_bindings,
        "page_actions": page_action_bindings,
        "show_protocol_pair_filters": page.show_protocol_pair_filters,
        "render_asset_select": page.show_asset_filter,
        "show_asset_filter": page.show_asset_filter and SHOW_ASSET_FILTER,
        "show_market_selectors": page.show_market_selectors,
        "api_page_id": page.api_page_id,
        "protocol": protocol,
        "pair": pair,
        "asset": asset,
        "last_window": DEFAULT_LAST_WINDOW,
        "last_window_options": LAST_WINDOW_OPTIONS,
        "api_base_url": BROWSER_API_BASE_URL,
        "show_pipeline_switcher": show_pipeline,
        "pipeline_info": pipeline_info,
        "current_pipeline": current_pipeline,
        "render_price_basis_select": page.show_price_basis_filter,
        "show_price_basis_filter": page.show_price_basis_filter and SHOW_PRICE_BASIS,
        "default_price_basis": DEFAULT_PRICE_BASIS,
        "content_template": page.content_template or "",
        "video_guide_youtube_id": page.video_guide_youtube_id,
        "cover_video_guide_youtube_id": COVER_VIDEO_GUIDE_ID,
        "min_supported_viewport_width": MIN_SUPPORTED_VIEWPORT_WIDTH,
        "request_mobile": request_mobile,
        "show_refresh_button": SHOW_REFRESH_BUTTON,
        "show_view_selector": not NAV_LAYOUT_SIDEBAR,
        "use_sidebar_nav": NAV_LAYOUT_SIDEBAR,
        "warmup_manifest": warmup_manifest,
        "cache_config": _CACHE_CONFIG,
    }


def _is_mobile_request(request: Request) -> bool:
    ch_mobile = (request.headers.get("sec-ch-ua-mobile", "") or "").strip().lower()
    if ch_mobile in {"?1", "1", "true"}:
        return True
    if ch_mobile in {"?0", "0", "false"}:
        return False

    ua = (request.headers.get("user-agent", "") or "").lower()
    mobile_markers = (
        "android",
        "iphone",
        "ipad",
        "ipod",
        "windows phone",
        "blackberry",
        "opera mini",
        "mobile",
    )
    return any(marker in ua for marker in mobile_markers)


def render_page(request: Request, page: PageConfig):
    page_options = [{"slug": cfg.slug, "label": cfg.label, "path": f"/{cfg.slug}"} for cfg in PAGES]
    pipeline_info = _get_pipeline_info() if ENABLE_PIPELINE_SWITCHER else None
    current_pipeline = pipeline_info.get("current", "") if isinstance(pipeline_info, dict) else DEFAULT_PIPELINE
    request_mobile = _is_mobile_request(request)

    ctx = _build_page_context(
        page,
        page_options,
        current_pipeline,
        pipeline_info,
        request_mobile=request_mobile,
    )

    shell_tpl = templates.env.get_template("partials/shell_embed.html")
    shell_map: dict[str, str] = {}
    for other_page in PAGES:
        if other_page.slug == page.slug:
            continue
        other_ctx = _build_page_context(
            other_page,
            page_options,
            current_pipeline,
            pipeline_info,
            request_mobile=request_mobile,
        )
        shell_map[f"/{other_page.slug}"] = shell_tpl.render(other_ctx)

    ctx["embedded_shells_json"] = json.dumps(shell_map).replace("</", "<\\/")

    return templates.TemplateResponse(
        request=request,
        name="base.html",
        context={**ctx, "request": request},
    )


def _make_page_handler(slug: str):
    def _handler(request: Request):
        return render_page(request, PAGES_BY_SLUG[slug])
    _handler.__name__ = slug.replace("-", "_")
    return _handler


for _page in PAGES:
    app.get(f"/{_page.slug}")(_make_page_handler(_page.slug))


@app.get("/chart-export", include_in_schema=False)
def chart_export(request: Request):
    """Private utility page for exporting charts as image assets."""
    chart_catalogue: list[dict] = []
    protocol_labels = {
        "orca": "Orca",
        "ray": "Raydium",
        "raydium": "Raydium",
    }
    for page in PAGES:
        for widget in page.widgets:
            if widget.kind != "chart":
                continue
            endpoint_page = widget.source_page_id or page.api_page_id
            endpoint_wid = widget.source_widget_id or widget.id
            protocol_override = widget.protocol_override or ""
            widget_title = widget.title
            if protocol_override:
                widget_title = f"{widget_title} ({protocol_labels.get(protocol_override, protocol_override)})"
            chart_catalogue.append({
                "page_label": page.label,
                "page_id": page.api_page_id,
                "widget_id": widget.id,
                "source_widget_id": endpoint_wid,
                "protocol_override": protocol_override,
                "widget_title": widget_title,
                "endpoint": build_widget_endpoint(BROWSER_API_BASE_URL, endpoint_page, endpoint_wid),
                "show_protocol_pair": page.show_protocol_pair_filters,
                "show_markets": page.show_market_selectors,
            })
    pipeline_info = _get_pipeline_info() if ENABLE_PIPELINE_SWITCHER else None
    return templates.TemplateResponse(
        request=request,
        name="export.html",
        context={
            "app_title": APP_TITLE,
            "chart_catalogue": chart_catalogue,
            "api_base_url": BROWSER_API_BASE_URL,
            "show_pipeline_switcher": ENABLE_PIPELINE_SWITCHER,
            "pipeline_info": pipeline_info,
        },
    )


_pipeline_cache: dict[str, object] = {"value": None, "expires_at": 0.0}

def _get_pipeline_info() -> dict | None:
    """Fetch pipeline state from the API server.  Cached for 5s."""
    now = time.time()
    if now < float(_pipeline_cache.get("expires_at", 0.0)):
        cached = _pipeline_cache.get("value")
        if isinstance(cached, dict):
            return cached

    try:
        req = urllib.request.Request(f"{API_BASE_URL}/api/v1/pipeline")
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read())
            _pipeline_cache["value"] = data
            _pipeline_cache["expires_at"] = time.time() + 5.0
            return data
    except Exception:
        return _pipeline_cache.get("value") if isinstance(_pipeline_cache.get("value"), dict) else None


@app.get("/api/pipeline-info")
def pipeline_info_proxy():
    """Client-side hydration endpoint for when server-side fetch missed."""
    info = _get_pipeline_info()
    if info:
        return JSONResponse(content=info)
    return JSONResponse(content={"current": None, "available": []}, status_code=503)


@app.post("/api/switch-pipeline")
def switch_pipeline_proxy(request: Request):
    """Same-origin proxy to avoid CORS for the pipeline switch POST."""
    import urllib.error
    try:
        body = json.dumps({"pipeline": dict(request.query_params).get("pipeline", "")})
        req = urllib.request.Request(
            f"{API_BASE_URL}/api/v1/pipeline",
            data=body.encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            payload = json.loads(resp.read())
            _pipeline_cache["value"] = payload
            _pipeline_cache["expires_at"] = time.time() + 5.0
            _health_proxy_cache["value"] = None
            _health_proxy_cache["expires_at"] = 0.0
            with _meta_proxy_lock:
                _meta_proxy_cache.clear()
            return JSONResponse(content=payload)
    except urllib.error.HTTPError as exc:
        return JSONResponse(content={"error": "Pipeline switch failed"}, status_code=exc.code)
    except Exception:
        return JSONResponse(content={"error": "Pipeline switch unavailable"}, status_code=502)


_proxy_timeout = float(os.getenv("HTMX_API_PROXY_TIMEOUT_SECONDS", "60"))
_httpx_client = None


def _get_httpx_client():
    global _httpx_client
    if httpx is None:
        return None
    if _httpx_client is None or _httpx_client.is_closed:
        _httpx_client = httpx.AsyncClient(
            base_url=f"{API_BASE_URL}/api/v1",
            timeout=httpx.Timeout(_proxy_timeout, connect=5.0),
            limits=httpx.Limits(max_connections=40, max_keepalive_connections=20),
        )
    return _httpx_client


@app.on_event("shutdown")
async def _close_httpx_client():
    if _httpx_client and hasattr(_httpx_client, "aclose") and not _httpx_client.is_closed:
        await _httpx_client.aclose()


def _proxy_v1_sync(target_url: str, method: str, body: bytes | None, content_type: str, timeout: float) -> tuple[bytes, str, int]:
    req = urllib.request.Request(target_url, data=body or None, method=method)
    req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        content = resp.read()
        ct = resp.headers.get("content-type", "application/json")
        status = int(getattr(resp, "status", 200))
        return content, ct, status


@app.api_route("/api/v1/{path:path}", methods=["GET", "POST"])
async def api_v1_proxy(path: str, request: Request):
    """Forward all /api/v1/* widget requests to the internal API server."""
    qs = request.url.query

    if request.method.upper() == "GET" and path == "meta":
        now = time.time()
        with _meta_proxy_lock:
            cached = _meta_proxy_cache.get(qs)
            if cached and cached[0] > now:
                return JSONResponse(content=cached[1], headers={"Cache-Control": "no-store"})

    body: bytes | None = None
    method = request.method.upper()
    if method in ("POST", "PUT", "PATCH"):
        body = await request.body()

    content_type = request.headers.get("content-type", "application/json")
    client = _get_httpx_client()

    try:
        if client is not None:
            target = f"/{path}"
            if qs:
                target = f"{target}?{qs}"
            resp = await client.request(method, target, content=body, headers={"content-type": content_type})
            content, ct, status = resp.content, resp.headers.get("content-type", "application/json"), resp.status_code
        else:
            target = f"{API_BASE_URL}/api/v1/{path}"
            if qs:
                target = f"{target}?{qs}"
            content, ct, status = await asyncio.to_thread(
                _proxy_v1_sync, target, method, body, content_type, _proxy_timeout,
            )

        if request.method.upper() == "GET" and path == "meta":
            try:
                payload = json.loads(content)
                with _meta_proxy_lock:
                    _meta_proxy_cache[qs] = (time.time() + META_PROXY_TTL_SECONDS, payload)
            except Exception:
                pass
        return Response(
            content=content, media_type=ct, status_code=status,
            headers={"Cache-Control": "no-store"},
        )
    except urllib.error.HTTPError as exc:
        return JSONResponse(content={"error": "API request failed"}, status_code=exc.code)
    except Exception:
        return JSONResponse(content={"error": "API unavailable"}, status_code=502)


@app.get("/api/health-status")
def health_status_proxy():
    """Same-origin proxy so the header indicator avoids cross-origin fetch."""
    now = time.time()
    if now < float(_health_proxy_cache.get("expires_at", 0.0)):
        cached = _health_proxy_cache.get("value")
        if isinstance(cached, dict):
            return JSONResponse(content=cached)

    with _health_proxy_lock:
        now = time.time()
        if now < float(_health_proxy_cache.get("expires_at", 0.0)):
            cached = _health_proxy_cache.get("value")
            if isinstance(cached, dict):
                return JSONResponse(content=cached)

        cached_before = _health_proxy_cache.get("value")
        if not isinstance(cached_before, dict):
            cached_before = None

    try:
        req = urllib.request.Request(f"{API_BASE_URL}/api/v1/health-status")
        with urllib.request.urlopen(req, timeout=HEALTH_PROXY_TIMEOUT_SECONDS) as resp:
            payload = json.loads(resp.read())
            with _health_proxy_lock:
                _health_proxy_cache["value"] = payload
                _health_proxy_cache["expires_at"] = time.time() + HEALTH_PROXY_TTL_SECONDS
            return JSONResponse(content=payload)
    except Exception:
        if isinstance(cached_before, dict):
            return JSONResponse(content=cached_before)
        return JSONResponse(content={"is_green": None})


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8002"))
    uvicorn.run("app.main:app", host="0.0.0.0", port=port, reload=True)
