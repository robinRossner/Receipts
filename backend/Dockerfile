# Receipts server. Multi-arch (linux/amd64 + linux/arm64: Oracle Ampere A1 VM).

# ---- builder: resolve + install locked deps into /opt/venv with uv ----
FROM python:3.12-slim AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/venv

COPY --from=ghcr.io/astral-sh/uv:0.13.5 /uv /usr/local/bin/uv

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# ---- claude-cli: the native Claude Code binary (extraction provider `claude_code`, Claude
# subscription via CLAUDE_CODE_OAUTH_TOKEN, the `claude_code` extraction provider). Version + SHA-256 pinned, verified in the script;
# bump all three together (checksums: downloads.claude.ai/claude-code-releases/<v>/manifest.json).
FROM python:3.12-slim AS claude-cli
ARG CLAUDE_CODE_VERSION=2.1.310
ARG CLAUDE_CODE_SHA256_ARM64=9c64d9a7442436b65fcd7cc02c1aa0051bb5a7041e7788576ed3b5f29c447d54
ARG CLAUDE_CODE_SHA256_X64=b73676430af12f97316a798b8371f81d640f90a58bdcb8f3ce56a835bb47df56
COPY docker/install_claude_cli.py /tmp/install_claude_cli.py
RUN python /tmp/install_claude_cli.py "$CLAUDE_CODE_VERSION" \
    "$CLAUDE_CODE_SHA256_ARM64" "$CLAUDE_CODE_SHA256_X64" /usr/local/bin/claude

# ---- runtime: no uv, no build tooling, non-root ----
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    HOME=/tmp \
    DISABLE_AUTOUPDATER=1 \
    RECEIPTS_DATABASE_URL=sqlite:////app/var/receipts.db \
    RECEIPTS_PHOTOS_DIR=/app/var/receipts_photos

COPY --from=builder /opt/venv /opt/venv
# world-executable, so it also runs as the host uid compose passes in (HOME=/tmp is writable)
COPY --from=claude-cli /usr/local/bin/claude /usr/local/bin/claude

WORKDIR /app
COPY . .

# All mutable state lives in /app/var (receipts.db, receipts_photos/); BACKEND_DIR
# (core/settings.py) resolves to /app, so the settings defaults already point there.
# Layout in the image: /app/server.py, /app/core, /app/receipts (code, Alembic, data), /app/alembic.ini.
# compose may run the container as another uid (the host user) so the bind mount stays writable
# for both the app and the host-side backup cron.
RUN useradd --uid 1000 --no-create-home app \
    && mkdir -p /app/var/receipts_photos \
    && chown -R app /app/var \
    && chmod +x /app/docker-entrypoint.sh
USER app

VOLUME ["/app/var"]
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"

ENTRYPOINT ["/app/docker-entrypoint.sh"]
