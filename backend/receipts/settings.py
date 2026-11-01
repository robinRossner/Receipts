"""Receipts settings: the shared `core.settings.CoreSettings` (receipts token, scheduler switches,
Claude credentials) plus everything receipts-specific, loaded from environment / `.env`.

Env var names are the field names upper-cased (`RECEIPTS_LLM_PROVIDER`, ...).
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from core.settings import BACKEND_DIR, CoreSettings

RECEIPTS_DIR = Path(__file__).resolve().parent  # backend/receipts: alembic, data

# Default model and thinking depth: Haiku 5.5 at high effort, the same pair the Mac app hardcodes
# (`ClaudeModel` in LLMSettings.swift), picked from a 30-receipt comparison (docs/decisions.md).
# One id for both providers. Production leaves the env unset, so switching to another model is a
# one-line change: RECEIPTS_LLM_MODEL (and RECEIPTS_LLM_EFFORT).
DEFAULT_MODEL = "claude-haiku-5-5"
DEFAULT_EFFORT = "high"


class ReceiptsSettings(CoreSettings):
    receipts_database_url: str = f"sqlite:///{BACKEND_DIR / 'var' / 'receipts.db'}"
    # Photos not yet archived on the laptop. Paths inside are generated from the receipt UUID only.
    receipts_photos_dir: Path = BACKEND_DIR / "var" / "receipts_photos"
    receipts_max_photo_bytes: int = 15 * 1024 * 1024
    receipts_taxonomy_path: Path = RECEIPTS_DIR / "data" / "category_taxonomy.json"

    # ---- LLM (receipts/llm). The credentials are core's: ANTHROPIC_API_KEY (Messages API)
    # and CLAUDE_CODE_OAUTH_TOKEN (headless `claude -p` on a subscription). auto = claude_code if
    # that token is set, else api if a key is set, else the queue waits (jobs stay queued).
    receipts_llm_provider: Literal["claude_code", "api", "auto"] = "auto"
    receipts_llm_model: str = DEFAULT_MODEL
    receipts_llm_effort: str = DEFAULT_EFFORT  # output_config.effort / `claude --effort`
    receipts_cli_path: str = "claude"
    receipts_cli_timeout_s: float = 240.0
    receipts_api_timeout_s: float = 240.0
    receipts_api_max_retries: int = 3  # SDK retries (429 / 5xx / connection) with backoff

    # ---- extraction queue
    receipts_extraction_max_attempts: int = 3
    receipts_extraction_backoff_s: float = 60.0  # base; doubles per attempt
    receipts_worker_enabled: bool = True  # the in-process queue worker thread (lifespan)

    # ---- photo retention / laptop archive
    receipts_archive_reminder_days: int = 30
    receipts_disk_warning_free_mb: int = 2048  # warn when the photos' filesystem has less free
    receipts_reminder_time: str = "09:00"  # daily check, scheduler_tz
    receipts_reminder_repeat_days: float = 3.0  # at most one reminder per this many days
    # Optional: POST the reminder text here (ntfy.sh style: body = message, Title header). Unset =
    # no delivery channel exists; the reminder is logged and status fields carry the warning.
    receipts_notify_url: str | None = None

    @property
    def llm_api_key(self) -> str | None:
        key = self.anthropic_api_key.get_secret_value().strip() if self.anthropic_api_key else ""
        return key or None

    @property
    def llm_oauth_token(self) -> str | None:
        tok = (
            self.claude_code_oauth_token.get_secret_value().strip()
            if self.claude_code_oauth_token
            else ""
        )
        return tok or None

    @property
    def llm_provider_resolved(self) -> Literal["api", "claude_code", "none"]:
        """Which provider will run: the requested one, or (auto) the first with a credential."""
        if self.receipts_llm_provider == "api":
            return "api" if self.llm_api_key else "none"
        if self.receipts_llm_provider == "claude_code":
            return "claude_code" if self.llm_oauth_token else "none"
        if self.llm_oauth_token:
            return "claude_code"
        return "api" if self.llm_api_key else "none"


@lru_cache
def get_settings() -> ReceiptsSettings:
    return ReceiptsSettings()
