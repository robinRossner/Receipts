"""`GET /api/v1/receipts/sync/pull`: everything that changed since an opaque cursor.

The cursor is built on `server_seq`, a global monotonic counter stamped on every write by SQLite
triggers (migration 0001), so it is independent of client clocks and of which code path wrote the
row (client push, extraction worker, archive confirmation, migration script). Records of all three
tables are merged by seq and cut into pages. Taxonomy additions are not in the sequence: every
response carries all of them (a short, append-only list).
Cursor forms (clients treat them as opaque):
  ""        start from the beginning (a full snapshot, paged)
  "c<seq>"  everything with a larger seq
"""

from __future__ import annotations

import re
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from core.db import iso_z, utcnow
from receipts.db.models import ItemDictionary, LineItem, Receipt, TaxonomyAddition
from receipts.extraction.taxonomy import Path3, get_taxonomy
from receipts.sync.serialize import (
    dictionary_out,
    line_item_out,
    receipt_out,
    taxonomy_addition_out,
)

PAGE_SIZE = 2000
_CURSOR = re.compile(r"^c(\d+)$")


class BadCursor(ValueError):
    pass


def parse_cursor(since: str | None) -> int:
    if not since:
        return 0
    m = _CURSOR.match(since)
    if not m:
        raise BadCursor("malformed cursor")
    return int(m.group(1))


def pull(db: Session, since: str | None, *, limit: int = PAGE_SIZE) -> dict[str, Any]:
    pos = parse_cursor(since)
    specs: list[tuple[type, str, Any]] = [
        (ItemDictionary, "dictionary", dictionary_out),
        (Receipt, "receipts", receipt_out),
        (LineItem, "line_items", line_item_out),
    ]
    found: list[tuple[int, str, Any]] = []
    for model, key, _ in specs:
        q = (
            select(model)
            .where(model.server_seq > pos)
            .order_by(model.server_seq)
            .limit(limit + 1)
            .execution_options(populate_existing=True)
        )
        found.extend((row.server_seq, key, row) for row in db.scalars(q))
    found.sort(key=lambda t: t[0])
    has_more = len(found) > limit
    page = found[:limit]
    last = page[-1][0] if page else pos
    additions = list(
        db.scalars(
            select(TaxonomyAddition).order_by(TaxonomyAddition.created_at, TaxonomyAddition.id)
        )
    )
    taxonomy = get_taxonomy().with_additions(
        [Path3(a.category, a.subcategory, a.item_group) for a in additions]
    )
    out: dict[str, Any] = {
        "cursor": f"c{last}",
        "has_more": has_more,
        "server_time": iso_z(utcnow()),
        "taxonomy_version": taxonomy.version,
        "taxonomy_additions": [taxonomy_addition_out(a) for a in additions],
        "dictionary": [],
        "receipts": [],
        "line_items": [],
    }
    ser = {key: fn for _, key, fn in specs}
    for _seq, key, row in page:
        out[key].append(ser[key](row))
    return out
