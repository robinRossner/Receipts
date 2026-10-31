"""Item categorisation (port of Pipeline/ItemCategorizer.swift, a port of categorize_item.py):
normalise a raw item name, try an exact / fuzzy match against what is already in the item
dictionary, let a keyword rule decide when it can, and send everything still unknown on the receipt
to one batched LLM classification call.

Entries a user edited (`is_manual_override`) are never touched here beyond the usage counters and
aliases; new names create new entries, so an extraction cannot overwrite a correction.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.receipts.db.models import ItemDictionary
from apps.receipts.extraction import fuzzy
from apps.receipts.extraction.jsonutil import coerce_int, coerce_str, extract_object
from apps.receipts.extraction.prompts import (
    ABBREVIATION_GLOSSARY,
    CLASSIFY_PROMPT_TEMPLATE,
    STORE_TYPE_HINTS,
    classification_schema,
)
from apps.receipts.extraction.taxonomy import Path3, Taxonomy
from apps.receipts.llm.base import LLMProvider
from core.db import utcnow

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


_Answer = tuple[str | None, int | None]  # (translation_en, path_number)


def _call_llm(
    item_names: list[str],
    taxonomy_list: str,
    path_numbers: list[int],
    ctx: str,
    correction: str,
    provider: LLMProvider,
) -> tuple[dict[int, _Answer], str]:
    item_list = "\n".join(f'[{i}] "{name}"' for i, name in enumerate(item_names, start=1))
    prompt = (
        CLASSIFY_PROMPT_TEMPLATE.replace("%%ITEM_LIST%%", item_list)
        .replace("%%TAXONOMY_LIST%%", taxonomy_list)
        .replace("%%STORE_CONTEXT%%", ctx)
        .replace("%%GLOSSARY%%", ABBREVIATION_GLOSSARY)
    )
    if correction:
        prompt += f"\n\n{correction}"
    response = provider.classify(
        prompt,
        classification_schema(len(item_names), path_numbers),
        100 + 80 * len(item_names),
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
            answers[index] = (
                coerce_str(entry.get("translation_en")),
                coerce_int(entry.get("path_number")),
            )
    elif len(item_names) == 1 and obj.get("path_number") is not None:
        # single item answered in the old flat shape
        answers[1] = (coerce_str(obj.get("translation_en")), coerce_int(obj.get("path_number")))
    return answers, response.provider_id


def classify_with_llm(
    item_names: list[str], taxonomy: Taxonomy, store_name: str | None, provider: LLMProvider
) -> tuple[list[Classification], list[str]]:
    """One LLM call per chunk; answers that are missing or not a valid taxonomy number get one
    batched retry, then fall back to Other > Miscellaneous > General with needs_review."""
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
                    number = "null" if prev is None or prev[1] is None else str(prev[1])
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
                path = index_map.get(answer[1]) if answer and answer[1] is not None else None
                log.debug(
                    "classified %r attempt=%d valid=%s", chunk[pos], attempt, path is not None
                )
                if path is not None:
                    resolved[pos] = Classification(
                        (answer[0] if answer and answer[0] else None) or chunk[pos],
                        path.category,
                        path.subcategory,
                        path.item_group,
                        False,
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
                        (prev[0] if prev and prev[0] else None) or chunk[pos],
                        *("Other", "Miscellaneous", "General"),
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

        candidates = [e.canonical_name for e in entries] + [n.normalized for n in new_items]
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
