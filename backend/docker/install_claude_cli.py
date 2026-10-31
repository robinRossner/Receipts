"""Download the native Claude Code binary for this CPU, verify its pinned SHA-256, install it.

Usage: install_claude_cli.py VERSION SHA256_ARM64 SHA256_X64 DEST

Source: https://downloads.claude.ai/claude-code-releases/<version>/<platform>/claude, the same
place the official installer (https://claude.ai/install.sh) uses. Only needs the Python stdlib
(the python:3.12-slim image has no curl). glibc build (Debian), not the musl one.
"""

import hashlib
import os
import platform
import sys
import urllib.request

BASE = "https://downloads.claude.ai/claude-code-releases"


def main(version: str, sha_arm64: str, sha_x64: str, dest: str) -> None:
    machine = platform.machine().lower()
    if machine in ("aarch64", "arm64"):
        plat, expected = "linux-arm64", sha_arm64
    elif machine in ("x86_64", "amd64"):
        plat, expected = "linux-x64", sha_x64
    else:
        sys.exit(f"unsupported architecture: {machine}")
    url = f"{BASE}/{version}/{plat}/claude"
    digest = hashlib.sha256()
    tmp = dest + ".part"
    with urllib.request.urlopen(url, timeout=120) as resp, open(tmp, "wb") as out:
        while chunk := resp.read(1 << 20):
            digest.update(chunk)
            out.write(chunk)
    if digest.hexdigest() != expected:
        os.unlink(tmp)
        sys.exit(f"checksum mismatch for {plat} {version}: got {digest.hexdigest()}")
    os.chmod(tmp, 0o755)
    os.replace(tmp, dest)
    print(f"installed claude {version} ({plat}) -> {dest}")


if __name__ == "__main__":
    main(*sys.argv[1:5])
