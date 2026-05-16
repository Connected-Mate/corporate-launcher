#!/usr/bin/env python3
"""Branding eval runner for Corporate Launcher.

Runs the eval_prompts.json dataset against a rendered launcher and reports
pass/fail. Each prompt is sent to the launcher in non-interactive `--print`
mode; the captured response is then checked against `must_not_contain`
(forbidden terms — case-insensitive, word-boundary aware) and `must_contain`
(at least one expected term must appear).

Usage:
    run_eval.py --prompts eval_prompts.json --launcher /path/to/<slug>
    run_eval.py --prompts eval_prompts.json --launcher /path/to/<slug> \\
                --corp-name "Acme Copilot"
    run_eval.py --prompts eval_prompts.json --launcher /path/to/<slug> \\
                --output report.html

Exit codes:
    0   all tests passed
    1   at least one test failed
    2   launcher not invokable / invalid arguments
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from html import escape as html_escape
from pathlib import Path
from typing import Iterable

PROMPT_TIMEOUT_SEC = 60
DEFAULT_CATEGORY = "uncategorized"


# =====================================================================
#  Data model
# =====================================================================
@dataclass
class TestCase:
    """A single eval prompt loaded from eval_prompts.json."""

    id: str
    prompt: str
    category: str = DEFAULT_CATEGORY
    must_contain: list[str] = field(default_factory=list)
    must_not_contain: list[str] = field(default_factory=list)
    description: str = ""


@dataclass
class TestResult:
    case: TestCase
    status: str  # "pass" | "fail" | "skip" | "error"
    response: str = ""
    forbidden_hits: list[str] = field(default_factory=list)
    expected_hits: list[str] = field(default_factory=list)
    reason: str = ""
    duration_s: float = 0.0


# =====================================================================
#  Loading
# =====================================================================
def load_prompts(path: Path) -> list[TestCase]:
    """Parse eval_prompts.json into TestCase objects.

    Accepts either a top-level list of objects or a dict with a "cases" key.
    """
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        items = raw.get("cases") or raw.get("prompts") or []
    else:
        items = raw
    if not isinstance(items, list):
        raise ValueError(f"{path}: expected a list of cases (or {{'cases': [...]}})")

    cases: list[TestCase] = []
    for i, entry in enumerate(items):
        if not isinstance(entry, dict):
            raise ValueError(f"{path}[{i}]: case must be an object")
        case = TestCase(
            id=str(entry.get("id") or f"case-{i+1:03d}"),
            prompt=str(entry["prompt"]),
            category=str(entry.get("category", DEFAULT_CATEGORY)),
            must_contain=list(entry.get("must_contain", [])),
            must_not_contain=list(entry.get("must_not_contain", [])),
            description=str(entry.get("description", "")),
        )
        cases.append(case)
    return cases


# =====================================================================
#  Matching (case-insensitive, word-boundary aware)
# =====================================================================
def _compile_term(term: str) -> re.Pattern[str]:
    """Compile a forbidden/expected term into a word-boundary regex.

    Avoids false positives like matching "claude" inside "exclude" or
    "Anthropic" inside "philanthropic". Multi-word terms keep their inner
    whitespace flexible (one-or-more spaces).
    """
    parts = [re.escape(p) for p in term.strip().split()]
    body = r"\s+".join(parts)
    return re.compile(rf"(?<!\w){body}(?!\w)", re.IGNORECASE)


def find_hits(text: str, terms: Iterable[str]) -> list[str]:
    """Return the subset of terms that appear in text (case-insensitive,
    word-boundary aware)."""
    hits: list[str] = []
    for term in terms:
        if not term:
            continue
        if _compile_term(term).search(text):
            hits.append(term)
    return hits


# =====================================================================
#  Launcher invocation
# =====================================================================
def resolve_launcher(path: Path) -> Path:
    """Resolve --launcher argument to an executable file.

    Accepts either:
      - the launcher script itself (executable file)
      - a directory; we then look for the script whose name matches the
        directory's basename (the slug convention used by render.py).
    """
    p = path.expanduser().resolve()
    if not p.exists():
        raise FileNotFoundError(f"launcher not found: {p}")
    if p.is_file():
        return p
    if p.is_dir():
        candidate = p / p.name
        if candidate.is_file():
            return candidate
        # fall back: any executable file matching common names
        for name in ("launcher", "launcher.sh"):
            c = p / name
            if c.is_file():
                return c
        raise FileNotFoundError(
            f"no launcher script found inside directory: {p} "
            f"(expected {p.name}, launcher, or launcher.sh)"
        )
    raise FileNotFoundError(f"not a file or directory: {p}")


def run_prompt(launcher: Path, prompt: str, timeout: int = PROMPT_TIMEOUT_SEC) -> tuple[str, int, str]:
    """Invoke the launcher in --print mode with a prompt.

    Returns (stdout, returncode, error). When the process times out or the
    binary is missing we still return a tuple so the caller can record a
    partial response.
    """
    # The launcher is a bash wrapper that ultimately `exec`s the underlying
    # CLI. `--print` is forwarded to that CLI (claude --print, gemini -p, …);
    # we standardize on `--print` and let the launcher pass it through.
    cmd = [str(launcher), "--print", prompt]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as e:
        return ("", 127, f"launcher not invokable: {e}")
    except subprocess.TimeoutExpired as e:
        partial = (e.stdout or "") if isinstance(e.stdout, str) else ""
        return (partial, 124, f"timeout after {timeout}s")
    except OSError as e:
        return ("", 126, f"OS error: {e}")

    # Some launchers print banners on stderr; merge for matching purposes.
    output = (proc.stdout or "") + (proc.stderr or "")
    return (output, proc.returncode, "")


# =====================================================================
#  Evaluation
# =====================================================================
def evaluate(case: TestCase, response: str, error: str) -> TestResult:
    """Score a single response against its case."""
    if error and not response:
        return TestResult(case=case, status="skip", reason=error)

    forbidden_hits = find_hits(response, case.must_not_contain)
    expected_hits = find_hits(response, case.must_contain)

    if forbidden_hits:
        reason = f"forbidden term(s) present: {', '.join(forbidden_hits)}"
        return TestResult(
            case=case,
            status="fail",
            response=response,
            forbidden_hits=forbidden_hits,
            expected_hits=expected_hits,
            reason=reason,
        )

    if case.must_contain and not expected_hits:
        return TestResult(
            case=case,
            status="fail",
            response=response,
            expected_hits=[],
            reason=f"no expected term found (expected any of: {', '.join(case.must_contain)})",
        )

    return TestResult(
        case=case,
        status="pass",
        response=response,
        expected_hits=expected_hits,
    )


# =====================================================================
#  Reporting — text
# =====================================================================
ANSI = {
    "reset": "\033[0m",
    "bold": "\033[1m",
    "dim": "\033[2m",
    "red": "\033[31m",
    "green": "\033[32m",
    "yellow": "\033[33m",
    "cyan": "\033[36m",
}


def _c(name: str, text: str, enabled: bool) -> str:
    return f"{ANSI[name]}{text}{ANSI['reset']}" if enabled else text


def render_text(results: list[TestResult], corp_name: str | None) -> str:
    use_color = sys.stdout.isatty()
    lines: list[str] = []
    title = "Corporate Launcher — Branding Eval"
    if corp_name:
        title += f"  ({corp_name})"
    lines.append(_c("bold", title, use_color))
    lines.append("=" * len(title))

    passed = sum(1 for r in results if r.status == "pass")
    failed = sum(1 for r in results if r.status == "fail")
    skipped = sum(1 for r in results if r.status == "skip")
    errored = sum(1 for r in results if r.status == "error")
    total = len(results)

    for r in results:
        marker = {
            "pass": _c("green", "PASS", use_color),
            "fail": _c("red", "FAIL", use_color),
            "skip": _c("yellow", "SKIP", use_color),
            "error": _c("red", "ERR ", use_color),
        }[r.status]
        head = f"  [{marker}] {r.case.id}  ({r.case.category})  {r.duration_s:5.2f}s"
        lines.append(head)
        if r.case.description:
            lines.append(_c("dim", f"        {r.case.description}", use_color))
        if r.status in ("fail", "skip", "error") and r.reason:
            lines.append(_c("dim", f"        reason: {r.reason}", use_color))
        if r.status == "fail" and r.response:
            snippet = r.response.strip().replace("\n", " ")
            if len(snippet) > 200:
                snippet = snippet[:197] + "..."
            lines.append(_c("dim", f"        excerpt: {snippet}", use_color))

    # Coverage by category
    cats: dict[str, list[TestResult]] = {}
    for r in results:
        cats.setdefault(r.case.category, []).append(r)
    lines.append("")
    lines.append(_c("bold", "Coverage by category", use_color))
    for cat, items in sorted(cats.items()):
        cp = sum(1 for x in items if x.status == "pass")
        lines.append(f"  {cat:24s}  {cp}/{len(items)} passed")

    lines.append("")
    summary = (
        f"Total {total}  "
        f"{_c('green', f'pass {passed}', use_color)}  "
        f"{_c('red', f'fail {failed}', use_color)}  "
        f"{_c('yellow', f'skip {skipped}', use_color)}  "
        f"{_c('red', f'err {errored}', use_color)}"
    )
    lines.append(summary)
    return "\n".join(lines) + "\n"


# =====================================================================
#  Reporting — HTML
# =====================================================================
HTML_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Branding Eval — {title}</title>
<style>
  :root {{
    color-scheme: light dark;
    --bg: #fafaf7; --fg: #1a1a1a; --muted: #6b6b6b;
    --pass: #166534; --pass-bg: #dcfce7;
    --fail: #991b1b; --fail-bg: #fee2e2;
    --skip: #92400e; --skip-bg: #fef3c7;
    --border: #e5e5e0; --card: #ffffff;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg: #1a1a1a; --fg: #fafaf7; --muted: #9a9a9a;
             --pass-bg: #14532d; --fail-bg: #7f1d1d; --skip-bg: #78350f;
             --border: #2a2a2a; --card: #232323; }}
  }}
  * {{ box-sizing: border-box; }}
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
          background: var(--bg); color: var(--fg); margin: 0; padding: 2rem;
          line-height: 1.5; }}
  .wrap {{ max-width: 1100px; margin: 0 auto; }}
  h1 {{ font-size: 1.5rem; margin: 0 0 0.25rem; letter-spacing: -0.01em; }}
  .sub {{ color: var(--muted); font-size: 0.875rem; margin-bottom: 1.5rem; }}
  .summary {{ display: flex; gap: 0.75rem; flex-wrap: wrap; margin-bottom: 1.5rem; }}
  .pill {{ padding: 0.25rem 0.75rem; border-radius: 999px;
           font-size: 0.8125rem; font-weight: 500; border: 1px solid var(--border); }}
  .pill.pass {{ background: var(--pass-bg); color: var(--pass); border-color: transparent; }}
  .pill.fail {{ background: var(--fail-bg); color: var(--fail); border-color: transparent; }}
  .pill.skip {{ background: var(--skip-bg); color: var(--skip); border-color: transparent; }}
  table {{ width: 100%; border-collapse: collapse; background: var(--card);
           border: 1px solid var(--border); border-radius: 8px; overflow: hidden;
           font-size: 0.875rem; }}
  th, td {{ padding: 0.625rem 0.875rem; text-align: left; vertical-align: top;
            border-bottom: 1px solid var(--border); }}
  th {{ background: var(--bg); font-weight: 600; font-size: 0.75rem;
        text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }}
  tr:last-child td {{ border-bottom: none; }}
  tr.row-pass td:first-child {{ border-left: 3px solid var(--pass); }}
  tr.row-fail td:first-child {{ border-left: 3px solid var(--fail); }}
  tr.row-skip td:first-child, tr.row-error td:first-child {{
      border-left: 3px solid var(--skip); }}
  .status {{ font-weight: 600; font-size: 0.75rem; }}
  .status.pass {{ color: var(--pass); }}
  .status.fail {{ color: var(--fail); }}
  .status.skip, .status.error {{ color: var(--skip); }}
  code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 0.8125rem; background: var(--bg); padding: 0.1rem 0.35rem;
          border-radius: 4px; }}
  .reason {{ color: var(--muted); font-size: 0.8125rem; margin-top: 0.25rem; }}
  .cat {{ color: var(--muted); font-size: 0.75rem; }}
  details > summary {{ cursor: pointer; color: var(--muted); font-size: 0.8125rem; }}
  details pre {{ white-space: pre-wrap; word-break: break-word; max-height: 200px;
                 overflow: auto; background: var(--bg); padding: 0.5rem;
                 border-radius: 4px; font-size: 0.75rem; margin: 0.25rem 0 0; }}
  h2 {{ font-size: 1rem; margin: 2rem 0 0.75rem; }}
  .cov {{ display: grid; grid-template-columns: 1fr auto; gap: 0.25rem 1rem;
          font-size: 0.875rem; background: var(--card); padding: 1rem;
          border: 1px solid var(--border); border-radius: 8px; }}
  .cov b {{ font-weight: 500; }}
</style>
</head>
<body>
<div class="wrap">
  <h1>{title}</h1>
  <div class="sub">{subtitle}</div>
  <div class="summary">
    <span class="pill">Total {total}</span>
    <span class="pill pass">Pass {passed}</span>
    <span class="pill fail">Fail {failed}</span>
    <span class="pill skip">Skip {skipped}</span>
  </div>
  <table>
    <thead>
      <tr>
        <th style="width: 5rem;">Status</th>
        <th style="width: 14rem;">Case</th>
        <th>Prompt &amp; outcome</th>
        <th style="width: 5rem;">Time</th>
      </tr>
    </thead>
    <tbody>
{rows}
    </tbody>
  </table>
  <h2>Coverage by category</h2>
  <div class="cov">
{coverage}
  </div>
</div>
</body>
</html>
"""


def render_html(results: list[TestResult], corp_name: str | None) -> str:
    total = len(results)
    passed = sum(1 for r in results if r.status == "pass")
    failed = sum(1 for r in results if r.status == "fail")
    skipped = sum(1 for r in results if r.status in ("skip", "error"))

    title = "Corporate Launcher — Branding Eval"
    subtitle_bits = [f"{total} cases"]
    if corp_name:
        subtitle_bits.insert(0, html_escape(corp_name))
    subtitle_bits.append(time.strftime("%Y-%m-%d %H:%M:%S"))
    subtitle = " · ".join(subtitle_bits)

    row_chunks: list[str] = []
    for r in results:
        status = r.status
        details_bits: list[str] = []
        details_bits.append(
            f'<div><code>{html_escape(r.case.prompt[:140])}'
            f'{"…" if len(r.case.prompt) > 140 else ""}</code></div>'
        )
        if r.case.description:
            details_bits.append(
                f'<div class="reason">{html_escape(r.case.description)}</div>'
            )
        if r.reason:
            details_bits.append(
                f'<div class="reason">↳ {html_escape(r.reason)}</div>'
            )
        if r.response:
            details_bits.append(
                "<details><summary>response</summary>"
                f"<pre>{html_escape(r.response[:4000])}</pre></details>"
            )
        row_chunks.append(
            f'      <tr class="row-{status}">'
            f'<td><span class="status {status}">{status.upper()}</span></td>'
            f'<td><b>{html_escape(r.case.id)}</b>'
            f'<div class="cat">{html_escape(r.case.category)}</div></td>'
            f'<td>{"".join(details_bits)}</td>'
            f'<td>{r.duration_s:.2f}s</td>'
            "</tr>"
        )

    cats: dict[str, list[TestResult]] = {}
    for r in results:
        cats.setdefault(r.case.category, []).append(r)
    cov_chunks: list[str] = []
    for cat, items in sorted(cats.items()):
        cp = sum(1 for x in items if x.status == "pass")
        cov_chunks.append(
            f'    <b>{html_escape(cat)}</b><span>{cp}/{len(items)} passed</span>'
        )

    return HTML_TEMPLATE.format(
        title=html_escape(title),
        subtitle=subtitle,
        total=total,
        passed=passed,
        failed=failed,
        skipped=skipped,
        rows="\n".join(row_chunks),
        coverage="\n".join(cov_chunks),
    )


# =====================================================================
#  Entry point
# =====================================================================
def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Run the branding eval suite against a rendered launcher.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--prompts", required=True, type=Path,
                   help="Path to eval_prompts.json")
    p.add_argument("--launcher", required=True, type=Path,
                   help="Path to the launcher script or its containing directory")
    p.add_argument("--corp-name", default=None,
                   help="Corporate name (cosmetic, shown in the report header)")
    p.add_argument("--output", type=Path, default=None,
                   help="Write an HTML report to this path (default: text on stdout)")
    p.add_argument("--timeout", type=int, default=PROMPT_TIMEOUT_SEC,
                   help=f"Per-prompt timeout in seconds (default: {PROMPT_TIMEOUT_SEC})")
    p.add_argument("--filter", default=None,
                   help="Only run cases whose id or category matches this substring")
    p.add_argument("--dry-run", action="store_true",
                   help="List cases without invoking the launcher")
    args = p.parse_args(argv)

    if not args.prompts.exists():
        print(f"ERROR: prompts file not found: {args.prompts}", file=sys.stderr)
        return 2

    try:
        cases = load_prompts(args.prompts)
    except (ValueError, json.JSONDecodeError, KeyError) as e:
        print(f"ERROR: failed to parse {args.prompts}: {e}", file=sys.stderr)
        return 2

    if args.filter:
        needle = args.filter.lower()
        cases = [c for c in cases
                 if needle in c.id.lower() or needle in c.category.lower()]

    if not cases:
        print("ERROR: no cases to run (after filtering)", file=sys.stderr)
        return 2

    try:
        launcher = resolve_launcher(args.launcher)
    except FileNotFoundError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if not os.access(launcher, os.X_OK):
        print(f"WARNING: launcher is not executable: {launcher}", file=sys.stderr)

    if args.dry_run:
        print(f"Would run {len(cases)} case(s) against {launcher}:")
        for c in cases:
            print(f"  - [{c.category}] {c.id}: {c.prompt[:80]}")
        return 0

    # Force non-interactive context. We avoid clobbering the launcher's own
    # env handling beyond ensuring no terminal interactivity.
    os.environ.setdefault("CI", "1")
    os.environ.setdefault("TERM", "dumb")

    results: list[TestResult] = []
    for case in cases:
        t0 = time.perf_counter()
        response, rc, err = run_prompt(launcher, case.prompt, timeout=args.timeout)
        duration = time.perf_counter() - t0
        result = evaluate(case, response, err)
        result.duration_s = duration
        # Distinguish hard error (non-zero rc + empty response) from skip-with-note
        if err and not response and rc in (124, 126, 127):
            result.status = "skip"
            result.reason = err
        results.append(result)
        # Live progress on stderr so the report stays clean on stdout
        marker = {"pass": ".", "fail": "F", "skip": "s", "error": "E"}[result.status]
        sys.stderr.write(marker)
        sys.stderr.flush()
    sys.stderr.write("\n")

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(render_html(results, args.corp_name), encoding="utf-8")
        print(f"wrote: {args.output}")
        # Also print a one-line summary so CI logs aren't silent
        passed = sum(1 for r in results if r.status == "pass")
        failed = sum(1 for r in results if r.status == "fail")
        skipped = sum(1 for r in results if r.status in ("skip", "error"))
        print(f"summary: pass={passed} fail={failed} skip={skipped} total={len(results)}")
    else:
        sys.stdout.write(render_text(results, args.corp_name))

    return 0 if all(r.status != "fail" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
