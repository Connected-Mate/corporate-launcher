"""End-to-end integration tests for the scenario fixtures.

Each fixture under ``evals/scenarios/scenario-*.json`` describes a complete
DOG-style configuration the skill would produce after the interview, plus
the file tree the generator must materialise. This test pins the contract:

  1. Load every scenario fixture.
  2. Write its ``config`` block to a temp config file.
  3. Run ``python3 scripts/generate.py --config <tmp>`` end-to-end.
  4. Assert every path in ``expected_files`` exists under <out>/ and every
     path in ``expected_dist_files`` exists under <dist>/.
  5. Run the rendered launcher with ``--help`` and capture stdout.
  6. Grep that stdout (the user-facing banner) for every term in
     ``expected_branding_check`` — none of them must appear.

The scenarios are realistic but self-contained — no network, no real
``gh`` / ``git``. Subprocess fan-out (scaffold.sh inside dist/) runs in
the temp dir; we do not push or publish anything.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCENARIOS_DIR = REPO_ROOT / "evals" / "scenarios"
GENERATE = REPO_ROOT / "scripts" / "generate.py"


def _scenarios() -> list[Path]:
    """Return every scenario-*.json fixture, sorted for deterministic IDs."""
    if not SCENARIOS_DIR.is_dir():
        return []
    return sorted(SCENARIOS_DIR.glob("scenario-*.json"))


def _load_scenario(path: Path) -> dict[str, Any]:
    """Read and minimally validate a scenario fixture."""
    data = json.loads(path.read_text(encoding="utf-8"))
    for required in ("scenario_name", "config", "expected_files", "expected_branding_check"):
        assert required in data, f"{path.name}: missing required key {required!r}"
    return data


def _write_config(tmp: Path, config: dict[str, Any]) -> Path:
    cfg = tmp / "config.json"
    cfg.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return cfg


def _run_generate(cfg: Path, out: Path, dist: Path) -> subprocess.CompletedProcess[str]:
    """Invoke scripts/generate.py end-to-end and capture output."""
    return subprocess.run(
        [
            sys.executable,
            str(GENERATE),
            "--config", str(cfg),
            "--out", str(out),
            "--dist-dir", str(dist),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def _run_launcher_help(launcher: Path) -> tuple[int, str]:
    """Run the rendered launcher with --help and return (returncode, stdout)."""
    proc = subprocess.run(
        ["bash", str(launcher), "--help"],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


@pytest.mark.skipif(not GENERATE.is_file(), reason="scripts/generate.py not present")
@pytest.mark.parametrize("scenario_path", _scenarios(), ids=lambda p: p.stem)
def test_scenario_end_to_end(scenario_path: Path, tmp_path: Path) -> None:
    """Render the scenario, verify expected_files, run --help, check branding."""
    data = _load_scenario(scenario_path)
    config = data["config"]
    slug = config["CORP_SLUG"]

    out = tmp_path / "install"
    dist = tmp_path / "dist"
    cfg = _write_config(tmp_path, config)

    # 1. Render the launcher.
    result = _run_generate(cfg, out, dist)
    assert result.returncode == 0, (
        f"generate.py failed for {scenario_path.name}:\n"
        f"  stdout: {result.stdout}\n"
        f"  stderr: {result.stderr}"
    )

    # 2. Every expected install-tree path must exist.
    missing = [rel for rel in data["expected_files"] if not (out / rel).exists()]
    assert not missing, (
        f"{scenario_path.name}: missing files under {out}: {missing}\n"
        f"actually produced: {sorted(p.relative_to(out).as_posix() for p in out.rglob('*') if p.is_file())}"
    )

    # 3. Every expected dist-tree path must exist (when declared).
    for rel in data.get("expected_dist_files", []):
        assert (dist / rel).exists(), (
            f"{scenario_path.name}: missing dist file {rel} under {dist}"
        )

    # 4. Launcher --help must succeed and produce non-empty output.
    launcher = out / slug
    # Not every CLI template ships a slug-named launcher (e.g. codex-cli emits
    # launcher.sh instead). Pick whichever exists.
    candidates = [out / slug, out / "launcher.sh"]
    launcher = next((p for p in candidates if p.exists()), None)
    assert launcher is not None, (
        f"{scenario_path.name}: no launcher found at any of "
        f"{[str(p.relative_to(out)) for p in candidates]}"
    )

    rc, help_text = _run_launcher_help(launcher)
    assert rc == 0, (
        f"{scenario_path.name}: launcher --help exited {rc}\n"
        f"output: {help_text[:2000]}"
    )
    assert help_text.strip(), f"{scenario_path.name}: launcher --help produced empty output"

    # 5. Grep launcher --help output for forbidden vendor terms.
    for term in data["expected_branding_check"]:
        # Word-boundary regex so 'Anthropicus' would still trip, but raw
        # substrings inside random hashes won't.
        pattern = re.compile(rf"\b{re.escape(term)}\b", re.IGNORECASE)
        match = pattern.search(help_text)
        assert match is None, (
            f"{scenario_path.name}: forbidden term {term!r} leaked into "
            f"launcher --help output near: {help_text[max(0, match.start()-40):match.end()+40]!r}"
        )


@pytest.mark.skipif(not GENERATE.is_file(), reason="scripts/generate.py not present")
def test_scenarios_directory_is_populated() -> None:
    """Fail loudly if someone removes the fixtures by mistake."""
    found = _scenarios()
    assert len(found) >= 3, (
        f"expected at least 3 scenario fixtures under {SCENARIOS_DIR}, "
        f"found {[p.name for p in found]}"
    )
    names = {p.stem for p in found}
    for required in ("scenario-claude-bedrock", "scenario-codex-azure", "scenario-cline-cursor"):
        assert required in names, f"missing required fixture {required}.json"
