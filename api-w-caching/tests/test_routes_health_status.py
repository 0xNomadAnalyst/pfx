from __future__ import annotations

import unittest

from app.api.routes import health_status


class _FakeService:
    def __init__(self, cached, raise_on_cached: bool = False):
        self._cached = cached
        self._raise_on_cached = raise_on_cached

    def get_health_indicator_status(self, **_: object):
        if self._raise_on_cached:
            raise RuntimeError("cached status failed")
        return self._cached


class HealthStatusRouteTests(unittest.TestCase):
    def test_uses_cached_status_when_present_true(self) -> None:
        svc = _FakeService(cached=True)
        self.assertEqual(health_status(svc), {"is_green": True})

    def test_uses_cached_status_when_present_false(self) -> None:
        svc = _FakeService(cached=False)
        self.assertEqual(health_status(svc), {"is_green": False})

    def test_returns_unknown_when_cache_has_no_value(self) -> None:
        svc = _FakeService(cached=None)
        self.assertEqual(health_status(svc), {"is_green": None})

    def test_returns_unknown_when_service_errors(self) -> None:
        svc = _FakeService(cached=None, raise_on_cached=True)
        self.assertEqual(health_status(svc), {"is_green": None})


if __name__ == "__main__":
    unittest.main()
