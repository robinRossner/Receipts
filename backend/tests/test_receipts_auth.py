"""Only RECEIPTS_API_TOKEN opens the receipts routes (no other token, e.g. an `API_TOKEN` in the
environment); none of the receipts routes is public."""

from __future__ import annotations

import re

import pytest
from fastapi.testclient import TestClient

from core.settings import get_core_settings
from server import create_app
from tests.receipts_helpers import AUTH, BASE, OTHER_TOKEN


def _receipts_operations() -> list[tuple[str, str]]:
    paths = create_app(docs_enabled=True).openapi()["paths"]
    return sorted(
        (m.upper(), re.sub(r"\{[^}]+\}", "3b241101-e2bb-4255-8caf-4136c566a962", p))
        for p, item in paths.items()
        for m in item
        if p.startswith(BASE + "/")
    )


@pytest.fixture
def anon(rfactory):
    return TestClient(create_app(docs_enabled=False))


def test_all_receipts_routes_are_found():
    assert len(_receipts_operations()) >= 12


@pytest.mark.parametrize(("method", "url"), _receipts_operations())
def test_other_token_and_no_token_get_401_on_every_receipts_route(anon, method, url):
    assert anon.request(method, url).status_code == 401
    assert (
        anon.request(method, url, headers={"Authorization": f"Bearer {OTHER_TOKEN}"}).status_code
        == 401
    )
    assert anon.request(method, url, headers={"Authorization": "Bearer nope"}).status_code == 401
    # the right token gets past auth (whatever the route then answers for this dummy request)
    assert anon.request(method, url, headers=AUTH).status_code not in (401, 503)


def test_api_token_in_the_environment_is_not_a_second_accepted_token(anon, monkeypatch):
    # rfactory sets API_TOKEN=OTHER_TOKEN; the settings ignore it
    assert (
        anon.get(f"{BASE}/status", headers={"Authorization": f"Bearer {OTHER_TOKEN}"}).status_code
        == 401
    )
    assert anon.get(f"{BASE}/status", headers=AUTH).status_code == 200


def test_unset_receipts_token_is_503_not_open(anon, monkeypatch):
    monkeypatch.delenv("RECEIPTS_API_TOKEN")
    get_core_settings.cache_clear()
    assert anon.get(f"{BASE}/status", headers=AUTH).status_code == 503
    assert anon.get(f"{BASE}/status").status_code == 503
