"""The ports of the Mac pipeline: fuzzy matching, name normalisation, taxonomy, keyword rules,
batched classification with its retry, and the prompt texts pinned to the Swift originals."""

from __future__ import annotations

import random
import re
from pathlib import Path

import pytest

from receipts.extraction import fuzzy, prompts
from receipts.extraction.categorize import classify_with_llm, normalize_name, store_context
from receipts.extraction.taxonomy import Path3, get_taxonomy
from receipts.llm.base import LLMResponse
from receipts.settings import RECEIPTS_DIR
from tests.receipts_helpers import path_number

# The Mac/iPhone sources are in this repo (backend/ is one level below the repo root); no skips:
# a missing source file fails the test.
MAC = Path(__file__).resolve().parents[2] / "Sources" / "ReceiptsApp"


# --------------------------------------------------------------------------- fuzzy


def indel_distance(a: str, b: str) -> int:
    """Straight port of FuzzyMatch.indelDistance (the oracle for the bit-parallel version)."""
    n, m = len(a), len(b)
    if n == 0:
        return m
    if m == 0:
        return n
    prev = list(range(m + 1))
    for i in range(1, n + 1):
        cur = [i] + [0] * m
        for j in range(1, m + 1):
            cur[j] = prev[j - 1] if a[i - 1] == b[j - 1] else 1 + min(prev[j], cur[j - 1])
        prev = cur
    return prev[m]


def oracle_ratio(a: str, b: str) -> int:
    sa = " ".join(sorted(a.split(" ")))
    sb = " ".join(sorted(b.split(" ")))
    total = len(sa) + len(sb)
    if total == 0:
        return 100
    return int((100.0 * (total - indel_distance(sa, sb)) / total) + 0.5)


def test_token_sort_ratio_matches_the_swift_algorithm():
    rng = random.Random(7)
    words = ["milch", "bio", "vollmilch", "käse", "gouda", "jogurt", "natur", "bananen", "ß", "x"]
    for _ in range(300):
        a = " ".join(rng.choice(words) for _ in range(rng.randint(1, 4)))
        b = " ".join(rng.choice(words) for _ in range(rng.randint(1, 4)))
        assert fuzzy.token_sort_ratio(a, b) == oracle_ratio(a, b), (a, b)
    assert fuzzy.token_sort_ratio("bio milch", "milch bio") == 100  # token order is ignored
    assert fuzzy.token_sort_ratio("", "") == 100
    assert fuzzy.token_sort_ratio("abc", "") == 0


def test_best_match_pruning_does_not_change_the_answer():
    rng = random.Random(11)
    alphabet = "abcdefghij "
    names = [
        "".join(rng.choice(alphabet) for _ in range(rng.randint(3, 14))).strip() or "a"
        for _ in range(300)
    ]
    for _ in range(60):
        q = rng.choice(names)
        q = q[:-1] + rng.choice(alphabet.strip()) if len(q) > 3 and rng.random() < 0.7 else q
        plain = max(((n, oracle_ratio(q, n)) for n in names), key=lambda t: t[1])
        # extractOne keeps the FIRST best
        first_best = next(n for n in names if oracle_ratio(q, n) == plain[1])
        got = fuzzy.best_match(q, names, floor=90)
        if plain[1] >= 90:
            assert got is not None and got == (first_best, plain[1]), q
        else:
            assert got is None or got[1] < 90


# --------------------------------------------------------------------------- normalisation


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("Vollmilch 1L", "vollmilch"),
        ("BIO Bananen 500g", "bio bananen"),
        ("Käse-Aufschnitt", "käse aufschnitt"),
        ("Cola 6x1,5L", "cola"),
        ("Bio Eier 10er", "bio eier 10er"),
        ("  Joghurt   Natur  ", "joghurt natur"),
        ("Pfand", "pfand"),
    ],
)
def test_normalize_name(raw, expected):
    assert normalize_name(raw) == expected


def test_store_context():
    assert store_context(None) == "The store these items were purchased from is unknown."
    assert store_context("dm") == (
        "These items were purchased at dm, a German drugstore "
        "(mostly personal care, household, and health items)."
    )
    assert "discount supermarket" in store_context("Aldi Süd")
    assert store_context("Corner Shop") == "These items were purchased at Corner Shop."


# --------------------------------------------------------------------------- taxonomy


def test_taxonomy_is_the_mac_resource_and_keeps_its_order():
    tax = get_taxonomy()
    assert [c for c, _ in tax.categories] == ["Food", "Household", "Personal Care", "Other"]
    text, index = tax.numbered_prompt()
    assert text.splitlines()[0].startswith(
        "1. Food > Vegetables > Tomatoes  (note: Includes cherry"
    )
    assert index[1] == Path3("Food", "Vegetables", "Tomatoes")
    assert len(index) == len(tax.flattened()) and len(index) > 60
    assert tax.contains(Path3("Other", "Miscellaneous", "General"))
    assert not tax.contains(Path3("Food", "Pantry", "Moon Cheese"))


def test_taxonomy_has_not_drifted_from_the_mac_app():
    # the server copy must not drift from the Mac app's until clients share one
    mac = MAC / "Resources/category_taxonomy.json"
    assert (RECEIPTS_DIR / "data/category_taxonomy.json").read_bytes() == mac.read_bytes()


@pytest.mark.parametrize(
    ("name", "label"),
    [
        ("summe", "Other > Not a product > Receipt text"),
        ("haferflocken", "Food > Pantry > Cereals & Muesli"),
        ("walnüsse", "Food > Snacks & Sweets > Nuts, Seeds & Dried Fruit"),
        ("skyr natur", "Food > Dairy & Eggs > Yogurt, Skyr & Quark"),
        ("riesling", "Food > Beverages > Wine"),
        ("sonnenmilch lsf 30", "Personal Care > Cosmetics > Sun Care"),
        ("backpapier", "Household > Household Goods > Foils, Baking Paper & Bin Bags"),
        ("brokkoli", "Food > Vegetables > Cabbage & Brassicas"),
    ],
)
def test_keyword_rules_fire(name, label):
    assert get_taxonomy().keyword_path(name).label == label


@pytest.mark.parametrize("name", ["kokosnuss", "nussnougatcreme", "milch", "haferdrink", "erdnuss"])
def test_keyword_rules_respect_their_exclusions(name):
    assert get_taxonomy().keyword_path(name) is None


# --------------------------------------------------------------------------- classification


class ScriptedClassifier:
    def __init__(self, answers):
        self.answers = answers  # one list of (index, path_number) per call
        self.prompts: list[str] = []

    def classify(self, prompt, schema, max_tokens):
        self.prompts.append(prompt)
        pairs = self.answers[len(self.prompts) - 1]
        items = [{"index": i, "translation_en": f"en {i}", "path_number": n} for i, n in pairs]
        import json

        return LLMResponse(json.dumps({"items": items}), "scripted")


def test_invalid_numbers_get_one_batched_retry_with_a_correction():
    good = path_number("Food > Dairy & Eggs > Milk")
    provider = ScriptedClassifier([[(1, good), (2, 99999)], [(1, good)]])
    results, ids = classify_with_llm(["Milch", "Rätsel"], get_taxonomy(), "Edeka", provider)
    assert [r.item_group for r in results] == ["Milk", "Milk"] and ids == ["scripted"]
    assert not any(r.needs_review for r in results)
    assert len(provider.prompts) == 2
    assert "Your previous answers for these items were not valid numbers" in provider.prompts[1]
    assert '[1] "Rätsel": you answered 99999' in provider.prompts[1]
    assert (
        'Items (German), each with its index in square brackets:\n[1] "Rätsel"'
        in provider.prompts[1]
    )


def test_still_invalid_after_the_retry_falls_back_and_is_flagged():
    provider = ScriptedClassifier([[], []])  # the model answers nothing, twice
    (result,), _ = classify_with_llm(["Unlesbar"], get_taxonomy(), None, provider)
    assert (result.category, result.subcategory, result.item_group) == (
        "Other",
        "Miscellaneous",
        "General",
    )
    assert result.needs_review is True and result.translation_en == "Unlesbar"
    assert "you answered null" in provider.prompts[1]


def test_long_receipts_are_classified_in_chunks_of_30():
    good = path_number("Food > Pantry > Legumes")
    provider = ScriptedClassifier(
        [[(i, good) for i in range(1, 31)], [(i, good) for i in range(1, 6)]]
    )
    results, _ = classify_with_llm(
        [f"Artikel {i}" for i in range(35)], get_taxonomy(), None, provider
    )
    assert len(results) == 35 and len(provider.prompts) == 2


# --------------------------------------------------------------------------- prompts


def _swift_string(source: str, name: str, *, raw: bool) -> str:
    delim = '#"""' if raw else '"""'
    end = '"""#' if raw else '"""'
    m = re.search(rf"let {name} = {re.escape(delim)}\n(.*?)\n(\s*){re.escape(end)}", source, re.S)
    assert m, name
    body, indent = m.group(1), m.group(2)
    return "\n".join(
        line[len(indent) :] if line.startswith(indent) else line for line in body.split("\n")
    )


def test_prompts_are_verbatim_ports_of_the_swift_originals():
    extractor = (MAC / "Pipeline/ReceiptExtractor.swift").read_text()
    categorizer = (MAC / "Pipeline/ItemCategorizer.swift").read_text()
    assert _swift_string(extractor, "promptTemplate", raw=True) == prompts.EXTRACTION_PROMPT
    assert (
        _swift_string(categorizer, "classifyPromptTemplate", raw=False)
        == prompts.CLASSIFY_PROMPT_TEMPLATE
    )
    assert (
        _swift_string(categorizer, "abbreviationGlossary", raw=False)
        == prompts.ABBREVIATION_GLOSSARY
    )


def test_extraction_schema_requires_what_the_prompt_asks_for():
    schema = prompts.extraction_schema()
    assert schema["required"] == ["store", "date", "time", "items", "total", "printed_item_count"]
    assert schema["properties"]["items"]["items"]["required"] == [
        "raw_text",
        "name",
        "quantity",
        "unit_price",
        "total_price",
    ]
    assert "STRICT 1:1 LINE MAPPING" in prompts.EXTRACTION_PROMPT
    assert prompts.EXTRACTION_PROMPT.rstrip().endswith("no markdown code fences.")
