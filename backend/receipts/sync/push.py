"""`POST /api/v1/receipts/sync/push`: per-record last-write-wins upserts of what a client edited.

Rules (docs/api/receipts.md): upsert by client uuid; the incoming record wins only if its
`updated_at` is strictly newer than the stored one (equal or older -> `stale`, nothing changes,
which also makes re-pushing a payload a no-op); a record that fails validation is `rejected`
alone; `deleted_at` is a tombstone (rows are never removed); everything runs in one transaction.
Order: taxonomy additions (a dictionary entry of the same request may use the new path),
dictionary entries, receipts, line items (they reference the former).

Server-owned fields (photo, archive, extraction state, usage counters) are never taken from a push.
A push that is applied to a receipt or one of its line items marks the receipt as user-edited
(`user_edited_at`), which makes every later extraction (retry included) leave its content alone.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

from pydantic import BaseModel, ValidationError
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from core.db import utcnow
from receipts.db.models import ItemDictionary, LineItem, Receipt, TaxonomyAddition
from receipts.extraction.taxonomy import Path3, Taxonomy, get_taxonomy, merged_taxonomy
from receipts.sync.schemas import (
    DictionaryIn,
    LineItemIn,
    PushRequest,
    PushResult,
    ReceiptIn,
)


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
    for index, raw in enumerate(req.taxonomy_additions):
        out.results.append(_taxonomy_addition(db, raw, req.device_id, now, index))
        db.flush()
    taxonomy = merged_taxonomy(db) if req.dictionary else get_taxonomy()
    for raw in req.dictionary:
        rec, err = _parse(DictionaryIn, raw)
        out.results.append(
            _result("dictionary", raw.get("id"), "rejected", err)
            if err
            else _dictionary(db, rec, taxonomy)
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


MAX_ADDITIONS = 300  # stored additions in total
MAX_PART = 60
MAX_FLAG_TEXT = 80  # column width of the suggestions


def _valid_part(value: Any) -> str | None:
    """A trimmed path part, or None when it is not usable (not text, empty, > 60 chars, contains
    ">" or a control character)."""
    if not isinstance(value, str):
        return None
    part = value.strip()
    if not part or len(part) > MAX_PART or ">" in part:
        return None
    if any(unicodedata.category(c) == "Cc" for c in part):
        return None
    return part


def _taxonomy_addition(
    db: Session, raw: dict[str, Any], device_id: str, now: datetime, index: int
) -> PushResult:
    parts = [raw.get(k) for k in ("category", "subcategory", "item_group")]
    label = " > ".join(p.strip() if isinstance(p, str) else "" for p in parts)
    rid = label if any(isinstance(p, str) and p.strip() for p in parts) else None
    clean = [_valid_part(p) for p in parts]
    if any(p is None for p in clean):
        return _result(
            "taxonomy_addition",
            rid,
            "rejected",
            "category, subcategory and item_group must each be 1-60 characters, "
            "without '>' or control characters",
        )
    path = Path3(*clean)  # type: ignore[arg-type]
    taxonomy = merged_taxonomy(db)  # base + what is stored so far (flushed)
    if taxonomy.contains_ci(path) is not None:
        return _result("taxonomy_addition", path.label, "stale", "path already exists")
    if db.scalar(select(func.count()).select_from(TaxonomyAddition)) >= MAX_ADDITIONS:
        return _result(
            "taxonomy_addition", path.label, "rejected", f"at most {MAX_ADDITIONS} additions"
        )
    # an existing category / subcategory keeps its spelling (no "household" next to "Household")
    cat = next((c for c in taxonomy.categories if c[0].lower() == path.category.lower()), None)
    if cat is not None:
        sub = next((n for n, _ in cat[1] if n.lower() == path.subcategory.lower()), None)
        path = Path3(cat[0], sub or path.subcategory, path.item_group)
    # additions of one request keep their order (pull sorts by created_at, then id)
    created = now + timedelta(microseconds=index)
    if isinstance(raw.get("created_at"), str):
        try:
            parsed = datetime.fromisoformat(raw["created_at"].replace("Z", "+00:00"))
            created = (
                parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)
            )
        except ValueError:
            pass
    db.add(
        TaxonomyAddition(
            category=path.category,
            subcategory=path.subcategory,
            item_group=path.item_group,
            created_at=created,
            device_id=device_id,
        )
    )
    return _result("taxonomy_addition", path.label, "applied")


def _flag_text(value: str | None) -> str | None:
    text = " ".join((value or "").split())
    return text[:MAX_FLAG_TEXT] or None


def _dictionary(db: Session, rec: DictionaryIn, taxonomy: Taxonomy) -> PushResult:
    path = (rec.category, rec.subcategory, rec.item_group)
    if all(path) and not taxonomy.contains(Path3(*path)):  # type: ignore[arg-type]
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
    sent = rec.model_fields_set
    flag_sent = "category_flagged" in sent and rec.category_flagged is not None
    if row is None:
        row = ItemDictionary(id=rec.id, created_at=rec.updated_at, times_seen=1)
        db.add(row)
        flagged, suggested_category, suggested_parent = False, None, None
    else:
        flagged = bool(row.category_flagged)
        suggested_category, suggested_parent = row.suggested_category, row.suggested_parent
        if path != (row.category, row.subcategory, row.item_group) and not flag_sent:
            # a client that predates the flag chose another category: that resolves the flag
            flagged, suggested_category, suggested_parent = False, None, None
    # fields present in the push win (also over the clearing above)
    if flag_sent:
        flagged = bool(rec.category_flagged)
    if "suggested_category" in sent and (flag_sent or flagged):
        suggested_category = rec.suggested_category
    if "suggested_parent" in sent and (flag_sent or flagged):
        suggested_parent = rec.suggested_parent
    row.category_flagged = flagged
    row.suggested_category = _flag_text(suggested_category) if flagged else None
    row.suggested_parent = _flag_text(suggested_parent) if flagged else None
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
