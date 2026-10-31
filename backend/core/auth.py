"""Shared-secret bearer auth for every endpoint except the public health check.

`require_token` accepts only `RECEIPTS_API_TOKEN`; any other bearer value gets 401. An unset token
answers 503.

Wrong or missing tokens are counted per client IP (core/throttle.py); past the limit they get 429
with `Retry-After`. A valid token always succeeds, even from a throttled IP.
"""

from __future__ import annotations

import secrets
from functools import lru_cache
from typing import Annotated

from fastapi import Depends, Header, HTTPException, Request

from core.settings import get_core_settings
from core.throttle import FailureThrottle, Network, client_ip, parse_networks


def get_api_token() -> str | None:
    token = get_core_settings().receipts_api_token
    return token.get_secret_value() if token else None


@lru_cache
def get_throttle() -> FailureThrottle:
    settings = get_core_settings()
    return FailureThrottle(settings.auth_max_failures, settings.auth_failure_window_s)


@lru_cache
def get_trusted_proxies() -> list[Network]:
    return parse_networks(get_core_settings().trusted_proxy_ips)


def _is_valid(authorization: str | None, token: str) -> bool:
    scheme, _, supplied = (authorization or "").partition(" ")
    # Bytes: compare_digest raises TypeError on a non-ASCII str, which would be a 500.
    return scheme.lower() == "bearer" and secrets.compare_digest(
        supplied.strip().encode(), token.encode()
    )


def require_token(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
    token: str | None = Depends(get_api_token),
    throttle: FailureThrottle = Depends(get_throttle),
    trusted_proxies: list[Network] = Depends(get_trusted_proxies),
) -> None:
    if not token:
        raise HTTPException(503, "RECEIPTS_API_TOKEN is not configured on the server")
    if _is_valid(authorization, token):
        return
    ip = client_ip(request, trusted_proxies)
    if retry_after := throttle.blocked_for(ip):
        raise HTTPException(
            429, "too many failed attempts, try again later", {"Retry-After": str(retry_after)}
        )
    throttle.record_failure(ip)
    raise HTTPException(401, "invalid or missing bearer token", {"WWW-Authenticate": "Bearer"})
