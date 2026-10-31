"""One extraction: photo -> vision call -> validation -> categorisation -> stored result.

Port of ReceiptPipeline.swift's `extractAndCategorize` / `flagPossibleDuplicate` / `processReceipt`
minus what the clients do on the device (scanning / straightening, HEIC conversion). Differences
that matter on a server:

- The result is applied with ONE conditional UPDATE (`... WHERE user_edited_at IS NULL`). When a
  client pushed an edit to the receipt or its items in the meantime (or before a retry), the
  edit stays untouched and the raw result is only stored in `extraction_result`. An extraction
  therefore never overwrites a user's edit; this holds for the first run and for every retry.
- Applying replaces the receipt's line items by tombstoning the old rows and inserting new ones,
  so clients see both through pull. `updated_at` (the LWW clock of client writes) is not touched.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from sqlalchemy import func, select, update
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session, sessionmaker

from core.db import utcnow
from receipts import photos
from receipts.db.models import LineItem, Receipt
from receipts.extraction.categorize import resolve_items
from receipts.extraction.prompts import (
    EXTRACTION_MAX_OUTPUT_TOKENS,
    EXTRACTION_PROMPT,
    extraction_schema,
)
from receipts.extraction.taxonomy import Taxonomy
from receipts.extraction.validate import (
    ExtractedReceipt,
    InvalidExtraction,
    parse_response,
    validate_receipt,
)
from receipts.llm.base import LLMError, LLMProvider
from receipts.settings import ReceiptsSettings

log = logging.getLogger(__name__)

# Chain names the extraction can produce (ReceiptPipeline.storeNameMap, copied verbatim).
STORE_NAME_MAP = {
    "edeka": "Edeka",
    "aldi sud": "Aldi Süd",
    "aldi süd": "Aldi Süd",
    "aldi nord": "Aldi Nord",
    "dm-drogerie markt": "dm",
    "dm": "dm",
    "rewe": "Rewe",
    "lidl": "Lidl",
    "penny-markt gmbh": "Penny",
    "penny": "Penny",
    "rossmann": "Rossmann",
    "kaufland": "Kaufland",
}


def canonicalize_store(raw: str | None) -> str:
    if raw is None:
        return "Unknown"
    trimmed = raw.strip(" \t")
    if not trimmed:
        return "Unknown"
    return STORE_NAME_MAP.get(trimmed.lower(), trimmed)


@dataclass(frozen=True)
class ExtractionResult:
    applied: bool  # False: the user's edits were kept and the result only stored for reference
    provider_id: str | None


def extract_and_validate(provider: LLMProvider, image: bytes, media_type: str) -> ExtractedReceipt:
    """Vision call, retried once on invalid JSON (same policy as the Mac app)."""
    schema = extraction_schema()
    for attempt in (1, 2):
        response = provider.extract_receipt(
            image, media_type, EXTRACTION_PROMPT, schema, EXTRACTION_MAX_OUTPUT_TOKENS
        )
        try:
            parsed = parse_response(response.text)
        except InvalidExtraction:
            log.warning("receipts extraction: invalid JSON from the model (attempt %d)", attempt)
            continue
        parsed.provider_id = response.provider_id
        return validate_receipt(parsed)
    raise LLMError(
        "invalid_output",
        "The model did not return valid JSON, also not on the second try.",
        retryable=True,
    )


def flag_possible_duplicate(db: Session, extracted: ExtractedReceipt, receipt_id: str) -> None:
    """Same store + date + total as another live receipt: still import it, but flag it. Time is
    ignored on purpose (the model misreads digits), and this only flags, never drops."""
    if extracted.date is None or extracted.total is None:
        return
    dup = db.scalar(
        select(Receipt.id)
        .where(
            Receipt.deleted_at.is_(None),
            Receipt.store == extracted.store,
            Receipt.date == extracted.date,
            func.abs(Receipt.total - extracted.total) < 0.005,
            Receipt.id != receipt_id,
        )
        .order_by(Receipt.created_at, Receipt.id)
        .limit(1)
    )
    if dup is not None:
        extracted.review_reasons.append(f"Possible duplicate of receipt {dup}")
        extracted.needs_review = True


def run_extraction(
    session_factory: sessionmaker[Session],
    receipt_id: str,
    provider: LLMProvider,
    taxonomy: Taxonomy,
    settings: ReceiptsSettings,
) -> ExtractionResult:
    with session_factory() as db:
        receipt = db.get(Receipt, receipt_id)
        if receipt is None:
            raise LLMError("receipt_missing", "The receipt no longer exists.")
        if receipt.photo_location != "server" or not receipt.photo_path:
            raise LLMError(
                "photo_missing",
                "The photo is not on the server (already archived on the laptop, or never "
                "uploaded), so it cannot be extracted again.",
            )
        relpath, media_type = receipt.photo_path, receipt.photo_media_type or photos.JPEG
    try:
        image = photos.read_photo(settings.receipts_photos_dir, relpath)
    except FileNotFoundError:
        raise LLMError("photo_missing", "The photo file is missing on the server.") from None

    extracted = extract_and_validate(provider, image, media_type)
    extracted.store = canonicalize_store(extracted.store)
    item_names = [i.name or i.raw_text or "" for i in extracted.items]

    # Dictionary entries are a shared cache: committed on their own, so entries created for a
    # receipt whose result is then not applied are harmless.
    with session_factory() as db:
        entries, classification_providers = resolve_items(
            db, item_names, taxonomy, extracted.store, provider
        )
        db.commit()
        entry_ids = [e.id for e in entries]

    for attempt in (1, 2, 3):
        try:
            return _apply(
                session_factory,
                receipt_id,
                extracted,
                item_names,
                entry_ids,
                classification_providers,
            )
        except OperationalError:  # a writer got in between our read and write: just try again
            if attempt == 3:
                raise
            log.warning("receipts extraction: database busy while applying, retrying")
    raise AssertionError("unreachable")


def _apply(
    session_factory: sessionmaker[Session],
    receipt_id: str,
    extracted: ExtractedReceipt,
    item_names: list[str],
    entry_ids: list[str],
    classification_providers: list[str],
) -> ExtractionResult:
    now = utcnow()
    with session_factory() as db:
        flag_possible_duplicate(db, extracted, receipt_id)
        result_json = extracted.to_json(classification_providers=classification_providers)
        res = db.execute(
            update(Receipt)
            .where(Receipt.id == receipt_id, Receipt.user_edited_at.is_(None))
            .values(
                store=extracted.store,
                date=extracted.date,
                time=extracted.time,
                total=extracted.total,
                computed_sum=extracted.computed_sum,
                needs_review=extracted.needs_review,
                review_reasons=list(extracted.review_reasons),
                reviewed_at=None,
                extraction_provider=extracted.provider_id,
                extraction_completed_at=now,
                extraction_result=result_json,
            )
            .execution_options(synchronize_session=False)
        )
        applied = res.rowcount == 1
        if applied:
            db.execute(
                update(LineItem)
                .where(LineItem.receipt_id == receipt_id, LineItem.deleted_at.is_(None))
                .values(deleted_at=now)
                .execution_options(synchronize_session=False)
            )
            for position, (item, name, entry_id) in enumerate(
                zip(extracted.items, item_names, entry_ids, strict=True)
            ):
                db.add(
                    LineItem(
                        receipt_id=receipt_id,
                        item_dictionary_id=entry_id,
                        position=position,
                        raw_text=item.raw_text,
                        name_de=name,
                        quantity=item.quantity if item.quantity is not None else 1.0,
                        unit_price=item.unit_price if item.unit_price is not None else 0.0,
                        total_price=item.total_price if item.total_price is not None else 0.0,
                        price_normalized=item.price_normalized,
                        updated_at=now,
                    )
                )
        else:
            # The user edited this receipt: keep the edits, store the result for reference only.
            db.execute(
                update(Receipt)
                .where(Receipt.id == receipt_id)
                .values(
                    extraction_provider=extracted.provider_id,
                    extraction_completed_at=now,
                    extraction_result=result_json,
                )
                .execution_options(synchronize_session=False)
            )
        db.commit()
    return ExtractionResult(applied, extracted.provider_id)
