"""Flagged categories: the LLM says no listed category fits an item (prompt, schema, lenient
parsing, suggestion sanitising), flagged dictionary entries through extraction, and the dictionary
cache rules (exact hit keeps the flag, fuzzy matching ignores flagged entries)."""

from __future__ import annotations

import json
import re

import pytest
from sqlalchemy import select

from receipts import worker
from receipts.db.models import ItemDictionary, LineItem, TaxonomyAddition
from receipts.extraction.categorize import (
    classify_with_llm,
    sanitize_suggestion,
)
from receipts.extraction.prompts import CLASSIFY_PROMPT_TEMPLATE, classification_schema
from receipts.extraction.taxonomy import FALLBACK_PATH, Path3, get_taxonomy
from receipts.llm.base import LLMResponse
from receipts.settings import get_settings
from tests.receipts_helpers import BASE, FakeProvider, make_jpeg, path_number, receipt_json

RID1 = "3b241101-e2bb-4255-8caf-4136c566a962"
RID2 = "4c352212-f3cc-4366-9dbf-5247d677b073"
GENERAL = path_number("Other > Miscellaneous > General")
MILK = path_number("Food > Dairy & Eggs > Milk")


class Raw:
    """Classifier that answers with the given raw JSON text per call (last one repeats)."""

    def __init__(self, *answers):
        self.answers = answers
        self.prompts: list[str] = []

    def classify(self, prompt, schema, max_tokens):
        self.prompts.append(prompt)
        text = self.answers[min(len(self.prompts), len(self.answers)) - 1]
        return LLMResponse(text if isinstance(text, str) else json.dumps(text), "raw")


def answer(index=1, number=GENERAL, **extra):
    return {"index": index, "translation_en": f"en {index}", "path_number": number, **extra}


def one(entry: dict, taxonomy=None, name="Hundefutter"):
    provider = Raw({"items": [entry]})
    (result,), _ = classify_with_llm([name], taxonomy or get_taxonomy(), "Edeka", provider)
    return result, provider


# --------------------------------------------------------------------------- prompt and schema


def test_prompt_has_the_flagging_rules_and_json_shape():
    t = CLASSIFY_PROMPT_TEMPLATE
    assert (
        "Below is a numbered list of the ONLY valid categories. For each item pick the single "
        "number that best matches - never invent a new category and never describe the item in "
        "that field, just give its number." in t
    )
    rules = t.split("Rules:\n")[1].split("\n\nRespond")[0].splitlines()
    assert (
        rules[-3:][0]
        == '- If genuinely unsure, use the number for "Other > Miscellaneous > General".'
    )
    assert rules[-2] == (
        "- If you cannot tell what the item is (cryptic or unreadable name), use the number for "
        '"Other > Miscellaneous > General" and do NOT flag it.'
    )
    assert rules[-1].startswith('- Missing category: set "no_good_match" to true ONLY when')
    assert rules[-1].endswith(
        'When you do not flag, set "no_good_match" to false and both suggestion fields to "".'
    )
    assert '"no_good_match": <true only if no listed category is a reasonable home' in t
    assert '"suggested_category": "<short name of the missing category' in t
    assert '"suggested_parent": "<Category or Category > Subcategory it would belong under' in t


def test_schema_requires_the_flag_fields():
    entry = classification_schema(2, [1, 2])["properties"]["items"]["items"]
    assert entry["required"] == [
        "index",
        "translation_en",
        "path_number",
        "no_good_match",
        "suggested_category",
        "suggested_parent",
    ]
    props = entry["properties"]
    assert props["no_good_match"]["type"] == "boolean"
    assert props["suggested_category"]["type"] == props["suggested_parent"]["type"] == "string"
    assert entry["additionalProperties"] is False


# --------------------------------------------------------------------------- parsing


def test_a_flagged_answer_files_under_the_fallback_with_the_suggestion():
    r, provider = one(
        answer(no_good_match=True, suggested_category="Pet Food", suggested_parent="Household")
    )
    assert (r.category, r.subcategory, r.item_group) == FALLBACK_PATH
    assert r.category_flagged is True and r.needs_review is True
    assert (r.suggested_category, r.suggested_parent) == ("Pet Food", "Household")
    assert len(provider.prompts) == 1


def test_a_flagged_answer_with_an_invalid_path_number_is_not_retried():
    r, provider = one(
        answer(
            number=99999,
            no_good_match=True,
            suggested_category="Pet Food",
            suggested_parent="Household > Pets",
        )
    )
    assert r.category_flagged is True and (r.category, r.item_group) == ("Other", "General")
    assert len(provider.prompts) == 1


def test_a_flagged_answer_without_a_usable_suggestion_is_still_flagged():
    for extra in (
        {"suggested_category": "", "suggested_parent": ""},
        {},
        {"suggested_category": 5, "suggested_parent": ["x"]},
    ):
        r, _ = one(answer(no_good_match=True, **extra))
        assert r.category_flagged is True and r.needs_review is True
        assert (r.suggested_category, r.suggested_parent) == (None, None)


@pytest.mark.parametrize("flag", [True, "true", "TRUE", 1])
def test_the_flag_is_coerced_to_a_bool(flag):
    r, _ = one(
        answer(no_good_match=flag, suggested_category="Pet Food", suggested_parent="Household")
    )
    assert r.category_flagged is True


@pytest.mark.parametrize("flag", [False, "false", 0, "", None, "no", "yes", 2, []])
def test_anything_else_is_not_flagged(flag):
    r, _ = one(
        answer(number=MILK, no_good_match=flag, suggested_category="X", suggested_parent="Y")
    )
    assert r.category_flagged is False and r.needs_review is False
    assert (r.category, r.item_group) == ("Food", "Milk")
    assert (r.suggested_category, r.suggested_parent) == (None, None)


def test_old_and_flat_answer_shapes_still_work():
    r, _ = one(answer(number=MILK))  # no flag keys at all
    assert r.category_flagged is False and r.item_group == "Milk"
    provider = Raw({"translation_en": "milk", "path_number": MILK})  # single item, flat shape
    (flat,), _ = classify_with_llm(["Milch"], get_taxonomy(), None, provider)
    assert flat.item_group == "Milk" and flat.category_flagged is False


def test_unflagged_invalid_numbers_still_get_the_second_attempt():
    provider = Raw(
        {"items": [answer(1, 99999), answer(2, no_good_match=True, suggested_category="Pet Food")]},
        {"items": [answer(1, MILK)]},
    )
    results, _ = classify_with_llm(["Rätsel", "Hundefutter"], get_taxonomy(), None, provider)
    assert [r.category_flagged for r in results] == [False, True]
    assert results[0].item_group == "Milk" and len(provider.prompts) == 2
    assert "Hundefutter" not in provider.prompts[1]  # only the invalid item is asked again


def test_a_suggestion_naming_an_existing_path_is_not_flagged():
    r, _ = one(
        answer(
            no_good_match=True,
            suggested_category="milk",
            suggested_parent="food > dairy & eggs",
        )
    )
    assert (r.category, r.subcategory, r.item_group) == ("Food", "Dairy & Eggs", "Milk")
    assert r.category_flagged is False and r.needs_review is False
    assert (r.suggested_category, r.suggested_parent) == (None, None)


def test_a_suggestion_matching_a_client_addition_is_not_flagged():
    merged = get_taxonomy().with_additions([Path3("Household", "Pets", "Pet Food")])
    r, _ = one(
        answer(
            no_good_match=True, suggested_category="Pet Food", suggested_parent="household > pets"
        ),
        merged,
    )
    assert (r.category, r.subcategory, r.item_group) == ("Household", "Pets", "Pet Food")
    assert r.category_flagged is False


def test_the_prompt_lists_the_merged_taxonomy():
    merged = get_taxonomy().with_additions([Path3("Household", "Pets", "Pet Food")])
    provider = Raw({"items": [answer(number=1)]})
    classify_with_llm(["Hundefutter"], merged, None, provider)
    assert re.search(r"^\d+\. Household > Pets > Pet Food$", provider.prompts[0], re.M)
    plain = Raw({"items": [answer(number=1)]})
    classify_with_llm(["Hundefutter"], get_taxonomy(), None, plain)
    assert "Household > Pets" not in plain.prompts[0]


# --------------------------------------------------------------------------- sanitising


@pytest.mark.parametrize(
    ("category", "parent", "expected"),
    [
        ('  "Pet   Food" ', "Household", ("Pet Food", "Household", None)),
        (
            "'Pet Food'",
            " household > household goods ",
            ("Pet Food", "Household > Household Goods", None),
        ),
        ("“Pet Food”", "Household > Pets", ("Pet Food", "Household > Pets", None)),
        ("Pet > Food", "Household", (None, "Household", None)),  # ">" in the leaf
        ("", "Household", (None, "Household", None)),
        ("Pet Food", "", ("Pet Food", None, None)),
        ("Pet Food", None, ("Pet Food", None, None)),
        ("Pet Food", "A > B > C", ("Pet Food", None, None)),  # three levels
        ("Pet Food", "Household >", ("Pet Food", None, None)),  # empty part
        ("Pet Food", "x" * 61, ("Pet Food", None, None)),
        ("Pet Food", f"Household > {'y' * 61}", ("Pet Food", None, None)),
        ("z" * 90, "Brand New", ("z" * 60, "Brand New", None)),  # leaf truncated, new category kept
        ("Pet Food", "Brand New > Pets", ("Pet Food", "Brand New > Pets", None)),
        (None, None, (None, None, None)),
    ],
)
def test_suggestions_are_sanitised(category, parent, expected):
    assert sanitize_suggestion(category, parent, get_taxonomy()) == expected


def test_a_suggested_path_is_resolved_against_existing_names():
    tax = get_taxonomy()
    _, parent, existing = sanitize_suggestion("MILK", "FOOD > DAIRY & EGGS", tax)
    assert existing == Path3("Food", "Dairy & Eggs", "Milk") and parent == "Food > Dairy & Eggs"
    # one-part parent: (category, leaf, "General")
    merged = tax.with_additions([Path3("Household", "Pets", "General")])
    assert sanitize_suggestion("pets", "household", merged)[2] == Path3(
        "Household", "Pets", "General"
    )
    assert sanitize_suggestion("pets", "household", tax)[2] is None


# --------------------------------------------------------------------------- extraction


class FlagProvider(FakeProvider):
    """FakeProvider whose classification flags the items named in `flags`
    ({lowercase name: (suggested_category, suggested_parent)}); the rest go to Legumes."""

    def __init__(self, extractions, flags):
        super().__init__(extractions)
        self.flags = flags
        self.asked: list[list[str]] = []

    def classify(self, prompt, schema, max_tokens):
        self.classify_calls.append(prompt)
        names = re.findall(r'^\[(\d+)\] "(.*)"$', prompt, re.M)
        self.asked.append([n for _, n in names])
        items = []
        for index, name in names:
            flag = self.flags.get(name.lower())
            entry = {
                "index": int(index),
                "translation_en": f"en {name}",
                "path_number": GENERAL if flag else path_number("Food > Pantry > Legumes"),
                "no_good_match": bool(flag),
                "suggested_category": flag[0] if flag else "",
                "suggested_parent": flag[1] if flag else "",
            }
            items.append(entry)
        return LLMResponse(json.dumps({"items": items}), "fake/test-model")


def upload(client, rid, seed):
    r = client.put(
        f"{BASE}/{rid}/photo", content=make_jpeg(seed), headers={"Content-Type": "image/jpeg"}
    )
    assert r.status_code == 201, r.text


def run_all(factory, provider):
    while worker.run_next(factory, provider):
        pass


@pytest.fixture(autouse=True)
def _fast_backoff(monkeypatch):
    monkeypatch.setenv("RECEIPTS_EXTRACTION_BACKOFF_S", "0")
    get_settings.cache_clear()


def entry_named(db, name) -> ItemDictionary:
    db.expire_all()
    return db.scalar(select(ItemDictionary).where(ItemDictionary.canonical_name == name))


def test_a_flagged_item_becomes_a_flagged_dictionary_entry(rclient, rdb, rfactory):
    upload(rclient, RID1, 1)
    provider = FlagProvider(
        [receipt_json([("Hundefutter Rind 400g", 1, 1.99), ("Milch", 1, 1.19)])],
        {"hundefutter rind 400g": ("Pet Food", "Household")},
    )
    run_all(rfactory, provider)

    d = entry_named(rdb, "hundefutter rind")
    assert (d.category, d.subcategory, d.item_group) == FALLBACK_PATH
    assert d.category_flagged is True and d.needs_review is True and d.is_manual_override is False
    assert (d.suggested_category, d.suggested_parent) == ("Pet Food", "Household")
    other = entry_named(rdb, "milch")
    assert other.category_flagged is False and other.suggested_category is None

    page = rclient.get(f"{BASE}/sync/pull").json()
    wire = next(e for e in page["dictionary"] if e["canonical_name"] == "hundefutter rind")
    assert wire["category_flagged"] is True and wire["needs_review"] is True
    assert (wire["suggested_category"], wire["suggested_parent"]) == ("Pet Food", "Household")
    # the receipt itself extracted normally and points at the flagged entry
    assert {i.item_dictionary_id for i in rdb.scalars(select(LineItem))} >= {d.id}


def test_an_exact_hit_on_a_flagged_entry_skips_the_llm_and_keeps_the_flag(rclient, rdb, rfactory):
    upload(rclient, RID1, 1)
    provider = FlagProvider(
        [receipt_json([("Hundefutter Rind", 1, 1.99)])],
        {"hundefutter rind": ("Pet Food", "Household")},
    )
    run_all(rfactory, provider)
    assert len(provider.classify_calls) == 1
    first = entry_named(rdb, "hundefutter rind")
    seq = first.server_seq

    upload(rclient, RID2, 2)
    run_all(rfactory, provider)  # same item name on a second receipt (same extraction answer)
    assert len(provider.classify_calls) == 1  # cache hit: no new classification
    again = entry_named(rdb, "hundefutter rind")
    assert again.id == first.id and again.category_flagged is True
    assert (again.suggested_category, again.suggested_parent) == ("Pet Food", "Household")
    assert again.times_seen == 2 and again.server_seq == seq  # a sighting is no change
    assert (
        len(rdb.scalars(select(LineItem).where(LineItem.item_dictionary_id == first.id)).all()) == 2
    )


def test_a_fuzzy_look_alike_does_not_inherit_the_flagged_entry(rclient, rdb, rfactory):
    upload(rclient, RID1, 1)
    provider = FlagProvider(
        [
            receipt_json([("Hundefutter Rind", 1, 1.99)]),
            receipt_json([("Hundefutter Rinder", 1, 2.0)]),
        ],
        {"hundefutter rind": ("Pet Food", "Household")},
    )
    run_all(rfactory, provider)
    upload(rclient, RID2, 2)
    run_all(rfactory, provider)

    assert provider.asked == [["Hundefutter Rind"], ["Hundefutter Rinder"]]  # asked again
    flagged = entry_named(rdb, "hundefutter rind")
    twin = entry_named(rdb, "hundefutter rinder")
    assert twin is not None and twin.id != flagged.id
    assert twin.category_flagged is False and twin.item_group == "Legumes"
    assert flagged.aliases == ["hundefutter rind"]  # no alias added to the flagged entry
    assert flagged.times_seen == 1


def test_a_fuzzy_look_alike_still_matches_an_unflagged_entry(rclient, rdb, rfactory):
    upload(rclient, RID1, 1)
    provider = FlagProvider(
        [
            receipt_json([("Hundefutter Rind", 1, 1.99)]),
            receipt_json([("Hundefutter Rinder", 1, 2.0)]),
        ],
        {},
    )
    run_all(rfactory, provider)
    upload(rclient, RID2, 2)
    run_all(rfactory, provider)
    assert len(provider.classify_calls) == 1
    assert entry_named(rdb, "hundefutter rind").aliases == [
        "hundefutter rind",
        "hundefutter rinder",
    ]


def test_keyword_rule_items_are_never_flagged_or_asked(rclient, rdb, rfactory):
    upload(rclient, RID1, 1)
    provider = FlagProvider(
        [receipt_json([("Haferflocken", 1, 1.0), ("Hundefutter", 1, 2.0)])],
        {"haferflocken": ("Oats", "Food"), "hundefutter": ("Pet Food", "Household")},
    )
    run_all(rfactory, provider)
    assert provider.asked == [["Hundefutter"]]  # the keyword rule decided the oats
    oats = entry_named(rdb, "haferflocken")
    assert oats.category_flagged is False and oats.item_group == "Cereals & Muesli"
    assert oats.needs_review is False


def test_extraction_offers_client_added_categories(rclient, rdb, rfactory):
    rdb.add(TaxonomyAddition(category="Household", subcategory="Pets", item_group="Pet Food"))
    rdb.commit()
    upload(rclient, RID1, 1)

    class Pick(FakeProvider):
        def classify(self, prompt, schema, max_tokens):
            self.classify_calls.append(prompt)
            number = re.search(r"^(\d+)\. Household > Pets > Pet Food$", prompt, re.M).group(1)
            item = {
                "index": 1,
                "translation_en": "dog food",
                "path_number": int(number),
                "no_good_match": False,
                "suggested_category": "",
                "suggested_parent": "",
            }
            return LLMResponse(json.dumps({"items": [item]}), "fake/test-model")

    run_all(rfactory, Pick([receipt_json([("Hundefutter", 1, 2.0)])]))
    d = entry_named(rdb, "hundefutter")
    assert (d.category, d.subcategory, d.item_group) == ("Household", "Pets", "Pet Food")
    assert d.category_flagged is False and d.needs_review is False
