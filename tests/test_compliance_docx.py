"""Tests for ``scripts/build-compliance-docx.py``.

The script renders a corporate compliance dossier (``.docx``) from a JSON
config and an optional audit report. It is meant to be shared with the
internal cyber authority, so the output must be a valid Office Open XML
container, contain the ten mandatory sections, substitute the corporate
placeholders, and land on disk with ``chmod 644`` (group/world readable).

The whole module is skipped if ``python-docx`` is not available — there is
no point asserting on a docx we cannot even build.

Inspection is done with stdlib ``zipfile`` only: a ``.docx`` is just a ZIP
archive whose ``word/document.xml`` part holds the body text.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any

import pytest

# Skip the entire module if python-docx is not installed — the script under
# test depends on it and so does the build step it exercises.
pytest.importorskip("docx")


# --------------------------------------------------------------------------- #
# Paths & module-level guards                                                  #
# --------------------------------------------------------------------------- #

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "build-compliance-docx.py"


def _require_script() -> None:
    """Skip the calling test if the script has not been written yet."""
    if not SCRIPT_PATH.exists():
        pytest.skip(
            f"build-compliance-docx.py not yet implemented at {SCRIPT_PATH}",
            allow_module_level=False,
        )


# The ten required sections, lowercased for tolerant matching.
REQUIRED_SECTIONS: tuple[str, ...] = (
    "executive summary",
    "threat model",
    "data classification",
    "access control",
    "logging and audit",
    "incident response",
    "supply chain",
    "secrets management",
    "network egress",
    "compliance attestation",
)


# --------------------------------------------------------------------------- #
# Fixtures                                                                     #
# --------------------------------------------------------------------------- #


@pytest.fixture()
def minimal_config(tmp_path: Path) -> Path:
    """Write a minimal but valid config JSON and return its path."""
    cfg: dict[str, Any] = {
        "corp_name": "ACME",
        "cyber_authority": "ACME Corporate Security Office",
        "cc_primary_url": "https://gateway.acme.example",
        "wrapped_cli": "claude-code",
        "distribution_mode": "tarball",
    }
    p = tmp_path / "config.json"
    p.write_text(json.dumps(cfg), encoding="utf-8")
    return p


@pytest.fixture()
def audit_report(tmp_path: Path) -> Path:
    """A tiny markdown audit report to feed via --audit-report."""
    p = tmp_path / "audit.md"
    p.write_text(
        "# Audit findings\n\n"
        "- 0 P0 issues\n"
        "- 2 P2 issues (documented in appendix)\n",
        encoding="utf-8",
    )
    return p


def _run_script(*args: str) -> subprocess.CompletedProcess[str]:
    """Invoke the script as a subprocess and capture stdout/stderr."""
    return subprocess.run(
        [sys.executable, str(SCRIPT_PATH), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def _read_document_xml(docx_path: Path) -> str:
    """Return the body XML of a .docx as a UTF-8 string."""
    with zipfile.ZipFile(docx_path) as zf:
        return zf.read("word/document.xml").decode("utf-8")


# --------------------------------------------------------------------------- #
# 1. Happy path — config → .docx                                              #
# --------------------------------------------------------------------------- #


def test_generates_docx_from_minimal_config(
    tmp_path: Path, minimal_config: Path
) -> None:
    _require_script()
    out = tmp_path / "compliance.docx"

    result = _run_script("--config", str(minimal_config), "--out", str(out))

    assert result.returncode == 0, (
        f"script exited {result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
    )
    assert out.exists(), f"expected docx at {out}"
    assert out.stat().st_size > 0, "docx must not be empty"


# --------------------------------------------------------------------------- #
# 2. Output is a valid OOXML container                                         #
# --------------------------------------------------------------------------- #


def test_docx_is_valid_zip_with_document_xml(
    tmp_path: Path, minimal_config: Path
) -> None:
    _require_script()
    out = tmp_path / "compliance.docx"
    _run_script("--config", str(minimal_config), "--out", str(out))

    assert zipfile.is_zipfile(out), "docx must be a valid ZIP archive"
    with zipfile.ZipFile(out) as zf:
        names = set(zf.namelist())
        assert "word/document.xml" in names, (
            f"word/document.xml missing from docx parts: {sorted(names)}"
        )
        # Basic sanity: [Content_Types].xml is required by the OOXML spec.
        assert "[Content_Types].xml" in names


# --------------------------------------------------------------------------- #
# 3. All ten required sections are present                                     #
# --------------------------------------------------------------------------- #


def test_contains_all_required_sections(
    tmp_path: Path, minimal_config: Path
) -> None:
    _require_script()
    out = tmp_path / "compliance.docx"
    _run_script("--config", str(minimal_config), "--out", str(out))

    body = _read_document_xml(out).lower()
    missing = [s for s in REQUIRED_SECTIONS if s not in body]
    assert not missing, f"missing required sections: {missing}"


# --------------------------------------------------------------------------- #
# 4. Placeholders are substituted with config values                           #
# --------------------------------------------------------------------------- #


def test_placeholders_are_substituted(
    tmp_path: Path, minimal_config: Path
) -> None:
    _require_script()
    out = tmp_path / "compliance.docx"
    _run_script("--config", str(minimal_config), "--out", str(out))

    body = _read_document_xml(out)

    # Raw placeholders must not leak through.
    for raw in ("${CORP_NAME}", "${CYBER_AUTHORITY}", "${CC_PRIMARY_URL}"):
        assert raw not in body, f"unresolved placeholder leaked: {raw}"

    # Their resolved values must appear at least once each.
    assert "ACME" in body
    assert "ACME Corporate Security Office" in body
    assert "https://gateway.acme.example" in body


# --------------------------------------------------------------------------- #
# 5. Optional --audit-report integration                                       #
# --------------------------------------------------------------------------- #


def test_audit_report_optional_integration(
    tmp_path: Path, minimal_config: Path, audit_report: Path
) -> None:
    _require_script()
    out = tmp_path / "compliance.docx"

    result = _run_script(
        "--config",
        str(minimal_config),
        "--out",
        str(out),
        "--audit-report",
        str(audit_report),
    )
    assert result.returncode == 0, result.stderr

    body = _read_document_xml(out)
    # Either the heading or a finding from the audit report should surface.
    assert "Audit findings" in body or "0 P0 issues" in body, (
        "audit report content was not merged into the dossier"
    )


def test_audit_report_truly_optional(
    tmp_path: Path, minimal_config: Path
) -> None:
    """Omitting --audit-report must still succeed."""
    _require_script()
    out = tmp_path / "compliance.docx"
    result = _run_script("--config", str(minimal_config), "--out", str(out))
    assert result.returncode == 0
    assert out.exists()


# --------------------------------------------------------------------------- #
# 6. python-docx missing → exit 1 with install hint                            #
# --------------------------------------------------------------------------- #


def test_exits_with_install_hint_when_python_docx_missing(
    tmp_path: Path, minimal_config: Path
) -> None:
    _require_script()
    out = tmp_path / "compliance.docx"

    # Force ``import docx`` to fail by shadowing it with a sitecustomize
    # that raises ImportError, and by pointing PYTHONPATH at a directory
    # holding a poison ``docx.py`` that does ``raise ImportError``.
    poison_dir = tmp_path / "poison"
    poison_dir.mkdir()
    (poison_dir / "docx.py").write_text(
        "raise ImportError('python-docx not installed (poisoned for test)')\n",
        encoding="utf-8",
    )

    env = os.environ.copy()
    env["PYTHONPATH"] = str(poison_dir) + os.pathsep + env.get("PYTHONPATH", "")

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT_PATH),
            "--config",
            str(minimal_config),
            "--out",
            str(out),
        ],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )

    assert result.returncode == 1, (
        f"expected exit 1 when python-docx is missing, got {result.returncode}\n"
        f"stdout={result.stdout}\nstderr={result.stderr}"
    )
    combined = (result.stdout + result.stderr).lower()
    assert "pip install" in combined and "python-docx" in combined, (
        f"missing install hint in error output:\n{result.stdout}\n{result.stderr}"
    )


# --------------------------------------------------------------------------- #
# 7. Output file permissions: 644 (shareable, not 600)                         #
# --------------------------------------------------------------------------- #


@pytest.mark.skipif(
    sys.platform.startswith("win"),
    reason="POSIX permission bits are not meaningful on Windows",
)
def test_output_file_is_chmod_644(
    tmp_path: Path, minimal_config: Path
) -> None:
    _require_script()
    out = tmp_path / "compliance.docx"
    result = _run_script("--config", str(minimal_config), "--out", str(out))
    assert result.returncode == 0, result.stderr

    mode = stat.S_IMODE(out.stat().st_mode)
    assert mode == 0o644, (
        f"expected 0o644 (shareable with cyber team), got {oct(mode)}; "
        "0o600 would block reviewers"
    )
