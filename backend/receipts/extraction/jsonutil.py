"""Lenient handling of LLM JSON (ports of JSONUtil.swift and `JSONCoerce`).

Vision models occasionally wrap the JSON in prose or markdown fences, emit "1.99" as a string, or
omit a field; none of that may fail a receipt.
"""

from __future__ import annotations

import json
import math
import re
from typing import Any

_BRACES = re.compile(r"\{.*\}", re.DOTALL)


def extract_object(raw: str) -> dict[str, Any] | None:
    """Everything between the first '{' and the last '}' parsed as a JSON object, else None."""
    match = _BRACES.search(raw)
    text = match.group(0) if match else raw
    try:
        value = json.loads(text)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def coerce_float(value: Any) -> float | None:
    if isinstance(value, bool):  # NSNumber semantics of the Swift original
        return 1.0 if value else 0.0
    if isinstance(value, int | float):
        number = float(value)
    elif isinstance(value, str):
        try:
            number = float(value.replace(",", "."))
        except ValueError:
            return None
    else:
        return None
    return number if math.isfinite(number) else None


def coerce_int(value: Any) -> int | None:
    number = coerce_float(value)
    return None if number is None else int(number)


def coerce_str(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def round2(value: float) -> float:
    """Round half away from zero to 2 decimals (Swift `(v * 100).rounded() / 100`)."""
    scaled = value * 100
    return math.copysign(math.floor(abs(scaled) + 0.5), scaled) / 100 + 0.0
