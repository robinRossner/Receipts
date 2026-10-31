from __future__ import annotations

import pytest

# receipts fixtures (rfactory, rdb, rclient, photos_dir, FakeProvider, ...)
pytest_plugins = ("tests.receipts_helpers",)


@pytest.fixture(autouse=True)
def _auth_throttle_off(monkeypatch):
    """Tests send many bad tokens from one fake client; the throttle is tested on its own."""
    from core.auth import get_throttle, get_trusted_proxies
    from core.settings import get_core_settings

    monkeypatch.setenv("AUTH_MAX_FAILURES", "1000000")
    for cached in (get_core_settings, get_throttle, get_trusted_proxies):
        cached.cache_clear()
    yield
    for cached in (get_core_settings, get_throttle, get_trusted_proxies):
        cached.cache_clear()
