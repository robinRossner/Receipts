"""JSON of the receipts sync API (contract: docs/api/receipts.md). snake_case, ISO UTC `Z`."""

from __future__ import annotations

from typing import Any

from core.db import iso_z
from receipts.db.models import ItemDictionary, LineItem, Receipt, TaxonomyAddition


def receipt_out(r: Receipt) -> dict[str, Any]:
    return {
        "id": r.id,
        "legacy_id": r.legacy_id,
        "store": r.store,
        "date": r.date,
        "time": r.time,
        "total": r.total,
        "computed_sum": r.computed_sum,
        "needs_review": bool(r.needs_review),
        "review_reasons": list(r.review_reasons or []),
        "reviewed_at": iso_z(r.reviewed_at),
        "created_at": iso_z(r.created_at),
        "photo_location": r.photo_location,
        "photo_sha256": r.photo_sha256,
        "photo_bytes": r.photo_bytes,
        "photo_media_type": r.photo_media_type,
        "uploaded_at": iso_z(r.uploaded_at),
        "archived_at": iso_z(r.archived_at),
        "extraction_status": r.extraction_status,
        "extraction_attempts": r.extraction_attempts,
        "extraction_error": r.extraction_error,
        "extraction_provider": r.extraction_provider,
        "extraction_completed_at": iso_z(r.extraction_completed_at),
        "updated_at": iso_z(r.updated_at),
        "deleted_at": iso_z(r.deleted_at),
    }


def line_item_out(i: LineItem) -> dict[str, Any]:
    return {
        "id": i.id,
        "legacy_id": i.legacy_id,
        "receipt_id": i.receipt_id,
        "item_dictionary_id": i.item_dictionary_id,
        "position": i.position,
        "raw_text": i.raw_text,
        "name_de": i.name_de,
        "quantity": i.quantity,
        "unit_price": i.unit_price,
        "total_price": i.total_price,
        "price_normalized": bool(i.price_normalized),
        "updated_at": iso_z(i.updated_at),
        "deleted_at": iso_z(i.deleted_at),
    }


def dictionary_out(d: ItemDictionary) -> dict[str, Any]:
    return {
        "id": d.id,
        "legacy_id": d.legacy_id,
        "canonical_name": d.canonical_name,
        "display_name_de": d.display_name_de,
        "translation_en": d.translation_en,
        "category": d.category,
        "subcategory": d.subcategory,
        "item_group": d.item_group,
        "aliases": list(d.aliases or []),
        "is_manual_override": bool(d.is_manual_override),
        "needs_review": bool(d.needs_review),
        "category_flagged": bool(d.category_flagged),
        "suggested_category": d.suggested_category,
        "suggested_parent": d.suggested_parent,
        "times_seen": d.times_seen,
        "created_at": iso_z(d.created_at),
        "last_seen_at": iso_z(d.last_seen_at),
        "updated_at": iso_z(d.updated_at),
        "deleted_at": iso_z(d.deleted_at),
    }


def taxonomy_addition_out(a: TaxonomyAddition) -> dict[str, Any]:
    return {
        "category": a.category,
        "subcategory": a.subcategory,
        "item_group": a.item_group,
        "created_at": iso_z(a.created_at),
    }
