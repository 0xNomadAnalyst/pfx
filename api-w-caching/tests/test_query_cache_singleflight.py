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


if __name__ == "__main__":
    unittest.main()
