from __future__ import annotations

from collections import OrderedDict
from datetime import UTC, datetime
import logging
import os
from threading import Event, RLock
from threading import Thread
from typing import Any, Callable

logger = logging.getLogger(__name__)


class QueryCache:
    def __init__(self, ttl_seconds: float, max_entries: int) -> None:
        self._ttl_seconds = ttl_seconds
        self._max_entries = max_entries
        self._cache: OrderedDict[str, tuple[float, float, Any]] = OrderedDict()
        self._inflight: dict[str, Event] = {}
        self._refreshing: set[str] = set()
        self._lock = RLock()
        self._log_swr = os.getenv("API_CACHE_LOG_SWR", "0") == "1"

    def get(self, key: str, *, allow_stale: bool = False) -> Any | None:
        now_ts = datetime.now(UTC).timestamp()
        with self._lock:
            entry = self._cache.get(key)
            if entry is None:
                return None
            expires_at, stale_expires_at, value = entry
            if expires_at > now_ts:
                self._cache.move_to_end(key)
                return value
            if allow_stale and stale_expires_at > now_ts:
                self._cache.move_to_end(key)
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
        expires_at = datetime.now(UTC).timestamp() + max(ttl, 0.0)
        stale_expires_at = expires_at + max(swr_seconds, 0.0)
        with self._lock:
            self._cache[key] = (expires_at, stale_expires_at, value)
            self._cache.move_to_end(key)
            while len(self._cache) > self._max_entries:
                self._cache.popitem(last=False)
        return value

    def clear(self) -> None:
        with self._lock:
            self._cache.clear()

    def cached(self, key: str, loader: Callable[[], Any], ttl_seconds: float | None = None) -> Any:
        existing = self.get(key, allow_stale=False)
        if existing is not None:
            return existing

        is_loader = False
        with self._lock:
            wait_event = self._inflight.get(key)
            if wait_event is None:
                wait_event = Event()
                self._inflight[key] = wait_event
                is_loader = True

        if not is_loader:
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
            with self._lock:
                if key not in self._refreshing:
                    self._refreshing.add(key)
                    launch_refresh = True

            if launch_refresh:
                if self._log_swr:
                    logger.info("cache_swr served_stale key=%s", key)
                Thread(
                    target=self._refresh_in_background,
                    args=(key, loader, ttl_seconds, swr_seconds),
                    daemon=True,
                ).start()
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
        except Exception:
            # Keep stale value until SWR window expires.
            if self._log_swr:
                logger.warning("cache_swr refresh_failed key=%s", key)
        finally:
            with self._lock:
                self._refreshing.discard(key)
