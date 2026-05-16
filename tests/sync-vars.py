#!/usr/bin/env python3
"""Audit template variables against references/interview-flow.md.

Scans every ``templates/**/*.tpl`` file for ``${VAR}`` references and
cross-checks them against the variable tables documented in
``references/interview-flow.md``.

Three classes of drift are reported:

1. **Undocumented**  Vars used in templates but missing from
   ``interview-flow.md``. These will fail at render time because the
   interview never collects a value.
2. **Dead spec**     Vars documented in ``interview-flow.md`` but not
   referenced by any template. The interview asks a question for
   nothing.
3. **Inconsistent**  Suspicious singular/plural or typo pairs
   (e.g. ``CORP_NAME`` vs ``CORP_NAMES``).

Exits ``1`` if any drift is found, ``0`` otherwise.
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# Regexes
# ---------------------------------------------------------------------------

# Match ${UPPER_SNAKE_CASE}. Skip escaped occurrences "$\{...}" used in
# documentation / shell heredocs where the launcher must emit a literal
# dollar-brace sequence.
VAR_RE = re.compile(r"(?<!\\)\$\{([A-Z][A-Z0-9_]*)\}")

# Table-row var. Matches: | `VAR_NAME` | ... |  (backticked first cell).
TABLE_ROW_RE = re.compile(r"^\s*\|\s*`([A-Z][A-Z0-9_]*)`\s*\|")

# Runtime-only / loop / helper / color vars produced by render machinery,
# never collected via the interview. They MUST not be reported as missing.
RUNTIME_WHITELIST: frozenset[str] = frozenset(
    {
        # Loop locals / generic helpers used inside bash templates.
        "VAR", "BASE", "HERE", "HOME", "PORT", "SESSION", "STAGING_DIR",
        "MARKER_START", "MARKER_END", "ACTUAL", "EXPECTED", "LEAKS",
        "SIG", "SIGNATURE", "TARBALL", "CHECKSUMS", "KEY_ID", "KEYRING",
        "GPG_CHECK", "GPG_KEYSERVER", "S3_BASE", "S3_PREFIX",
        "STATUS_PAGE_URL", "SUPPORT_CHANNEL", "SUPPORT_EMAIL",
        "INCIDENT_CHANNEL", "VERSION", "BUILD_DATE",
        # ANSI color codes injected by the renderer from BANNER_COLOR_PRIMARY.
        "C_BOLD", "C_BRAND", "C_DIM", "C_GREEN", "C_OK",
        "C_RED", "C_RESET", "C_RST", "C_YELLOW",
        # Derived at generation time from other answers (not interview keys).
        "CORP_SLUG_UPPER", "CORP_LAUNCHER_VERSION", "CORP_VERSION",
        "CORP_COPYRIGHT_YEAR", "DIST_YEAR", "DIST_DIR", "DIST_GENERATED_AT",
        "CYBER_RULES_SHA256_SHORT", "TARBALL_SHA256", "TARBALL_SHA256_SHORT",
        "INSTALL_SH_SHA256", "INSTALL_SH_SHA256_SHORT", "INSTALL_SH_LINES",
        "DIST_TARBALL_SHA256", "DIST_TARBALL_URL",
        "DIST_ONELINER_HOSTNAME", "DIST_GIT_URL",
        "DIST_GPG_KEY_FINGERPRINT_OWNER",
        "FORBIDDEN_TERMS_LIST",
        # Resolved automatically (gateway hostname, derived URLs).
        "VPN_REQUIRED_NOTE",
    }
)

# Aliases used by the interview but never quoted in markdown tables; the
# interview spec uses bullet/prose entries instead. Treat them as documented.
DOC_ALIASES: frozenset[str] = frozenset(
    {
        "DIST_PUBLIC_FORCE",  # mentioned in validation rule #7
        # Distribution-only credentials: documented as required env vars in
        # interview-flow.md §9 (Distribution) and used inside upload-* shell
        # templates via `${VAR:-default}` parameter expansion, which is the
        # bash form — never the render-time ${VAR} form. Treat as documented
        # so we don't flag them as dead spec.
        "ARTIFACTORY_USER",
        "ARTIFACTORY_PASS",
        "ARTIFACTORY_TOKEN",
        "AWS_PROFILE",
        "NEXUS_USER",
        "NEXUS_PASS",
        # ANSI color literals injected by templates/banner/footer.sh.tpl.
        "RED", "DIM", "RESET",
        # Counts derived at generation time from list-valued answers.
        "MCP_SERVERS_COUNT", "SKILLS_COUNT",
        # Dev-rules config keys consumed by scripts/dev-rules-installer.py at
        # generation time (not by template rendering). Documented in §10 of
        # interview-flow.md and read directly from the config JSON.
        "DEV_RULES_CONTENT", "DEV_RULES_GIT_PATH", "DEV_RULES_GIT_REF",
    }
)

# Pairs we want to call out as likely typos / drift. Add new pairs here
# whenever a new family appears.
KNOWN_CONFUSIONS: tuple[tuple[str, str], ...] = (
    ("CORP_NAME", "CORP_NAMES"),
    ("CORP_SLUG", "CORP_SLUGS"),
    ("WRAPPED_CLIS", "WRAPPED_CLI"),
    ("MCP_SERVERS", "MCP_SERVER"),
    ("SKILLS_PRESETS", "SKILLS_PRESET"),
    ("FORBIDDEN_TERMS", "FORBIDDEN_TERM"),
)


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------


def extract_template_vars(root: Path) -> dict[str, list[Path]]:
    """Return {VAR_NAME: [files that reference it]}.

    Scans both `templates/**/*.tpl` (Jinja-style ${VAR}) and the Python
    generator scripts in `scripts/` (which read flags via ctx.get("VAR")).
    Variables consumed only by Python orchestration (e.g. API_PROBE_ENABLED
    gating a sub-script invocation) would otherwise look "dead" to this tool.
    """
    usage: dict[str, list[Path]] = defaultdict(list)
    for tpl in sorted(root.glob("templates/**/*.tpl")):
        try:
            text = tpl.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for var in VAR_RE.findall(text):
            usage[var].append(tpl.relative_to(root))
    # Also scan generator scripts for ctx.get("VAR_NAME") references.
    py_var_re = re.compile(r'ctx(?:\.get)?\s*[\(\[]\s*["\']([A-Z][A-Z0-9_]*)["\']')
    for py in sorted(root.glob("scripts/*.py")):
        try:
            text = py.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for var in py_var_re.findall(text):
            usage[var].append(py.relative_to(root))
    return usage


DOC_FILES: tuple[str, ...] = (
    # Tables here document CONFIG VARS (interview answers, Jinja-substituted).
    # env-vars.md describes RUNTIME shell exports — out of scope here.
    "references/interview-flow.md",
    "references/skills-bundle.md",
)


def extract_documented_vars(flow_md: Path) -> set[str]:
    """Pull every var name from table rows in the v0.5 reference docs.

    interview-flow.md is the primary spec, but several families are
    documented in companion tables (env-vars, skills-bundle, etc.). All
    are part of the contract for sync-vars purposes.
    """
    documented: set[str] = set()
    root = flow_md.parent.parent
    candidates = [flow_md] + [root / p for p in DOC_FILES]
    seen: set[Path] = set()
    for doc in candidates:
        try:
            doc_r = doc.resolve()
        except OSError:
            continue
        if doc_r in seen or not doc_r.is_file():
            continue
        seen.add(doc_r)
        for line in doc.read_text(encoding="utf-8").splitlines():
            match = TABLE_ROW_RE.match(line)
            if match:
                documented.add(match.group(1))
    return documented | DOC_ALIASES


# ---------------------------------------------------------------------------
# Drift detection
# ---------------------------------------------------------------------------


def find_inconsistencies(used: set[str]) -> list[tuple[str, str]]:
    """Detect singular/plural confusion or typo pairs both present."""
    hits: list[tuple[str, str]] = []
    for a, b in KNOWN_CONFUSIONS:
        if a in used and b in used:
            hits.append((a, b))
    return hits


def render_table(title: str, rows: list[tuple[str, str]]) -> str:
    """Format a two-column ASCII table."""
    if not rows:
        return f"  {title}: none\n"
    width_a = max(len(r[0]) for r in rows)
    width_b = max(len(r[1]) for r in rows)
    width_a = max(width_a, len("VAR"))
    width_b = max(width_b, len("DETAIL"))
    border = f"  +-{'-' * width_a}-+-{'-' * width_b}-+"
    out = [f"  {title}:", border, f"  | {'VAR':<{width_a}} | {'DETAIL':<{width_b}} |", border]
    for var, detail in rows:
        out.append(f"  | {var:<{width_a}} | {detail:<{width_b}} |")
    out.append(border)
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="Project root (default: parent of tests/).",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Only print drift; suppress success banner.",
    )
    args = parser.parse_args()

    root: Path = args.root.resolve()
    flow_md = root / "references" / "interview-flow.md"
    if not flow_md.exists():
        print(f"error: missing {flow_md}", file=sys.stderr)
        return 2

    usage = extract_template_vars(root)
    used: set[str] = set(usage.keys())
    documented: set[str] = extract_documented_vars(flow_md)

    # Class 1 — used by templates but never documented.
    undocumented = sorted(
        v for v in (used - documented) if v not in RUNTIME_WHITELIST
    )
    # Class 2 — documented but no template ever uses it.
    dead_spec = sorted(documented - used - DOC_ALIASES)
    # Class 3 — inconsistent pairs.
    inconsistencies = find_inconsistencies(used)

    rows_undoc = [
        (v, f"used in {len(usage[v])} file(s) (e.g. {usage[v][0]})")
        for v in undocumented
    ]
    rows_dead = [(v, "documented but never referenced") for v in dead_spec]
    rows_incon = [(f"{a} vs {b}", "both used — likely typo") for a, b in inconsistencies]

    drift = bool(undocumented or dead_spec or inconsistencies)

    print()
    print("  Corporate Launcher — template-variable sync report")
    print("  " + "=" * 50)
    print(f"  templates scanned : {sum(1 for _ in root.glob('templates/**/*.tpl'))}")
    print(f"  vars used         : {len(used)}")
    print(f"  vars documented   : {len(documented)}")
    print()
    print(render_table("Undocumented (will fail render)", rows_undoc))
    print(render_table("Dead spec (documented but unused)", rows_dead))
    print(render_table("Inconsistent (singular/plural)", rows_incon))

    if drift:
        print("  RESULT: DRIFT — fix interview-flow.md or templates.\n")
        return 1
    if not args.quiet:
        print("  RESULT: clean — templates and interview are in sync.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
