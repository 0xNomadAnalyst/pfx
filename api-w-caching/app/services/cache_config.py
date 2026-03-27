"""API cache mode profiles and resolver.

Loaded at import time so it's available before DataService instantiation
(which happens at import time in routes.py).
"""
from __future__ import annotations

import os
from typing import Any

API_CACHE_PROFILES: dict[str, dict[str, Any]] = {
    "fresh": {
        "API_CACHE_TTL_SECONDS": 30,
        "API_CACHE_SWR_SECONDS": 5,
        "API_CACHE_TTL_JITTER_PCT": 0,
        "API_CACHE_SWR_WORKERS": 2,
        "API_CACHE_MAX_ENTRIES": 256,
        "API_CACHE_STATS_ENABLED": False,
    },
    "balanced": {
        "API_CACHE_TTL_SECONDS": 30,
        "API_CACHE_SWR_SECONDS": 15,
        "API_CACHE_TTL_JITTER_PCT": 10,
        "API_CACHE_SWR_WORKERS": 4,
        "API_CACHE_MAX_ENTRIES": 256,
        "API_CACHE_STATS_ENABLED": True,
    },
    "speed": {
        "API_CACHE_TTL_SECONDS": 120,
        "API_CACHE_SWR_SECONDS": 30,
        "API_CACHE_TTL_JITTER_PCT": 15,
        "API_CACHE_SWR_WORKERS": 6,
        "API_CACHE_MAX_ENTRIES": 512,
        "API_CACHE_STATS_ENABLED": False,
    },
}

_ENV_MAP: dict[str, type] = {
    "API_CACHE_TTL_SECONDS": float,
    "API_CACHE_SWR_SECONDS": float,
    "API_CACHE_TTL_JITTER_PCT": float,
    "API_CACHE_SWR_WORKERS": int,
    "API_CACHE_MAX_ENTRIES": int,
    "API_CACHE_STATS_ENABLED": bool,
}


def _parse_bool(value: str) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _read_dash_refresh_interval_seconds(default: float = 30.0) -> float:
    raw = os.getenv("DASH_REFRESH_INTERVAL_SECONDS")
    if raw is None:
        return default
    try:
        parsed = float(raw.strip())
    except Exception:
        return default
    if not parsed or parsed < 0:
        return default
    return max(5.0, min(3600.0, parsed))


def _resolve() -> dict[str, Any]:
    mode = os.getenv("API_CACHE_MODE", "balanced").lower().strip()
    profile = dict(API_CACHE_PROFILES.get(mode, API_CACHE_PROFILES["balanced"]))
    dash_refresh_seconds = _read_dash_refresh_interval_seconds()
    if "API_CACHE_TTL_SECONDS" not in os.environ:
        profile["API_CACHE_TTL_SECONDS"] = dash_refresh_seconds
    if "API_CACHE_SWR_SECONDS" not in os.environ:
        profile["API_CACHE_SWR_SECONDS"] = max(5.0, round(dash_refresh_seconds * 0.5, 3))
    profile["DASH_REFRESH_INTERVAL_SECONDS"] = dash_refresh_seconds

    for key, converter in _ENV_MAP.items():
        raw = os.getenv(key)
        if raw is None:
            continue
        raw = raw.strip()
        if converter is bool:
            profile[key] = _parse_bool(raw)
        elif converter is float:
            profile[key] = float(raw)
        elif converter is int:
            profile[key] = int(raw)
        else:
            profile[key] = raw

    return profile


API_CACHE_CONFIG: dict[str, Any] = _resolve()
