"""Receipts provider that runs headless Claude Code (`claude -p`) on a Claude subscription.

Port of ClaudeCLIProvider.swift. How the photo reaches Claude: not through a file and not through
tools (`--tools ""`; the fitness advisor provider is text only): the prompt is sent on stdin as one
`--input-format stream-json` user message whose content holds a base64 `image` block followed by the
prompt text, exactly as the Mac app does. The answer comes from `--json-schema` (delivered in the
envelope's `structured_output`, with the `result` text as a fallback).

Flags (checked against `claude --help` of Claude Code 2.1.314; no prompt was run):
  -p, --output-format json, --input-format stream-json (images only), --json-schema <schema>,
  --model, --max-turns 3 (hidden but accepted; `--json-schema` answers through an internal tool
  call, so one turn can be too few), --tools "", --strict-mcp-config, --setting-sources "",
  --disable-slash-commands, --no-session-persistence, --permission-mode dontAsk,
  --system-prompt <text> (replaces Claude Code's coding system prompt), --effort <level>.
Not used: --bare (never reads the OAuth token).

The subprocess gets an empty temp cwd and exactly PATH, a temp HOME, the OAuth token and
DISABLE_AUTOUPDATER: never ANTHROPIC_API_KEY (it outranks the subscription token and would bill
the API account instead), never the rest of the server environment. No shell is involved.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import re
import shutil
import tempfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from apps.receipts.llm.base import LLMError, LLMResponse, anthropic_compatible
from apps.receipts.settings import ReceiptsSettings
from core.redact import install_log_redaction, redact, register_secret

log = logging.getLogger(__name__)

# Replaces Claude Code's coding-agent system prompt (ClaudeCLIProvider.systemPrompt).
SYSTEM_PROMPT = (
    "You are a data extraction and classification engine inside a receipts app. Follow the "
    "user's instructions exactly and answer only with the requested JSON. You have no tools."
)
AUTH_MESSAGE = (
    "The Claude subscription login is missing or expired. Run `claude setup-token` on your Mac "
    "and put the new CLAUDE_CODE_OAUTH_TOKEN into backend/.env.production, then redeploy."
)
USAGE_LIMIT_MESSAGE = "Subscription usage limit reached, retry later"
_AUTH_RE = re.compile(
    r"not logged in|/login|login expired|token (has )?expired|token is invalid|"
    r"access token is invalid|failed to authenticate|authentication[_ ]error|"
    r"invalid (x-)?api key|invalid bearer|unauthorized|oauth token (is )?(invalid|revoked)",
    re.I,
)
_LIMIT_RE = re.compile(
    r"usage limit|hit your limit|limit reached|rate[ _]limit|too many requests|"
    r"out of (extra )?usage|session limit|weekly limit|resets? (at )?\d",
    re.I,
)


@dataclass
class CliRun:
    returncode: int | None
    stdout: str
    stderr: str


def stream_json_message(image: bytes, media_type: str, prompt: str) -> bytes:
    """One stream-json user message: the image block first, then the prompt text."""
    message = {
        "type": "user",
        "message": {
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": media_type,
                        "data": base64.standard_b64encode(image).decode("ascii"),
                    },
                },
                {"type": "text", "text": prompt},
            ],
        },
    }
    return json.dumps(message).encode() + b"\n"


def parse_envelope(stdout: str) -> dict[str, Any] | None:
    """The `result` message of `--output-format json` (an object, or a list of messages)."""
    try:
        data = json.loads(stdout)
    except ValueError:
        return None
    if isinstance(data, list):
        data = next(
            (m for m in reversed(data) if isinstance(m, dict) and m.get("type") == "result"), None
        )
    return data if isinstance(data, dict) else None


def classify_failure(
    envelope: dict[str, Any] | None, stdout: str, stderr: str, returncode: int | None
) -> LLMError:
    status = (envelope or {}).get("api_error_status")
    text = str((envelope or {}).get("result") or "") or f"{stdout[:300]} {stderr[:300]}"
    if status == 429 or _LIMIT_RE.search(text):
        return LLMError("usage_limit", USAGE_LIMIT_MESSAGE, retryable=True)
    if status in (401, 403) or _AUTH_RE.search(text):
        return LLMError("auth", AUTH_MESSAGE)
    detail = redact(text.strip())[:300] or "no output"
    return LLMError(
        "cli_error",
        f"Claude Code failed (exit {returncode}): {detail}",
        retryable=isinstance(status, int) and status >= 500,
    )


def result_text(envelope: dict[str, Any]) -> str:
    """`structured_output` if present, else the `result` text (parsed leniently downstream)."""
    structured = envelope.get("structured_output")
    if structured is not None:
        return json.dumps(structured)
    return str(envelope.get("result") or "")


def _run_sync(coro: Any) -> Any:
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    with ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, coro).result()


class ClaudeCodeProvider:
    def __init__(self, settings: ReceiptsSettings):
        self.settings = settings

    @property
    def provider_id(self) -> str:
        return f"claude-cli-token/{self.settings.receipts_llm_model}"

    def argv(self, exe: str, schema: dict[str, Any], *, image_input: bool) -> list[str]:
        s = self.settings
        args = [
            exe,
            "-p",
            "--model",
            s.receipts_llm_model,
            "--output-format",
            "json",
            "--json-schema",
            json.dumps(anthropic_compatible(schema), separators=(",", ":")),
            "--max-turns",
            "3",
            "--tools",
            "",
            "--strict-mcp-config",
            "--setting-sources",
            "",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--permission-mode",
            "dontAsk",
            "--system-prompt",
            SYSTEM_PROMPT,
            "--effort",
            s.receipts_llm_effort,
        ]
        if image_input:
            args += ["--input-format", "stream-json"]
        return args

    @staticmethod
    def env(token: str, home: str) -> dict[str, str]:
        """Exactly what the CLI needs. ANTHROPIC_API_KEY must never be here (it would win)."""
        return {
            "PATH": os.environ.get("PATH") or "/usr/local/bin:/usr/bin:/bin",
            "HOME": home,
            "CLAUDE_CODE_OAUTH_TOKEN": token,
            "DISABLE_AUTOUPDATER": "1",
        }

    async def _run_cli(self, argv_for: Any, stdin: bytes, token: str) -> CliRun:
        s = self.settings
        exe = shutil.which(s.receipts_cli_path)
        if exe is None:
            raise LLMError(
                "cli_missing", f"The Claude Code CLI (`{s.receipts_cli_path}`) is not installed."
            )
        with tempfile.TemporaryDirectory(prefix="receipts-cli-") as tmp:
            home, cwd = Path(tmp, "home"), Path(tmp, "cwd")
            home.mkdir()
            cwd.mkdir()
            try:
                proc = await asyncio.create_subprocess_exec(
                    *argv_for(exe),
                    stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                    cwd=str(cwd),
                    env=self.env(token, str(home)),
                )
            except OSError as exc:
                raise LLMError(
                    "cli_missing", redact(f"Could not start the Claude Code CLI: {exc}")
                ) from None
            try:
                out, err = await asyncio.wait_for(
                    proc.communicate(stdin), timeout=s.receipts_cli_timeout_s
                )
            except TimeoutError:
                proc.kill()
                await proc.wait()
                raise LLMError(
                    "timeout",
                    f"Claude Code did not answer within {s.receipts_cli_timeout_s:.0f} s.",
                    retryable=True,
                ) from None
        return CliRun(
            proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")
        )

    async def _call(self, argv_for: Any, stdin: bytes) -> LLMResponse:
        token = self.settings.llm_oauth_token
        if token is None:
            raise LLMError("auth", AUTH_MESSAGE)
        install_log_redaction()
        register_secret(token)
        run = await self._run_cli(argv_for, stdin, token)
        envelope = parse_envelope(run.stdout)
        if run.returncode != 0 or envelope is None or envelope.get("is_error"):
            if run.stderr.strip():
                log.warning("claude cli stderr: %s", redact(run.stderr.strip())[:500])
            raise classify_failure(envelope, run.stdout, run.stderr, run.returncode)
        stop = envelope.get("stop_reason")
        if stop == "refusal":
            raise LLMError(
                "refusal", "Claude declined to answer this request (stop_reason: refusal)."
            )
        if stop == "max_tokens":
            raise LLMError(
                "truncated",
                "Claude's answer was cut off (stop_reason: max_tokens).",
                retryable=True,
            )
        text = result_text(envelope)
        if not text.strip():
            raise LLMError("empty", "Claude Code returned no answer.", retryable=True)
        return LLMResponse(text, self.provider_id)

    def extract_receipt(
        self, image: bytes, media_type: str, prompt: str, schema: dict[str, Any], max_tokens: int
    ) -> LLMResponse:
        stdin = stream_json_message(image, media_type, prompt)
        return _run_sync(self._call(lambda exe: self.argv(exe, schema, image_input=True), stdin))

    def classify(self, prompt: str, schema: dict[str, Any], max_tokens: int) -> LLMResponse:
        return _run_sync(
            self._call(lambda exe: self.argv(exe, schema, image_input=False), prompt.encode())
        )
