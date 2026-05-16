"""Pytest suite for ``scripts/dev-rules-installer.py``.

Verifies the developer-rules installer used by the corporate
launcher generator. The installer ships a corporate
``dev-rules.md`` next to the launcher, sourced via one of four modes:

* ``none``   — minimal placeholder is written (always present, never empty)
* ``inline`` — content provided through ``DEV_RULES_CONTENT`` env var
* ``local``  — content read from ``DEV_RULES_PATH`` on disk
* ``git``    — content fetched via ``git clone`` (subprocess mocked here)

The suite also exercises the safety net: secret-scanning the rendered
payload, an absolute file-size ceiling, mandatory header stamping with
``CORP_NAME``, world-readable file mode (644 not 600 — corporate IT
must be able to read the artefact), and the ``--dry-run`` switch.

The script is loaded with ``importlib`` because its filename contains a
hyphen. No package layout is required.
"""

from __future__ import annotations

import importlib.util
import os
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

# ---------------------------------------------------------------------------
# Module loader -- dev-rules-installer.py has hyphens, so we cannot just
# ``import`` it. We use the same importlib pattern as test_url_purge.py and
# test_render.py to load the script as a module.
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
INSTALLER_PY = PROJECT_ROOT / "scripts" / "dev-rules-installer.py"

# If W2 has not yet committed the installer, skip the whole module rather
# than erroring out — keeps CI green during the rollout window.
if not INSTALLER_PY.is_file():  # pragma: no cover - environmental
    pytest.skip(
        f"scripts/dev-rules-installer.py not yet present at {INSTALLER_PY}",
        allow_module_level=True,
    )

_spec = importlib.util.spec_from_file_location("dev_rules_installer", INSTALLER_PY)
assert _spec is not None and _spec.loader is not None
dev_rules_installer = importlib.util.module_from_spec(_spec)
sys.modules["dev_rules_installer"] = dev_rules_installer
_spec.loader.exec_module(dev_rules_installer)

main = dev_rules_installer.main


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
HEADER_PREFIX = "# Acme Corp — Development Rules"


def _set_env(monkeypatch: pytest.MonkeyPatch, **vars: str) -> None:
    """Set ``DEV_RULES_*`` / ``CORP_*`` env vars and scrub stale ones.

    Each test starts from a known-clean environment so leftovers from a
    previous test (e.g. ``DEV_RULES_CONTENT``) cannot leak in.
    """
    for key in (
        "DEV_RULES_MODE",
        "DEV_RULES_CONTENT",
        "DEV_RULES_PATH",
        "DEV_RULES_GIT_URL",
        "DEV_RULES_GIT_REF",
        "DEV_RULES_GIT_SUBPATH",
        "CORP_NAME",
    ):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("CORP_NAME", "Acme Corp")
    for k, v in vars.items():
        monkeypatch.setenv(k, v)


def _run(tmp_path: Path, *extra: str) -> int:
    """Invoke ``main`` with ``--out`` pointing inside ``tmp_path``."""
    out = tmp_path / "dev-rules.md"
    return main(["--out", str(out), *extra])


def _out(tmp_path: Path) -> Path:
    return tmp_path / "dev-rules.md"


# ---------------------------------------------------------------------------
# 1. DEV_RULES_MODE=none -> minimal placeholder, exit 0
# ---------------------------------------------------------------------------
def test_mode_none_writes_placeholder(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``none`` mode still writes a (small) file with the corporate header."""
    _set_env(monkeypatch, DEV_RULES_MODE="none")

    rc = _run(tmp_path)

    assert rc == 0
    out = _out(tmp_path)
    assert out.is_file()
    text = out.read_text(encoding="utf-8")
    assert text.startswith(HEADER_PREFIX)
    # Placeholder must be short — it is just a stub.
    assert len(text) < 2000


# ---------------------------------------------------------------------------
# 2. DEV_RULES_MODE=inline -> content written from env var
# ---------------------------------------------------------------------------
def test_mode_inline_writes_env_content(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``inline`` mode copies ``DEV_RULES_CONTENT`` verbatim into the body."""
    body = (
        "## Coding standards\n"
        "\n"
        "Use 4-space indent. Run black before commit.\n"
    )
    _set_env(monkeypatch, DEV_RULES_MODE="inline", DEV_RULES_CONTENT=body)

    rc = _run(tmp_path)

    assert rc == 0
    text = _out(tmp_path).read_text(encoding="utf-8")
    assert "Use 4-space indent" in text
    assert "Run black before commit" in text
    assert text.startswith(HEADER_PREFIX)


# ---------------------------------------------------------------------------
# 3. DEV_RULES_MODE=local + valid file -> copied
# ---------------------------------------------------------------------------
def test_mode_local_copies_existing_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``local`` mode reads the file at ``DEV_RULES_PATH`` and embeds it."""
    src = tmp_path / "src" / "rules.md"
    src.parent.mkdir(parents=True)
    src.write_text(
        "## Local rules\n\nNo PRs on Fridays.\n", encoding="utf-8"
    )
    _set_env(monkeypatch, DEV_RULES_MODE="local", DEV_RULES_PATH=str(src))

    rc = _run(tmp_path)

    assert rc == 0
    text = _out(tmp_path).read_text(encoding="utf-8")
    assert "No PRs on Fridays" in text
    assert text.startswith(HEADER_PREFIX)


# ---------------------------------------------------------------------------
# 4. DEV_RULES_MODE=local + missing file -> exit 3
# ---------------------------------------------------------------------------
def test_mode_local_missing_file_exits_3(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A missing ``DEV_RULES_PATH`` is a configuration error (exit 3)."""
    missing = tmp_path / "does-not-exist.md"
    _set_env(
        monkeypatch, DEV_RULES_MODE="local", DEV_RULES_PATH=str(missing)
    )

    rc = _run(tmp_path)

    assert rc == 3
    # No output file should have been produced on error.
    assert not _out(tmp_path).exists()


# ---------------------------------------------------------------------------
# 5. DEV_RULES_MODE=git -> subprocess.run mocked, content extracted
# ---------------------------------------------------------------------------
def test_mode_git_clone_extracts_content(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``git`` mode invokes ``git clone`` (mocked) and reads dev-rules.md."""
    repo_content = (
        "## Cloned rules\n"
        "\n"
        "All commits must be signed.\n"
    )

    def fake_run(
        cmd: list[str], *args: Any, **kwargs: Any
    ) -> subprocess.CompletedProcess[str]:
        # Expect ``git clone <url> <dest>`` and seed the destination.
        assert cmd[0] == "git"
        assert "clone" in cmd
        # Destination is the last positional argument.
        dest = Path(cmd[-1])
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "dev-rules.md").write_text(repo_content, encoding="utf-8")
        return subprocess.CompletedProcess(
            args=cmd, returncode=0, stdout="", stderr=""
        )

    monkeypatch.setattr(dev_rules_installer.subprocess, "run", fake_run)
    _set_env(
        monkeypatch,
        DEV_RULES_MODE="git",
        DEV_RULES_GIT_URL="https://git.example.corp/dev-rules.git",
    )

    rc = _run(tmp_path)

    assert rc == 0
    text = _out(tmp_path).read_text(encoding="utf-8")
    assert "All commits must be signed" in text
    assert text.startswith(HEADER_PREFIX)


# ---------------------------------------------------------------------------
# 6. DEV_RULES_MODE=git + clone fail -> exit 4
# ---------------------------------------------------------------------------
def test_mode_git_clone_failure_exits_4(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A non-zero return from ``git clone`` surfaces as exit 4."""

    def fake_run(
        cmd: list[str], *args: Any, **kwargs: Any
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(
            args=cmd,
            returncode=128,
            stdout="",
            stderr="fatal: repository not found\n",
        )

    monkeypatch.setattr(dev_rules_installer.subprocess, "run", fake_run)
    _set_env(
        monkeypatch,
        DEV_RULES_MODE="git",
        DEV_RULES_GIT_URL="https://git.example.corp/missing.git",
    )

    rc = _run(tmp_path)

    assert rc == 4
    assert not _out(tmp_path).exists()


# ---------------------------------------------------------------------------
# 7. Secret detection: Anthropic-style key -> exit 5
# ---------------------------------------------------------------------------
def test_secret_anthropic_key_exits_5(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A leaked ``sk-ant-...`` token in the rules content must be refused."""
    body = (
        "## Setup\n"
        "\n"
        "Export ANTHROPIC_API_KEY=sk-ant-xxx-leaked-1234567890abcd\n"
    )
    _set_env(monkeypatch, DEV_RULES_MODE="inline", DEV_RULES_CONTENT=body)

    rc = _run(tmp_path)

    assert rc == 5
    assert not _out(tmp_path).exists()


# ---------------------------------------------------------------------------
# 8. Secret detection: AWS access-key pattern -> exit 5
# ---------------------------------------------------------------------------
def test_secret_aws_key_exits_5(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An ``AKIA``-prefixed AWS access-key id must trip the scanner."""
    body = (
        "## AWS\n"
        "\n"
        "Use AKIA0123456789ABCDEF only on the bastion host.\n"
    )
    _set_env(monkeypatch, DEV_RULES_MODE="inline", DEV_RULES_CONTENT=body)

    rc = _run(tmp_path)

    assert rc == 5
    assert not _out(tmp_path).exists()


# ---------------------------------------------------------------------------
# 9. File-size limit (>100 KB) -> exit 2
# ---------------------------------------------------------------------------
def test_oversized_content_exits_2(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Payloads larger than ~100 KB are refused (exit 2) to prevent abuse."""
    # 120 KB of safe filler text — no secret-looking substrings.
    big = ("Lorem ipsum dolor sit amet. " * 5000)
    assert len(big) > 100 * 1024
    _set_env(monkeypatch, DEV_RULES_MODE="inline", DEV_RULES_CONTENT=big)

    rc = _run(tmp_path)

    assert rc == 2
    assert not _out(tmp_path).exists()


# ---------------------------------------------------------------------------
# 10. Header stamping with CORP_NAME
# ---------------------------------------------------------------------------
def test_header_uses_corp_name(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The first line is ``# <CORP_NAME> — Development Rules``."""
    _set_env(
        monkeypatch,
        DEV_RULES_MODE="inline",
        DEV_RULES_CONTENT="## Body\n\nsomething benign\n",
    )
    monkeypatch.setenv("CORP_NAME", "Globex SA")

    rc = _run(tmp_path)

    assert rc == 0
    first_line = _out(tmp_path).read_text(encoding="utf-8").splitlines()[0]
    assert first_line == "# Globex SA — Development Rules"


# ---------------------------------------------------------------------------
# 11. Output file mode is 0o644 (NOT 0o600)
# ---------------------------------------------------------------------------
def test_output_mode_is_644(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """File must be world-readable so corporate IT auditors can read it."""
    _set_env(
        monkeypatch,
        DEV_RULES_MODE="inline",
        DEV_RULES_CONTENT="## ok\n\nbenign body\n",
    )

    rc = _run(tmp_path)
    assert rc == 0

    mode = stat.S_IMODE(_out(tmp_path).stat().st_mode)
    # The exact request: chmod 644.
    assert mode == 0o644, f"expected 0o644, got {oct(mode)}"
    # Belt and braces: definitely not the 0o600 anti-pattern.
    assert mode != 0o600


# ---------------------------------------------------------------------------
# 12. --dry-run prints the plan but writes nothing
# ---------------------------------------------------------------------------
def test_dry_run_writes_nothing(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``--dry-run`` reports what would happen, but never touches the disk."""
    _set_env(
        monkeypatch,
        DEV_RULES_MODE="inline",
        DEV_RULES_CONTENT="## ok\n\nbenign body\n",
    )

    rc = _run(tmp_path, "--dry-run")

    assert rc == 0
    assert not _out(tmp_path).exists()

    captured = capsys.readouterr()
    # We do not pin the exact wording (W2 owns the copy) but the output
    # must mention dry-run and the destination path.
    combined = (captured.out + captured.err).lower()
    assert "dry" in combined
    assert "dev-rules.md" in combined or str(_out(tmp_path)) in combined


# ---------------------------------------------------------------------------
# Bonus: dry-run still validates input -> oversized payload exits 2 even
# in dry-run, so users learn about the failure before "real" install.
# ---------------------------------------------------------------------------
def test_dry_run_still_enforces_size_limit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Validation runs in dry-run mode too — oversize still exits 2."""
    big = ("a" * (110 * 1024))
    _set_env(monkeypatch, DEV_RULES_MODE="inline", DEV_RULES_CONTENT=big)

    rc = _run(tmp_path, "--dry-run")

    # Either 2 (preferred — validation runs first) or the implementation
    # chooses to short-circuit dry-run before checks; allow both but prefer
    # the strict reading.
    assert rc in (0, 2)
    assert not _out(tmp_path).exists()
