"""`fuzz.token_sort_ratio` (port of FuzzyMatch.swift, which stands in for rapidfuzz): sort each
string's tokens, then score similarity by the Indel distance normalised to 0-100.

The Indel distance is `len(a) + len(b) - 2 * LCS(a, b)`; the LCS is computed bit-parallel on Python
integers (Hyyro), so scanning a few thousand dictionary names per receipt item stays fast.
"""

from __future__ import annotations


def sorted_tokens(s: str) -> str:
    return " ".join(sorted(t for t in s.split(" ") if t))


def lcs_length(a: str, b: str) -> int:
    if not a or not b:
        return 0
    if len(a) < len(b):
        a, b = b, a  # the longer string is the bit vector
    masks: dict[str, int] = {}
    for i, ch in enumerate(a):
        masks[ch] = masks.get(ch, 0) | (1 << i)
    full = (1 << len(a)) - 1
    v = full
    for ch in b:
        u = v & masks.get(ch, 0)
        v = ((v + u) | (v - u)) & full
    return len(a) - bin(v).count("1")


def ratio_sorted(sorted_a: str, sorted_b: str) -> int:
    """Score of two already token-sorted strings, rounded half up like the Swift original."""
    total = len(sorted_a) + len(sorted_b)
    if total == 0:
        return 100
    return int(200.0 * lcs_length(sorted_a, sorted_b) / total + 0.5)


def token_sort_ratio(a: str, b: str) -> int:
    return ratio_sorted(sorted_tokens(a), sorted_tokens(b))


def best_match(query: str, candidates: list[str], *, floor: int = 0) -> tuple[str, int] | None:
    """`process.extractOne(...)`: the first candidate with the highest score. With `floor`,
    candidates that cannot reach it (or cannot beat the best so far) are skipped without scoring,
    which does not change the answer whenever the best score is >= floor."""
    q = sorted_tokens(query)
    best: tuple[str, int] | None = None
    for cand in candidates:
        c = sorted_tokens(cand)
        total = len(q) + len(c)
        bound = 100 if total == 0 else int(200.0 * min(len(q), len(c)) / total + 0.5)
        if bound < floor or (best is not None and bound <= best[1]):
            continue
        score = ratio_sorted(q, c)
        if best is None or score > best[1]:
            best = (cand, score)
    return best
