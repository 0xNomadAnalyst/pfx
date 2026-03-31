from __future__ import annotations

import random
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor

import logging
import os
from threading import Event, RLock
import time
from typing import Any, Callable

logger = logging.getLogger(__name__)


class QueryCache:
    def __init__(
        self,
        ttl_seconds: float,
        max_entries: int,
        *,
        swr_workers: int | None = None,
        jitter_pct: float | None = None,
    ) -> None:
        self._ttl_seconds = ttl_seconds
        self._max_entries = max_entries
        self._cache: OrderedDict[str, tuple[float, float, Any]] = OrderedDict()
        self._inflight: dict[str, Event] = {}
        self._refreshing: set[str] = set()
        self._refresh_retry_after_ts: dict[str, float] = {}
        self._lock = RLock()
        self._log_swr = os.getenv("API_CACHE_LOG_SWR", "0") == "1"
        self._refresh_failure_cooldown_ms = max(0, int(os.getenv("API_CACHE_SWR_FAILURE_COOLDOWN_MS", "500")))

        workers = swr_workers if swr_workers is not None else int(os.getenv("API_CACHE_SWR_WORKERS", "4"))
        self._swr_executor = ThreadPoolExecutor(
            max_workers=max(workers, 1),
            thread_name_prefix="cache-swr",
        )

        jp = jitter_pct if jitter_pct is not None else float(os.getenv("API_CACHE_TTL_JITTER_PCT", "10"))
        self._jitter_pct = max(jp / 100.0, 0.0)

        self._hits = 0
        self._misses = 0
        self._stale_served = 0
        self._inflight_waits = 0
        self._bg_refresh_started = 0
        self._bg_refresh_failed = 0
        self._evictions = 0

    def _apply_jitter(self, ttl: float) -> float:
        if self._jitter_pct > 0 and ttl > 0:
            jitter = ttl * self._jitter_pct * (2 * random.random() - 1)
            return max(ttl + jitter, 1.0)
        return max(ttl, 0.0)

    def get(self, key: str, *, allow_stale: bool = False) -> Any | None:
        now_ts = time.time()
        with self._lock:
            entry = self._cache.get(key)
            if entry is None:
                return None
            expires_at, stale_expires_at, value = entry
            if expires_at > now_ts:
                self._cache.move_to_end(key)
                self._hits += 1
                return value
            if allow_stale and stale_expires_at > now_ts:
                self._cache.move_to_end(key)
                self._stale_served += 1
                return value
            if stale_expires_at <= now_ts:
                del self._cache[key]
                return None
            return None

    def set(
        self,
        key: str,
        value: Any,
        ttl_seconds: float | None = None,
        swr_seconds: float = 0.0,
    ) -> Any:
        ttl = self._ttl_seconds if ttl_seconds is None else ttl_seconds
        ttl = self._apply_jitter(ttl)
        expires_at = time.time() + ttl
        stale_expires_at = expires_at + max(swr_seconds, 0.0)
        with self._lock:
            self._cache[key] = (expires_at, stale_expires_at, value)
            self._cache.move_to_end(key)
            while len(self._cache) > self._max_entries:
                self._cache.popitem(last=False)
                self._evictions += 1
        return value

    def clear(self) -> None:
        with self._lock:
            self._cache.clear()

    def cached(self, key: str, loader: Callable[[], Any], ttl_seconds: float | None = None) -> Any:
        existing = self.get(key, allow_stale=False)
        if existing is not None:
            return existing

        self._misses += 1
        is_loader = False
        with self._lock:
            wait_event = self._inflight.get(key)
            if wait_event is None:
                wait_event = Event()
                self._inflight[key] = wait_event
                is_loader = True

        if not is_loader:
            self._inflight_waits += 1
            wait_ttl = self._ttl_seconds if ttl_seconds is None else ttl_seconds
            wait_event.wait(timeout=max(wait_ttl, 1.0))
            existing_after_wait = self.get(key, allow_stale=False)
            if existing_after_wait is not None:
                return existing_after_wait
            return self.set(key, loader(), ttl_seconds=ttl_seconds)

        try:
            value = loader()
            return self.set(key, value, ttl_seconds=ttl_seconds)
        finally:
            with self._lock:
                event = self._inflight.pop(key, None)
                if event is not None:
                    event.set()

    def cached_swr(
        self,
        key: str,
        loader: Callable[[], Any],
        *,
        ttl_seconds: float | None = None,
        swr_seconds: float = 0.0,
    ) -> Any:
        fresh = self.get(key, allow_stale=False)
        if fresh is not None:
            return fresh
        if swr_seconds <= 0:
            return self.cached(key, loader, ttl_seconds=ttl_seconds)

        stale = self.get(key, allow_stale=True)
        if stale is not None:
            launch_refresh = False
            now = time.monotonic()
            with self._lock:
                retry_after = float(self._refresh_retry_after_ts.get(key, 0.0) or 0.0)
                if key not in self._refreshing and now >= retry_after:
                    self._refreshing.add(key)
                    launch_refresh = True

            if launch_refresh:
                if self._log_swr:
                    logger.info("cache_swr served_stale key=%s", key)
                self._bg_refresh_started += 1
                self._swr_executor.submit(
                    self._refresh_in_background, key, loader, ttl_seconds, swr_seconds,
                )
            return stale

        if self._log_swr:
            logger.info("cache_swr hard_miss key=%s", key)
        return self.cached(key, loader, ttl_seconds=ttl_seconds)

    def _refresh_in_background(
        self,
        key: str,
        loader: Callable[[], Any],
        ttl_seconds: float | None,
        swr_seconds: float,
    ) -> None:
        try:
            value = loader()
            self.set(key, value, ttl_seconds=ttl_seconds, swr_seconds=swr_seconds)
            with self._lock:
                self._refresh_retry_after_ts.pop(key, None)
        except Exception:
            self._bg_refresh_failed += 1
            if self._refresh_failure_cooldown_ms > 0:
                with self._lock:
                    self._refresh_retry_after_ts[key] = time.monotonic() + (self._refresh_failure_cooldown_ms / 1000.0)
            if self._log_swr:
                logger.warning("cache_swr refresh_failed key=%s", key)
        finally:
            with self._lock:
                self._refreshing.discard(key)

    def stats(self) -> dict[str, Any]:
        with self._lock:
            entries = len(self._cache)
        try:
            active = self._swr_executor._threads and len(self._swr_executor._threads) or 0
        except Exception:
            active = 0
        return {
            "entries": entries,
            "max_entries": self._max_entries,
            "ttl_seconds": self._ttl_seconds,
            "jitter_pct": round(self._jitter_pct * 100, 1),
            "hits": self._hits,
            "misses": self._misses,
            "stale_served": self._stale_served,
            "inflight_waits": self._inflight_waits,
            "bg_refresh_started": self._bg_refresh_started,
            "bg_refresh_failed": self._bg_refresh_failed,
            "evictions": self._evictions,
            "swr_executor_active_count": active,
        }

    def close(self) -> None:
        self._swr_executor.shutdown(wait=False)
