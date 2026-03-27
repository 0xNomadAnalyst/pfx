from __future__ import annotations

import threading
import unittest
from unittest.mock import patch

from app.api import routes


class _StubSql:
    def __init__(self) -> None:
        self.reset_pool_calls = 0

    def reset_pool(self) -> None:
        self.reset_pool_calls += 1


class _StubService:
    def __init__(self) -> None:
        self.sql = _StubSql()
        self.flush_calls = 0

    def flush_caches(self) -> None:
        self.flush_calls += 1


class PipelineSwitchConcurrencyTests(unittest.TestCase):
    def test_concurrent_requests_trigger_single_switch_and_flush(self) -> None:
        service = _StubService()
        switch_calls = 0
        current_pipeline = "solstice"
        state_lock = threading.Lock()

        def fake_get_current() -> str:
            with state_lock:
                return current_pipeline

        def fake_switch_to(requested: str) -> bool:
            nonlocal current_pipeline, switch_calls
            with state_lock:
                switch_calls += 1
                current_pipeline = requested
            return True

        with patch.object(routes, "_service", service), \
             patch.object(routes.pipeline_config, "is_enabled", return_value=True), \
             patch.object(routes.pipeline_config, "get_current", side_effect=fake_get_current), \
             patch.object(routes.pipeline_config, "switch_to", side_effect=fake_switch_to):
            threads = [
                threading.Thread(target=routes._ensure_pipeline_for_request, args=("onyc",))
                for _ in range(10)
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()

        self.assertEqual(switch_calls, 1, "concurrent requests should coalesce into one switch")
        self.assertEqual(service.sql.reset_pool_calls, 1, "pool reset should run once")
        self.assertEqual(service.flush_calls, 1, "cache flush should run once")


if __name__ == "__main__":
    unittest.main()
