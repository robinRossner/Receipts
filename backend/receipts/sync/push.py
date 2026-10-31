"""`POST /api/v1/receipts/sync/push`: per-record last-write-wins upserts of what a client edited.

Rules (docs/api/receipts.md): upsert by client uuid; the incoming record wins only if its
`updated_at` is strictly newer than the stored one (equal or older -> `stale`, nothing changes,
which also makes re-pushing a payload a no-op); a record that fails validation is `rejected`
alone; `deleted_at` is a tombstone (rows are never removed); everything runs in one transaction.
Order: dictionary entries, receipts, line items (they reference the former).

Server-owned fields (photo, archive, extraction state, usage counters) are never taken from a push.
A push that is applied to a receipt or one of its line items marks the receipt as user-edited
(`user_edited_at`), which makes every later extraction (retry included) leave its content alone.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from pydantic import BaseModel, ValidationError
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.receipts.db.models import ItemDictionary, LineItem, Receipt
from apps.receipts.extraction.taxonomy import Path3, get_taxonomy
from apps.receipts.sync.schemas import (
    DictionaryIn,
    LineItemIn,
    PushRequest,
    PushResult,
    ReceiptIn,
)
from core.db import utcnow


@dataclass
class PushOutcome:
    results: list[PushResult] = field(default_factory=list)


def _result(entity: str, id_: Any, status: str, reason: str | None = None) -> PushResult:
    return PushResult(
        entity=entity, id=id_ if isinstance(id_, str) else None, status=status, reason=reason
    )  # type: ignore[arg-type]


def _parse(model: type[BaseModel], raw: dict[str, Any]) -> tuple[Any, str | None]:
    try:
        return model.model_validate(raw), None
    except ValidationError as exc:
        errs = [f"{'.'.join(str(p) for p in e['loc'])}: {e['msg']}" for e in exc.errors()[:3]]
        return None, "invalid: " + "; ".join(errs)


def _newer(incoming: datetime, stored: datetime | None) -> bool:
    return stored is None or incoming > stored


def apply_push(db: Session, req: PushRequest) -> PushOutcome:
    """Apply the payload to `db` (flushes, never commits)."""
    out = PushOutcome()
    now = utcnow()
    for raw in req.dictionary:
        rec, err = _parse(DictionaryIn, raw)
        out.results.append(
            _result("dictionary", raw.get("id"), "rejected", err) if err else _dictionary(db, rec)
        )
        db.flush()
    for raw in req.receipts:
        rec, err = _parse(ReceiptIn, raw)
        out.results.append(
            _result("receipt", raw.get("id"), "rejected", err)
            if err
            else _receipt(db, rec, req.device_id, now)
        )
        db.flush()
    for raw in req.line_items:
        rec, err = _parse(LineItemIn, raw)
        out.results.append(
            _result("line_item", raw.get("id"), "rejected", err)
            if err
            else _line_item(db, rec, now)
        )
        db.flush()
    return out


def _dictionary(db: Session, rec: DictionaryIn) -> PushResult:
    path = (rec.category, rec.subcategory, rec.item_group)
    if all(path) and not get_taxonomy().contains(Path3(*path)):  # type: ignore[arg-type]
        return _result(
            "dictionary", rec.id, "rejected", "unknown category path " + " > ".join(path)
        )  # type: ignore[arg-type]
    row = db.get(ItemDictionary, rec.id)
    if row is not None and not _newer(rec.updated_at, row.updated_at):
        return _result("dictionary", rec.id, "stale")
    if rec.deleted_at is None:
        clash = db.scalar(
            select(ItemDictionary.id).where(
                ItemDictionary.canonical_name == rec.canonical_name,
                ItemDictionary.deleted_at.is_(None),
                ItemDictionary.id != rec.id,
            )
        )
        if clash is not None:
            return _result(
                "dictionary",
                rec.id,
                "rejected",
                f"canonical_name already used by entry {clash}; merge into it instead",
            )
    if row is None:
        row = ItemDictionary(id=rec.id, created_at=rec.updated_at, times_seen=1)
        db.add(row)
    row.canonical_name = rec.canonical_name
    row.display_name_de = rec.display_name_de
    row.translation_en = rec.translation_en
    row.category = rec.category
    row.subcategory = rec.subcategory
    row.item_group = rec.item_group
    # the server adds aliases while extracting; a push only ever adds to them
    row.aliases = list(dict.fromkeys([*(row.aliases or []), *rec.aliases]))
    row.is_manual_override = rec.is_manual_override
    row.needs_review = rec.needs_review
    row.deleted_at = rec.deleted_at
    row.updated_at = rec.updated_at
    return _result("dictionary", rec.id, "applied")


def _receipt(db: Session, rec: ReceiptIn, device_id: str, now: datetime) -> PushResult:
    row = db.get(Receipt, rec.id)
    if row is not None and not _newer(rec.updated_at, row.updated_at):
        return _result("receipt", rec.id, "stale")
    has_content = any(
        v is not None for v in (rec.store, rec.date, rec.time, rec.total, rec.reviewed_at)
    )
    if row is None:
        row = Receipt(id=rec.id, created_at=rec.updated_at, photo_location=rec.photo_location)
        if rec.photo_location == "archived":
            row.archived_at, row.archived_by = now, device_id
        db.add(row)
        if has_content:
            row.user_edited_at = now
    else:
        row.user_edited_at = now
    row.store = rec.store
    row.date = rec.date
    row.time = rec.time
    row.total = rec.total
    row.computed_sum = rec.computed_sum
    row.needs_review = rec.needs_review
    row.review_reasons = list(rec.review_reasons)
    row.reviewed_at = rec.reviewed_at
    row.deleted_at = rec.deleted_at
    row.updated_at = rec.updated_at
    return _result("receipt", rec.id, "applied")


def _line_item(db: Session, rec: LineItemIn, now: datetime) -> PushResult:
    receipt = db.get(Receipt, rec.receipt_id)
    if receipt is None:
        return _result("line_item", rec.id, "rejected", f"unknown receipt_id {rec.receipt_id}")
    if db.get(ItemDictionary, rec.item_dictionary_id) is None:
        return _result(
            "line_item", rec.id, "rejected", f"unknown item_dictionary_id {rec.item_dictionary_id}"
        )
    row = db.get(LineItem, rec.id)
    if row is not None and not _newer(rec.updated_at, row.updated_at):
        return _result("line_item", rec.id, "stale")
    if row is not None and row.receipt_id != rec.receipt_id:
        return _result(
            "line_item", rec.id, "rejected", "receipt_id of an existing item cannot change"
        )
    if row is None:
        row = LineItem(id=rec.id, receipt_id=rec.receipt_id)
        db.add(row)
    row.item_dictionary_id = rec.item_dictionary_id
    row.position = rec.position
    row.raw_text = rec.raw_text
    row.name_de = rec.name_de
    row.quantity = rec.quantity
    row.unit_price = rec.unit_price
    row.total_price = rec.total_price
    row.price_normalized = rec.price_normalized
    row.deleted_at = rec.deleted_at
    row.updated_at = rec.updated_at
    receipt.user_edited_at = now
    return _result("line_item", rec.id, "applied")
