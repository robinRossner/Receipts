"""LLM providers: request shape of the Messages API path, the `claude -p` command line, the
subprocess environment (no ANTHROPIC_API_KEY), error mapping. A fake SDK client and a fake `claude`
script stand in for Claude: no test makes a real call."""

from __future__ import annotations

import base64
import json
import os
import stat
import sys
from types import SimpleNamespace

import anthropic
import httpx
import pytest

from receipts.extraction.prompts import extraction_schema
from receipts.llm import api as api_mod
from receipts.llm import claude_code as cli_mod
from receipts.llm.base import LLMError, anthropic_compatible
from receipts.llm.factory import build_provider, provider_status
from receipts.settings import ReceiptsSettings, get_settings
from tests.receipts_helpers import make_jpeg, make_png

SCHEMA = extraction_schema()
SECRET_KEY = "sk-ant-api03-SECRETSECRETSECRET"
SECRET_TOKEN = "sk-ant-oat01-TOKENTOKENTOKENTOKEN"


def settings(monkeypatch, **env) -> ReceiptsSettings:
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    get_settings.cache_clear()
    return get_settings()


# --------------------------------------------------------------------------- provider choice


def test_provider_resolution(monkeypatch):
    assert settings(monkeypatch).llm_provider_resolved == "none"
    assert provider_status(get_settings())["credential_configured"] is False
    assert settings(monkeypatch, ANTHROPIC_API_KEY=SECRET_KEY).llm_provider_resolved == "api"
    both = settings(monkeypatch, CLAUDE_CODE_OAUTH_TOKEN=SECRET_TOKEN)
    assert both.llm_provider_resolved == "claude_code"  # auto prefers the subscription
    assert settings(monkeypatch, RECEIPTS_LLM_PROVIDER="api").llm_provider_resolved == "api"
    only_cli = settings(monkeypatch, RECEIPTS_LLM_PROVIDER="claude_code")
    assert only_cli.llm_provider_resolved == "claude_code"
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN")
    assert settings(monkeypatch).llm_provider_resolved == "none"  # claude_code without a token


def test_factory_and_status_never_expose_credentials(monkeypatch):
    s = settings(monkeypatch, ANTHROPIC_API_KEY=SECRET_KEY)
    assert isinstance(build_provider(s), api_mod.AnthropicProvider)
    s = settings(monkeypatch, CLAUDE_CODE_OAUTH_TOKEN=SECRET_TOKEN)
    assert isinstance(build_provider(s), cli_mod.ClaudeCodeProvider)
    status = provider_status(s)
    assert status == {
        "provider": "claude_code",
        "requested_provider": "auto",
        "credential_configured": True,
        "billing": "subscription",
        "model": "claude-haiku-5-5",
    }
    assert SECRET_KEY not in str(status) and SECRET_TOKEN not in str(status)
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN")
    monkeypatch.delenv("ANTHROPIC_API_KEY")
    assert build_provider(settings(monkeypatch)) is None


def test_default_model_is_the_one_the_mac_app_uses_and_is_configurable(monkeypatch):
    assert settings(monkeypatch).receipts_llm_model == "claude-haiku-5-5"
    assert settings(monkeypatch, RECEIPTS_LLM_MODEL="claude-opus-5-5").receipts_llm_model == (
        "claude-opus-5-5"
    )


# --------------------------------------------------------------------------- Messages API


class FakeMessages:
    def __init__(self, answer):
        self.answer = answer
        self.calls: list[dict] = []

    def create(self, **kwargs):
        self.calls.append(kwargs)
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer


def fake_client(answer):
    return SimpleNamespace(messages=FakeMessages(answer))


def text_response(text="{}", stop="end_turn"):
    return SimpleNamespace(
        stop_reason=stop,
        content=[SimpleNamespace(type="text", text=text)],
        usage=SimpleNamespace(input_tokens=1, output_tokens=1),
    )


def test_api_request_follows_the_current_rules(monkeypatch):
    s = settings(monkeypatch, ANTHROPIC_API_KEY=SECRET_KEY)
    client = fake_client(text_response('{"ok": true}'))
    provider = api_mod.AnthropicProvider(s, client=client)
    image = make_jpeg(1)
    out = provider.extract_receipt(image, "image/jpeg", "PROMPT", SCHEMA, 2048)
    assert out.text == '{"ok": true}' and out.provider_id == "anthropic-api/claude-haiku-5-5"

    kw = client.messages.calls[0]
    assert kw["model"] == "claude-haiku-5-5" and kw["max_tokens"] == 8192
    # nothing the current models reject: no sampling params, thinking switch or forced tool use
    for banned in ("temperature", "top_p", "top_k", "thinking", "tool_choice", "tools", "system"):
        assert banned not in kw
    (msg,) = kw["messages"]  # one user turn: no assistant prefill
    assert msg["role"] == "user"
    img, txt = msg["content"]
    assert img["type"] == "image" and img["source"]["media_type"] == "image/jpeg"
    assert base64.b64decode(img["source"]["data"]) == image
    assert txt == {"type": "text", "text": "PROMPT"}
    fmt = kw["output_config"]["format"]
    assert fmt["type"] == "json_schema" and fmt["schema"]["additionalProperties"] is False
    assert kw["output_config"]["effort"] == "medium"


def test_png_media_type_is_passed_through(monkeypatch):
    client = fake_client(text_response())
    api_mod.AnthropicProvider(settings(monkeypatch), client=client).extract_receipt(
        make_png(1), "image/png", "p", SCHEMA, 100
    )
    assert (
        client.messages.calls[0]["messages"][0]["content"][0]["source"]["media_type"] == "image/png"
    )


def test_classify_is_text_only_with_room_for_thinking(monkeypatch):
    client = fake_client(text_response())
    api_mod.AnthropicProvider(settings(monkeypatch), client=client).classify("P", SCHEMA, 180)
    kw = client.messages.calls[0]
    assert kw["messages"][0]["content"] == [{"type": "text", "text": "P"}]
    assert kw["max_tokens"] == api_mod.CLASSIFY_MIN_TOKENS


def test_structured_output_schema_is_made_compatible():
    schema = {
        "type": "object",
        "properties": {
            "n": {"type": "integer", "minimum": 1, "maximum": 5, "enum": [1, 2]},
            "name": {"type": "string", "maxLength": 20},
            "list": {
                "type": "array",
                "minItems": 3,
                "maxItems": 4,
                "items": {"type": "object", "properties": {}},
            },
        },
        "required": ["n"],
    }
    out = anthropic_compatible(schema)
    assert out["additionalProperties"] is False
    assert out["properties"]["n"] == {"type": "integer", "enum": [1, 2]}
    assert out["properties"]["name"] == {"type": "string"}
    assert out["properties"]["list"]["items"]["additionalProperties"] is False
    assert (
        "minItems" not in out["properties"]["list"] and "maxItems" not in out["properties"]["list"]
    )
    assert "minimum" in schema["properties"]["n"]  # the input is not modified


class ExplodingContent:
    stop_reason = "refusal"
    usage = None

    @property
    def content(self):
        raise AssertionError("content must not be read when stop_reason is refusal")


def test_refusal_and_truncation_are_checked_before_content(monkeypatch):
    s = settings(monkeypatch)
    with pytest.raises(LLMError) as exc:
        api_mod.AnthropicProvider(s, client=fake_client(ExplodingContent())).classify(
            "p", SCHEMA, 10
        )
    assert exc.value.kind == "refusal" and exc.value.retryable is False
    truncated = SimpleNamespace(stop_reason="max_tokens", content=[], usage=None)
    with pytest.raises(LLMError) as exc:
        api_mod.AnthropicProvider(s, client=fake_client(truncated)).classify("p", SCHEMA, 10)
    assert exc.value.kind == "truncated" and exc.value.retryable is True
    with pytest.raises(LLMError) as exc:
        api_mod.AnthropicProvider(s, client=fake_client(text_response("  "))).classify(
            "p", SCHEMA, 10
        )
    assert exc.value.kind == "empty"


def test_api_errors_are_mapped_and_carry_no_secrets(monkeypatch):
    s = settings(monkeypatch)
    req = httpx.Request("POST", "https://api.anthropic.com/v1/messages")

    def status_error(cls, code):
        return cls(f"boom {SECRET_KEY}", response=httpx.Response(code, request=req), body=None)

    cases = [
        (status_error(anthropic.RateLimitError, 429), "rate_limit", True),
        (status_error(anthropic.InternalServerError, 529), "api_status", True),
        (status_error(anthropic.BadRequestError, 400), "api_status", False),
        (anthropic.APIConnectionError(request=req), "connection", True),
    ]
    for error, kind, retryable in cases:
        provider = api_mod.AnthropicProvider(s, client=fake_client(error))
        with pytest.raises(LLMError) as exc:
            provider.classify("p", SCHEMA, 10)
        assert (exc.value.kind, exc.value.retryable) == (kind, retryable)
        assert SECRET_KEY not in exc.value.message


def test_oversized_image_is_refused_before_any_call(monkeypatch):
    client = fake_client(text_response())
    provider = api_mod.AnthropicProvider(settings(monkeypatch), client=client)
    with pytest.raises(LLMError) as exc:
        provider.extract_receipt(b"\xff" * (6 * 1024 * 1024), "image/jpeg", "p", SCHEMA, 10)
    assert exc.value.kind == "image_too_large" and client.messages.calls == []


def test_api_provider_needs_a_key(monkeypatch):
    provider = api_mod.AnthropicProvider(settings(monkeypatch))
    with pytest.raises(LLMError) as exc:
        provider.classify("p", SCHEMA, 10)
    assert exc.value.kind == "no_credential"


# --------------------------------------------------------------------------- claude -p


def test_cli_command_line(monkeypatch):
    provider = cli_mod.ClaudeCodeProvider(
        settings(monkeypatch, CLAUDE_CODE_OAUTH_TOKEN=SECRET_TOKEN)
    )
    argv = provider.argv("/bin/claude", SCHEMA, image_input=True)

    def after(flag):
        return argv[argv.index(flag) + 1]

    assert argv[:2] == ["/bin/claude", "-p"]
    assert after("--model") == "claude-haiku-5-5"
    # --input-format stream-json is only accepted with stream-json output, which needs --verbose
    assert after("--output-format") == "stream-json" and "--verbose" in argv
    assert after("--tools") == ""  # no tools: the image goes in through the prompt, not a file
    assert after("--setting-sources") == ""
    assert after("--permission-mode") == "dontAsk"
    assert after("--max-turns") == "3"
    assert after("--input-format") == "stream-json"
    assert after("--system-prompt") == cli_mod.SYSTEM_PROMPT
    assert json.loads(after("--json-schema"))["additionalProperties"] is False
    for flag in ("--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"):
        assert flag in argv
    assert "--bare" not in argv
    assert SECRET_TOKEN not in " ".join(argv)  # the token never goes through argv
    text_only = provider.argv("/bin/claude", SCHEMA, image_input=False)
    assert "--input-format" not in text_only
    assert text_only[text_only.index("--output-format") + 1] == "json"
    assert "--verbose" not in text_only


def cli_argv_problem(argv):
    """The CLI's own argument check (message copied from Claude Code 2.1.314), or None if valid."""
    flag = lambda name: argv[argv.index(name) + 1] if name in argv else None  # noqa: E731
    if flag("--input-format") == "stream-json" and flag("--output-format") != "stream-json":
        return "Error: --input-format=stream-json requires output-format=stream-json."
    if flag("--output-format") == "stream-json" and "--verbose" not in argv:
        return "Error: When using --print, --output-format=stream-json requires --verbose"
    return None


@pytest.mark.parametrize("image_input", [True, False])
def test_cli_argv_is_accepted_by_the_clis_own_validation(monkeypatch, image_input):
    provider = cli_mod.ClaudeCodeProvider(settings(monkeypatch))
    assert cli_argv_problem(provider.argv("/bin/claude", SCHEMA, image_input=image_input)) is None
    # the former combination (json output + stream-json input) is exactly what the CLI rejected
    broken = ["claude", "-p", "--output-format", "json", "--input-format", "stream-json"]
    assert "requires output-format=stream-json" in cli_argv_problem(broken)


def test_cli_environment_is_minimal_and_has_no_api_key(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", SECRET_KEY)
    monkeypatch.setenv("ANTHROPIC_AUTH_TOKEN", "other")
    monkeypatch.setenv("SOME_SERVER_SECRET", "hunter2")
    env = cli_mod.ClaudeCodeProvider.env(SECRET_TOKEN, "/tmp/home")
    assert set(env) == {"PATH", "HOME", "CLAUDE_CODE_OAUTH_TOKEN", "DISABLE_AUTOUPDATER"}
    assert env["HOME"] == "/tmp/home" and env["CLAUDE_CODE_OAUTH_TOKEN"] == SECRET_TOKEN


def test_stream_json_message_has_the_image_block_first():
    image = make_jpeg(3)
    raw = cli_mod.stream_json_message(image, "image/jpeg", "PROMPT")
    assert raw.endswith(b"\n") and raw.count(b"\n") == 1
    msg = json.loads(raw)
    assert msg["type"] == "user" and msg["message"]["role"] == "user"
    img, txt = msg["message"]["content"]
    assert img["type"] == "image" and base64.b64decode(img["source"]["data"]) == image
    assert txt == {"type": "text", "text": "PROMPT"}


FAKE_CLAUDE = """import json, os, sys
out = {out!r}  # the server environment is scrubbed, so the path is baked in
argv = sys.argv
open(out + ".env", "w").write(json.dumps(dict(os.environ)))
open(out + ".argv", "w").write(json.dumps(argv))
open(out + ".stdin", "wb").write(sys.stdin.buffer.read())
open(out + ".cwd", "w").write(os.getcwd())
fmt = argv[argv.index("--output-format") + 1]
if "--input-format" in argv and fmt != "stream-json":  # what the real CLI does
    sys.stderr.write("Error: --input-format=stream-json requires output-format=stream-json.\\n")
    sys.exit(1)
result = {{"type": "result", "subtype": "success", "is_error": False, "stop_reason": "end_turn",
    "structured_output": {{"store": "Edeka", "items": []}}}}
if fmt == "stream-json":
    for event in ({{"type": "system", "subtype": "init"}}, {{"type": "assistant"}}, result):
        sys.stdout.write(json.dumps(event) + "\\n")
else:
    sys.stdout.write(json.dumps(result))
"""


def test_extract_through_a_fake_claude_binary(monkeypatch, tmp_path):
    """The real subprocess plumbing against a script that records what it was given."""
    exe = tmp_path / "claude"
    out = tmp_path / "captured"
    script = tmp_path / "fake_claude.py"
    script.write_text(FAKE_CLAUDE.format(out=str(out)))
    # a shell wrapper: a shebang line breaks when the interpreter path contains a space
    exe.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n')
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("ANTHROPIC_API_KEY", SECRET_KEY)  # in the server's environment...
    monkeypatch.setenv("SOME_SERVER_SECRET", "hunter2")
    s = settings(monkeypatch, CLAUDE_CODE_OAUTH_TOKEN=SECRET_TOKEN, RECEIPTS_CLI_PATH=str(exe))
    image = make_jpeg(5)
    response = cli_mod.ClaudeCodeProvider(s).extract_receipt(
        image, "image/jpeg", "PROMPT", SCHEMA, 100
    )
    assert json.loads(response.text) == {"store": "Edeka", "items": []}
    assert response.provider_id == "claude-cli-token/claude-haiku-5-5"

    env = json.loads((tmp_path / "captured.env").read_text())
    assert "ANTHROPIC_API_KEY" not in env and "SOME_SERVER_SECRET" not in env  # ...not in the CLI's
    assert env["CLAUDE_CODE_OAUTH_TOKEN"] == SECRET_TOKEN
    sent = json.loads((tmp_path / "captured.stdin").read_text())
    assert base64.b64decode(sent["message"]["content"][0]["source"]["data"]) == image
    argv = json.loads((tmp_path / "captured.argv").read_text())
    assert "--input-format" in argv and SECRET_TOKEN not in " ".join(argv)
    cwd = (tmp_path / "captured.cwd").read_text()
    assert cwd != os.getcwd() and not os.path.exists(cwd)  # an empty temp dir, removed afterwards


def test_cli_without_binary_or_token(monkeypatch):
    s = settings(
        monkeypatch, CLAUDE_CODE_OAUTH_TOKEN=SECRET_TOKEN, RECEIPTS_CLI_PATH="/no/such/claude"
    )
    with pytest.raises(LLMError) as exc:
        cli_mod.ClaudeCodeProvider(s).classify("p", SCHEMA, 10)
    assert exc.value.kind == "cli_missing"
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN")
    with pytest.raises(LLMError) as exc:
        cli_mod.ClaudeCodeProvider(settings(monkeypatch)).classify("p", SCHEMA, 10)
    assert exc.value.kind == "auth"


def test_cli_envelope_parsing_and_failure_mapping():
    env = {"type": "result", "structured_output": {"a": 1}, "result": "ignored"}
    assert json.loads(cli_mod.result_text(env)) == {"a": 1}
    assert cli_mod.result_text({"result": "plain"}) == "plain"
    listed = json.dumps([{"type": "system"}, {"type": "result", "result": "x"}])
    assert cli_mod.parse_envelope(listed) == {"type": "result", "result": "x"}
    assert cli_mod.parse_envelope("not json") is None

    limit = cli_mod.classify_failure(
        {"is_error": True, "result": "Claude usage limit reached"}, "", "", 1
    )
    assert (limit.kind, limit.retryable) == ("usage_limit", True)
    auth = cli_mod.classify_failure({"is_error": True, "result": "Invalid API key"}, "", "", 1)
    assert (auth.kind, auth.retryable) == ("auth", False)
    other = cli_mod.classify_failure(None, "", f"crashed with {SECRET_KEY}", 2)
    assert other.kind == "cli_error"


# --------------------------------------------------------------------------- stream-json output
# Shapes captured from real `claude -p --output-format stream-json --verbose` runs of Claude Code
# 2.1.314 (receipt photo + --json-schema + --max-turns 3 + --tools ""), with ids, session data and
# long fields removed. The answer arrives twice in the final `result` message: `structured_output`
# (an object) and `result` (the same JSON as text). `stop_reason` there is "tool_use" on success,
# because the schema is answered through an internal StructuredOutput tool call.

RECEIPT = {"store": "Musterladen Testmarkt", "date": "2026-10-15", "items": [], "total": 12.87}

REAL_STREAM_EVENTS = [
    {
        "type": "system",
        "subtype": "init",
        "cwd": "/tmp/x",
        "model": "claude-haiku-5-5",
        "tools": [],
    },
    {"type": "system", "subtype": "thinking_tokens"},
    {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "thinking"}]}},
    {
        "type": "assistant",
        "message": {
            "role": "assistant",
            "content": [{"type": "tool_use", "name": "StructuredOutput", "input": RECEIPT}],
        },
    },
    {
        "type": "user",
        "message": {"role": "user", "content": [{"type": "tool_result"}]},
        "tool_use_result": "Structured output provided successfully",
    },
    {"type": "rate_limit_event", "rate_limit_info": {"status": "allowed"}},
    {
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "api_error_status": None,
        "stop_reason": "tool_use",
        "terminal_reason": "completed",
        "num_turns": 2,
        "result": json.dumps(RECEIPT, separators=(",", ":")),
        "structured_output": RECEIPT,
    },
]
# a bad --model: exit 1, an error result whose subtype is (oddly) still "success"
REAL_ERROR_EVENTS = [
    {"type": "system", "subtype": "init", "model": "no-such-model"},
    {"type": "assistant", "error": "model_not_found", "api_error_status": 404},
    {
        "type": "result",
        "subtype": "success",
        "is_error": True,
        "api_error_status": 404,
        "stop_reason": "stop_sequence",
        "terminal_reason": "api_error",
        "num_turns": 1,
        "result": "There's an issue with the selected model (no-such-model). It may not exist.",
    },
]


def ndjson(events) -> str:
    return "".join(json.dumps(e) + "\n" for e in events)


def run_with_stdout(monkeypatch, stdout, *, returncode=0, stderr=""):
    """Provider._call against canned CLI output (no process is started)."""
    provider = cli_mod.ClaudeCodeProvider(
        settings(monkeypatch, CLAUDE_CODE_OAUTH_TOKEN=SECRET_TOKEN)
    )

    async def fake_run(self, argv_for, stdin, token):
        return cli_mod.CliRun(returncode, stdout, stderr)

    monkeypatch.setattr(cli_mod.ClaudeCodeProvider, "_run_cli", fake_run)
    return provider.extract_receipt(make_jpeg(1), "image/jpeg", "PROMPT", SCHEMA, 100)


def test_ndjson_stream_parses_to_the_final_result():
    envelope = cli_mod.parse_envelope(ndjson(REAL_STREAM_EVENTS))
    assert envelope["type"] == "result" and envelope["num_turns"] == 2
    assert json.loads(cli_mod.result_text(envelope)) == RECEIPT


def test_ndjson_tolerates_blank_lines_and_noise_and_takes_the_last_result():
    early = {"type": "result", "subtype": "success", "result": "early"}
    noisy = "warming up\n\n" + ndjson([early]) + "\n" + ndjson(REAL_STREAM_EVENTS)
    assert cli_mod.parse_envelope(noisy)["structured_output"] == RECEIPT
    # one-line output is still plain JSON, and a stream without a result has no envelope
    assert cli_mod.parse_envelope(json.dumps(REAL_STREAM_EVENTS[-1]))["is_error"] is False
    assert cli_mod.parse_envelope(ndjson(REAL_STREAM_EVENTS[:-1])) is None
    assert cli_mod.parse_envelope("") is None


def test_stream_extraction_returns_the_structured_output(monkeypatch):
    response = run_with_stdout(monkeypatch, ndjson(REAL_STREAM_EVENTS))
    assert json.loads(response.text) == RECEIPT
    assert response.provider_id == "claude-cli-token/claude-haiku-5-5"


def test_stream_extraction_falls_back_to_the_result_text(monkeypatch):
    events = [dict(e) for e in REAL_STREAM_EVENTS]
    del events[-1]["structured_output"]
    response = run_with_stdout(monkeypatch, ndjson(events))
    assert json.loads(response.text) == RECEIPT


def test_stream_error_result_is_a_cli_error_with_the_clis_message(monkeypatch):
    with pytest.raises(LLMError) as exc:
        run_with_stdout(
            monkeypatch,
            ndjson(REAL_ERROR_EVENTS),
            returncode=1,
            stderr='[claude-code:unrecognized_model] {"model":"no-such-model"}',
        )
    assert exc.value.kind == "cli_error" and not exc.value.retryable
    assert "selected model" in exc.value.message and "exit 1" in exc.value.message
    assert "init" not in exc.value.message  # not the first stream line


def test_stream_error_results_map_to_limit_and_auth(monkeypatch):
    def error_stream(**fields):
        return ndjson(
            [{"type": "system", "subtype": "init"}, {"type": "result", "is_error": True, **fields}]
        )

    with pytest.raises(LLMError) as exc:
        run_with_stdout(monkeypatch, error_stream(api_error_status=429, result="x"), returncode=1)
    assert (exc.value.kind, exc.value.retryable) == ("usage_limit", True)
    with pytest.raises(LLMError) as exc:
        run_with_stdout(monkeypatch, error_stream(result="Invalid API key - /login"), returncode=1)
    assert exc.value.kind == "auth"
    with pytest.raises(LLMError) as exc:
        run_with_stdout(
            monkeypatch, error_stream(api_error_status=529, result="overloaded"), returncode=1
        )
    assert exc.value.kind == "cli_error" and exc.value.retryable


def test_error_subtype_without_is_error_is_still_a_failure(monkeypatch):
    stream = ndjson(
        [
            {"type": "system", "subtype": "init"},
            {"type": "result", "subtype": "error_max_turns", "is_error": False, "num_turns": 4},
        ]
    )
    with pytest.raises(LLMError) as exc:
        run_with_stdout(monkeypatch, stream)
    assert exc.value.kind == "cli_error" and "error_max_turns" in exc.value.message


def test_truncated_stream_is_reported_as_truncated_not_as_garbage(monkeypatch):
    full = ndjson(REAL_STREAM_EVENTS)
    cut_mid_result = full[: full.rindex('"structured_output"')]  # the result line is cut off
    for stdout in (cut_mid_result, ndjson(REAL_STREAM_EVENTS[:-1])):
        with pytest.raises(LLMError) as exc:
            run_with_stdout(monkeypatch, stdout)
        assert exc.value.kind == "cli_error" and exc.value.retryable
        assert "without a result" in exc.value.message
    # killed mid-stream: non-zero exit and stderr, no result at all
    with pytest.raises(LLMError) as exc:
        run_with_stdout(monkeypatch, cut_mid_result, returncode=137, stderr="Killed: 9")
    assert exc.value.kind == "cli_error" and "Killed" in exc.value.message
    with pytest.raises(LLMError) as exc:
        run_with_stdout(monkeypatch, "", returncode=0)
    assert exc.value.kind == "cli_error" and "no output" in exc.value.message
