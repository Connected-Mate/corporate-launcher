#!/usr/bin/env python3
"""Dev rules installer for Corporate Launcher.

Reads a JSON config that describes WHERE the company's internal dev rules
live (inline string, local file, or a git repo) and materialises them as
`<launcher-dir>/dev-rules.md`. That file is later appended to the
launcher's system prompt via `launcher.sh --append-system-prompt-file`,
so the AI assistant always carries the corporate coding standards on top
of the 15 cyber controls.

Usage:
    dev-rules-installer.py --config dev-rules.json \\
        --launcher-dir ~/.local/share/${CORP_SLUG}/launcher

    dev-rules-installer.py --config dev-rules.json \\
        --launcher-dir <dir> --dry-run

Config schema (dev-rules.json):
    {
      "CORP_NAME": "Acme Corp",
      "DEV_RULES_MODE": "git",         # none | inline | local | git
      "DEV_RULES_CONTENT": "...",      # markdown string (mode=inline)
      "DEV_RULES_LOCAL_PATH": "...",   # absolute path (mode=local)
      "DEV_RULES_GIT_URL": "https://...",   # repo URL (mode=git)
      "DEV_RULES_GIT_REF": "main",          # branch / tag / commit
      "DEV_RULES_GIT_PATH": "docs/dev-rules.md"   # file inside the repo
    }

Exit codes:
    0  OK
    2  invalid config
    3  source file not found
    4  git clone / checkout failure
    5  secret detected in rules content

Anti-patterns enforced:
    - Never log the rules body (could be confidential).
    - Never commit DEV_RULES_LOCAL_PATH into a public repo by accident
      (we copy the content out, we never reference the path at runtime).
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

MAX_BYTES = 100 * 1024  # 100 KB hard cap on the rendered dev-rules.md
VALID_MODES = {"none", "inline", "local", "git"}

# Regex patterns that flag obvious secrets — keep conservative, false
# positives are cheaper than leaking a key into a system prompt.
SECRET_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("openai-key", re.compile(r"\bsk-[A-Za-z0-9]{20,}\b")),
    ("anthropic-key", re.compile(r"\bsk-ant-[A-Za-z0-9\-_]{20,}\b")),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("aws-secret", re.compile(r"\baws_secret_access_key\s*=\s*\S+", re.IGNORECASE)),
    ("github-token", re.compile(r"\bghp_[A-Za-z0-9]{30,}\b")),
    ("gitlab-token", re.compile(r"\bglpat-[A-Za-z0-9\-_]{20,}\b")),
    ("google-key", re.compile(r"\bAIza[0-9A-Za-z\-_]{30,}\b")),
    ("private-key-block", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9\-]{10,}\b")),
]


def log(msg: str) -> None:
    """Emit a status line to stderr. Never contains rules content."""
    print(f"[dev-rules-installer] {msg}", file=sys.stderr)


def fail(code: int, msg: str) -> None:
    log(f"ERROR: {msg}")
    sys.exit(code)


def load_config(path: Path) -> dict[str, Any]:
    if not path.is_file():
        fail(2, f"config file not found: {path}")
    try:
        cfg = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(2, f"invalid JSON in {path}: {exc}")
    if not isinstance(cfg, dict):
        fail(2, "config root must be a JSON object")
    mode = cfg.get("DEV_RULES_MODE", "none")
    if mode not in VALID_MODES:
        fail(2, f"DEV_RULES_MODE must be one of {sorted(VALID_MODES)}, got {mode!r}")
    return cfg


def fetch_inline(cfg: dict[str, Any]) -> str:
    content = cfg.get("DEV_RULES_CONTENT")
    if not isinstance(content, str) or not content.strip():
        fail(2, "mode=inline requires non-empty DEV_RULES_CONTENT string")
    return content  # type: ignore[return-value]


def fetch_local(cfg: dict[str, Any]) -> str:
    raw = cfg.get("DEV_RULES_LOCAL_PATH")
    if not isinstance(raw, str) or not raw.strip():
        fail(2, "mode=local requires DEV_RULES_LOCAL_PATH")
    src = Path(raw).expanduser()
    if not src.is_file():
        fail(3, f"local rules file not found: {src}")
    try:
        return src.read_text(encoding="utf-8")
    except OSError as exc:
        fail(3, f"cannot read {src}: {exc}")
    return ""  # unreachable


def fetch_git(cfg: dict[str, Any]) -> str:
    url = cfg.get("DEV_RULES_GIT_URL")
    ref = cfg.get("DEV_RULES_GIT_REF", "main")
    rel_path = cfg.get("DEV_RULES_GIT_PATH")
    if not isinstance(url, str) or not url.strip():
        fail(2, "mode=git requires DEV_RULES_GIT_URL")
    if not isinstance(rel_path, str) or not rel_path.strip():
        fail(2, "mode=git requires DEV_RULES_GIT_PATH")

    with tempfile.TemporaryDirectory(prefix="dev-rules-") as tmp:
        tmp_path = Path(tmp)
        log(f"cloning {url} @ {ref} (shallow)")
        try:
            subprocess.run(
                ["git", "clone", "--depth", "1", "--branch", str(ref), url, str(tmp_path / "repo")],
                check=True,
                capture_output=True,
                timeout=120,
            )
        except FileNotFoundError:
            fail(4, "git binary not found on PATH")
        except subprocess.TimeoutExpired:
            fail(4, "git clone timed out after 120s")
        except subprocess.CalledProcessError as exc:
            # Fallback: clone default branch then checkout ref (handles SHAs).
            log("shallow clone with --branch failed, retrying with full ref checkout")
            try:
                subprocess.run(
                    ["git", "clone", url, str(tmp_path / "repo")],
                    check=True,
                    capture_output=True,
                    timeout=180,
                )
                subprocess.run(
                    ["git", "-C", str(tmp_path / "repo"), "checkout", str(ref)],
                    check=True,
                    capture_output=True,
                    timeout=60,
                )
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                fail(4, f"git checkout {ref} failed (stderr suppressed for safety)")
                _ = exc  # keep reference, never log content

        target = (tmp_path / "repo" / rel_path).resolve()
        repo_root = (tmp_path / "repo").resolve()
        # Defence against ../../ path traversal in the config.
        if repo_root not in target.parents and target != repo_root:
            fail(2, "DEV_RULES_GIT_PATH escapes the cloned repo")
        if not target.is_file():
            fail(3, f"DEV_RULES_GIT_PATH not found inside repo: {rel_path}")
        try:
            return target.read_text(encoding="utf-8")
        except OSError as exc:
            fail(3, f"cannot read {target.name}: {exc}")
    return ""  # unreachable


def scan_for_secrets(text: str) -> list[str]:
    hits: list[str] = []
    for name, pattern in SECRET_PATTERNS:
        if pattern.search(text):
            hits.append(name)
    return hits


def count_sections(body: str) -> int:
    """Count top-level markdown sections (# or ##) — used for the recap line."""
    n = 0
    for line in body.splitlines():
        s = line.lstrip()
        if s.startswith("# ") or s.startswith("## "):
            n += 1
    return max(n, 1)


def build_header(corp_name: str, mode: str) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return (
        f"# {corp_name} — Development Rules\n\n"
        f"Sourced: {mode}\n"
        f"Generated: {ts}\n"
        f"Do not edit — re-run dev-rules-installer.py to update.\n\n"
        f"---\n\n"
    )


def render_minimal(corp_name: str) -> str:
    return (
        build_header(corp_name, "none")
        + "_No corporate dev rules defined for this launcher._\n"
    )


def write_output(launcher_dir: Path, content: str, dry_run: bool) -> Path:
    out = launcher_dir / "dev-rules.md"
    if dry_run:
        log(f"[dry-run] would write {len(content.encode('utf-8'))} bytes to {out}")
        return out
    launcher_dir.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".md.tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(out)
    return out


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="dev-rules-installer.py",
        description="Materialise the company's dev rules into <launcher-dir>/dev-rules.md.",
    )
    p.add_argument("--config", required=True, type=Path, help="path to dev-rules.json")
    p.add_argument("--launcher-dir", required=True, type=Path, help="launcher install dir")
    p.add_argument("--dry-run", action="store_true", help="validate + print plan, write nothing")
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    cfg = load_config(args.config)
    mode: str = cfg["DEV_RULES_MODE"] if "DEV_RULES_MODE" in cfg else "none"
    corp_name = str(cfg.get("CORP_NAME", "Corporate")).strip() or "Corporate"

    log(f"mode={mode} corp={corp_name} launcher-dir={args.launcher_dir}")

    if mode == "none":
        out = write_output(args.launcher_dir, render_minimal(corp_name), args.dry_run)
        print(f"Installed 0 rules sections into {out}")
        return 0

    if mode == "inline":
        body = fetch_inline(cfg)
    elif mode == "local":
        body = fetch_local(cfg)
    elif mode == "git":
        body = fetch_git(cfg)
    else:  # pragma: no cover — guarded in load_config
        fail(2, f"unknown mode: {mode}")
        return 2

    # Validate: must look like markdown (heuristic: not binary, has text)
    if "\x00" in body:
        fail(2, "rules content looks binary (NUL byte found)")

    # Validate: size cap. We check the PRE-header body so the header
    # cannot push us over by itself.
    if len(body.encode("utf-8")) > MAX_BYTES:
        fail(2, f"rules content exceeds {MAX_BYTES} bytes")

    # Validate: secret scan. We do NOT log matches — only the category.
    leaks = scan_for_secrets(body)
    if leaks:
        fail(5, f"possible secret detected in rules content: {', '.join(leaks)}")

    n_sections = count_sections(body)
    rendered = build_header(corp_name, mode) + body
    if not rendered.endswith("\n"):
        rendered += "\n"

    # Final size guard after header injection.
    if len(rendered.encode("utf-8")) > MAX_BYTES:
        fail(2, f"final rendered file exceeds {MAX_BYTES} bytes")

    out = write_output(args.launcher_dir, rendered, args.dry_run)
    print(f"Installed {n_sections} rules sections into {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
