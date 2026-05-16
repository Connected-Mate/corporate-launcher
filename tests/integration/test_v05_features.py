"""End-to-end integration tests for the v0.5 feature set.

This module pins the full pipeline against the canonical example config
(``examples/configs/acme-claude-litellm.json``) and exercises every new
v0.5 capability so a regression anywhere in the chain breaks CI loudly:

* generate.py: dry-run AND real render exit cleanly.
* audit-launcher.py: scores 8/8 (no P0 / P1 / P2 findings).
* url-purge.py: zero VIOLATIONs on a clean render.
* pixel-art-logo.py: emits a non-empty ASCII banner.
* api-probe.py: exposes --help (CLI contract intact).

Each test runs in a fresh ``tmp_path``; the generator never touches the
real filesystem outside the temp tree. No network, no MCP, no skills
fetch (config sets SKILLS_MODE=combined but the installer no-ops without
SKILLS_GIT_URL connectivity).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EXAMPLE_CFG = REPO_ROOT / "examples" / "configs" / "acme-claude-litellm.json"
SCRIPTS = REPO_ROOT / "scripts"


# --------------------------------------------------------------------------- #
# Fixtures                                                                    #
# --------------------------------------------------------------------------- #


@pytest.fixture(scope="module")
def example_config_path() -> Path:
    """Sanity-check that the canonical config is committed before tests run."""
    assert EXAMPLE_CFG.is_file(), (
        f"Missing canonical example config at {EXAMPLE_CFG}. The v0.5 "
        f"integration suite cannot run without it."
    )
    return EXAMPLE_CFG


@pytest.fixture(scope="module")
def generated_launcher(tmp_path_factory, example_config_path: Path) -> Path:
    """Run generate.py once per module; reuse the output across tests.

    Scoping at module level keeps the suite under ~5s on a laptop. Per-test
    regeneration would add ~3s × N — wasteful for an integration test that
    only inspects the rendered tree.
    """
    out_dir = tmp_path_factory.mktemp("v05-launcher")
    cmd = [
        sys.executable,
        str(SCRIPTS / "generate.py"),
        "--config", str(example_config_path),
        "--out", str(out_dir),
    ]
    proc = subprocess.run(
        cmd, capture_output=True, text=True, cwd=str(REPO_ROOT), check=False
    )
    assert proc.returncode == 0, (
        f"generate.py failed (rc={proc.returncode}):\n"
        f"--- stdout ---\n{proc.stdout}\n"
        f"--- stderr ---\n{proc.stderr}"
    )
    # The launcher binary is named after CORP_SLUG.
    slug = json.loads(example_config_path.read_text())["CORP_SLUG"]
    launcher_bin = out_dir / slug
    assert launcher_bin.is_file(), f"launcher binary {launcher_bin} not rendered"
    return out_dir


# --------------------------------------------------------------------------- #
# generate.py — dry-run + real                                                #
# --------------------------------------------------------------------------- #


def test_generate_dry_run_clean(tmp_path: Path, example_config_path: Path) -> None:
    """Dry-run must produce a complete PLAN without writing any files."""
    out = tmp_path / "dry"
    proc = subprocess.run(
        [
            sys.executable,
            str(SCRIPTS / "generate.py"),
            "--config", str(example_config_path),
            "--out", str(out),
            "--dry-run",
        ],
        capture_output=True, text=True, cwd=str(REPO_ROOT), check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert "generation PLAN" in proc.stdout
    assert "Dry run — no files were written" in proc.stdout
    # The generator may create the out dir during validation, but nothing
    # inside it should be a rendered launcher binary.
    slug = json.loads(example_config_path.read_text())["CORP_SLUG"]
    assert not (out / slug).is_file()


def test_generate_real_render_produces_launcher(generated_launcher: Path) -> None:
    """The full pipeline must materialise the canonical launcher tree."""
    expected = [
        "acme-copilot",       # launcher binary (CORP_SLUG)
        "install.sh",
        "uninstall.sh",
        "settings.json",
        "BRANDING.md",
        "audit-report.md",
        "url-purge-report.md",
        "banner.txt",
        "scripts/cyber-rules.md",
        "scripts/api-probe.sh",
        "scripts/proxy-detect.sh",
    ]
    missing = [p for p in expected if not (generated_launcher / p).exists()]
    assert not missing, f"Missing expected files: {missing}"

    # Shell scripts and the launcher binary must be executable.
    for rel in ("acme-copilot", "install.sh", "uninstall.sh"):
        mode = (generated_launcher / rel).stat().st_mode
        assert mode & 0o111, f"{rel} not executable (mode={oct(mode)})"


# --------------------------------------------------------------------------- #
# audit-launcher.py                                                           #
# --------------------------------------------------------------------------- #


def test_audit_launcher_passes_all_checks(
    tmp_path: Path, generated_launcher: Path, example_config_path: Path
) -> None:
    """Audit must report 0 failures on the canonical render."""
    report_md = tmp_path / "audit.md"
    proc = subprocess.run(
        [
            sys.executable,
            str(SCRIPTS / "audit-launcher.py"),
            "--launcher-dir", str(generated_launcher),
            "--config", str(example_config_path),
            "--output", str(report_md),
        ],
        capture_output=True, text=True, cwd=str(REPO_ROOT), check=False,
    )
    assert proc.returncode == 0, (
        f"audit-launcher failed (rc={proc.returncode}):\n{proc.stderr}"
    )
    # Inspect the JSON twin for a structured assertion on P0/P1/P2 count.
    report_json = report_md.with_suffix(".json")
    assert report_json.is_file(), "audit JSON report missing"
    data = json.loads(report_json.read_text())
    failures = int(data.get("failures", -1))
    assert failures == 0, (
        f"audit reported {failures} failure(s):\n{report_md.read_text()}"
    )
    # Sanity: at least 8 checks ran (matches v0.5 rulebook).
    assert int(data.get("total", 0)) >= 8


# --------------------------------------------------------------------------- #
# url-purge.py                                                                #
# --------------------------------------------------------------------------- #


def test_url_purge_reports_zero_violations(
    tmp_path: Path, generated_launcher: Path, example_config_path: Path
) -> None:
    """A freshly generated launcher must have ZERO vendor-URL violations."""
    report = tmp_path / "purge.md"
    proc = subprocess.run(
        [
            sys.executable,
            str(SCRIPTS / "url-purge.py"),
            "--launcher-dir", str(generated_launcher),
            "--config", str(example_config_path),
            "--report", str(report),
        ],
        capture_output=True, text=True, cwd=str(REPO_ROOT), check=False,
    )
    assert proc.returncode == 0, proc.stderr
    text = (proc.stdout or "") + (proc.stderr or "")
    # The purge tool prints `Violations: <n>` to stdout.
    assert "Violations: 0" in text, (
        f"Expected zero violations.\nstdout:\n{proc.stdout}\n"
        f"report:\n{report.read_text() if report.is_file() else '(no report)'}"
    )


# --------------------------------------------------------------------------- #
# pixel-art-logo.py                                                           #
# --------------------------------------------------------------------------- #


def test_pixel_art_logo_emits_banner() -> None:
    """The ASCII banner generator must produce non-empty output."""
    proc = subprocess.run(
        [
            sys.executable,
            str(SCRIPTS / "pixel-art-logo.py"),
            "--text", "ACME COPILOT",
            "--style", "block",
            "--color", "33",
        ],
        capture_output=True, text=True, cwd=str(REPO_ROOT), check=False,
    )
    assert proc.returncode == 0, proc.stderr
    body = proc.stdout
    # The fallback embedded font draws blocks with `█`; pyfiglet output also
    # contains it for the block style. Either way, a real banner must be
    # multi-line and non-empty.
    assert body.strip(), "pixel-art-logo produced empty output"
    assert "\n" in body.strip(), "banner should be multi-line"
    # ANSI color sequence must be wrapped around the body when --color is set.
    assert "\033[" in body, "banner missing ANSI color escape"


# --------------------------------------------------------------------------- #
# api-probe.py                                                                #
# --------------------------------------------------------------------------- #


def test_api_probe_help_invocable() -> None:
    """The probe CLI must respond to --help without imports/IO side effects."""
    proc = subprocess.run(
        [sys.executable, str(SCRIPTS / "api-probe.py"), "--help"],
        capture_output=True, text=True, cwd=str(REPO_ROOT), check=False,
    )
    assert proc.returncode == 0, proc.stderr
    out = proc.stdout.lower()
    # Required argument surface area for v0.5 probe contract.
    for token in ("--url", "--token", "--backend"):
        assert token in out, f"--help output missing {token}"
