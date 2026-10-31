"""In-process throttle for failed bearer attempts, per client IP.

Single uvicorn worker, so a plain in-memory dict is enough; it resets on restart, which is fine.
A sliding window counts failures per IP; once an IP has `limit` failures within `window_s`
seconds, `blocked_for` says how long it must wait. Callers only consult it for requests that
have no valid token, so a valid token is never throttled.

The client IP is the socket peer, or the right-most `X-Forwarded-For` entry when the peer is a
trusted reverse proxy (`client_ip`); a client-sent header is never believed on its own.
"""

from __future__ import annotations

import ipaddress
import math
import time
from collections import OrderedDict, deque
from collections.abc import Callable, Iterable

from fastapi import Request

Network = ipaddress.IPv4Network | ipaddress.IPv6Network

MAX_TRACKED_IPS = 10_000  # hard bound on memory; the least recently failing IPs are dropped first


def parse_networks(spec: str) -> list[Network]:
    """`"10.0.0.0/8, 192.0.2.7"` -> networks; a bare address is a /32 (or /128)."""
    return [
        ipaddress.ip_network(part.strip(), strict=False) for part in spec.split(",") if part.strip()
    ]


def _parse_ip(text: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        return ipaddress.ip_address(text.strip())
    except ValueError:
        return None


def client_ip(request: Request, trusted_proxies: Iterable[Network]) -> str:
    """The IP this request is attributed to (anything unparsable falls back to the peer)."""
    peer = request.client.host if request.client else "unknown"
    peer_ip = _parse_ip(peer)
    if peer_ip is None or not any(peer_ip in net for net in trusted_proxies):
        return peer
    forwarded = ",".join(request.headers.getlist("x-forwarded-for"))
    last = forwarded.rsplit(",", 1)[-1] if forwarded else ""
    ip = _parse_ip(last)
    return str(ip) if ip is not None else peer


class FailureThrottle:
    def __init__(
        self,
        limit: int = 20,
        window_s: float = 600.0,
        clock: Callable[[], float] = time.monotonic,
        max_ips: int = MAX_TRACKED_IPS,
    ) -> None:
        self.limit = limit
        self.window_s = window_s
        self._clock = clock
        self._max_ips = max_ips
        self._failures: OrderedDict[str, deque[float]] = OrderedDict()  # oldest activity first
        self._last_sweep = clock()

    def _expire(self, ip: str, now: float) -> deque[float] | None:
        failures = self._failures.get(ip)
        if failures is None:
            return None
        while failures and failures[0] <= now - self.window_s:
            failures.popleft()
        if not failures:
            del self._failures[ip]
            return None
        return failures

    def _sweep(self, now: float) -> None:
        """Drop every IP whose failures have all expired; at most once per window."""
        if now - self._last_sweep < self.window_s and len(self._failures) <= self._max_ips:
            return
        self._last_sweep = now
        for ip in list(self._failures):
            self._expire(ip, now)
        while len(self._failures) > self._max_ips:
            self._failures.popitem(last=False)

    def blocked_for(self, ip: str) -> int:
        """Whole seconds until `ip` may fail again without being refused (0: not throttled)."""
        now = self._clock()
        failures = self._expire(ip, now)
        if failures is None or len(failures) < self.limit:
            return 0
        return max(1, math.ceil(failures[0] + self.window_s - now))

    def record_failure(self, ip: str) -> None:
        now = self._clock()
        self._sweep(now)
        failures = self._expire(ip, now)
        if failures is None:
            failures = self._failures[ip] = deque(maxlen=max(self.limit, 1))
        failures.append(now)
        self._failures.move_to_end(ip)
