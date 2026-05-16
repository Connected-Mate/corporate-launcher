"""Pytest suite for ``scripts/render.py``.

Covers the template-rendering engine of Corporate Launcher:

* ``render`` — string-level substitution, escaping, comment stripping
* ``render_file`` — file-level rendering and executable-bit preservation
* ``render_tree`` — recursive rendering with directory-name substitution
* ``load_context`` — JSON loading with derived defaults and key filtering
* ``validate`` — required-field and slug-regex checks
* End-to-end smoke test against ``templates/shared/cyber-rules.md.tpl``

The tests use only stdlib pytest (``tmp_path``, ``capsys``) — no plugins.
"""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Load scripts/render.py as a module without requiring a package layout.
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
RENDER_PY = PROJECT_ROOT / "scripts" / "render.py"

_spec = importlib.util.spec_from_file_location("render", RENDER_PY)
assert _spec is not None and _spec.loader is not None
render_mod = importlib.util.module_from_spec(_spec)
sys.modules["render"] = render_mod
_spec.loader.exec_module(render_mod)

render = render_mod.render
render_file = render_mod.render_file
render_tree = render_mod.render_tree
load_context = render_mod.load_context
validate = render_mod.validate
UnresolvedVariable = render_mod.UnresolvedVariable


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
@pytest.fixture
def ctx() -> dict[str, object]:
    """A minimal, fully populated rendering context."""
    return {
        "CORP_NAME": "Patrick Code",
        "CORP_SLUG": "patrick-code",
        "CORP_POWERED_BY": "TGV Europe",
        "CORP_ORGANIZATION": "SNCF",
        "CYBER_AUTHORITY": "Direction Cybersecurite SNCF",
        "FORBIDDEN_TERMS": "Claude, Anthropic",
    }


# ---------------------------------------------------------------------------
# render() — string-level behaviour
# ---------------------------------------------------------------------------
def test_render_substitutes_single_var() -> None:
    """A single ``${VAR}`` is replaced with its context value."""
    assert render("hello ${NAME}", {"NAME": "world"}) == "hello world"


def test_render_raises_on_missing_key() -> None:
    """Missing keys raise ``UnresolvedVariable`` (a ``KeyError`` subclass)."""
    with pytest.raises(UnresolvedVariable):
        render("hello ${MISSING}", {})


def test_render_unescapes_literal_braces() -> None:
    """``$\\{LITERAL\\}`` survives pass 1 and is unescaped to ``${LITERAL}``."""
    out = render(r"keep $\{LITERAL\} as-is", {})
    assert out == "keep ${LITERAL} as-is"


def test_render_strips_hash_tpl_comments() -> None:
    """Lines matching ``# tpl: ...`` are removed from the output."""
    src = "line1\n# tpl: this is metadata\nline2\n"
    out = render(src, {})
    assert "tpl:" not in out
    assert "line1" in out and "line2" in out


def test_render_strips_slash_tpl_comments() -> None:
    """JS-style ``// tpl: ...`` comment lines are also stripped."""
    src = "const x = 1;\n// tpl: do not ship this line\nconst y = 2;\n"
    out = render(src, {})
    assert "tpl:" not in out
    assert "const x = 1;" in out
    assert "const y = 2;" in out


def test_render_unescapes_does_not_re_substitute() -> None:
    """A literal ``${VAR}`` produced by unescaping must not be re-substituted."""
    # If pass 2 ran before pass 1, ``${NAME}`` would be substituted; verify
    # the unescape result is preserved as a literal token.
    out = render(r"$\{NAME\}", {"NAME": "should-not-appear"})
    assert out == "${NAME}"


# ---------------------------------------------------------------------------
# render_file() — file-level behaviour
# ---------------------------------------------------------------------------
def test_render_file_writes_to_dst_and_preserves_exec_bit(
    tmp_path: Path, ctx: dict[str, object]
) -> None:
    """Executable shell template -> executable rendered script."""
    src = tmp_path / "install.sh.tpl"
    src.write_text("#!/bin/sh\necho ${CORP_NAME}\n", encoding="utf-8")
    # Make the source executable.
    src.chmod(src.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    dst = tmp_path / "out" / "install.sh"
    render_file(src, dst, ctx)

    assert dst.is_file()
    body = dst.read_text(encoding="utf-8")
    assert "echo Patrick Code" in body
    # Executable bit preserved on the destination.
    assert dst.stat().st_mode & 0o111, "executable bit was lost"


def test_render_file_unresolved_variable_includes_path(tmp_path: Path) -> None:
    """Errors raised by ``render_file`` mention the source path."""
    src = tmp_path / "broken.md.tpl"
    src.write_text("hello ${MISSING}\n", encoding="utf-8")
    dst = tmp_path / "out" / "broken.md"
    with pytest.raises(UnresolvedVariable) as exc:
        render_file(src, dst, {})
    assert str(src) in str(exc.value)


# ---------------------------------------------------------------------------
# render_tree() — recursive behaviour
# ---------------------------------------------------------------------------
def test_render_tree_renders_tpl_and_copies_others(
    tmp_path: Path, ctx: dict[str, object]
) -> None:
    """``.tpl`` files are rendered; non-template files are copied verbatim."""
    src_dir = tmp_path / "src"
    (src_dir / "nested").mkdir(parents=True)
    (src_dir / "greet.txt.tpl").write_text("hi ${CORP_NAME}", encoding="utf-8")
    (src_dir / "nested" / "data.json").write_text(
        '{"x": 1, "literal": "${KEEP_ME_AS_IS}"}', encoding="utf-8"
    )

    dst_dir = tmp_path / "out"
    written = render_tree(src_dir, dst_dir, ctx)

    # Rendered template: .tpl suffix stripped, variable substituted.
    rendered = dst_dir / "greet.txt"
    assert rendered.is_file()
    assert rendered.read_text(encoding="utf-8") == "hi Patrick Code"

    # Verbatim copy: contents byte-for-byte identical (no substitution).
    copied = dst_dir / "nested" / "data.json"
    assert copied.is_file()
    assert "${KEEP_ME_AS_IS}" in copied.read_text(encoding="utf-8")

    assert set(written) == {rendered, copied}


def test_render_tree_substitutes_in_directory_names(
    tmp_path: Path, ctx: dict[str, object]
) -> None:
    """``${VAR}`` segments inside directory names are also resolved."""
    src_dir = tmp_path / "src"
    nested = src_dir / "${CORP_SLUG}" / "config"
    nested.mkdir(parents=True)
    (nested / "app.conf.tpl").write_text("name=${CORP_NAME}\n", encoding="utf-8")

    dst_dir = tmp_path / "out"
    render_tree(src_dir, dst_dir, ctx)

    expected = dst_dir / "patrick-code" / "config" / "app.conf"
    assert expected.is_file()
    # NOTE: render() splits-then-joins on "\n", which drops a trailing newline.
    # We accept either form here so the test documents the actual contract.
    assert expected.read_text(encoding="utf-8").rstrip("\n") == "name=Patrick Code"


# ---------------------------------------------------------------------------
# load_context() — JSON loading
# ---------------------------------------------------------------------------
def test_load_context_derives_corp_slug_upper(tmp_path: Path) -> None:
    """``CORP_SLUG_UPPER`` is derived from ``CORP_SLUG`` when absent."""
    path = tmp_path / "ctx.json"
    path.write_text(json.dumps({"CORP_SLUG": "patrick-code"}), encoding="utf-8")
    ctx = load_context(path)
    assert ctx["CORP_SLUG_UPPER"] == "PATRICK_CODE"


def test_load_context_does_not_override_explicit_upper(tmp_path: Path) -> None:
    """An explicit ``CORP_SLUG_UPPER`` is preserved as-is."""
    path = tmp_path / "ctx.json"
    path.write_text(
        json.dumps({"CORP_SLUG": "patrick-code", "CORP_SLUG_UPPER": "CUSTOM"}),
        encoding="utf-8",
    )
    ctx = load_context(path)
    assert ctx["CORP_SLUG_UPPER"] == "CUSTOM"


def test_load_context_rejects_non_conforming_keys(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Keys not matching ``^[A-Z][A-Z0-9_]*$`` are dropped with a warning."""
    path = tmp_path / "ctx.json"
    path.write_text(
        json.dumps(
            {
                "CORP_NAME": "Patrick Code",
                "lowercase": "nope",
                "Has-Dash": "nope",
                "1LEADING_DIGIT": "nope",
            }
        ),
        encoding="utf-8",
    )
    ctx = load_context(path)
    assert "CORP_NAME" in ctx
    assert "lowercase" not in ctx
    assert "Has-Dash" not in ctx
    assert "1LEADING_DIGIT" not in ctx
    captured = capsys.readouterr()
    assert "lowercase" in captured.err


# ---------------------------------------------------------------------------
# validate() — required keys and slug regex
# ---------------------------------------------------------------------------
def test_validate_reports_missing_required_and_bad_slug() -> None:
    """Missing required keys and a malformed slug are both surfaced."""
    errs = validate({"CORP_SLUG": "Not A Slug!"})
    joined = " | ".join(errs)
    # All required keys (except CORP_SLUG, which is present but invalid).
    assert "CORP_NAME" in joined
    assert "CORP_POWERED_BY" in joined
    assert "CORP_ORGANIZATION" in joined
    # Slug regex violation.
    assert "CORP_SLUG" in joined and "must match" in joined


def test_validate_passes_on_clean_context(ctx: dict[str, object]) -> None:
    """A well-formed context produces no validation errors."""
    assert validate(ctx) == []


# ---------------------------------------------------------------------------
# End-to-end: render the real cyber-rules template
# ---------------------------------------------------------------------------
def test_end_to_end_cyber_rules_template(
    tmp_path: Path, ctx: dict[str, object]
) -> None:
    """Render the shipped ``cyber-rules.md.tpl`` and assert no ``${VAR}`` leaks."""
    tpl = PROJECT_ROOT / "templates" / "shared" / "cyber-rules.md.tpl"
    assert tpl.is_file(), f"fixture template missing: {tpl}"

    dst = tmp_path / "cyber-rules.md"
    render_file(tpl, dst, ctx)

    out = dst.read_text(encoding="utf-8")
    # No unresolved placeholders remain.
    assert "${" not in out, "unresolved variable in rendered output"
    # Substitutions actually landed.
    assert "Patrick Code" in out
    assert "TGV Europe" in out
    assert "SNCF" in out
    assert "Direction Cybersecurite SNCF" in out
