"""Prompts of the extraction pipeline, ported verbatim from the Mac app (Pipeline/ReceiptExtractor.swift
and Pipeline/ItemCategorizer.swift) so extraction quality is unchanged. Do not reword them here:
change the Mac source of truth first (a test pins these texts to their Swift originals when the
Mac sources are present)."""

from __future__ import annotations

from typing import Any

EXTRACTION_PROMPT = r"""You are an expert OCR and data extraction AI. You are looking at a photo of a German supermarket or drugstore receipt (e.g., Aldi, Edeka, dm, Rewe, Lidl).

Extract ONLY the shopping information into this exact JSON structure and nothing else:

{
  "store": "<store name, e.g. 'Aldi Sud', 'Edeka', 'dm-drogerie markt'>",
  "date": "<YYYY-MM-DD>",
  "time": "<HH:MM or null if unclear>",
  "items": [
    {
      "raw_text": "<the original OCR line(s) for this item, uncorrected>",
      "name": "<your best-guess cleaned-up German item name, fixing obvious OCR typos>",
      "quantity": <number of units purchased - see rules below>,
      "unit_price": <price per single unit as a number, e.g. 1.25>,
      "total_price": <quantity x unit_price, as a number>
    }
  ],
  "total": <the printed total for the whole receipt - always positive - as a number>,
  "printed_item_count": <the article/item count printed on the receipt, e.g., from "22 Artikel" or "Posten: 9" - as an integer, or null if not visible>
}

CRITICAL RULES - Read carefully. These are the strict boundaries for your extraction:

1. STRICT 1:1 LINE MAPPING (NO CONSOLIDATING). If the exact same product appears on multiple separate lines on the receipt, you MUST output a separate JSON object for EACH physical line. Do not group, merge, or sum them together just because they are the same item. We need a perfect 1:1 representation of the physical paper.

2. QUANTITY IS 1 BY DEFAULT. Only output a quantity other than 1 if there is an EXPLICIT multiplier printed on the receipt for that specific item (e.g., a line saying "2 x 0.99", or a weight calculation like "0.804 kg x 1.99"). If a product is just listed multiple times on consecutive lines, keep its quantity as 1 and make multiple item entries.

3. PACKAGING SIZES ARE NOT QUANTITIES. A number inside a product name (e.g., "2x70" in "Duo Sensitiv2x70") describes the package size as printed on the label (2 packs of 70ml), not how many the customer bought. Ignore these numbers for the quantity field.

4. WEIGHT-BASED ITEMS usually print a second line below the item showing the calculation, e.g., "0,804 kg x 1,99 €/kg". This belongs to that single item's price calculation. Use it to get that item's quantity (0.804) and unit_price (1.99), and do not let it shift which price belongs to the next item.

5. QUANTITY IS ALWAYS POSITIVE. Never make quantity negative. For refunds, discounts, or deposit returns (Leergut, Rabatt), keep the quantity positive (usually 1) and make the unit_price and total_price NEGATIVE instead.

6. PFAND (DEPOSIT) IS POSITIVE when buying a bottle - it's money paid, same sign as any other item. It is only NEGATIVE when explicitly showing a minus sign (e.g., "-0,15" for a return). Pfand is its own separate item row - never merge it into the drink it belongs to. Standard German deposit amounts are 0.08, 0.15, 0.25, or 1.50.

7. NEVER MERGE TWO DIFFERENT PRODUCTS. If you see two different product names, they are two separate entries, even if you can only find one price nearby. Make your best guess for each rather than combining them.

8. THE TOTAL comes ONLY from the number next to "SUMME", "SUMME EUR", or "SUMME €". Do NOT use a payment method line (e.g., "VISA EUR", "Geg. Mastercard") even if it shows a similar or negative number. The total you report must always be positive.

9. PRODUCT CODES ARE NEVER PRICES. Item lines are often prefixed with a 5-8 digit product code (e.g., "205137 Bio Eier"). Never read this code as a price. A price always has exactly 2 decimal places.

10. PREFER UNAMBIGUOUS DATES. If the receipt shows a timestamp in "YYYY-MM-DD HH:MM:SS" format (often near "Start", "Ende", or "TSE"), use it. It is much more reliable than trying to read a blurry "DD.MM.YYYY" header.

11. STOP EXTRACTING AT THE TOTAL. The item list ends exactly when you see the subtotal or total (e.g., "SUMME", "ZU ZAHLEN", "BAR", "KARTENZAHLUNG"). NEVER include payment details, change given, or footer metadata like "K-U-N-D-E-N-B-E-L-E-G", "TSE", "MwSt", or "Auf Wiedersehen" as items.

12. BEWARE OF STUTTERING ON REPEATED ITEMS. If the receipt shows a repetitive pattern (e.g., multiple consecutive lines of the same Beer and Pfand), you must count the EXACT number of physical pairs on the paper. Do not accidentally output 5 pairs if there are only 4 on the receipt. Verify your count against the image before writing the JSON.

13. EVERY ITEM MUST HAVE A PRICE. If a line of text on the receipt does not have a clear monetary value attached to it, it is not a purchasable product (it is likely a header, description, or footer). Do not extract it as an item.

WORKED EXAMPLE:
Imagine a receipt showing a Cola with an explicit multiplier line ("2 x 0,99" above "400123 Cola 6x1,5L"), followed by two SEPARATE rows of "Pfand" at 0,25 each, a "Leergut" return of -0,50, "Bananen" priced by weight as "0,804 kg x 1,99 €/kg", "Posten: 5", a "Start: 2026-03-01 09:12:00" timestamp, and a total of "SUMME EUR 3,58".

The correct extraction is:

{
  "store": "Example Markt",
  "date": "2026-03-01",
  "time": "09:12",
  "items": [
    {"raw_text": "2 x 0,99 \n 400123 Cola 6x1,5L", "name": "Cola 6x1,5L", "quantity": 2, "unit_price": 0.99, "total_price": 1.98},
    {"raw_text": "Pfand 0,25", "name": "Pfand", "quantity": 1, "unit_price": 0.25, "total_price": 0.25},
    {"raw_text": "Pfand 0,25", "name": "Pfand", "quantity": 1, "unit_price": 0.25, "total_price": 0.25},
    {"raw_text": "Leergut -0,50", "name": "Leergut", "quantity": 1, "unit_price": -0.50, "total_price": -0.50},
    {"raw_text": "Bananen / 0,804 kg x 1,99 €/kg", "name": "Bananen", "quantity": 0.804, "unit_price": 1.99, "total_price": 1.60}
  ],
  "total": 3.58,
  "printed_item_count": 5
}

Notice in the example: The Cola received a quantity of 2 because of the explicit "2 x 0,99" multiplier text (Rule 2). The two Pfand items were kept as separate entries with a quantity of 1 because they were separate lines on the receipt (Rule 1).

Respond with ONLY the JSON object, no explanation, no markdown code fences."""

ABBREVIATION_GLOSSARY = """Common German receipt abbreviations - expand these mentally before translating:
- Deo = Deodorant
- ToiPa = Toilettenpapier (toilet paper)
- Feu. = Feuchtigkeit(s)- (moisture/moisturizing) - NOT "Feuer" (fire)
- SH = Shampoo
- Duo = pack of 2
- LSF = Lichtschutzfaktor (SPF / sun protection factor)
- St. = Stück (piece) or Stift (stick)
- Rd = Rinder- (beef)
- Alkf. = alkoholfrei (non-alcoholic)
- Einw. = Einweg (single-use/disposable)
- Bio = organic
- Bio E.Reg. = organic regional (Bio Eigenmarke Regional) - a label, not the product
- Hä. = Hähnchen (chicken)
- Zungenreiniger = tongue cleaner
- G&G / Gut&Günstig, Ja!, K-Classic, Rewe Beste Wahl = supermarket house brands, not the product type"""

CLASSIFY_PROMPT_TEMPLATE = """You are classifying German supermarket/drugstore items into a fixed category tree, and translating each item's name to natural English.

%%STORE_CONTEXT%%

%%GLOSSARY%%

Items (German), each with its index in square brackets:
%%ITEM_LIST%%

For each item, first mentally expand any abbreviations or brand names in its name using the glossary above. Then translate what the product actually IS in natural English - not a literal word-for-word translation of the abbreviation.

Below is a numbered list of the ONLY valid categories. For each item pick the single number that best matches - never invent a new category and never describe the item in that field, just give its number.

%%TAXONOMY_LIST%%

Rules:
- Classify by how it is sold and shopped, not strict biology (e.g. tomatoes, cucumbers, zucchini go under Vegetables even though botanically fruits).
- Brand names and product-line marketing terms (e.g. "PRO+") don't affect the category - look at what the product actually is, not what it's called.
- Classify each item on its own; being on the same receipt says nothing about its category.
- Oats (Haferflocken) and muesli are Pantry > Cereals & Muesli, never vegetables.
- Baking paper (Backpapier) is a household foil/paper item, not kitchen roll.
- If genuinely unsure, use the number for "Other > Miscellaneous > General".

Respond with ONLY this JSON, no explanation, no markdown fences - exactly one entry per item, using the item's index from the square brackets:
{
  "items": [
    {
      "index": <the item's index>,
      "translation_en": "<natural English translation of what the product actually is>",
      "path_number": <the single number from the category list above, as an integer>
    }
  ]
}"""

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


def _nullable(type_: str, description: str) -> dict[str, Any]:
    return {"type": [type_, "null"], "description": description}


def extraction_schema() -> dict[str, Any]:
    """The JSON structure EXTRACTION_PROMPT asks for, as a schema for structured output
    (ReceiptExtractor.outputSchema). Nullable where the prompt allows null / unclear values."""
    item = {
        "type": "object",
        "properties": {
            "raw_text": {
                "type": "string",
                "description": "The original OCR line(s) for this item, uncorrected",
            },
            "name": {"type": "string", "description": "Best-guess cleaned-up German item name"},
            "quantity": {
                "type": "number",
                "description": "Units purchased; 1 unless an explicit multiplier or weight is printed",
            },
            "unit_price": {
                "type": "number",
                "description": "Price per single unit; negative for returns/discounts",
            },
            "total_price": {"type": "number", "description": "quantity x unit_price"},
        },
        "required": ["raw_text", "name", "quantity", "unit_price", "total_price"],
        "additionalProperties": False,
    }
    return {
        "type": "object",
        "properties": {
            "store": _nullable("string", "Store name"),
            "date": _nullable("string", "Purchase date, YYYY-MM-DD"),
            "time": _nullable("string", "Purchase time, HH:MM, or null if unclear"),
            "items": {"type": "array", "items": item},
            "total": _nullable("number", "Printed SUMME total, always positive"),
            "printed_item_count": _nullable(
                "integer", "Article count printed on the receipt, or null if not visible"
            ),
        },
        "required": ["store", "date", "time", "items", "total", "printed_item_count"],
        "additionalProperties": False,
    }


def classification_schema(item_count: int, path_numbers: list[int]) -> dict[str, Any]:
    """Schema of the batched classification answer (ItemCategorizer.classificationSchema):
    `index` and `path_number` are limited to valid values."""
    entry = {
        "type": "object",
        "properties": {
            "index": {
                "type": "integer",
                "enum": list(range(1, max(item_count, 1) + 1)),
                "description": "The item's index from the item list",
            },
            "translation_en": {
                "type": "string",
                "description": "Natural English translation of what the product actually is",
            },
            "path_number": {
                "type": "integer",
                "enum": path_numbers,
                "description": "Number of the chosen category from the category list",
            },
        },
        "required": ["index", "translation_en", "path_number"],
        "additionalProperties": False,
    }
    return {
        "type": "object",
        "properties": {"items": {"type": "array", "items": entry}},
        "required": ["items"],
        "additionalProperties": False,
    }
