"""Item categorisation (port of Pipeline/ItemCategorizer.swift, a port of categorize_item.py):
normalise a raw item name, try an exact / fuzzy match against what is already in the item
dictionary, let a keyword rule decide when it can, and send everything still unknown on the receipt
to one batched LLM classification call.

Entries a user edited (`is_manual_override`) are never touched here beyond the usage counters and
aliases; new names create new entries, so an extraction cannot overwrite a correction.

An item the model says has no good category in the taxonomy (or files under the fallback path
Other > Miscellaneous > General although its name is readable) becomes a flagged dictionary entry
(`category_flagged`, fallback category, `needs_review`, a proposed missing category): it is listed
for a client to resolve later, and every receipt using the entry is fixed by that one resolution.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from core.db import utcnow
from receipts.db.models import ItemDictionary
from receipts.extraction import fuzzy
from receipts.extraction.jsonutil import coerce_int, coerce_str, extract_object
from receipts.extraction.prompts import (
    CLASSIFY_PROMPT_TEMPLATE,
    STORE_TYPE_HINTS,
    classification_schema,
)
from receipts.extraction.taxonomy import FALLBACK_PATH, Path3, Taxonomy
from receipts.llm.base import LLMProvider

log = logging.getLogger(__name__)

FUZZY_MATCH_THRESHOLD = 90
MAX_ITEMS_PER_CALL = 30  # a typical receipt is one call; this only splits very long ones

_PACK_SIZE = re.compile(r"\b\d+[.,]?\d*\s?(g|kg|ml|l|cl|stk|stück|x\d*)\b", re.IGNORECASE)
_NON_WORD = re.compile(r"[^a-zäöüß0-9\s]", re.IGNORECASE)
_SPACES = re.compile(r"\s+")


def normalize_name(raw: str) -> str:
    s = raw.lower()
    s = _PACK_SIZE.sub(" ", s)
    s = _NON_WORD.sub(" ", s)
    s = _SPACES.sub(" ", s)
    return s.strip(" \t")


_VOWELS = "aeiouyäöü"


def is_readable_name(raw: str) -> bool:
    """False for a cryptic / unreadable item name: no word of at least 3 letters with a vowel in it
    ("Hnlt Ktfl", "XQ 7", "A1 K3"). Such a name may sit at the fallback path unflagged (the prompt
    tells the model to do that); a readable name there is a missing category and gets flagged."""
    for word in normalize_name(raw).split():
        letters = word.strip("0123456789")
        if len(letters) >= 3 and letters.isalpha() and any(c in _VOWELS for c in letters):
            return True
    return False


def store_context(store_name: str | None) -> str:
    if not store_name:
        return "The store these items were purchased from is unknown."
    lower = store_name.lower()
    for match, hint in STORE_TYPE_HINTS:
        if match in lower:
            return f"These items were purchased at {store_name}, {hint}."
    return f"These items were purchased at {store_name}."


@dataclass
class Classification:
    translation_en: str
    category: str
    subcategory: str
    item_group: str
    needs_review: bool
    # no good category in the taxonomy: filed under the fallback path, suggestions say what is
    # missing (None when the model gave nothing usable)
    category_flagged: bool = False
    suggested_category: str | None = None
    suggested_parent: str | None = None


@dataclass
class _Answer:
    translation_en: str | None
    path_number: int | None
    no_good_match: bool = False
    suggested_category: str | None = None
    suggested_parent: str | None = None


MAX_SUGGESTION_PART = 60
_QUOTES = "\"'`\u201c\u201d\u201e\u2018\u2019\u00ab\u00bb"


def _coerce_bool(value: object) -> bool:
    """true / "true" / 1 are true; anything else (missing, false, "no", ...) is not."""
    if isinstance(value, bool):
        return value
    if isinstance(value, int | float):
        return value == 1
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1")
    return False


def _clean(value: object) -> str:
    if not isinstance(value, str):
        return ""
    return _SPACES.sub(" ", value).strip().strip(_QUOTES).strip()


def sanitize_suggestion(
    category: object, parent: object, taxonomy: Taxonomy
) -> tuple[str | None, str | None, Path3 | None]:
    """Clean what the model proposed for a missing category.

    Returns (suggested_category, suggested_parent, existing_path). `suggested_category` is a short
    leaf name (no ">", truncated to 60), `suggested_parent` is "Category" or "Category > Sub" with
    existing names spelled as in the taxonomy. `existing_path` is set when the suggestion resolves
    to a path the taxonomy already has: the caller then files the item there instead of flagging.
    """
    leaf = _clean(category)
    leaf_out = None if not leaf or ">" in leaf else leaf[:MAX_SUGGESTION_PART].rstrip()
    parts = [_clean(p) for p in parent.split(">")] if isinstance(parent, str) else []
    if len(parts) not in (1, 2) or any(not p or len(p) > MAX_SUGGESTION_PART for p in parts):
        return leaf_out or None, None, None
    cat_entry = next((c for c in taxonomy.categories if c[0].lower() == parts[0].lower()), None)
    if cat_entry is not None:
        parts[0] = cat_entry[0]
        if len(parts) == 2:
            sub_entry = next((s for s in cat_entry[1] if s[0].lower() == parts[1].lower()), None)
            if sub_entry is not None:
                parts[1] = sub_entry[0]
    parent_out = " > ".join(parts)
    existing = None
    if leaf_out:
        wanted = (
            Path3(parts[0], parts[1], leaf_out)
            if len(parts) == 2
            else Path3(parts[0], leaf_out, "General")
        )
        existing = taxonomy.contains_ci(wanted)
    return leaf_out, parent_out, existing


_FALLBACK_LINE = re.compile(
    r"^(\d+)\. " + re.escape(" > ".join(FALLBACK_PATH)) + r"(?:  \(note:.*)?$", re.MULTILINE
)


def fallback_number(taxonomy_list: str) -> int:
    """The number of the fallback path in a numbered taxonomy list; the prompt names it."""
    m = _FALLBACK_LINE.search(taxonomy_list)
    if m is None:
        raise ValueError("the fallback path is not in the taxonomy list")
    return int(m.group(1))


def _call_llm(
    item_names: list[str],
    taxonomy_list: str,
    path_numbers: list[int],
    ctx: str,
    correction: str,
    provider: LLMProvider,
) -> tuple[dict[int, _Answer], str]:
    item_list = "\n".join(f'[{i}] "{name}"' for i, name in enumerate(item_names, start=1))
    # The item list goes in last, so an item name that looks like a placeholder is left as it is.
    prompt = (
        CLASSIFY_PROMPT_TEMPLATE.replace("%%FALLBACK%%", str(fallback_number(taxonomy_list)))
        .replace("%%TAXONOMY_LIST%%", taxonomy_list)
        .replace("%%STORE_CONTEXT%%", ctx)
        .replace("%%ITEM_LIST%%", item_list)
    )
    if correction:
        prompt += f"\n\n{correction}"
    response = provider.classify(
        prompt,
        classification_schema(len(item_names), path_numbers),
        100 + 100 * len(item_names),  # per item: `identified` and the answer fields
    )
    obj = extract_object(response.text)
    if obj is None:
        return {}, response.provider_id
    answers: dict[int, _Answer] = {}
    entries = obj.get("items")
    if isinstance(entries, list):
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            index = coerce_int(entry.get("index"))
            if index is None or not 1 <= index <= len(item_names) or index in answers:
                continue
            answers[index] = _Answer(
                coerce_str(entry.get("translation_en")),
                coerce_int(entry.get("path_number")),
                _coerce_bool(entry.get("no_good_match")),
                coerce_str(entry.get("suggested_category")),
                coerce_str(entry.get("suggested_parent")),
            )
    elif len(item_names) == 1 and obj.get("path_number") is not None:
        # single item answered in the old flat shape
        answers[1] = _Answer(
            coerce_str(obj.get("translation_en")), coerce_int(obj.get("path_number"))
        )
    return answers, response.provider_id


def _flagged(translation: str, answer: _Answer, taxonomy: Taxonomy) -> Classification:
    """The model found no fitting category: file the item under the fallback path, flagged, with
    the sanitised suggestion. A suggestion that names a path the taxonomy already has is not a
    missing category: the item simply goes there."""
    leaf, parent, existing = sanitize_suggestion(
        answer.suggested_category, answer.suggested_parent, taxonomy
    )
    if existing is not None:
        return Classification(
            translation, existing.category, existing.subcategory, existing.item_group, False
        )
    return Classification(translation, *FALLBACK_PATH, True, True, leaf, parent)


def classify_with_llm(
    item_names: list[str], taxonomy: Taxonomy, store_name: str | None, provider: LLMProvider
) -> tuple[list[Classification], list[str]]:
    """One LLM call per chunk; answers that are missing or not a valid taxonomy number get one
    batched retry, then fall back to Other > Miscellaneous > General with needs_review. Items the
    model flags as having no good category are not retried (see `_flagged`)."""
    taxonomy_list, index_map = taxonomy.numbered_prompt()
    path_numbers = sorted(index_map)
    ctx = store_context(store_name)
    results: list[Classification] = []
    provider_ids: list[str] = []

    for start in range(0, len(item_names), MAX_ITEMS_PER_CALL):
        chunk = item_names[start : start + MAX_ITEMS_PER_CALL]
        resolved: dict[int, Classification] = {}
        last_answers: dict[int, _Answer | None] = {}
        pending = list(range(len(chunk)))
        for attempt in (1, 2):
            if not pending:
                break
            correction = ""
            if attempt == 2:
                lines = []
                for b, pos in enumerate(pending):
                    prev = last_answers.get(pos)
                    number = (
                        "null"
                        if prev is None or prev.path_number is None
                        else str(prev.path_number)
                    )
                    lines.append(f'[{b + 1}] "{chunk[pos]}": you answered {number}')
                correction = (
                    "Your previous answers for these items were not valid numbers from the "
                    "category list above:\n"
                    + "\n".join(lines)
                    + "\nLook again and give each item just one of the listed numbers."
                )
            batch = [chunk[pos] for pos in pending]
            answers, provider_id = _call_llm(
                batch, taxonomy_list, path_numbers, ctx, correction, provider
            )
            if provider_id not in provider_ids:
                provider_ids.append(provider_id)
            still: list[int] = []
            for b, pos in enumerate(pending):
                answer = answers.get(b + 1)
                last_answers[pos] = answer
                translation = (answer.translation_en if answer else None) or chunk[pos]
                if answer is not None and answer.no_good_match:
                    resolved[pos] = _flagged(translation, answer, taxonomy)  # never retried
                    log.debug("classified %r attempt=%d flagged", chunk[pos], attempt)
                    continue
                number = answer.path_number if answer else None
                path = index_map.get(number) if number is not None else None
                log.debug(
                    "classified %r attempt=%d valid=%s", chunk[pos], attempt, path is not None
                )
                if path is not None:
                    if (
                        path.category,
                        path.subcategory,
                        path.item_group,
                    ) == FALLBACK_PATH and is_readable_name(chunk[pos]):
                        # The model filed a readable item under Miscellaneous without saying it
                        # has no category: that is a missing category too, so it is flagged
                        # (with whatever suggestion the model gave, none otherwise).
                        resolved[pos] = _flagged(translation, answer, taxonomy)
                        log.debug("classified %r attempt=%d fallback->flagged", chunk[pos], attempt)
                        continue
                    resolved[pos] = Classification(
                        translation, path.category, path.subcategory, path.item_group, False
                    )
                else:
                    still.append(pos)
            pending = still
        for pos in range(len(chunk)):
            if pos in resolved:
                results.append(resolved[pos])
            else:
                prev = last_answers.get(pos)
                results.append(
                    Classification(
                        (prev.translation_en if prev and prev.translation_en else None)
                        or chunk[pos],
                        *FALLBACK_PATH,
                        True,
                    )
                )
    return results, provider_ids


@dataclass
class _NewItem:
    normalized: str
    raw_name: str
    aliases: list[str]
    positions: list[int] = field(default_factory=list)
    keyword_path: Path3 | None = None


def _touch(entry: ItemDictionary, alias: str | None) -> None:
    if alias is not None and alias not in (entry.aliases or []):
        entry.aliases = [*(entry.aliases or []), alias]
    entry.times_seen = (entry.times_seen or 0) + 1
    entry.last_seen_at = utcnow()


def resolve_items(
    db: Session,
    raw_names: list[str],
    taxonomy: Taxonomy,
    store_name: str | None,
    provider: LLMProvider,
) -> tuple[list[ItemDictionary], list[str]]:
    """For every raw name, in order: normalise -> exact cache match -> fuzzy cache match, against
    the live dictionary loaded ONCE; whatever is left is classified in one batched LLM call and
    cached. Names repeated within the batch (or fuzzy-close to an earlier new one) share one new
    entry. Flushes, never commits. `classification_providers` is empty when everything came from
    the cache."""
    entries = list(db.scalars(select(ItemDictionary).where(ItemDictionary.deleted_at.is_(None))))
    by_canonical = {e.canonical_name: e for e in entries}
    alias_index: dict[str, ItemDictionary] = {}
    for e in entries:
        for a in e.aliases or []:
            alias_index.setdefault(a, e)

    resolved: dict[int, ItemDictionary] = {}
    new_items: list[_NewItem] = []

    for position, raw_name in enumerate(raw_names):
        normalized = normalize_name(raw_name)
        exact = by_canonical.get(normalized) or alias_index.get(normalized)
        if exact is not None:
            _touch(exact, None)
            resolved[position] = exact
            continue
        same_new = next(
            (n for n in new_items if n.normalized == normalized or normalized in n.aliases), None
        )
        if same_new is not None:
            same_new.positions.append(position)
            continue

        # A flagged entry holds a poor-fit fallback: look-alike items must not inherit it (they get
        # their own classification), so it is no fuzzy candidate. Exact name / alias hits above
        # still return it unchanged.
        candidates = [e.canonical_name for e in entries if not e.category_flagged] + [
            n.normalized for n in new_items
        ]
        best = (
            fuzzy.best_match(normalized, candidates, floor=FUZZY_MATCH_THRESHOLD)
            if candidates
            else None
        )
        if best is not None and best[1] >= FUZZY_MATCH_THRESHOLD:
            entry = by_canonical.get(best[0])
            if entry is not None:
                _touch(entry, normalized)
                alias_index.setdefault(normalized, entry)
                resolved[position] = entry
                continue
            near = next((n for n in new_items if n.normalized == best[0]), None)
            if near is not None:
                if normalized not in near.aliases:
                    near.aliases.append(normalized)
                near.positions.append(position)
                continue

        new_items.append(
            _NewItem(
                normalized, raw_name, [normalized], [position], taxonomy.keyword_path(normalized)
            )
        )

    provider_ids: list[str] = []
    if new_items:
        llm_items = [n for n in new_items if n.keyword_path is None]
        llm_results: list[Classification] = []
        if llm_items:
            llm_results, provider_ids = classify_with_llm(
                [n.raw_name for n in llm_items], taxonomy, store_name, provider
            )
        it = iter(llm_results)
        now = utcnow()
        for item in new_items:
            if item.keyword_path is not None:
                kw = item.keyword_path
                cls = Classification("", kw.category, kw.subcategory, kw.item_group, False)
            else:
                cls = next(it)
            entry = ItemDictionary(
                canonical_name=item.normalized,
                display_name_de=item.raw_name,
                translation_en=cls.translation_en or None,
                category=cls.category,
                subcategory=cls.subcategory,
                item_group=cls.item_group,
                aliases=list(item.aliases),
                is_manual_override=False,
                needs_review=cls.needs_review,
                category_flagged=cls.category_flagged,
                suggested_category=cls.suggested_category,
                suggested_parent=cls.suggested_parent,
                times_seen=1 + max(len(item.positions) - 1, 0),  # each repeat is a sighting
                created_at=now,
                last_seen_at=now,
                updated_at=now,
            )
            db.add(entry)
            for position in item.positions:
                resolved[position] = entry
        db.flush()

    return [resolved[i] for i in range(len(raw_names))], provider_ids
