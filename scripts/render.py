#!/usr/bin/env python3
r"""Template rendering engine for Corporate Launcher.

Substitutes ${VAR} placeholders with values from a JSON context file.
Raises on unresolved variables (no silent empty substitution).
Lines starting with `# tpl:` (or `// tpl:`) are stripped from the output.
Escape `${...}` that should remain literal as `$\{...\}`.

Usage:
    render.py --context config.json --template templates/claude-code/launcher.sh.tpl --out build/pcode
    render.py --context config.json --tree templates/claude-code --out build/

The --tree variant recurses through a directory, rendering every .tpl file
and copying non-template files verbatim.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Mapping

VAR_RE = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")
# Match a literal `$\{...\}` escape. Forbid `$\{` and `\}` *inside* the body
# so the innermost escape is replaced first; outer escapes are then handled
# in subsequent passes (see `_unescape_literals`). This is the only way to
# unwrap nested shell parameter defaults like `$\{OUTER:-$\{INNER\}\}`.
ESCAPED_RE = re.compile(r"\$\\\{((?:(?!\$\\\{|\\\}).)*?)\\\}")
TPL_COMMENT_RE = re.compile(r"^\s*(#|//)\s*tpl:.*$")


class UnresolvedVariable(KeyError):
    pass


def render(text: str, ctx: Mapping[str, object]) -> str:
    """Render a single string with ${VAR} substitution."""

    def repl(match: re.Match) -> str:
        name = match.group(1)
        if name not in ctx:
            raise UnresolvedVariable(name)
        value = ctx[name]
        if value is None:
            raise UnresolvedVariable(f"{name} (null)")
        # Lists/dicts: emit JSON so shell templates can parse them
        # (Python's str() of a list uses single quotes which break tr/jq).
        if isinstance(value, (list, dict)):
            return json.dumps(value)
        if isinstance(value, bool):
            return "true" if value else "false"
        return str(value)

    # Pass 1: substitute real ${VAR}
    out = VAR_RE.sub(repl, text)
    # Pass 2: unescape $\{LITERAL\} → ${LITERAL}, iteratively from innermost
    # out, so nested escapes (rare but valid in bash defaults) all unwrap.
    while True:
        replaced = ESCAPED_RE.sub(r"${\1}", out)
        if replaced == out:
            break
        out = replaced
    # Pass 3: strip # tpl: comment lines
    out = "\n".join(line for line in out.splitlines() if not TPL_COMMENT_RE.match(line))
    return out


def render_file(src: Path, dst: Path, ctx: Mapping[str, object]) -> None:
    """Render src .tpl → dst (strips .tpl from filename)."""
    text = src.read_text(encoding="utf-8")
    try:
        out = render(text, ctx)
    except UnresolvedVariable as e:
        raise UnresolvedVariable(f"{src}: variable not in context: {e}") from None
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(out, encoding="utf-8")
    # Shell scripts, Python scripts, and the launcher binary (extensionless)
    # MUST be executable. Templates in git often lose +x, so we force 0o755
    # for rendered scripts. Other files inherit the source mode verbatim.
    if src.suffix == ".tpl":
        if dst.suffix in {".sh", ".py", ""}:
            os.chmod(dst, 0o755)
        else:
            mode = os.stat(src).st_mode
            if mode & 0o111:
                os.chmod(dst, mode)


def render_tree(src_dir: Path, dst_dir: Path, ctx: Mapping[str, object]) -> list[Path]:
    """Render every file under src_dir into dst_dir.

    - `.tpl` files are rendered, with the .tpl suffix removed
    - other files are copied verbatim
    - directory names are also subject to ${VAR} substitution
    """
    written: list[Path] = []
    for src in src_dir.rglob("*"):
        if src.is_dir():
            continue
        rel = src.relative_to(src_dir)
        # Substitute variables in path components
        rel_str = render(str(rel), ctx) if "${" in str(rel) else str(rel)
        # Strip .tpl suffix
        if rel_str.endswith(".tpl"):
            rel_str = rel_str[:-4]
        dst = dst_dir / rel_str
        if src.suffix == ".tpl":
            render_file(src, dst, ctx)
        else:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        written.append(dst)
    return written


def load_context(path: Path) -> dict[str, object]:
    """Load interview answers from a JSON config file."""
    raw = json.loads(path.read_text(encoding="utf-8"))
    ctx: dict[str, object] = {}
    for k, v in raw.items():
        if not re.match(r"^[A-Z][A-Z0-9_]*$", k):
            print(f"warning: ignoring non-conforming key: {k}", file=sys.stderr)
            continue
        ctx[k] = v
    # Derived defaults
    if "CORP_SLUG" in ctx and "CORP_SLUG_UPPER" not in ctx:
        ctx["CORP_SLUG_UPPER"] = str(ctx["CORP_SLUG"]).upper().replace("-", "_")
    return ctx


def validate(ctx: Mapping[str, object]) -> list[str]:
    """Return a list of validation errors. Empty list = OK."""
    errs: list[str] = []
    required = ["CORP_NAME", "CORP_SLUG", "CORP_POWERED_BY", "CORP_ORGANIZATION"]
    for r in required:
        if r not in ctx or not ctx[r]:
            errs.append(f"missing required: {r}")
    slug = str(ctx.get("CORP_SLUG", ""))
    if slug and not re.match(r"^[a-z][a-z0-9-]{1,30}$", slug):
        errs.append(f"CORP_SLUG must match ^[a-z][a-z0-9-]{{1,30}}$ (got: {slug!r})")
    return errs


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--context", required=True, type=Path, help="JSON file with interview answers")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--template", type=Path, help="Single .tpl file to render")
    g.add_argument("--tree", type=Path, help="Directory of templates to render recursively")
    p.add_argument("--out", required=True, type=Path, help="Output file or directory")
    p.add_argument("--strict", action="store_true", help="Fail on validation errors")
    args = p.parse_args(argv)

    ctx = load_context(args.context)
    errs = validate(ctx)
    if errs:
        for e in errs:
            print(f"ERROR: {e}", file=sys.stderr)
        if args.strict:
            return 2

    try:
        if args.template:
            render_file(args.template, args.out, ctx)
            print(f"wrote: {args.out}")
        else:
            written = render_tree(args.tree, args.out, ctx)
            for w in written:
                print(f"wrote: {w}")
    except UnresolvedVariable as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 3

    return 0


if __name__ == "__main__":
    sys.exit(main())
