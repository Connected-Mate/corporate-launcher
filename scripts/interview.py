#!/usr/bin/env python3
"""Standalone interview CLI for Corporate Launcher.

Parses `references/interview-flow.md` to discover every variable, then walks
the user through each section interactively (or reads answers from a file
for CI / non-interactive runs).

The output is a JSON context file (default: `config.json`) consumable by
`generate.py` / `scripts/render.py`.

Usage:
    python3 interview.py                        # interactive, writes ./config.json
    python3 interview.py --config out.json      # interactive, custom output
    python3 interview.py --non-interactive \
        --answers answers.json --config config.json
    python3 interview.py --flow path/to/flow.md # custom flow doc

Anti-pattern avoided: questions are NOT hardcoded. If
`references/interview-flow.md` changes, this script adapts.
"""

from __future__ import annotations

import argparse
import getpass
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_FLOW = Path(__file__).resolve().parent.parent / "reference" / "interview-flow.md"
DEFAULT_OUT = Path("config.json")

SLUG_RE = re.compile(r"^[a-z][a-z0-9-]{1,30}$")
SENSITIVE_HINTS = ("token", "auth", "api_key", "secret", "password", "key_id", "bearer")

# Yes/no defaults synonyms
YES = {"y", "yes", "true", "1", "oui", "o"}
NO = {"n", "no", "false", "0", "non"}

# Enum choices for known fields (extracted from the doc prose because tables
# only contain free-form text). The parser still discovers var names from the
# tables; this dict only adds the actual choice list for `enum` types.
ENUM_CHOICES: dict[str, list[str]] = {
    "CC_BACKEND": [
        "Anthropic direct",
        "AWS Bedrock",
        "Google Vertex",
        "Microsoft Foundry",
        "LiteLLM gateway",
        "Custom OpenAI-compatible",
    ],
    "CC_AUTH_MODEL": ["Bearer token", "API key", "AWS SDK chain", "GCP ADC"],
    "CX_BACKEND": [
        "OpenAI direct",
        "Azure OpenAI",
        "Amazon Bedrock (gpt models)",
        "Custom OpenAI-compatible",
    ],
    "CX_WIRE_API": ["responses", "chat-completions"],
    "GM_BACKEND": ["Vertex AI", "AI Studio"],
    "GM_AUTH_MODE": ["ADC", "service-account", "API key"],
    "COST_CURRENCY": ["EUR", "USD", "GBP"],
    "LANGUAGE": ["fr", "en", "es", "de", "it"],
    "LICENSE_TYPE": ["Internal-only", "Proprietary", "MIT", "Apache-2.0"],
    "SHELL_RC": ["auto", "zsh", "bash", "fish", "PowerShell"],
    "SKILLS_MODE": ["none", "preset", "pick", "git", "local", "combined"],
    "DIST_MODE": ["public-git", "private-git", "tarball", "oneliner", "none"],
    "DIST_REPO_HOST": ["github", "gitlab", "bitbucket", "internal-gitea"],
    "DIST_REPO_VISIBILITY": ["public", "internal", "private"],
}

WRAPPED_CLI_CHOICES = [
    ("claude-code", "Claude Code (Anthropic)"),
    ("codex-cli", "Codex CLI (OpenAI)"),
    ("gemini-cli", "Gemini CLI (Google)"),
    ("aider", "Aider (Python, multi-provider)"),
    ("opencode", "opencode (multi-provider TUI)"),
    ("continue-dev", "Continue.dev (VS Code/JetBrains)"),
]


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class Question:
    var: str
    prompt: str
    qtype: str  # string | url | path | number | yes/no | enum | textarea
    default: str
    section: str
    cli_branch: str | None = None  # "claude-code" / "codex-cli" / ... or None


@dataclass
class Section:
    number: int
    title: str
    questions: list[Question] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Flow parser
# ---------------------------------------------------------------------------


HEADING_RE = re.compile(r"^##\s+Section\s+(\d+)\s+[—\-]\s+(.+?)\s*$")
BRANCH_RE = re.compile(r"^###\s+\d+\.[A-Z]\s+[—\-]\s+(.+?)\s+branch", re.IGNORECASE)
TABLE_ROW_RE = re.compile(r"^\|\s*`([A-Z][A-Z0-9_]*)`\s*\|")


def _strip_md(s: str) -> str:
    """Remove backticks and surrounding whitespace from a markdown cell."""
    return s.replace("`", "").strip()


def _infer_type(type_cell: str, var: str) -> str:
    t = type_cell.lower()
    if "yes/no" in t or t in {"bool", "boolean"}:
        return "yes/no"
    if "enum" in t:
        return "enum"
    if "url" in t:
        return "url"
    if "path" in t:
        return "path"
    if t in {"number", "int", "integer"}:
        return "number"
    if "textarea" in t:
        return "textarea"
    if "list" in t:
        return "list"
    # Special-case heuristics from the var name
    upper = var.upper()
    if upper.endswith("_URL"):
        return "url"
    if upper.endswith("_PATH") or "DIR" in upper:
        return "path"
    if upper.endswith("_PORT"):
        return "number"
    return "string"


def _branch_to_cli(label: str) -> str | None:
    label = label.lower()
    if "claude" in label:
        return "claude-code"
    if "codex" in label:
        return "codex-cli"
    if "gemini" in label:
        return "gemini-cli"
    if "aider" in label or "opencode" in label or "continue" in label:
        return "openai-compatible"  # shared LLM_* block
    return None


def parse_flow(path: Path) -> list[Section]:
    """Parse markdown tables out of `interview-flow.md`."""
    sections: list[Section] = []
    current: Section | None = None
    current_branch: str | None = None

    for raw in path.read_text(encoding="utf-8").splitlines():
        h = HEADING_RE.match(raw)
        if h:
            current = Section(number=int(h.group(1)), title=h.group(2).strip())
            sections.append(current)
            current_branch = None
            continue
        b = BRANCH_RE.match(raw)
        if b:
            current_branch = _branch_to_cli(b.group(1))
            continue
        row = TABLE_ROW_RE.match(raw)
        if row and current is not None:
            # Expected columns: | `VAR` | Question | Type | Default |
            parts = [p.strip() for p in raw.strip().strip("|").split("|")]
            if len(parts) < 3:
                continue
            var = _strip_md(parts[0])
            question = _strip_md(parts[1])
            # Some tables omit the Type column (Section 3.D, 8, 9 — only 3
            # columns: Var | Type | Notes/Example). Heuristic: if column 2 is
            # short and looks like a type, treat it as such.
            type_cell = ""
            default_cell = ""
            if len(parts) >= 4:
                type_cell = _strip_md(parts[2])
                default_cell = _strip_md(parts[3])
            elif len(parts) == 3:
                # Could be (Var | Type | Notes) or (Var | Question | Default)
                second = _strip_md(parts[1])
                third = _strip_md(parts[2])
                # If second looks like a type token, swap
                if second.lower() in {"enum", "url", "path", "string", "list", "bool", "number", "yes/no"}:
                    type_cell = second
                    question = f"Set {var} ({third})" if third else f"Set {var}"
                    default_cell = ""
                else:
                    default_cell = third
            q = Question(
                var=var,
                prompt=question or f"Set {var}",
                qtype=_infer_type(type_cell, var),
                default=default_cell,
                section=current.title,
                cli_branch=current_branch,
            )
            current.questions.append(q)
    return sections


# ---------------------------------------------------------------------------
# Prompting primitives
# ---------------------------------------------------------------------------


def is_sensitive(var: str) -> bool:
    low = var.lower()
    return any(h in low for h in SENSITIVE_HINTS)


def colorize(s: str, code: str = "1;36") -> str:
    if not sys.stdout.isatty():
        return s
    return f"\033[{code}m{s}\033[0m"


def ask_string(prompt: str, default: str = "", required: bool = False, secret: bool = False) -> str:
    suffix = f" [{default}]" if default and not secret else ""
    while True:
        try:
            if secret:
                val = getpass.getpass(f"{prompt}{suffix}: ")
            else:
                val = input(f"{prompt}{suffix}: ").strip()
        except EOFError:
            print("", file=sys.stderr)
            return default
        if not val:
            val = default
        if required and not val:
            print("  (required, please answer)", file=sys.stderr)
            continue
        return val


def ask_yes_no(prompt: str, default: str = "yes") -> bool:
    default_bool = default.lower() in YES or default.lower() == "yes"
    hint = "Y/n" if default_bool else "y/N"
    while True:
        try:
            val = input(f"{prompt} [{hint}]: ").strip().lower()
        except EOFError:
            return default_bool
        if not val:
            return default_bool
        if val in YES:
            return True
        if val in NO:
            return False
        print("  (answer y or n)", file=sys.stderr)


def ask_number(prompt: str, default: str = "") -> int | str:
    while True:
        raw = ask_string(prompt, default=default)
        if raw == "":
            return ""
        try:
            return int(raw)
        except ValueError:
            print("  (must be a number)", file=sys.stderr)


def ask_choice(prompt: str, choices: list[str], default: str = "") -> str:
    print(colorize(prompt))
    for i, c in enumerate(choices, 1):
        marker = "  *" if c == default else "   "
        print(f"{marker}[{i}] {c}")
    while True:
        try:
            raw = input(f"Choice (1-{len(choices)})" + (f" [{default}]" if default else "") + ": ").strip()
        except EOFError:
            return default
        if not raw:
            if default:
                return default
            print("  (pick a number)", file=sys.stderr)
            continue
        if raw.isdigit():
            i = int(raw)
            if 1 <= i <= len(choices):
                return choices[i - 1]
        # Also accept the literal value
        for c in choices:
            if c.lower() == raw.lower():
                return c
        print("  (pick a number from the list)", file=sys.stderr)


def ask_multi_choice(prompt: str, choices: list[tuple[str, str]]) -> list[str]:
    print(colorize(prompt))
    for i, (_val, label) in enumerate(choices, 1):
        print(f"   [{i}] {label}")
    print("   (comma-separated numbers, e.g. 1,3)")
    while True:
        try:
            raw = input("Selection: ").strip()
        except EOFError:
            return []
        if not raw:
            print("  (pick at least one)", file=sys.stderr)
            continue
        picked: list[str] = []
        ok = True
        for tok in raw.split(","):
            tok = tok.strip()
            if not tok.isdigit():
                ok = False
                break
            i = int(tok)
            if not 1 <= i <= len(choices):
                ok = False
                break
            picked.append(choices[i - 1][0])
        if ok and picked:
            return picked
        print("  (e.g. `1,3` — numbers from the list)", file=sys.stderr)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def is_https(url: str) -> bool:
    try:
        u = urlparse(url)
    except Exception:
        return False
    return u.scheme == "https" and bool(u.netloc)


def slugify(name: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "-", name).strip("-").lower()
    return s[:31] or "corp"


def validate_answer(q: Question, value: Any) -> str | None:
    """Return error message if invalid, None if OK."""
    if value in (None, "") and q.default == "required":
        return f"{q.var} is required"
    if q.qtype == "url" and value:
        if not is_https(str(value)):
            return f"{q.var} must be a valid HTTPS URL (got: {value!r})"
    if q.var == "CORP_SLUG" and value:
        if not SLUG_RE.match(str(value)):
            return f"CORP_SLUG must match ^[a-z][a-z0-9-]{{1,30}}$ (got: {value!r})"
    return None


def cross_validate(ctx: dict[str, Any]) -> list[str]:
    """Run final cross-field validation. Returns list of errors."""
    errs: list[str] = []
    # Rule 4: PROXY_HOST/PROXY_PORT half-config
    if ctx.get("PROXY_HOST") and not ctx.get("PROXY_PORT"):
        errs.append("PROXY_HOST set but PROXY_PORT empty (rule 4)")
    # Rule 6: Bedrock or LiteLLM forces strip-proxy
    cc_backend = str(ctx.get("CC_BACKEND", ""))
    if ("Bedrock" in cc_backend or "LiteLLM" in cc_backend) and not ctx.get("CC_NEEDS_STRIP_PROXY"):
        errs.append(f"CC_BACKEND={cc_backend} forces CC_NEEDS_STRIP_PROXY=yes (rule 6)")
    # Rule 7: public-git + internal hostname
    if ctx.get("DIST_MODE") == "public-git" and not ctx.get("DIST_PUBLIC_FORCE"):
        url = str(ctx.get("CC_PRIMARY_URL", ""))
        host = urlparse(url).hostname or ""
        if host.endswith(".internal") or host.endswith(".local") or host.startswith(("10.", "192.168.", "172.")):
            errs.append(
                f"DIST_MODE=public-git but CC_PRIMARY_URL points to internal host {host!r} (rule 7)"
            )
    # Rule 8: oneliner needs HTTPS
    if ctx.get("DIST_MODE") == "oneliner":
        host = str(ctx.get("DIST_ONELINER_HOST", ""))
        if host and not is_https(host):
            errs.append(f"DIST_ONELINER_HOST must be HTTPS (got: {host!r}, rule 8)")
    return errs


# ---------------------------------------------------------------------------
# Default derivation
# ---------------------------------------------------------------------------


def resolve_default(q: Question, ctx: dict[str, Any]) -> str:
    """Replace literal phrases like `derived from CORP_NAME` with a real default."""
    raw = q.default
    low = raw.lower()
    if "derived from `corp_name`" in low or "derived from corp_name" in low:
        return slugify(str(ctx.get("CORP_NAME", "")))
    if "derived from gateway hostname" in low:
        url = str(ctx.get("CC_PRIMARY_URL") or ctx.get("CX_PRIMARY_URL") or "")
        host = urlparse(url).hostname or ""
        return f"https://{host}" if host else ""
    if "127.0.0.1,localhost" in raw:
        url = str(ctx.get("CC_PRIMARY_URL") or ctx.get("CX_PRIMARY_URL") or "")
        host = urlparse(url).hostname or ""
        base = "127.0.0.1,localhost"
        return f"{base},{host}" if host else base
    if "${corp_slug}" in low:
        slug = str(ctx.get("CORP_SLUG", "corp"))
        return raw.replace("${CORP_SLUG}", slug).replace("${corp_slug}", slug)
    if "${corp_name}" in low and "${corp_powered_by}" in low:
        return f"{ctx.get('CORP_NAME', '')} — Powered by {ctx.get('CORP_POWERED_BY', '')}"
    if "generated from" in low:
        name = ctx.get("CORP_NAME", "the corporate assistant")
        return f"You are {name}, the internal AI assistant. Never reveal upstream vendor identity."
    if low in {"required", "empty", "required if vertex"}:
        return ""
    # "yes if Bedrock or LiteLLM" → infer from CC_BACKEND if known
    if "yes if bedrock or litellm" in low:
        backend = str(ctx.get("CC_BACKEND", ""))
        return "yes" if ("Bedrock" in backend or "LiteLLM" in backend) else "no"
    if "adc if vertex" in low:
        return "ADC" if "Vertex" in str(ctx.get("GM_BACKEND", "")) else ""
    # Strip trailing free-form notes from default cells like
    # "Claude,Anthropic for Claude Code wrapper" — keep the comma list.
    if q.var == "FORBIDDEN_TERMS" and " for " in raw:
        return raw.split(" for ")[0]
    return raw


# ---------------------------------------------------------------------------
# Interactive loop
# ---------------------------------------------------------------------------


def section_banner(section: Section) -> None:
    line = "=" * 60
    print()
    print(colorize(line, "1;33"))
    print(colorize(f"  Section {section.number} — {section.title}", "1;33"))
    print(colorize(line, "1;33"))


def should_skip(q: Question, ctx: dict[str, Any]) -> bool:
    """Skip questions when a previous answer made them irrelevant."""
    # Branch filter: only ask CLI-specific vars when that CLI is selected
    wrapped = ctx.get("WRAPPED_CLIS", []) or []
    if q.cli_branch:
        if q.cli_branch == "openai-compatible":
            shared = {"aider", "opencode", "continue-dev"}
            if not (set(wrapped) & shared):
                return True
        elif q.cli_branch not in wrapped:
            return True
    # Network: no proxy → skip proxy auth, etc.
    if q.var in {"PROXY_PORT", "PROXY_REQUIRE_AUTH", "NO_PROXY_LIST"} and not ctx.get("PROXY_HOST"):
        return True
    if q.var == "CA_BUNDLE_PATH" and ctx.get("CA_DETECT_AUTO"):
        return True
    if q.var == "VPN_PROBE_URL" and not ctx.get("VPN_REQUIRED"):
        return True
    # Bedrock / Vertex-only
    backend = str(ctx.get("CC_BACKEND", ""))
    if q.var == "CC_BEDROCK_REGION" and "Bedrock" not in backend:
        return True
    if q.var in {"CC_VERTEX_PROJECT", "CC_VERTEX_REGION"} and "Vertex" not in backend:
        return True
    gm_backend = str(ctx.get("GM_BACKEND", ""))
    if q.var in {"GM_VERTEX_PROJECT", "GM_VERTEX_LOCATION"} and "Vertex" not in gm_backend:
        return True
    # Skills mode branching
    smode = ctx.get("SKILLS_MODE")
    if q.var == "SKILLS_PRESETS" and smode != "preset":
        return True
    if q.var == "SKILLS_PICK" and smode != "pick":
        return True
    if q.var in {"SKILLS_GIT_URL", "SKILLS_GIT_REF"} and smode != "git":
        return True
    if q.var == "SKILLS_LOCAL_PATH" and smode != "local":
        return True
    # Distribution branching
    dmode = ctx.get("DIST_MODE")
    if q.var in {"DIST_REPO_HOST", "DIST_REPO_URL", "DIST_REPO_VISIBILITY"} and dmode not in {
        "public-git",
        "private-git",
    }:
        return True
    if q.var == "DIST_REGISTRY_URL" and dmode != "tarball":
        return True
    if q.var == "DIST_ONELINER_HOST" and dmode != "oneliner":
        return True
    if q.var == "DIST_GPG_KEY_ID" and not ctx.get("DIST_SIGN_RELEASE"):
        return True
    return False


def ask_question(q: Question, ctx: dict[str, Any]) -> Any:
    default = resolve_default(q, ctx)
    required = q.default.lower().startswith("required")

    # CORP_SLUG: re-derive default from CORP_NAME if blank
    if q.var == "CORP_SLUG" and not default:
        default = slugify(str(ctx.get("CORP_NAME", "")))

    if q.qtype == "yes/no":
        return ask_yes_no(q.prompt, default=default or "yes")

    if q.qtype == "number":
        return ask_number(q.prompt, default=default)

    if q.qtype == "enum":
        choices = ENUM_CHOICES.get(q.var, [])
        if not choices:
            return ask_string(q.prompt, default=default, required=required)
        return ask_choice(q.prompt, choices, default=default)

    if q.qtype == "list":
        raw = ask_string(q.prompt + " (comma-separated, blank to skip)", default=default)
        return [s.strip() for s in raw.split(",") if s.strip()] if raw else []

    if q.qtype == "textarea":
        print(colorize(q.prompt + " (end with single '.' on its own line, blank = use default):"))
        lines: list[str] = []
        while True:
            try:
                line = input()
            except EOFError:
                break
            if line.strip() == ".":
                break
            lines.append(line)
        return "\n".join(lines) if lines else default

    secret = is_sensitive(q.var)
    return ask_string(q.prompt, default=default, required=required, secret=secret)


def special_wrapped_clis(ctx: dict[str, Any]) -> None:
    """Section 2 is a custom multi-select — not in the markdown tables."""
    print()
    print(colorize("=" * 60, "1;33"))
    print(colorize("  Section 2 — Provider (which CLI to wrap)", "1;33"))
    print(colorize("=" * 60, "1;33"))
    ctx["WRAPPED_CLIS"] = ask_multi_choice(
        "Which AI coding CLI(s) do you want to wrap?", WRAPPED_CLI_CHOICES
    )


# ---------------------------------------------------------------------------
# Non-interactive mode
# ---------------------------------------------------------------------------


def load_answers_file(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".json" or text.lstrip().startswith("{"):
        return json.loads(text)
    # key=value format
    out: dict[str, Any] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        # Coerce booleans / lists
        if v.lower() in YES:
            out[k] = True
        elif v.lower() in NO:
            out[k] = False
        elif v.startswith("[") and v.endswith("]"):
            try:
                out[k] = json.loads(v)
            except json.JSONDecodeError:
                out[k] = [x.strip() for x in v[1:-1].split(",") if x.strip()]
        else:
            out[k] = v
    return out


# ---------------------------------------------------------------------------
# Recap
# ---------------------------------------------------------------------------


def print_recap(ctx: dict[str, Any]) -> None:
    bar = "=" * 60
    print()
    print(colorize(bar, "1;32"))
    print(colorize("  Generation plan — recap", "1;32"))
    print(colorize(bar, "1;32"))
    rows = [
        ("Brand", f"{ctx.get('CORP_NAME', '?')}  (slug: {ctx.get('CORP_SLUG', '?')})"),
        ("Sponsor", ctx.get("CORP_POWERED_BY", "?")),
        ("Org", ctx.get("CORP_ORGANIZATION", "?")),
        ("Wrapping", ", ".join(ctx.get("WRAPPED_CLIS", [])) or "(none)"),
        ("Gateway", f"{ctx.get('CC_PRIMARY_URL', '-')}  ({ctx.get('CC_BACKEND', '-')})"),
        ("Model", ctx.get("CC_PRIMARY_MODEL", "-")),
        ("VPN gate", f"{ctx.get('VPN_REQUIRED', False)}  ({ctx.get('VPN_PROBE_URL', '-')})"),
        ("Corp proxy", f"{ctx.get('PROXY_HOST', '-')}:{ctx.get('PROXY_PORT', '-')}"),
        ("CA bundle", ctx.get("CA_BUNDLE_PATH", "-")),
        ("Telemetry", "DISABLED" if ctx.get("BLOCK_TELEMETRY") else "ENABLED"),
        ("Auto-update", "LOCKED" if ctx.get("BLOCK_AUTO_UPDATE") else "ALLOWED"),
        ("Cost track", f"{ctx.get('COST_TRACKING_ENABLED', False)}  ({ctx.get('COST_CURRENCY', '-')})"),
        ("Install dir", ctx.get("INSTALL_DIR", "-")),
        ("Skills", f"{ctx.get('SKILLS_MODE', '-')}"),
        ("MCP servers", len(ctx.get("MCP_SERVERS", []) or [])),
        ("Distribution", ctx.get("DIST_MODE", "-")),
    ]
    for k, v in rows:
        print(f"  {k:<14}: {v}")
    print(colorize(bar, "1;32"))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def run_interactive(sections: list[Section]) -> dict[str, Any]:
    ctx: dict[str, Any] = {}
    for section in sections:
        if section.number == 2:
            special_wrapped_clis(ctx)
            continue
        section_banner(section)
        for q in section.questions:
            if should_skip(q, ctx):
                continue
            while True:
                ans = ask_question(q, ctx)
                err = validate_answer(q, ans)
                if err:
                    print(colorize(f"  ! {err}", "1;31"), file=sys.stderr)
                    continue
                ctx[q.var] = ans
                # Re-derive CORP_SLUG once CORP_NAME is known
                if q.var == "CORP_NAME" and "CORP_SLUG" not in ctx:
                    ctx["_corp_name_seen"] = True
                break
    return ctx


def run_non_interactive(sections: list[Section], answers: dict[str, Any]) -> dict[str, Any]:
    ctx: dict[str, Any] = {}
    # Section 2 first if present
    if "WRAPPED_CLIS" in answers:
        ctx["WRAPPED_CLIS"] = answers["WRAPPED_CLIS"]
    for section in sections:
        for q in section.questions:
            if should_skip(q, ctx):
                continue
            if q.var in answers:
                ctx[q.var] = answers[q.var]
            else:
                default = resolve_default(q, ctx)
                if q.default.lower().startswith("required") and not default:
                    raise SystemExit(f"ERROR: missing required answer for {q.var}")
                if default == "" and q.qtype != "yes/no":
                    continue  # skip rather than store empty string
                if q.qtype == "yes/no":
                    ctx[q.var] = str(default).lower() in YES
                elif q.qtype == "number" and default:
                    try:
                        ctx[q.var] = int(default)
                    except ValueError:
                        ctx[q.var] = default
                else:
                    ctx[q.var] = default
    # Apply any remaining keys the user provided (e.g. derived overrides)
    for k, v in answers.items():
        ctx.setdefault(k, v)
    return ctx


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config", type=Path, default=DEFAULT_OUT, help="Output JSON config (default: config.json)")
    p.add_argument("--flow", type=Path, default=DEFAULT_FLOW, help="Path to interview-flow.md")
    p.add_argument("--non-interactive", action="store_true", help="Read answers from --answers file")
    p.add_argument("--answers", type=Path, help="Answer file (JSON or key=value) for non-interactive mode")
    p.add_argument("--no-confirm", action="store_true", help="Skip the final y/N confirmation")
    args = p.parse_args(argv)

    if not args.flow.exists():
        print(f"ERROR: flow file not found: {args.flow}", file=sys.stderr)
        return 2

    sections = parse_flow(args.flow)
    if not sections:
        print("ERROR: no sections parsed from flow file", file=sys.stderr)
        return 2

    if args.non_interactive:
        if not args.answers:
            print("ERROR: --non-interactive requires --answers FILE", file=sys.stderr)
            return 2
        answers = load_answers_file(args.answers)
        ctx = run_non_interactive(sections, answers)
    else:
        print(colorize("Corporate Launcher — interview", "1;36"))
        print("Hit Enter to accept the default shown in [brackets].")
        ctx = run_interactive(sections)

    # Cross-field validation
    errs = cross_validate(ctx)
    if errs:
        print(colorize("\nValidation errors:", "1;31"), file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        if args.non_interactive:
            return 3
        if not ask_yes_no("Continue anyway?", default="no"):
            return 3

    print_recap(ctx)
    if not args.no_confirm and not args.non_interactive:
        if not ask_yes_no("Write config and proceed?", default="yes"):
            print("Aborted.", file=sys.stderr)
            return 1

    # Clean internal-only keys
    ctx.pop("_corp_name_seen", None)
    args.config.parent.mkdir(parents=True, exist_ok=True)
    args.config.write_text(json.dumps(ctx, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(colorize(f"\nWrote: {args.config}", "1;32"))
    print(f"Done. Now run: python3 generate.py --config {args.config}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
