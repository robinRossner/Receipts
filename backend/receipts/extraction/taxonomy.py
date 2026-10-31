"""The category taxonomy and its keyword rules (port of Models/Taxonomy.swift; data in
apps/receipts/data/category_taxonomy.json, a copy of the Mac app's resource).

Order matters: the taxonomy is shown to the LLM as a numbered list and used by client pickers, so
the JSON key order is preserved. Keyword rules are evaluated in order, the first match wins.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

from apps.receipts.settings import get_settings

FALLBACK_PATH = ("Other", "Miscellaneous", "General")


@dataclass(frozen=True)
class Path3:
    category: str
    subcategory: str
    item_group: str

    @property
    def label(self) -> str:
        return f"{self.category} > {self.subcategory} > {self.item_group}"


@dataclass(frozen=True)
class KeywordRule:
    pattern: re.Pattern[str]
    exclude: re.Pattern[str] | None
    path: Path3

    def matches(self, normalized_name: str) -> bool:
        if not self.pattern.search(normalized_name):
            return False
        return not (self.exclude and self.exclude.search(normalized_name))


class Taxonomy:
    def __init__(self, data: dict[str, Any], raw_bytes: bytes):
        self.version = hashlib.sha256(raw_bytes).hexdigest()[:16]
        self.categories: list[tuple[str, list[tuple[str, list[str]]]]] = []
        for cat, subs in data["categories"].items():
            self.categories.append(
                (cat, [(sub, list(groups) or ["General"]) for sub, groups in subs.items()])
            )
        self.notes: dict[str, str] = data.get("notes") or {}
        self.keyword_rules: list[KeywordRule] = []
        for rule in data.get("keyword_rules") or []:
            parts = rule["path"].split(" > ")
            if len(parts) != 3:
                raise ValueError(f"keyword rule path is not 'A > B > C': {rule['path']}")
            path = Path3(*parts)
            if not self.contains(path):
                raise ValueError(f"keyword rule points at a missing path: {path.label}")
            self.keyword_rules.append(
                KeywordRule(
                    re.compile(rule["pattern"], re.IGNORECASE),
                    re.compile(rule["exclude"], re.IGNORECASE) if rule.get("exclude") else None,
                    path,
                )
            )

    def contains(self, path: Path3) -> bool:
        for cat, subs in self.categories:
            if cat != path.category:
                continue
            return any(
                sub == path.subcategory and path.item_group in groups for sub, groups in subs
            )
        return False

    def keyword_path(self, normalized_name: str) -> Path3 | None:
        for rule in self.keyword_rules:
            if rule.matches(normalized_name):
                return rule.path
        return None

    def flattened(self) -> list[tuple[Path3, str | None]]:
        out: list[tuple[Path3, str | None]] = []
        for cat, subs in self.categories:
            for sub, groups in subs:
                for group in groups:
                    path = Path3(cat, sub, group)
                    out.append((path, self.notes.get(path.label)))
        return out

    def numbered_prompt(self) -> tuple[str, dict[int, Path3]]:
        """Numbered prompt text + a lookup from number to path (build_numbered_taxonomy)."""
        lines: list[str] = []
        index: dict[int, Path3] = {}
        for i, (path, note) in enumerate(self.flattened(), start=1):
            line = f"{i}. {path.label}"
            if note:
                line += f"  (note: {note})"
            lines.append(line)
            index[i] = path
        return "\n".join(lines), index

    def to_json(self) -> dict[str, Any]:
        """The client-facing shape: ordered categories, item-group notes and a version hash."""
        return {
            "version": self.version,
            "categories": [
                {
                    "name": cat,
                    "subcategories": [{"name": sub, "item_groups": groups} for sub, groups in subs],
                }
                for cat, subs in self.categories
            ],
            "notes": self.notes,
        }


def load_taxonomy(path: Path | None = None) -> Taxonomy:
    path = path or get_settings().receipts_taxonomy_path
    raw = path.read_bytes()
    return Taxonomy(json.loads(raw), raw)


@lru_cache
def get_taxonomy() -> Taxonomy:
    return load_taxonomy()
