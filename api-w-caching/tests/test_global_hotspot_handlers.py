from __future__ import annotations

import unittest

from app.services.pages.global_ecosystem import GlobalEcosystemPageService


class _StubSql:
    def fetch_rows(self, *_args, **_kwargs):
        return []


class _StubCache:
    def cached_swr(self, _key, fn, ttl_seconds=30.0, swr_seconds=15.0):
        return fn()


class GlobalHotspotHandlerTests(unittest.TestCase):
    def test_global_hotspot_widget_handlers_are_registered(self) -> None:
        service = GlobalEcosystemPageService(_StubSql(), _StubCache())
        handlers = set(service.list_widgets())
        self.assertIn("ge-activity-vol-usx", handlers)
        self.assertIn("ge-tvl-share-usx", handlers)


if __name__ == "__main__":
    unittest.main()
