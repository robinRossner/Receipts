"""Settings base of the server, loaded from the environment / `backend/.env` via pydantic-settings.

`receipts.settings.ReceiptsSettings` extends `CoreSettings` with the receipts-specific fields; the
env var names are the field names upper-cased. Secrets are `SecretStr` so they never end up in
logs or reprs.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_DIR = Path(__file__).resolve().parents[1]  # backend/: var/ (state), .env, Dockerfile


class CoreSettings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=BACKEND_DIR / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # The one bearer token every /api/v1/receipts route needs (core/auth.py). Unset => 503.
    receipts_api_token: SecretStr | None = None

    # Interactive API docs (/docs, /redoc, /openapi.json): 404 unless enabled (dev only).
    docs_enabled: bool = False

    # Throttle for wrong or missing bearer tokens (core/throttle.py): after `auth_max_failures`
    # failures within `auth_failure_window_s` seconds from one client IP, requests from that IP
    # without a valid token get 429. A valid token is never throttled.
    auth_max_failures: int = 20
    auth_failure_window_s: int = 600
    # Comma-separated IPs / CIDRs of reverse proxies whose X-Forwarded-For header is believed
    # (the right-most entry is then the client IP); any other peer is used as is. The default is
    # the private ranges: in deploy/docker-compose.yml the backend is only reachable from the
    # Caddy container over a Docker bridge network (172.16.0.0/12 by default, any RFC 1918 range
    # when the daemon is configured otherwise). Caddy replaces a client-sent X-Forwarded-For with
    # the real address. Local dev (peer 127.0.0.1) is not trusted, so the header is ignored there.
    trusted_proxy_ips: str = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7"

    # Scheduler (APScheduler in the FastAPI process); off by default locally.
    scheduler_enabled: bool = False
    scheduler_tz: str = "Europe/Vienna"

    # Claude credentials: `anthropic_api_key` (Messages API, paid per token) and
    # `claude_code_oauth_token` (headless `claude -p` on a Claude Pro/Max subscription, from
    # `claude setup-token`). Which provider is used, and with which model, is a receipts setting.
    anthropic_api_key: SecretStr | None = None
    claude_code_oauth_token: SecretStr | None = None


@lru_cache
def get_core_settings() -> CoreSettings:
    return CoreSettings()
