"""Prompts and output schemas of the extraction pipeline. They are the versions that were evaluated
against labelled receipts (prompt variant h2_combo: a2_minimal extraction, b2_columns classification),
and the Mac app (Pipeline/ReceiptExtractor.swift, Pipeline/ItemCategorizer.swift) carries the same
texts and schemas. Do not reword them here without re-running that evaluation: a test pins these
texts to their Swift copies when the Mac sources are present.

Extraction relies on the output schema for its JSON shape (the prompt does not spell it out), and
classification relies on the property order of its schema: `identified` before `path_number`.
"""

from __future__ import annotations

from typing import Any

EXTRACTION_PROMPT = """The photo shows a German supermarket or drugstore receipt. Extract the purchase into the JSON schema.

Items: one entry per amount in the right-hand column, in printed order, from the first item down to the line above SUMME. A repeated product stays as separate entries. Text rows with no amount of their own (a supplier note such as "Z9 Beispiel GmbH", a weight row) belong to the item they describe and take no amount. Photos are often tilted, so match amounts to items by their order in the column, not by which name looks level with them. Read every amount from the photo, even when lines repeat in a pattern.
- raw_text: the printed text, uncorrected. name: the German name with OCR typos fixed.
- total_price: the printed amount. unit_price: the price of one unit.
- quantity: 1 unless a multiplier or weight is printed ("3 x 1,50", "0,500 kg x 3,00 €/kg", giving quantity 3 or 0.5). Pack sizes in a name ("6x250") are not quantities.
- Leergut, Rabatt and other refunds: quantity 1 with negative prices. Pfand is its own item and positive unless printed with a minus.
- Numbers of 5-8 digits before a name are product codes, not prices.

Other fields: store as printed. date as YYYY-MM-DD, time as HH:MM or null if unclear; a TSE timestamp is more legible than the header for the date, but one ending in Z is UTC, so take the time from the printed local clock (its minutes can settle an unclear minute there). total: the amount next to SUMME, positive, never a payment line. printed_item_count: the number at "Posten" or "Artikel", else null.

Report what is printed. If a digit is hard to read, give your best reading of that digit alone; never choose a digit because it makes the amounts add up. A sum that does not match SUMME is fine: the app sends that receipt to a person for review."""

CLASSIFY_PROMPT_TEMPLATE = """<task>
For each German supermarket or drugstore item, say what it is, translate it to natural English and choose its number from the category list.
</task>

<context>
%%STORE_CONTEXT%%
</context>

<names>
Receipt names are cut short and run words together. Expand common German shop shortenings from the rest of the name, and never read a shortened word as an unrelated one that starts the same way. House brands and labels (organic, regional) are not the product type.
</names>

<items>
%%ITEM_LIST%%
</items>

<categories>
%%TAXONOMY_LIST%%
</categories>

<fields>
- identified: at most 6 English words naming brand and product type, written before choosing, e.g. "house brand: strawberry jam" or "unknown abbreviation". Use what you know about the brand: it tells you the product even when the words do not.
- translation_en: what the product is, naturally. Expand an abbreviation only if you are sure of it; otherwise keep the printed word as it stands.
- path_number: the group a German shop would sell it under. Follow the form sold: an ice cream brand's product is ice cream whatever flavour the name mentions, tinned or jarred food is not fresh produce, and a spice brand's product is a spice.
</fields>

<flagging>
Answer in this order:
1. Any part of the name is a word you can read, or the brand tells you the kind of product: give your most likely group, no_good_match false. A best guess beats %%FALLBACK%%. Every common grocery, drugstore and household item has a group, even an imperfect one.
2. No word in the name is readable (codes, letter fragments): path_number %%FALLBACK%%, no_good_match false.
3. Only if you know what it is and no listed group is where a shop would sell it, such as fresh flowers, toys, clothing or stationery: path_number %%FALLBACK%%, no_good_match true, suggested_category a short English name of at most 4 words, suggested_parent an existing "Category" or "Category > Subcategory".
Outside case 3, both suggestion fields are empty.
</flagging>

Settle each item quickly; do not weigh it at length. Give one entry per item, with index taken from the square brackets."""

EXTRACTION_MAX_OUTPUT_TOKENS = 2048

# Store type hints for the classification prompt (ItemCategorizer.storeTypeHints, in order).
_DRUGSTORE = "a German drugstore (mostly personal care, household, and health items)"
_SUPERMARKET = "a German supermarket (mostly food and beverages)"
_DISCOUNT = "a German discount supermarket (mostly food and beverages)"
STORE_TYPE_HINTS: list[tuple[str, str]] = [
    ("dm", _DRUGSTORE),
    ("rossmann", _DRUGSTORE),
    ("edeka", _SUPERMARKET),
    ("rewe", _SUPERMARKET),
    ("aldi", _DISCOUNT),
    ("lidl", _DISCOUNT),
    ("kaufland", _SUPERMARKET),
]


def _item_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "raw_text": {"type": "string"},
            "name": {"type": "string"},
            "quantity": {"type": "number"},
            "unit_price": {"type": "number"},
            "total_price": {"type": "number"},
        },
        "required": ["raw_text", "name", "quantity", "unit_price", "total_price"],
        "additionalProperties": False,
    }


def extraction_schema() -> dict[str, Any]:
    """The JSON structure EXTRACTION_PROMPT asks for, as a schema for structured output
    (ReceiptExtractor.outputSchema). Nullable where the prompt allows null / unclear values.
    Deliberately without descriptions: the evaluated version had none."""
    return {
        "type": "object",
        "properties": {
            "store": {"type": ["string", "null"]},
            "date": {"type": ["string", "null"]},
            "time": {"type": ["string", "null"]},
            "items": {"type": "array", "items": _item_schema()},
            "total": {"type": ["number", "null"]},
            "printed_item_count": {"type": ["integer", "null"]},
        },
        "required": ["store", "date", "time", "items", "total", "printed_item_count"],
        "additionalProperties": False,
    }


def classification_schema(item_count: int, path_numbers: list[int]) -> dict[str, Any]:
    """Schema of the batched classification answer (ItemCategorizer.classificationSchema):
    `index` and `path_number` are limited to valid values. Property order is part of the prompt:
    `identified` comes before `translation_en` and `path_number`, so the model names the product
    before it chooses. The evaluated version had no descriptions."""
    properties: dict[str, Any] = {
        "index": {"type": "integer", "enum": list(range(1, max(item_count, 1) + 1))},
        "identified": {"type": "string"},
        "translation_en": {"type": "string"},
        "path_number": {"type": "integer", "enum": path_numbers},
        "no_good_match": {"type": "boolean"},
        "suggested_category": {"type": "string"},
        "suggested_parent": {"type": "string"},
    }
    return {
        "type": "object",
        "properties": {
            "items": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": properties,
                    "required": list(properties),
                    "additionalProperties": False,
                },
            }
        },
        "required": ["items"],
        "additionalProperties": False,
    }
