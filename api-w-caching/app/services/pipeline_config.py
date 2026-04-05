"""
Pipeline switcher — dev-only utility for toggling between Solstice and ONyc databases.

Gated by the ENABLE_PIPELINE_SWITCHER environment variable.  Set it to "1" in
the API .env to activate; omit or set to any other value for production.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

logger = logging.getLogger(__name__)

_DB_KEYS = ("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD", "DB_SSLMODE")

PIPELINES: dict[str, dict[str, str]] = {}
_current_pipeline: str = ""

PIPELINE_DEFAULTS: dict[str, dict[str, str]] = {
    "solstice": {"protocol": "raydium", "pair": "USDG-ONyc"},
    "onyc":     {"protocol": "orca",    "pair": "ONyc-USDC"},
}


def _parse_env_file(path: Path) -> dict[str, str]:
    """Minimal .env parser — handles KEY=VALUE lines, ignores comments/blanks."""
    result: dict[str, str] = {}
    if not path.exists():
        return result
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        result[key.strip()] = value.strip()
    return result


def _load_pipelines() -> None:
    global _current_pipeline

    project_root = Path(__file__).resolve().parents[3]  # pfx/api-w-caching/app/services → pfx/

    solstice_env = project_root.parent / ".env.prod.core"
    onyc_env = project_root / ".env.pfx.core"

    sol = _parse_env_file(solstice_env)
    onyc = _parse_env_file(onyc_env)

    if sol:
        if not sol.get("DB_SSLMODE") and sol.get("PGSSLMODE"):
            sol["DB_SSLMODE"] = sol["PGSSLMODE"]
        PIPELINES["solstice"] = {k: sol.get(k, "") for k in _DB_KEYS}
    if onyc:
        if not onyc.get("DB_SSLMODE") and onyc.get("PGSSLMODE"):
            onyc["DB_SSLMODE"] = onyc["PGSSLMODE"]
        PIPELINES["onyc"] = {k: onyc.get(k, "") for k in _DB_KEYS}

    current_host = os.getenv("DB_HOST", "")
    for name, cfg in PIPELINES.items():
        if cfg.get("DB_HOST") == current_host:
            _current_pipeline = name
            break

    if not _current_pipeline and PIPELINES:
        _current_pipeline = next(iter(PIPELINES))

    logger.info(
        "Pipeline switcher loaded %d pipelines, current=%s",
        len(PIPELINES),
        _current_pipeline,
    )


def is_enabled() -> bool:
    return os.getenv("ENABLE_PIPELINE_SWITCHER", "0") == "1"


def get_current() -> str:
    return _current_pipeline


def get_defaults() -> dict[str, str]:
    return PIPELINE_DEFAULTS.get(_current_pipeline, {})


def get_available() -> list[dict[str, str]]:
    return [
        {"id": name, "label": name.title(), "current": name == _current_pipeline}
        for name in PIPELINES
    ]


def switch_to(name: str) -> bool:
    """Write new DB credentials into os.environ.  Returns True on success."""
    global _current_pipeline
    cfg = PIPELINES.get(name)
    if cfg is None:
        return False
    for key, value in cfg.items():
        os.environ[key] = value
    _current_pipeline = name
    logger.info("Switched pipeline to %s (DB_HOST=%s)", name, cfg.get("DB_HOST", "?"))
    return True


_load_pipelines()
