"""Types shared by the receipts LLM providers (Messages API and Claude Code CLI).

Both providers expose the two calls the Mac app's pipeline makes (ReceiptExtractionProvider /
ItemClassificationProvider in LLMProvider.swift): `extract_receipt` (a vision call with the photo)
and `classify` (text only). Both answer with the text of a JSON object that the callers parse
leniently (extraction/jsonutil.py).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol


class LLMError(Exception):
    """A failed call. Messages never contain a key, token or header.

    `kind`: rate_limit | api_status | connection | timeout (API and CLI), auth | usage_limit |
    cli_missing | cli_error (CLI), refusal | truncated | empty | image_too_large | no_credential.
    `retryable`: another attempt can plausibly succeed (the queue backs off and retries those,
    the others fail the job at once and wait for a manual retry).
    """

    def __init__(self, kind: str, message: str, *, retryable: bool = False):
        super().__init__(message)
        self.kind = kind
        self.message = message
        self.retryable = retryable


@dataclass(frozen=True)
class LLMResponse:
    text: str
    provider_id: str  # e.g. "anthropic-api/claude-haiku-5-5", stored with the extraction


class LLMProvider(Protocol):
    def extract_receipt(
        self, image: bytes, media_type: str, prompt: str, schema: dict[str, Any], max_tokens: int
    ) -> LLMResponse: ...

    def classify(self, prompt: str, schema: dict[str, Any], max_tokens: int) -> LLMResponse: ...


def anthropic_compatible(schema: dict[str, Any]) -> dict[str, Any]:
    """A copy that satisfies Claude structured-output limits (port of
    `JSONSchema.anthropicCompatible()` in AnthropicAPIProvider.swift): `additionalProperties:
    false` on every object, and none of the numeric / length constraints that return a 400."""
    unsupported = {
        "minimum",
        "maximum",
        "exclusiveMinimum",
        "exclusiveMaximum",
        "multipleOf",
        "minLength",
        "maxLength",
        "maxItems",
        "minProperties",
        "maxProperties",
    }

    def clean(value: Any) -> Any:
        if isinstance(value, list):
            return [clean(v) for v in value]
        if not isinstance(value, dict):
            return value
        out = {k: v for k, v in value.items() if k not in unsupported}
        if isinstance(out.get("minItems"), int) and out["minItems"] > 1:
            del out["minItems"]
        typ = out.get("type")
        if typ == "object" or (isinstance(typ, list) and "object" in typ) or "properties" in out:
            out["additionalProperties"] = False
        for key, child in list(out.items()):
            if key in ("properties", "$defs", "definitions"):
                # name -> schema maps: clean each schema, never the property names themselves
                if isinstance(child, dict):
                    out[key] = {name: clean(sub) for name, sub in child.items()}
            elif key in ("enum", "const", "required", "default", "description"):
                continue
            else:
                out[key] = clean(child)
        return out

    return clean(schema)
