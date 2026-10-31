"""Receipts provider on the Messages API with ANTHROPIC_API_KEY (official `anthropic` SDK).

Port of AnthropicAPIProvider.swift, with the current API rules: structured output through
`output_config.format` (json_schema), no assistant prefill, no `temperature`, no forced
`tool_choice`, no `thinking` parameter (Haiku 5.5 thinks adaptively by itself;
`output_config.effort` keeps it short). `stop_reason` is checked for `refusal` / `max_tokens`
before any content is read.
"""

from __future__ import annotations

import base64
import logging
from typing import Any

import anthropic

from apps.receipts.llm.base import LLMError, LLMResponse, anthropic_compatible
from apps.receipts.settings import ReceiptsSettings
from core.redact import install_log_redaction, redact, register_secret

log = logging.getLogger(__name__)

# The Messages API rejects images over 5 MB (base64 payload is checked separately by the API).
API_MAX_IMAGE_BYTES = 5 * 1024 * 1024
# Thinking tokens count towards max_tokens, so leave headroom beyond the answer itself
# (the Mac provider used max(requested, 8192) for extraction and max(requested, 1024) for classify).
EXTRACT_MIN_TOKENS = 8192
CLASSIFY_MIN_TOKENS = 4096


def image_block(image: bytes, media_type: str) -> dict[str, Any]:
    return {
        "type": "image",
        "source": {
            "type": "base64",
            "media_type": media_type,
            "data": base64.standard_b64encode(image).decode("ascii"),
        },
    }


def request_kwargs(
    settings: ReceiptsSettings,
    content: list[dict[str, Any]],
    schema: dict[str, Any],
    max_tokens: int,
) -> dict[str, Any]:
    """Everything `messages.create` is called with (also what the tests assert on)."""
    return {
        "model": settings.receipts_llm_model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": content}],
        "output_config": {
            "effort": settings.receipts_llm_effort,
            "format": {"type": "json_schema", "schema": anthropic_compatible(schema)},
        },
    }


class AnthropicProvider:
    def __init__(self, settings: ReceiptsSettings, client: Any | None = None):
        self.settings = settings
        self._client = client

    @property
    def provider_id(self) -> str:
        return f"anthropic-api/{self.settings.receipts_llm_model}"

    def _get_client(self) -> Any:
        if self._client is None:
            key = self.settings.llm_api_key
            if key is None:
                raise LLMError("no_credential", "ANTHROPIC_API_KEY is not configured")
            install_log_redaction()
            register_secret(key)
            self._client = anthropic.Anthropic(
                api_key=key,
                max_retries=self.settings.receipts_api_max_retries,
                timeout=self.settings.receipts_api_timeout_s,
            )
        return self._client

    def extract_receipt(
        self, image: bytes, media_type: str, prompt: str, schema: dict[str, Any], max_tokens: int
    ) -> LLMResponse:
        if len(image) > API_MAX_IMAGE_BYTES:
            raise LLMError(
                "image_too_large",
                f"The photo is {len(image) / 1e6:.1f} MB; the Claude API accepts images up to "
                "5 MB. Send a smaller JPEG (long edge about 2500 px).",
            )
        content = [image_block(image, media_type), {"type": "text", "text": prompt}]
        return self._send(content, schema, max(max_tokens, EXTRACT_MIN_TOKENS))

    def classify(self, prompt: str, schema: dict[str, Any], max_tokens: int) -> LLMResponse:
        return self._send(
            [{"type": "text", "text": prompt}], schema, max(max_tokens, CLASSIFY_MIN_TOKENS)
        )

    def _send(
        self, content: list[dict[str, Any]], schema: dict[str, Any], max_tokens: int
    ) -> LLMResponse:
        client = self._get_client()
        try:
            resp = client.messages.create(
                **request_kwargs(self.settings, content, schema, max_tokens)
            )
        except anthropic.RateLimitError as exc:
            raise LLMError(
                "rate_limit",
                redact(f"Claude rate limit reached (429): {exc.message}"),
                retryable=True,
            ) from None
        except anthropic.APIStatusError as exc:
            raise LLMError(
                "api_status",
                redact(f"Claude API error (HTTP {exc.status_code}): {exc.message}"),
                retryable=exc.status_code >= 500,
            ) from None
        except anthropic.APIConnectionError as exc:
            raise LLMError(
                "connection",
                redact(f"Could not reach the Claude API: {exc.message}"),
                retryable=True,
            ) from None
        # stop_reason first: a refused or truncated response has no usable content
        stop = getattr(resp, "stop_reason", None)
        if stop == "refusal":
            raise LLMError(
                "refusal", "Claude declined to answer this request (stop_reason: refusal)."
            )
        if stop == "max_tokens":
            raise LLMError(
                "truncated",
                "Claude's answer hit the output token limit (stop_reason: max_tokens).",
                retryable=True,
            )
        text = "".join(
            b.text
            for b in getattr(resp, "content", None) or []
            if getattr(b, "type", None) == "text"
        )
        if not text.strip():
            raise LLMError("empty", "The Claude response contained no text.", retryable=True)
        usage = getattr(resp, "usage", None)
        log.info(
            "receipts llm call (api): stop=%s in=%s out=%s",
            stop,
            getattr(usage, "input_tokens", "?"),
            getattr(usage, "output_tokens", "?"),
        )
        return LLMResponse(text, self.provider_id)
