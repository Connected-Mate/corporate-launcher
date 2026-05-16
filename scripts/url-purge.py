#!/usr/bin/env python3
"""url-purge.py — scan a rendered launcher tree for vendor public endpoints.

Verifies no mention of api.anthropic.com / api.openai.com / etc. leaks into
the generated launcher EXCEPT inside `permissions.deny` arrays or `# tpl:`
template comments. Used as a post-render step by the corporate
launcher generator.

Usage:
    python3 scripts/url-purge.py \\
        --launcher-dir <path> \\
        --config <config.json> \\
        [--strict] [--report report.md] [--patch]
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

# --------------------------------------------------------------------------- #
# Fallback blocklist used when templates/shared/url-purge-list.json is absent.
# --------------------------------------------------------------------------- #
FALLBACK_BLOCKLIST: list[str] = [
    "api.anthropic.com",
    "api.openai.com",
    "api.mistral.ai",
    "generativelanguage.googleapis.com",
    "api.cohere.ai",
    "api.deepseek.com",
    "api.groq.com",
    "api.together.xyz",
    "api.perplexity.ai",
    "api.x.ai",
    "console.anthropic.com",
    "platform.openai.com",
]

EXCLUDED_DIRS = {".git", "__pycache__", "node_modules", ".venv", "venv", ".mypy_cache"}
# Files we never scan: either reports we just emitted, or detector data that
# legitimately enumerates the very URLs we want to block.
EXCLUDED_FILES = {
    "url-purge-report.md",
    "url-purge-list.json",
    "audit-report.md",
    "audit-report.json",
    "compliance.docx",
}
SENTINEL = "[BLOCKED-VENDOR-URL]"
COMMENT_PREFIXES = ("#", "//", "--", ";", "/*", "*")
DOC_SECTION_KEYWORDS = (
    "not allowed", "blocked", "denied", "forbidden", "interdit", "bloque",
    "white-label", "white label", "identity",
)


# --------------------------------------------------------------------------- #
# Data classes
# --------------------------------------------------------------------------- #
@dataclass
class Finding:
    file: Path
    line_no: int
    url: str
    verdict: str  # "VIOLATION" | "OK (deny list)" | "OK (comment)" | "OK (doc)"
    snippet: str = ""

    @property
    def is_violation(self) -> bool:
        return self.verdict == "VIOLATION"


@dataclass
class ScanResult:
    findings: list[Finding] = field(default_factory=list)

    @property
    def violations(self) -> list[Finding]:
        return [f for f in self.findings if f.is_violation]


# --------------------------------------------------------------------------- #
# Blocklist loading
# --------------------------------------------------------------------------- #
def load_blocklist(launcher_dir: Path) -> list[str]:
    """Load url-purge-list.json from templates/shared, else use fallback."""
    candidates = [
        launcher_dir / "templates" / "shared" / "url-purge-list.json",
        launcher_dir.parent / "templates" / "shared" / "url-purge-list.json",
        Path(__file__).resolve().parent.parent / "templates" / "shared" / "url-purge-list.json",
    ]
    for path in candidates:
        if path.is_file():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(data, dict) and "urls" in data:
                    return list(data["urls"])
                if isinstance(data, list):
                    return list(data)
            except (json.JSONDecodeError, OSError):
                continue
    return FALLBACK_BLOCKLIST


# --------------------------------------------------------------------------- #
# Classification logic
# --------------------------------------------------------------------------- #
def iter_files(root: Path) -> Iterable[Path]:
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in EXCLUDED_DIRS for part in path.parts):
            continue
        if path.name in EXCLUDED_FILES:
            continue
        yield path


def is_comment_line(line: str, suffix: str) -> bool:
    stripped = line.lstrip()
    if stripped.startswith(COMMENT_PREFIXES):
        return True
    # Template-style markers `# tpl:` already covered by `#` prefix.
    # JSON has no comments; HTML/XML comments rarely host URLs in our trees.
    return False


def is_in_deny_list(file_path: Path, line_no: int, lines: list[str]) -> bool:
    """Heuristic: is the URL inside a `"deny": [...]` block of settings.json?"""
    if file_path.name not in {"settings.json", "settings.local.json"}:
        return False
    # Walk backwards looking for `"deny"` opening before any closing `]` of permissions.
    bracket_depth = 0
    for idx in range(line_no - 1, -1, -1):
        text = lines[idx]
        bracket_depth += text.count("]") - text.count("[")
        if '"deny"' in text and bracket_depth <= 0:
            return True
        if bracket_depth > 0:
            # We've left the array we were in.
            return False
    return False


def is_in_doc_blocked_section(
    file_path: Path, line_no: int, lines: list[str]
) -> bool:
    """For .md files: is the URL beneath a heading mentioning blocked/denied?"""
    if file_path.suffix.lower() != ".md":
        return False
    heading_re = re.compile(r"^\s{0,3}#{1,6}\s+(.*)$")
    for idx in range(line_no - 1, -1, -1):
        m = heading_re.match(lines[idx])
        if m:
            heading = m.group(1).lower()
            return any(kw in heading for kw in DOC_SECTION_KEYWORDS)
    return False


def has_purge_allow_marker(line: str, lines: list[str], line_no: int) -> bool:
    """Honour `# url-purge: allow` inline marker on same/previous line."""
    marker = "url-purge: allow"
    if marker in line:
        return True
    if line_no >= 2 and marker in lines[line_no - 2]:
        return True
    return False


def classify(
    file_path: Path, line_no: int, line: str, lines: list[str], suffix: str
) -> str:
    if has_purge_allow_marker(line, lines, line_no):
        return "OK (marker)"
    if is_in_deny_list(file_path, line_no, lines):
        return "OK (deny list)"
    if is_comment_line(line, suffix):
        return "OK (comment)"
    if is_in_doc_blocked_section(file_path, line_no, lines):
        return "OK (doc)"
    return "VIOLATION"


# --------------------------------------------------------------------------- #
# Scanning
# --------------------------------------------------------------------------- #
def build_pattern(blocklist: list[str]) -> re.Pattern[str]:
    escaped = sorted((re.escape(u) for u in blocklist), key=len, reverse=True)
    return re.compile("|".join(escaped))


def scan_file(path: Path, pattern: re.Pattern[str]) -> list[Finding]:
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return []
    lines = text.splitlines()
    out: list[Finding] = []
    suffix = path.suffix.lower()
    for line_no, line in enumerate(lines, start=1):
        for match in pattern.finditer(line):
            url = match.group(0)
            verdict = classify(path, line_no, line, lines, suffix)
            out.append(
                Finding(
                    file=path,
                    line_no=line_no,
                    url=url,
                    verdict=verdict,
                    snippet=line.strip()[:120],
                )
            )
    return out


def scan_tree(root: Path, blocklist: list[str]) -> ScanResult:
    pattern = build_pattern(blocklist)
    result = ScanResult()
    for f in iter_files(root):
        result.findings.extend(scan_file(f, pattern))
    return result


# --------------------------------------------------------------------------- #
# Patching
# --------------------------------------------------------------------------- #
def patch_violations(result: ScanResult, root: Path) -> int:
    """Rewrite each violation line, replacing URL with SENTINEL. Returns count."""
    by_file: dict[Path, list[Finding]] = {}
    for f in result.violations:
        by_file.setdefault(f.file, []).append(f)
    patched = 0
    for path, items in by_file.items():
        backup = path.with_suffix(path.suffix + ".bak")
        shutil.copy2(path, backup)
        text = path.read_text(encoding="utf-8")
        for it in items:
            text = text.replace(it.url, SENTINEL)
            patched += 1
        path.write_text(text, encoding="utf-8")
    return patched


# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #
def render_report(result: ScanResult, root: Path) -> str:
    lines = [
        "# URL purge report",
        "",
        f"Root: `{root}`",
        f"Findings: {len(result.findings)} (violations: {len(result.violations)})",
        "",
        "| File | Line | URL | Verdict |",
        "|------|------|-----|---------|",
    ]
    for f in result.findings:
        rel = f.file.relative_to(root) if f.file.is_relative_to(root) else f.file
        lines.append(f"| `{rel}` | {f.line_no} | `{f.url}` | {f.verdict} |")
    return "\n".join(lines) + "\n"


def render_console(result: ScanResult, root: Path) -> str:
    rows = [("File", "Line", "URL", "Verdict")]
    for f in result.findings:
        rel = f.file.relative_to(root) if f.file.is_relative_to(root) else f.file
        rows.append((str(rel), str(f.line_no), f.url, f.verdict))
    widths = [max(len(r[i]) for r in rows) for i in range(4)]
    out = []
    for i, r in enumerate(rows):
        out.append("  ".join(c.ljust(widths[j]) for j, c in enumerate(r)))
        if i == 0:
            out.append("  ".join("-" * w for w in widths))
    return "\n".join(out)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Scan launcher tree for vendor URL leaks.")
    p.add_argument("--launcher-dir", required=True, type=Path)
    p.add_argument("--config", required=True, type=Path)
    p.add_argument("--strict", action="store_true", help="Exit code = #violations")
    p.add_argument("--report", type=Path, help="Write markdown report to this path")
    p.add_argument("--patch", action="store_true", help="Replace violating URLs in-place (.bak backup)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    root: Path = args.launcher_dir.resolve()
    if not root.is_dir():
        print(f"error: launcher-dir not found: {root}", file=sys.stderr)
        return 2
    if not args.config.is_file():
        print(f"error: config not found: {args.config}", file=sys.stderr)
        return 2

    blocklist = load_blocklist(root)
    result = scan_tree(root, blocklist)

    if result.findings:
        print(render_console(result, root))
    else:
        print("No vendor URLs found.")

    if args.report:
        args.report.write_text(render_report(result, root), encoding="utf-8")
        print(f"\nReport written: {args.report}")

    if args.patch and result.violations:
        n = patch_violations(result, root)
        print(f"Patched {n} violation(s) with sentinel {SENTINEL!r}.")

    print(f"\nViolations: {len(result.violations)}")
    if args.strict:
        return len(result.violations)
    return 0


if __name__ == "__main__":
    sys.exit(main())
