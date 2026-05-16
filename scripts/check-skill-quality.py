#!/usr/bin/env python3
"""Programmatic quality checker for the corporate-launcher skill.

Runs a fixed battery of structural and content checks against the
skill living at ``<repo-root>/`` (auto-detected from this file's path).
Each check is independent, reports 0 or 1, and contributes a single
line to a scored report. The final score is ``N/M`` where ``M`` is the
total number of checks executed.

Usage::

    python3 scripts/check-skill-quality.py
    python3 scripts/check-skill-quality.py --strict

In ``--strict`` mode the process exit code is ``M - N`` (so a perfect
run exits 0 and each miss bumps the exit code by 1, capped at 125 by
POSIX convention). Without ``--strict`` the exit code is always 0 and
the script is purely informational.

Conventions:
    - Python 3.10+, stdlib only.
    - Type-annotated, dataclass-based check results.
    - No network, no writes, no mutation of the skill tree.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent

DESCRIPTION_MAX = 1500
TRIGGER_KEYWORDS = ("wrap", "white-label", "corporate", "internal")
TRIGGER_MIN_HITS = 3
PUSHY_PHRASES = (
    "make sure to use this skill whenever",
    "always use this skill when",
    "use this skill whenever",
)

SKILL_BODY_MAX_LINES = 500
REFERENCE_TOC_LINE_THRESHOLD = 300
TOC_PATTERN = re.compile(r"^##+\s+(table of contents|contents|toc)\b", re.IGNORECASE | re.MULTILINE)

FORBIDDEN_TERMS = ("patrick", "sncf", "tgv europe")

REQUIRED_DIRS = ("references", "templates", "scripts")
REQUIRED_SCRIPTS = ("render.py", "generate.py")
EVALS_FILE = Path("evals") / "evals.json"
SYNC_VARS = Path("tests") / "sync-vars.py"
TEST_RENDER = Path("tests") / "test_render.py"


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------


@dataclass
class CheckResult:
    """One programmatic check outcome."""

    name: str
    passed: bool
    comment: str = ""

    @property
    def score(self) -> int:
        return 1 if self.passed else 0


@dataclass
class Report:
    """Aggregated checker run."""

    results: list[CheckResult] = field(default_factory=list)

    def add(self, result: CheckResult) -> None:
        self.results.append(result)

    @property
    def total(self) -> int:
        return len(self.results)

    @property
    def passed(self) -> int:
        return sum(r.score for r in self.results)

    @property
    def missed(self) -> int:
        return self.total - self.passed

    def render(self) -> str:
        width = max((len(r.name) for r in self.results), default=10)
        lines = ["Corporate Launcher — skill quality report", "=" * 46, ""]
        for r in self.results:
            mark = "PASS" if r.passed else "FAIL"
            lines.append(f"  [{mark}] {r.name.ljust(width)}  {r.comment}")
        lines.append("")
        lines.append(f"Score: {self.passed}/{self.total}")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"cannot read {path}: {exc}")


def _split_frontmatter(text: str) -> tuple[str, str]:
    """Return ``(frontmatter, body)``. Frontmatter is the raw YAML-ish
    block between the leading ``---`` fences. Body is everything after.
    Empty strings if no frontmatter is found."""
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.DOTALL)
    if not m:
        return "", text
    return m.group(1), m.group(2)


def _yaml_field(frontmatter: str, key: str) -> str | None:
    """Cheap YAML-ish single-key extractor — good enough for ``name:``
    and ``description:`` which are flat strings on one logical line
    (possibly very long). Stops at the next top-level ``key:`` line."""
    pattern = rf"^{re.escape(key)}:\s*(.+?)(?=^[a-zA-Z_][\w-]*:\s|\Z)"
    m = re.search(pattern, frontmatter, re.DOTALL | re.MULTILINE)
    if not m:
        return None
    return m.group(1).strip()


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------


def check_frontmatter_required(skill_md: str, report: Report) -> dict[str, str]:
    """Both ``name`` and ``description`` are present in frontmatter."""
    fm, _ = _split_frontmatter(skill_md)
    name = _yaml_field(fm, "name") or ""
    desc = _yaml_field(fm, "description") or ""
    ok = bool(name) and bool(desc)
    report.add(CheckResult(
        "frontmatter has name+description",
        ok,
        f"name={'yes' if name else 'MISSING'}, description={'yes' if desc else 'MISSING'}",
    ))
    return {"name": name, "description": desc}


def check_description_length(desc: str, report: Report) -> None:
    n = len(desc)
    ok = 0 < n <= DESCRIPTION_MAX
    report.add(CheckResult(
        "description ≤ 1500 chars",
        ok,
        f"{n} chars (limit {DESCRIPTION_MAX})",
    ))


def check_description_triggers(desc: str, report: Report) -> None:
    low = desc.lower()
    hits = sum(low.count(kw) for kw in TRIGGER_KEYWORDS)
    ok = hits >= TRIGGER_MIN_HITS
    report.add(CheckResult(
        "description has triggering keywords",
        ok,
        f"{hits} keyword mentions (need ≥{TRIGGER_MIN_HITS}) across {TRIGGER_KEYWORDS}",
    ))


def check_description_pushy(desc: str, report: Report) -> None:
    low = desc.lower()
    matched = next((p for p in PUSHY_PHRASES if p in low), None)
    report.add(CheckResult(
        "description ends with pushy phrase",
        matched is not None,
        f'matched "{matched}"' if matched else f"missing any of {PUSHY_PHRASES}",
    ))


def check_skill_body_length(skill_md: str, report: Report) -> None:
    _, body = _split_frontmatter(skill_md)
    n = body.count("\n") + 1
    ok = n < SKILL_BODY_MAX_LINES
    report.add(CheckResult(
        "SKILL.md body < 500 lines",
        ok,
        f"{n} body lines (limit {SKILL_BODY_MAX_LINES})",
    ))


def check_section_present(skill_md: str, section_re: re.Pattern[str], label: str, report: Report) -> None:
    ok = section_re.search(skill_md) is not None
    report.add(CheckResult(f"SKILL.md has '{label}' section", ok, "found" if ok else "missing"))


def check_antipattern_rationale(skill_md: str, report: Report) -> None:
    """Every bullet under ``## Anti-patterns`` mentions ``because``."""
    m = re.search(r"^## Anti-patterns.*?$(.*?)(?=^## |\Z)", skill_md, re.DOTALL | re.MULTILINE)
    if not m:
        report.add(CheckResult(
            "anti-pattern bullets have 'because' rationale",
            False,
            "no Anti-patterns section",
        ))
        return
    section = m.group(1)
    bullets = [ln for ln in section.splitlines() if ln.lstrip().startswith("- ")]
    if not bullets:
        report.add(CheckResult(
            "anti-pattern bullets have 'because' rationale",
            False,
            "Anti-patterns section has no bullets",
        ))
        return
    missing = [b for b in bullets if "because" not in b.lower()]
    ok = not missing
    report.add(CheckResult(
        "anti-pattern bullets have 'because' rationale",
        ok,
        f"{len(bullets) - len(missing)}/{len(bullets)} bullets justified",
    ))


def check_structure(report: Report) -> None:
    """``references/``, ``templates/``, ``scripts/`` exist (plural)."""
    missing_dirs = [d for d in REQUIRED_DIRS if not (ROOT / d).is_dir()]
    legacy = (ROOT / "reference").exists()  # singular = legacy typo
    ok = not missing_dirs and not legacy
    parts = []
    if missing_dirs:
        parts.append("missing " + ",".join(missing_dirs))
    if legacy:
        parts.append("found singular reference/ — must be references/")
    if ok:
        parts.append("references/, templates/, scripts/ all present")
    report.add(CheckResult("required dirs present (plural)", ok, "; ".join(parts)))

    missing_scripts = [s for s in REQUIRED_SCRIPTS if not (ROOT / "scripts" / s).exists()]
    report.add(CheckResult(
        "scripts/render.py + scripts/generate.py exist",
        not missing_scripts,
        "ok" if not missing_scripts else f"missing {missing_scripts}",
    ))

    evals_ok = (ROOT / EVALS_FILE).exists()
    report.add(CheckResult(
        "evals/evals.json exists",
        evals_ok,
        "found" if evals_ok else f"missing {EVALS_FILE}",
    ))


def check_references_toc(report: Report) -> None:
    ref_dir = ROOT / "references"
    if not ref_dir.is_dir():
        report.add(CheckResult(
            "references >300 lines have a TOC",
            False,
            "references/ missing",
        ))
        return
    offenders: list[str] = []
    checked = 0
    for path in sorted(ref_dir.rglob("*.md")):
        text = _read(path)
        lines = text.count("\n") + 1
        if lines <= REFERENCE_TOC_LINE_THRESHOLD:
            continue
        checked += 1
        if not TOC_PATTERN.search(text):
            offenders.append(path.relative_to(ROOT).as_posix())
    ok = not offenders
    if checked == 0:
        comment = "no references over threshold"
    elif ok:
        comment = f"{checked} long files, all have a TOC"
    else:
        comment = f"missing TOC in {offenders}"
    report.add(CheckResult("references >300 lines have a TOC", ok, comment))


def check_no_forbidden_terms(report: Report) -> None:
    scopes = [ROOT / "references", ROOT / "scripts", ROOT / "templates", ROOT / "SKILL.md"]
    pattern = re.compile("|".join(re.escape(t) for t in FORBIDDEN_TERMS), re.IGNORECASE)
    self_path = Path(__file__).resolve()
    hits: list[str] = []
    for scope in scopes:
        if scope.is_file():
            paths = [scope]
        elif scope.is_dir():
            paths = list(scope.rglob("*"))
        else:
            continue
        for path in paths:
            if not path.is_file():
                continue
            # Skip the checker itself (FORBIDDEN_TERMS is by definition listed inside it).
            if path.resolve() == self_path:
                continue
            if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".ico"}:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            if pattern.search(text):
                hits.append(path.relative_to(ROOT).as_posix())
    ok = not hits
    report.add(CheckResult(
        "no forbidden brand terms in body",
        ok,
        "clean" if ok else f"hits in {hits[:5]}{'...' if len(hits) > 5 else ''}",
    ))


def check_sync_vars(report: Report) -> None:
    script = ROOT / SYNC_VARS
    if not script.exists():
        report.add(CheckResult(
            "templates ↔ interview-flow sync (sync-vars.py)",
            False,
            f"missing {SYNC_VARS}",
        ))
        return
    try:
        proc = subprocess.run(
            [sys.executable, str(script)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        report.add(CheckResult(
            "templates ↔ interview-flow sync (sync-vars.py)",
            False,
            f"error: {exc}",
        ))
        return
    if proc.returncode == 0:
        comment = "no drift"
    else:
        first_err = (proc.stderr or proc.stdout or "").strip().splitlines()
        snippet = first_err[0] if first_err else "non-zero exit"
        comment = f"drift (exit {proc.returncode}): {snippet[:120]}"
    report.add(CheckResult(
        "templates ↔ interview-flow sync (sync-vars.py)",
        proc.returncode == 0,
        comment,
    ))


def check_pytest_collect(report: Report) -> None:
    test_file = ROOT / TEST_RENDER
    if not test_file.exists():
        report.add(CheckResult(
            "tests/test_render.py collects under pytest",
            False,
            f"missing {TEST_RENDER}",
        ))
        return
    pytest_bin = shutil.which("pytest")
    cmd: list[str]
    if pytest_bin:
        cmd = [pytest_bin, "--collect-only", "-q", str(test_file)]
    else:
        # Fall back to ``python -m pytest`` if pytest is importable
        try:
            __import__("pytest")
            cmd = [sys.executable, "-m", "pytest", "--collect-only", "-q", str(test_file)]
        except ImportError:
            report.add(CheckResult(
                "tests/test_render.py collects under pytest",
                False,
                "pytest not installed (pip install pytest)",
            ))
            return
    try:
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, OSError) as exc:
        report.add(CheckResult(
            "tests/test_render.py collects under pytest",
            False,
            f"error: {exc}",
        ))
        return
    ok = proc.returncode == 0
    if ok:
        # last non-empty line usually shows the collected count
        tail = [ln for ln in (proc.stdout or "").splitlines() if ln.strip()]
        comment = tail[-1] if tail else "collected"
    else:
        first = (proc.stderr or proc.stdout or "").strip().splitlines()
        comment = f"exit {proc.returncode}: {(first[0] if first else '')[:120]}"
    report.add(CheckResult("tests/test_render.py collects under pytest", ok, comment))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run() -> Report:
    skill_path = ROOT / "SKILL.md"
    if not skill_path.exists():
        raise SystemExit(f"SKILL.md not found at {skill_path}")
    skill_md = _read(skill_path)
    report = Report()

    # 1. frontmatter
    fields = check_frontmatter_required(skill_md, report)
    check_description_length(fields["description"], report)
    check_description_triggers(fields["description"], report)
    check_description_pushy(fields["description"], report)

    # 2. body
    check_skill_body_length(skill_md, report)
    check_section_present(
        skill_md,
        re.compile(r"^##+\s+when to use\b", re.IGNORECASE | re.MULTILINE),
        "When to use",
        report,
    )
    check_section_present(
        skill_md,
        re.compile(r"^##+\s+anti-?patterns?\b", re.IGNORECASE | re.MULTILINE),
        "Anti-patterns",
        report,
    )
    check_antipattern_rationale(skill_md, report)

    # 3. structure
    check_structure(report)

    # 4. references
    check_references_toc(report)
    check_no_forbidden_terms(report)

    # 5. templates ↔ interview drift
    check_sync_vars(report)

    # 6. tests
    check_pytest_collect(report)

    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero (M-N) when any check fails",
    )
    args = parser.parse_args(argv)

    report = run()
    print(report.render())

    if args.strict:
        return min(report.missed, 125)
    return 0


if __name__ == "__main__":
    sys.exit(main())
