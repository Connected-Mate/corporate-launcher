#!/usr/bin/env python3
"""Corporate Launcher self-audit.

Scans a rendered launcher tree against its source config and reports
leaks, missing guardrails, or weak permissions before the bundle ships.

Usage:
    audit-launcher.py --launcher-dir build/acme-copilot \
                      --config examples/configs/acme-claude-litellm.json \
                      [--strict] [--output report.md]

Exit code:
    0 on full pass. With --strict, exit code equals the number of failing
    checks (capped at 125) so CI pipelines can gate on it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Callable, Iterable


# ---------------------------------------------------------------------------
# Detection patterns
# ---------------------------------------------------------------------------

VENDOR_URL_PATTERNS = [
    re.compile(r"\bapi\.anthropic\.com\b"),
    re.compile(r"\bapi\.openai\.com\b"),
    re.compile(r"\bgenerativelanguage\.googleapis\.com\b"),
]

SECRET_PATTERNS = [
    ("anthropic-key", re.compile(r"sk-ant-[A-Za-z0-9_\-]{20,}")),
    ("openai-key", re.compile(r"sk-(?!ant-)[A-Za-z0-9]{20,}")),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("gcp-api-key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("github-pat", re.compile(r"\bghp_[A-Za-z0-9]{36,}\b")),
]

REQUIRED_KILL_SWITCHES = [
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
    "DISABLE_TELEMETRY=1",
    "DISABLE_ERROR_REPORTING=1",
    "DISABLE_BUG_COMMAND=1",
    "DISABLE_AUTOUPDATER=1",
]

TEXT_SUFFIXES = {
    ".sh", ".py", ".md", ".json", ".yml", ".yaml", ".toml", ".txt",
    ".cfg", ".ini", ".env", ".tpl", ".conf", ".bash", ".zsh", ".fish",
    "",  # extension-less binaries (launcher.sh symlink targets)
}

SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "dist"}

# Files that are *reports about* leaks; their content is meta and must not be
# re-scanned (otherwise the audit reports forbidden terms it just emitted).
SKIP_FILE_NAMES = {
    "audit-report.md",
    "audit-report.json",
    "url-purge-report.md",
    "url-purge-list.json",
}


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class CheckResult:
    name: str
    passed: bool
    details: list[str] = field(default_factory=list)

    @property
    def status(self) -> str:
        return "PASS" if self.passed else "FAIL"


@dataclass
class AuditReport:
    launcher_dir: str
    config_path: str
    checks: list[CheckResult] = field(default_factory=list)

    @property
    def failures(self) -> int:
        return sum(1 for c in self.checks if not c.passed)

    @property
    def total(self) -> int:
        return len(self.checks)

    @property
    def score(self) -> int:
        return self.total - self.failures


# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------


def iter_text_files(root: Path) -> Iterable[Path]:
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.name in SKIP_FILE_NAMES:
            continue
        if path.suffix.lower() in TEXT_SUFFIXES or path.suffix == "":
            yield path


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def find_launcher_binary(root: Path, config: dict) -> Path | None:
    slug = str(config.get("CORP_SLUG") or "").strip()
    cli = str(config.get("CC_CLI_NAME") or "").strip()
    candidates: list[Path] = []
    # Primary: the rendered launcher binary is named after CORP_SLUG.
    if slug:
        candidates += list(root.rglob(slug))
    if cli:
        candidates += list(root.rglob(cli))
    candidates += list(root.rglob("launcher.sh"))
    for c in candidates:
        if c.is_file():
            return c
    return None


def line_of(text: str, idx: int) -> int:
    return text.count("\n", 0, idx) + 1


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------


def check_vendor_urls(root: Path, config: dict) -> CheckResult:
    """Flag hardcoded vendor URLs outside permissions.deny / comments."""
    hits: list[str] = []
    # Files that legitimately enumerate vendor URLs as denylist or doc:
    #   - settings.json:       permissions.deny + WebFetch(domain:...)
    #   - BRANDING.md:         lists vendor URLs that are FORBIDDEN
    #   - cyber-rules.md:      cybersecurity prose explaining what to block
    #   - api-probe.sh:        contains backend-specific endpoint fallbacks
    #     that are never bound unless GM_BACKEND is set.
    allow_files = {
        "settings.json",
        "BRANDING.md",
        "cyber-rules.md",
        "api-probe.sh",
        "url-purge.py",
        "audit-launcher.py",
    }
    for path in iter_text_files(root):
        if path.name in allow_files:
            continue
        text = read_text(path)
        # Skip permission-deny JSON blobs by line: ignore lines containing "deny"
        for pat in VENDOR_URL_PATTERNS:
            for m in pat.finditer(text):
                line_no = line_of(text, m.start())
                line = text.splitlines()[line_no - 1] if line_no <= text.count("\n") + 1 else ""
                stripped = line.strip()
                if stripped.startswith("#") or stripped.startswith("//"):
                    continue
                if '"deny"' in text[max(0, m.start() - 200): m.start()].lower():
                    # heuristic: nearby deny key — accept
                    continue
                if "deny" in line.lower():
                    continue
                hits.append(f"{path.relative_to(root)}:{line_no}: {m.group(0)}")
    return CheckResult("hardcoded-vendor-urls", not hits, hits[:20])


def check_plain_secrets(root: Path) -> CheckResult:
    hits: list[str] = []
    for path in iter_text_files(root):
        text = read_text(path)
        for label, pat in SECRET_PATTERNS:
            for m in pat.finditer(text):
                line_no = line_of(text, m.start())
                hits.append(f"{path.name}:{line_no}: {label}: {m.group(0)[:12]}...")
    return CheckResult("plain-text-secrets", not hits, hits[:20])


def check_vpn(root: Path, config: dict) -> CheckResult:
    vpn_required = str(config.get("VPN_REQUIRED", "")).lower() == "yes"
    if not vpn_required:
        return CheckResult("vpn-check-present", True, ["VPN_REQUIRED=no — skipped"])
    binary = find_launcher_binary(root, config)
    if not binary:
        return CheckResult("vpn-check-present", False, ["launcher binary not found"])
    text = read_text(binary)
    # Require check_vpn (definition or call) to appear before any exec line
    exec_idx = re.search(r"^\s*exec\s+", text, re.MULTILINE)
    vpn_idx = re.search(r"check_vpn\b", text)
    if not vpn_idx:
        return CheckResult("vpn-check-present", False,
                           [f"{binary.name}: no check_vpn reference"])
    if exec_idx and vpn_idx.start() > exec_idx.start():
        return CheckResult("vpn-check-present", False,
                           [f"{binary.name}: check_vpn appears AFTER exec"])
    return CheckResult("vpn-check-present", True,
                       [f"{binary.name}: check_vpn gate found"])


def check_cyber_rules(root: Path, config: dict) -> CheckResult:
    details: list[str] = []
    branding = next((p for p in root.rglob("BRANDING.md") if p.is_file()), None)
    rules_name = str(config.get("CORP_RULES_FILE") or "cyber-rules.md")
    rules = next((p for p in root.rglob(rules_name) if p.is_file()), None)
    if not branding:
        details.append("BRANDING.md missing")
    if not rules:
        details.append(f"{rules_name} missing")
    binary = find_launcher_binary(root, config)
    if binary:
        text = read_text(binary)
        if "--append-system-prompt-file" not in text and "append-system-prompt" not in text:
            details.append(f"{binary.name}: no --append-system-prompt-file flag")
        else:
            if branding and branding.name not in text:
                details.append(f"{binary.name}: does not reference BRANDING.md")
            if rules and rules.name not in text:
                details.append(f"{binary.name}: does not reference {rules_name}")
    else:
        details.append("launcher binary not found")
    return CheckResult("cyber-rules-referenced", not details, details)


def check_kill_switches(root: Path, config: dict) -> CheckResult:
    binary = find_launcher_binary(root, config)
    if not binary:
        return CheckResult("telemetry-kill-switches", False, ["launcher binary not found"])
    text = read_text(binary)
    missing: list[str] = []
    for kv in REQUIRED_KILL_SWITCHES:
        key = kv.split("=", 1)[0]
        # Accept any export ... KEY=1 (value may be quoted)
        if not re.search(rf"\b{re.escape(key)}\s*=\s*['\"]?1['\"]?", text):
            missing.append(kv)
    return CheckResult("telemetry-kill-switches", not missing,
                       [f"missing: {m}" for m in missing])


def check_forbidden_terms(root: Path, config: dict) -> CheckResult:
    raw = config.get("FORBIDDEN_TERMS", "")
    terms = [t.strip() for t in str(raw).split(",") if t.strip()]
    if not terms:
        return CheckResult("forbidden-terms", True, ["FORBIDDEN_TERMS empty — skipped"])
    branding = next((p for p in root.rglob("BRANDING.md") if p.is_file()), None)
    details: list[str] = []
    if not branding:
        details.append("BRANDING.md missing — cannot verify allowlist")
    else:
        b_text = read_text(branding)
        for t in terms:
            if t not in b_text:
                details.append(f"BRANDING.md missing term: {t}")
    # Now check no other rendered file contains the literal term
    cyber_rules_name = str(config.get("CORP_RULES_FILE") or "cyber-rules.md")
    # Allowlist: brand doc, cyber rules, and the detector scripts whose JOB
    # is to mention these terms (so they can BLOCK them).
    allow = {
        "BRANDING.md",
        cyber_rules_name,
        "pre-tool-hook.py",
        "url-purge-list.json",
        "url-purge.py",
        "audit-launcher.py",
        # settings.json contains permissions.deny entries that name vendor URLs.
        "settings.json",
    }
    for path in iter_text_files(root):
        if path.name in allow:
            continue
        text = read_text(path)
        for t in terms:
            # word-ish match, but terms may include dots (domains)
            if t in text:
                # tolerate comments
                # report first hit per (file, term)
                idx = text.find(t)
                line_no = line_of(text, idx)
                details.append(f"{path.relative_to(root)}:{line_no}: forbidden term '{t}'")
                break
    return CheckResult("forbidden-terms", not details, details[:25])


def check_ca_handling(root: Path, config: dict) -> CheckResult:
    accepts = str(config.get("ACCEPT_TLS_INSPECTION", "")).lower() == "yes"
    if accepts:
        return CheckResult("ca-handling", True, ["ACCEPT_TLS_INSPECTION=yes — skipped"])
    hits: list[str] = []
    pat = re.compile(r"NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*['\"]?0['\"]?")
    # Markdown docs that *forbid* the pattern are allowed to mention it.
    allow_names = {"cyber-rules.md", "BRANDING.md"}
    for path in iter_text_files(root):
        if path.name in allow_names:
            continue
        text = read_text(path)
        for m in pat.finditer(text):
            line_no = line_of(text, m.start())
            # Look at surrounding context: if the match is inside a clearly
            # dead `if "no" = "yes"` (or `false`) shell branch, treat as safe.
            line_start = text.rfind("\n", 0, m.start()) + 1
            window_start = max(0, m.start() - 400)
            window = text[window_start:m.start()]
            # Match constant-false guards rendered from `${ACCEPT_TLS_INSPECTION}`
            #   if [ "no" = "yes" ]; then ...
            #   if [ "0" = "1" ]; then ...
            #   if false; then ...
            if (
                re.search(r'if\s+\[\s+"no"\s*=\s*"yes"\s+\]', window)
                or re.search(r'if\s+\[\s+"0"\s*=\s*"1"\s+\]', window)
                or re.search(r"if\s+false\b", window)
            ):
                continue
            # Skip commented-out lines.
            line = text[line_start : text.find("\n", m.start()) if text.find("\n", m.start()) != -1 else len(text)]
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith("//"):
                continue
            hits.append(f"{path.relative_to(root)}:{line_no}: TLS bypass")
    return CheckResult("ca-handling", not hits, hits[:20])


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def check_permissions(root: Path, config: dict, config_path: Path) -> CheckResult:
    details: list[str] = []
    binary = find_launcher_binary(root, config)
    if binary:
        m = _mode(binary)
        if not (m & 0o111):
            details.append(f"{binary.name}: not executable (mode {m:o})")
    else:
        details.append("launcher binary not found")
    guard = next((p for p in root.rglob("cyber-guard*") if p.is_file()), None)
    if guard:
        m = _mode(guard)
        if m != 0o555:
            details.append(f"{guard.name}: mode {m:o} (expected 555)")
    # config file: 600 expected — but only flag if the config lives inside
    # the launcher directory (a deployed bundle). Source/example configs that
    # sit elsewhere in the dev tree are exempt.
    try:
        cp = config_path.resolve()
        rt = root.resolve()
        if str(cp).startswith(str(rt) + os.sep):
            m = _mode(config_path)
            if m & 0o077:
                details.append(f"{config_path.name}: mode {m:o} (expected 600)")
    except OSError as e:
        details.append(f"config stat failed: {e}")
    return CheckResult("permissions", not details, details)


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def run_audit(launcher_dir: Path, config_path: Path) -> AuditReport:
    config = json.loads(config_path.read_text(encoding="utf-8"))
    report = AuditReport(str(launcher_dir), str(config_path))
    runners: list[Callable[[], CheckResult]] = [
        lambda: check_vendor_urls(launcher_dir, config),
        lambda: check_plain_secrets(launcher_dir),
        lambda: check_vpn(launcher_dir, config),
        lambda: check_cyber_rules(launcher_dir, config),
        lambda: check_kill_switches(launcher_dir, config),
        lambda: check_forbidden_terms(launcher_dir, config),
        lambda: check_ca_handling(launcher_dir, config),
        lambda: check_permissions(launcher_dir, config, config_path),
    ]
    for fn in runners:
        try:
            report.checks.append(fn())
        except Exception as e:  # noqa: BLE001
            report.checks.append(CheckResult(fn.__name__, False, [f"check crashed: {e}"]))
    return report


def render_markdown(report: AuditReport) -> str:
    lines = [
        "# Corporate Launcher Audit",
        "",
        f"- Launcher: `{report.launcher_dir}`",
        f"- Config:   `{report.config_path}`",
        f"- Score:    **{report.score}/{report.total}**"
        f" ({report.failures} failure{'s' if report.failures != 1 else ''})",
        "",
        "| # | Check | Status |",
        "|---|-------|--------|",
    ]
    for i, c in enumerate(report.checks, 1):
        lines.append(f"| {i} | {c.name} | {c.status} |")
    lines.append("")
    for c in report.checks:
        if c.passed and not c.details:
            continue
        lines.append(f"## {c.name} — {c.status}")
        for d in c.details:
            lines.append(f"- {d}")
        lines.append("")
    return "\n".join(lines)


def render_json(report: AuditReport) -> str:
    payload = {
        "launcher_dir": report.launcher_dir,
        "config_path": report.config_path,
        "score": report.score,
        "total": report.total,
        "failures": report.failures,
        "checks": [asdict(c) for c in report.checks],
    }
    return json.dumps(payload, indent=2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Audit a rendered Corporate Launcher tree.")
    parser.add_argument("--launcher-dir", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--strict", action="store_true",
                        help="Exit code = number of failing checks.")
    parser.add_argument("--output", type=Path, default=None,
                        help="Write markdown report here (sidecar .json written next to it).")
    args = parser.parse_args(argv)

    if not args.launcher_dir.is_dir():
        print(f"error: launcher-dir not found: {args.launcher_dir}", file=sys.stderr)
        return 2
    if not args.config.is_file():
        print(f"error: config not found: {args.config}", file=sys.stderr)
        return 2

    report = run_audit(args.launcher_dir.resolve(), args.config.resolve())
    md = render_markdown(report)
    js = render_json(report)

    if args.output:
        args.output.write_text(md, encoding="utf-8")
        args.output.with_suffix(".json").write_text(js, encoding="utf-8")
    else:
        print(md)

    if args.strict:
        return min(report.failures, 125)
    return 0 if report.failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
