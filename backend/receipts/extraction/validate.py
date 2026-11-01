"""Extraction models and the validation checks, ported from ReceiptExtractor.swift /
ExtractionModels.swift (themselves ports of scan_and_parse_receipt.py): Pfand normalisation, sum
mismatch, per-line math, quantities. The review reasons are the same texts the Mac app shows."""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any

from receipts.extraction.jsonutil import (
    coerce_float,
    coerce_int,
    coerce_str,
    extract_object,
    round2,
)

SUM_MISMATCH_TOLERANCE = 0.02
KNOWN_PFAND_VALUES = (0.08, 0.15, 0.25, 1.50)
PFAND_AUTOCORRECT_THRESHOLD = 0.10


# Sign plausibility (shifted price column). Names are folded to ASCII words (lower case, umlauts and
# accents dropped, ss for the sharp s) and matched word by word, never as substrings of the whole
# name. Mirrors ReceiptExtractor.swift; both run the table in tests/test_receipts_sign_checks.py.
_DEPOSIT_RETURN_PREFIXES = (
    "leergut", "pfandbon", "pfandruck", "pfandrueck", "pfanderstatt", "pfandgutschrift",
    "pfandzuruck", "pfandzurueck", "pfandeinlos", "ruckpfand", "rueckpfand",
)  # fmt: skip
_DEPOSIT_RETURN_WORDS = (
    "zuruck", "zurueck", "ruckgabe", "rueckgabe", "ruckerstattung", "rueckerstattung",
    "erstattung", "ruckzahlung", "rueckzahlung", "gutschrift", "bon", "einlosung", "einloesung",
)  # fmt: skip
# Legitimately negative lines: a word starting or ending with one of these.
_NEGATIVE_OK_STEMS = (
    "rabatt", "coupon", "gutschein", "gutschrift", "nachlass", "storno", "bonus",
    "payback", "ersparnis", "korrektur", "retoure", "umtausch", "erstattung", "abzug",
    "skonto", "ruckgabe", "rueckgabe", "abschlag", "preissenkung", "cashback",
)  # fmt: skip
# Only at the start of a word ("Aktionsware" yes, "Reaktion" no).
_NEGATIVE_OK_PREFIXES = ("aktion", "storn", "reduzier", "punkte", "treue")
# Only at the end of a word ("Preisvorteil" yes, "Vorteilspack" no).
_NEGATIVE_OK_SUFFIXES = ("vorteil",)
# Whole words only (abbreviations printed on receipts).
_NEGATIVE_OK_WORDS = ("rab", "rabt", "gutsch", "gutschr", "korr")


def _name_words(name: str | None) -> list[str]:
    decomposed = unicodedata.normalize("NFD", (name or "").lower())
    folded = "".join(c for c in decomposed if not unicodedata.combining(c)).replace("ß", "ss")
    return [w for w in re.split(r"[^a-z0-9]+", folded) if w]


def _is_pfand_word(w: str) -> bool:
    return w.startswith("pfand") or w.endswith("pfand")


def is_deposit_return_name(name: str | None) -> bool:
    words = _name_words(name)
    if any(w.startswith(_DEPOSIT_RETURN_PREFIXES) for w in words):
        return True
    return any(_is_pfand_word(w) for w in words) and any(w in _DEPOSIT_RETURN_WORDS for w in words)


def _is_deposit_name(name: str | None) -> bool:
    words = _name_words(name)
    return is_deposit_return_name(name) or any(
        _is_pfand_word(w) or w.startswith("leergut") for w in words
    )


def is_legit_negative_name(name: str | None) -> bool:
    if _is_deposit_name(name):
        return True
    for w in _name_words(name):
        if w in _NEGATIVE_OK_WORDS or w.startswith(_NEGATIVE_OK_PREFIXES):
            return True
        if w.endswith(_NEGATIVE_OK_SUFFIXES):
            return True
        if any(w.startswith(s) or w.endswith(s) for s in _NEGATIVE_OK_STEMS):
            return True
    return False


class InvalidExtraction(ValueError):
    """The model's answer contained no JSON object."""


@dataclass
class ExtractedItem:
    raw_text: str | None = None
    name: str | None = None
    quantity: float | None = None
    unit_price: float | None = None
    total_price: float | None = None
    price_normalized: bool = False

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> ExtractedItem:
        return cls(
            raw_text=coerce_str(d.get("raw_text")),
            name=coerce_str(d.get("name")),
            quantity=coerce_float(d.get("quantity")),
            unit_price=coerce_float(d.get("unit_price")),
            total_price=coerce_float(d.get("total_price")),
        )


@dataclass
class ExtractedReceipt:
    store: str | None = None
    date: str | None = None
    time: str | None = None
    items: list[ExtractedItem] = field(default_factory=list)
    total: float | None = None
    printed_item_count: int | None = None
    computed_sum: float = 0.0
    needs_review: bool = False
    review_reasons: list[str] = field(default_factory=list)
    provider_id: str | None = None

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> ExtractedReceipt:
        raw_items = d.get("items")
        items = (
            [ExtractedItem.from_dict(i) for i in raw_items if isinstance(i, dict)]
            if isinstance(raw_items, list)
            else []
        )
        return cls(
            store=coerce_str(d.get("store")),
            date=coerce_str(d.get("date")),
            time=coerce_str(d.get("time")),
            items=items,
            total=coerce_float(d.get("total")),
            printed_item_count=coerce_int(d.get("printed_item_count")),
        )

    def to_json(self, **extra: Any) -> dict[str, Any]:
        """For `receipts.extraction_result` (the Mac app's debug dump)."""
        d: dict[str, Any] = {
            "extraction_provider": self.provider_id,
            "store": self.store,
            "date": self.date,
            "time": self.time,
            "items": [
                {
                    "raw_text": i.raw_text,
                    "name": i.name,
                    "quantity": i.quantity,
                    "unit_price": i.unit_price,
                    "total_price": i.total_price,
                    "price_normalized": i.price_normalized,
                }
                for i in self.items
            ],
            "total": self.total,
            "printed_item_count": self.printed_item_count,
            "computed_sum": self.computed_sum,
            "needs_review": self.needs_review,
            "review_reasons": list(self.review_reasons),
        }
        d.update(extra)
        return d


def parse_response(raw: str) -> ExtractedReceipt:
    obj = extract_object(raw)
    if obj is None:
        raise InvalidExtraction("no JSON object found")
    return ExtractedReceipt.from_dict(obj)


def validate_receipt(raw: ExtractedReceipt) -> ExtractedReceipt:
    r = raw
    # Rule 13 enforcement: drop anything the model emitted without a clear price.
    r.items = [i for i in r.items if i.unit_price is not None and i.total_price is not None]
    issues: list[str] = []
    _normalize_pfand(r, issues)
    _validate_totals(r, issues)
    _validate_line_math(r, issues)
    _validate_quantities(r, issues)
    _validate_signs(r, issues)
    r.needs_review = bool(issues)
    r.review_reasons = issues
    return r


def _normalize_pfand(r: ExtractedReceipt, issues: list[str]) -> None:
    for item in r.items:
        name = (item.name or "").lower()
        if "pfand" not in name or item.unit_price is None:
            continue
        unit = item.unit_price
        sign = -1.0 if unit < 0 else 1.0
        magnitude = abs(unit)
        closest = min(KNOWN_PFAND_VALUES, key=lambda v: abs(v - magnitude))
        deviation = abs(magnitude - closest)
        if deviation == 0:
            item.price_normalized = False
        elif deviation <= PFAND_AUTOCORRECT_THRESHOLD:
            qty = item.quantity if item.quantity is not None else 1.0
            new_unit = round2(sign * closest)
            item.unit_price = new_unit
            item.total_price = round2(sign * closest * qty)
            item.price_normalized = True
            issues.append(
                f"Pfand item '{item.name or ''}' had unit_price {unit} - corrected to {new_unit}."
            )
        else:
            item.price_normalized = False
            issues.append(
                f"Pfand item '{item.name or ''}' has unit_price {unit}, which isn't close to any "
                "standard German deposit amount - check manually."
            )


def _validate_totals(r: ExtractedReceipt, issues: list[str]) -> None:
    for i, item in enumerate(r.items):
        if item.total_price is None:
            issues.append(f"Item #{i} ({item.name or 'nil'}) has no total_price - treated as 0")
    item_sum = round2(sum((i.total_price or 0.0) for i in r.items))
    r.computed_sum = item_sum
    if r.total is None:
        issues.append("No total found on receipt")
        return
    if r.total < 0:
        issues.append(f"Printed total is negative ({r.total}) - likely picked up payment line")
    diff = round2(abs(item_sum - r.total))
    if diff > SUM_MISMATCH_TOLERANCE:
        issues.append(
            f"Item prices sum to {item_sum}, but printed total is {r.total} "
            f"(difference: {diff}). Check raw_text per item."
        )


def _validate_line_math(r: ExtractedReceipt, issues: list[str]) -> None:
    for i, item in enumerate(r.items):
        qty = item.quantity if item.quantity is not None else 1.0
        unit = item.unit_price if item.unit_price is not None else 0.0
        total = item.total_price if item.total_price is not None else 0.0
        expected = round2(qty * unit)
        if round2(abs(expected - total)) > SUM_MISMATCH_TOLERANCE:
            issues.append(
                f"Item #{i} ({item.name or 'nil'}): {qty} x {unit} = {expected}, "
                f"but total_price is {total}"
            )


def _validate_quantities(r: ExtractedReceipt, issues: list[str]) -> None:
    for i, item in enumerate(r.items):
        qty = item.quantity if item.quantity is not None else 1.0
        if qty <= 0:
            issues.append(
                f"Item #{i} ({item.name or 'nil'}) has quantity {qty} - should be positive"
            )


def _validate_signs(r: ExtractedReceipt, issues: list[str]) -> None:
    """A shifted price column keeps the sum right, so check each line's sign against its name."""
    for i, item in enumerate(r.items):
        total = item.total_price if item.total_price is not None else 0.0
        label = item.name or item.raw_text
        if total > 0 and is_deposit_return_name(label):
            issues.append(
                f"Item #{i} ({item.name or 'nil'}): deposit return has a positive amount {total} - "
                "check whether the price column shifted by a line."
            )
        elif total < 0 and not is_legit_negative_name(label):
            issues.append(
                f"Item #{i} ({item.name or 'nil'}): product has a negative amount {total} - "
                "check whether the price column shifted by a line."
            )
