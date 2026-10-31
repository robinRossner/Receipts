"""Build the configured receipts LLM provider (RECEIPTS_LLM_PROVIDER = claude_code | api | auto)."""

from __future__ import annotations

from receipts.llm.base import LLMProvider
from receipts.settings import ReceiptsSettings


def build_provider(settings: ReceiptsSettings) -> LLMProvider | None:
    """The provider `settings.llm_provider_resolved` names, or None without a credential."""
    resolved = settings.llm_provider_resolved
    if resolved == "claude_code":
        from receipts.llm.claude_code import ClaudeCodeProvider

        return ClaudeCodeProvider(settings)
    if resolved == "api":
        from receipts.llm.api import AnthropicProvider

        return AnthropicProvider(settings)
    return None


def provider_status(settings: ReceiptsSettings) -> dict[str, object]:
    """What the status endpoint shows; never contains a credential."""
    resolved = settings.llm_provider_resolved
    return {
        "provider": resolved,
        "requested_provider": settings.receipts_llm_provider,
        "credential_configured": resolved != "none",
        "billing": {"api": "api", "claude_code": "subscription"}.get(resolved),
        "model": settings.receipts_llm_model,
    }
