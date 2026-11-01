"""Wire models of `POST /api/v1/receipts/sync/push`. Records are validated one by one (push.py) so a
single bad record is `rejected` instead of failing the whole request."""

from __future__ import annotations

import re
import uuid
from datetime import UTC, date, datetime
from typing import Annotated, Any, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field


def _uuid(v: str) -> str:
    return str(uuid.UUID(v))  # canonical lowercase; ValueError -> record rejected


def _utc(v: datetime) -> datetime:
    return v.replace(tzinfo=UTC) if v.tzinfo is None else v.astimezone(UTC)


def _day(v: str) -> str:
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", v):
        raise ValueError("date must be YYYY-MM-DD")
    date.fromisoformat(v)
    return v


def _clock(v: str) -> str:
    if not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", v):
        raise ValueError("time must be HH:MM")
    return v


UUIDStr = Annotated[str, AfterValidator(_uuid)]
UTCTime = Annotated[datetime, AfterValidator(_utc)]
DayStr = Annotated[str, AfterValidator(_day)]
ClockStr = Annotated[str, AfterValidator(_clock)]
Money = Annotated[float, Field(ge=-1_000_000, le=1_000_000)]


class _Record(BaseModel):
    model_config = ConfigDict(extra="ignore")
    updated_at: UTCTime
    deleted_at: UTCTime | None = None


class DictionaryIn(_Record):
    id: UUIDStr
    canonical_name: str = Field(min_length=1, max_length=255)
    display_name_de: str | None = Field(default=None, max_length=255)
    translation_en: str | None = Field(default=None, max_length=255)
    category: str | None = Field(default=None, max_length=80)
    subcategory: str | None = Field(default=None, max_length=80)
    item_group: str | None = Field(default=None, max_length=80)
    aliases: list[str] = Field(default_factory=list, max_length=200)
    is_manual_override: bool = False
    needs_review: bool = False
    # Flag fields: unlike the rest of the record they are applied only when the pushed object has
    # the key (`model_fields_set`), so a client that predates them cannot wipe a flag by
    # re-pushing the entry (push.py `_dictionary`). null counts as absent for the bool.
    category_flagged: bool | None = None
    suggested_category: str | None = None
    suggested_parent: str | None = None


class ReceiptIn(_Record):
    id: UUIDStr
    store: str | None = Field(default=None, max_length=160)
    date: DayStr | None = None
    time: ClockStr | None = None
    total: Money | None = None
    computed_sum: Money | None = None
    needs_review: bool = False
    review_reasons: list[str] = Field(default_factory=list, max_length=100)
    reviewed_at: UTCTime | None = None
    # Only read when the server does not know the receipt yet: a receipt that has no photo, or
    # whose photo is already held by the archive device (Mac migration). Ignored on updates.
    photo_location: Literal["none", "archived"] = "none"


class LineItemIn(_Record):
    id: UUIDStr
    receipt_id: UUIDStr
    item_dictionary_id: UUIDStr
    position: int = Field(default=0, ge=0, le=10000)
    raw_text: str | None = None
    name_de: str | None = Field(default=None, max_length=255)
    quantity: Annotated[float, Field(ge=-100000, le=100000)] = 1.0
    unit_price: Money = 0.0
    total_price: Money = 0.0
    price_normalized: bool = False


class PushRequest(BaseModel):
    device_id: str = Field(min_length=1, max_length=100)
    dictionary: list[dict[str, Any]] = []
    receipts: list[dict[str, Any]] = []
    line_items: list[dict[str, Any]] = []
    # extra category paths added by a client; absent for clients that predate them
    taxonomy_additions: list[dict[str, Any]] = []


class PushResult(BaseModel):
    entity: Literal["dictionary", "receipt", "line_item", "taxonomy_addition"]
    id: str | None
    status: Literal["applied", "stale", "rejected"]
    reason: str | None = None


class PushResponse(BaseModel):
    server_time: str
    results: list[PushResult]
