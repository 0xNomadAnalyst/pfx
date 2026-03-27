from __future__ import annotations

import threading
import time
import unittest

from app.services.shared.cache_store import QueryCache


class QueryCacheSingleflightTests(unittest.TestCase):
    def test_waiters_use_per_call_ttl_for_inflight_wait(self) -> None:
        cache = QueryCache(ttl_seconds=0.05, max_entries=16)
        calls = 0
        calls_lock = threading.Lock()
        results: list[str] = []

        def loader() -> str:
            nonlocal calls
            with calls_lock:
                calls += 1
            time.sleep(0.15)
            return "ok"

        def worker() -> None:
            value = cache.cached("ts-key", loader, ttl_seconds=1.0)
            results.append(value)

        t1 = threading.Thread(target=worker)
        t2 = threading.Thread(target=worker)
        t1.start()
        time.sleep(0.01)
        t2.start()
        t1.join()
        t2.join()

        self.assertEqual(calls, 1, "inflight waiter should not trigger duplicate loader")
        self.assertEqual(results, ["ok", "ok"])

    def test_cached_swr_serves_stale_and_bounds_refresh_failures(self) -> None:
        cache = QueryCache(ttl_seconds=0.05, max_entries=16, swr_workers=2, jitter_pct=0)
        cache.set("swr-key", {"value": "stale"}, ttl_seconds=0.01, swr_seconds=0.5)
        time.sleep(0.03)

        loader_calls = 0
        loader_lock = threading.Lock()

        def loader():
            nonlocal loader_calls
            with loader_lock:
                loader_calls += 1
            raise RuntimeError("refresh failed")

        results = []

        def worker() -> None:
            results.append(cache.cached_swr("swr-key", loader, ttl_seconds=0.05, swr_seconds=0.5))

        threads = [threading.Thread(target=worker) for _ in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # Background refresh runs asynchronously; give it a short moment.
        time.sleep(0.1)
        stats = cache.stats()
        self.assertEqual(len(results), 6)
        self.assertTrue(all(item == {"value": "stale"} for item in results))
        self.assertLessEqual(loader_calls, 2, "swr refresh pressure should stay bounded under contention")
        self.assertGreaterEqual(int(stats.get("bg_refresh_started", 0)), 1)
        self.assertGreaterEqual(int(stats.get("bg_refresh_failed", 0)), 1)

    def test_cached_swr_serves_stale_on_timeout_failures(self) -> None:
        cache = QueryCache(ttl_seconds=0.05, max_entries=16, swr_workers=1, jitter_pct=0)
        cache.set("timeout-key", {"value": "stale"}, ttl_seconds=0.01, swr_seconds=0.5)
        time.sleep(0.03)

        loader_calls = 0

        def loader():
            nonlocal loader_calls
            loader_calls += 1
            raise TimeoutError("simulated backend timeout")

        first = cache.cached_swr("timeout-key", loader, ttl_seconds=0.05, swr_seconds=0.5)
        second = cache.cached_swr("timeout-key", loader, ttl_seconds=0.05, swr_seconds=0.5)

        time.sleep(0.1)
        stats = cache.stats()
        self.assertEqual(first, {"value": "stale"})
        self.assertEqual(second, {"value": "stale"})
        self.assertLessEqual(loader_calls, 2, "timeout-driven refresh attempts should stay bounded")
        self.assertGreaterEqual(int(stats.get("bg_refresh_failed", 0)), 1)


if __name__ == "__main__":
    unittest.main()
