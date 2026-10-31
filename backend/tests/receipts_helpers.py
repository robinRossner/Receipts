"""Shared fixtures and fakes of the receipts tests (loaded through conftest `pytest_plugins`).

No test ever makes a real Claude call: `FakeProvider` stands in for the LLM provider, the API
provider is tested against a fake SDK client and the CLI provider only builds its command line.
"""

from __future__ import annotations

import json
import struct
import zlib
from pathlib import Path
from typing import Any

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient

from core.auth import get_throttle, get_trusted_proxies
from core.settings import BACKEND_DIR, get_core_settings
from receipts.extraction.taxonomy import get_taxonomy
from receipts.llm.base import LLMError, LLMResponse
from receipts.settings import get_settings

RECEIPTS_TOKEN = "receipts-test-token"
OTHER_TOKEN = "some-other-token"  # an API_TOKEN in the environment is not accepted
AUTH = {"Authorization": f"Bearer {RECEIPTS_TOKEN}"}
BASE = "/api/v1/receipts"


def _clear_caches() -> None:
    from receipts.db.session import reset_engine

    for cached in (get_core_settings, get_settings, get_throttle, get_trusted_proxies):
        cached.cache_clear()
    reset_engine()


@pytest.fixture(autouse=True)
def _receipts_env(tmp_path: Path, monkeypatch):
    """Every test: own receipts.db + photos dir in tmp, no worker thread, no Claude credentials.
    Nothing can touch backend/var or spend quota."""
    monkeypatch.setenv("RECEIPTS_DATABASE_URL", f"sqlite:///{tmp_path / 'receipts.db'}")
    monkeypatch.setenv("RECEIPTS_PHOTOS_DIR", str(tmp_path / "photos"))
    monkeypatch.setenv("RECEIPTS_WORKER_ENABLED", "false")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    _clear_caches()
    yield
    _clear_caches()


def alembic_config(url: str) -> Config:
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.attributes["url"] = url
    return cfg


def migrate_receipts(url: str) -> None:
    cfg = alembic_config(url)
    command.upgrade(cfg, "head")


@pytest.fixture
def rfactory(_receipts_env, monkeypatch):
    """sessionmaker of a fresh, fully migrated receipts.db (the one the app under test uses);
    RECEIPTS_API_TOKEN is configured."""
    from receipts.db.session import get_session_factory

    monkeypatch.setenv("RECEIPTS_API_TOKEN", RECEIPTS_TOKEN)
    monkeypatch.setenv("API_TOKEN", OTHER_TOKEN)
    get_core_settings.cache_clear()
    migrate_receipts(get_settings().receipts_database_url)
    return get_session_factory()


@pytest.fixture
def rdb(rfactory):
    session = rfactory()
    yield session
    session.close()


@pytest.fixture
def rclient(rfactory):
    from server import create_app

    return TestClient(create_app(docs_enabled=False), headers=AUTH)


@pytest.fixture
def photos_dir() -> Path:
    return get_settings().receipts_photos_dir


# --------------------------------------------------------------------------- images


def make_jpeg(seed: int = 0, width: int = 40, height: int = 60) -> bytes:
    """A small structurally valid JPEG; `seed` makes the bytes (and sha256) unique."""
    comment = f"seed-{seed}".encode()
    app0 = b"\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    com = b"\xff\xfe" + struct.pack(">H", len(comment) + 2) + comment
    dqt = b"\xff\xdb\x00\x43\x00" + bytes(range(1, 65))
    sof = (
        b"\xff\xc0\x00\x11\x08"
        + struct.pack(">HH", height, width)
        + b"\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01"
    )
    sos = b"\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00\x3f\x00"
    scan = bytes((seed * 7 + i) % 251 for i in range(64))
    return b"\xff\xd8" + app0 + com + dqt + sof + sos + scan + b"\xff\xd9"


def _chunk(kind: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(kind + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)


def make_png(seed: int = 0, width: int = 8, height: int = 8) -> bytes:
    rows = b"".join(
        b"\x00" + bytes((seed + x + y) % 256 for x in range(width * 3)) for y in range(height)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + _chunk(b"IDAT", zlib.compress(rows))
        + _chunk(b"IEND", b"")
    )


# --------------------------------------------------------------------------- fake LLM


def path_number(label: str) -> int:
    """The number the classification prompt gives a taxonomy path ('Food > Pantry > Legumes')."""
    for number, path in get_taxonomy().numbered_prompt()[1].items():
        if path.label == label:
            return number
    raise KeyError(label)


def receipt_json(
    items: list[tuple[str, float, float]] | None = None,
    *,
    store: str | None = "Edeka",
    date: str | None = "2026-03-01",
    total: float | None = None,
) -> str:
    """What the vision model would answer: items are (name, quantity, unit_price)."""
    items = items if items is not None else [("Bio Eier 10er", 1, 2.49), ("Pfand", 1, 0.25)]
    rows = [
        {
            "raw_text": name,
            "name": name,
            "quantity": qty,
            "unit_price": unit,
            "total_price": round(qty * unit, 2),
        }
        for name, qty, unit in items
    ]
    if total is None:
        total = round(sum(r["total_price"] for r in rows), 2)
    return json.dumps(
        {
            "store": store,
            "date": date,
            "time": "09:12",
            "items": rows,
            "total": total,
            "printed_item_count": len(rows),
        }
    )


class FakeProvider:
    """Scripted LLM provider. `extractions` is a list of answers (str = response text, an
    Exception instance = raised); the last one repeats. Classification files every item under
    `classify_label`. Every call is recorded."""

    def __init__(
        self,
        extractions: list[Any] | None = None,
        classify_label: str = "Food > Pantry > Legumes",
    ):
        self.extractions = extractions if extractions is not None else [receipt_json()]
        self.classify_label = classify_label
        self.extract_calls: list[dict[str, Any]] = []
        self.classify_calls: list[str] = []

    def extract_receipt(self, image, media_type, prompt, schema, max_tokens) -> LLMResponse:
        self.extract_calls.append({"image": image, "media_type": media_type, "prompt": prompt})
        i = min(len(self.extract_calls) - 1, len(self.extractions) - 1)
        answer = self.extractions[i]
        if isinstance(answer, Exception):
            raise answer
        return LLMResponse(answer, "fake/test-model")

    def classify(self, prompt, schema, max_tokens) -> LLMResponse:
        self.classify_calls.append(prompt)
        n = len(schema["properties"]["items"]["items"]["properties"]["index"]["enum"])
        number = path_number(self.classify_label)
        items = [
            {"index": i, "translation_en": f"item {i}", "path_number": number}
            for i in range(1, n + 1)
        ]
        return LLMResponse(json.dumps({"items": items}), "fake/test-model")


def transient_error(msg: str = "overloaded") -> LLMError:
    return LLMError("api_status", msg, retryable=True)
