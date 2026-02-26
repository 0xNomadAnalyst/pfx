from __future__ import annotations

from collections import OrderedDict
from datetime import UTC, datetime
from threading import Event, RLock
from typing import Any, Callable


class QueryCache:
    def __init__(self, ttl_seconds: float, max_entries: int) -> None:
        self._ttl_seconds = ttl_seconds
        self._max_entries = max_entries
        self._cache: OrderedDict[str, tuple[float, Any]] = OrderedDict()
        self._inflight: dict[str, Event] = {}
        self._lock = RLock()

    def get(self, key: str) -> Any | None:
        now_ts = datetime.now(UTC).timestamp()
        with self._lock:
            entry = self._cache.get(key)
            if entry is None:
                return None
            expires_at, value = entry
            if expires_at <= now_ts:
                del self._cache[key]
                return None
            self._cache.move_to_end(key)
            return value

    def set(self, key: str, value: Any, ttl_seconds: float | None = None) -> Any:
        ttl = self._ttl_seconds if ttl_seconds is None else ttl_seconds
        expires_at = datetime.now(UTC).timestamp() + max(ttl, 0.0)
        with self._lock:
            self._cache[key] = (expires_at, value)
            self._cache.move_to_end(key)
            while len(self._cache) > self._max_entries:
                self._cache.popitem(last=False)
        return value

    def cached(self, key: str, loader: Callable[[], Any], ttl_seconds: float | None = None) -> Any:
        existing = self.get(key)
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
            wait_event.wait(timeout=max(self._ttl_seconds, 1.0))
            existing_after_wait = self.get(key)
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
