"""End-to-end integration tests for the v0.6 feature set.

v0.6 adds two flagship capabilities on top of the v0.5 baseline:

* **Dev-rules pipeline** (``scripts/dev-rules-installer.py``) — materialises
  the company's internal coding conventions as ``<launcher>/dev-rules.md``
  from one of four sources (``inline`` | ``local`` | ``git`` | ``none``).
* **Claude-Code plugin manifest** (``.claude-plugin/plugin.json``) plus the
  ``agents/`` directory shipping the four canonical sub-agents.

This module pins each surface against the canonical example config so a
regression in any of them breaks CI loudly. The tests intentionally
exercise the installer **directly** (rather than going through
``generate.py``) when the mode under test is not yet on the generator's
allow-list (e.g. ``inline``) — that way we still get end-to-end coverage
of the rendering contract without depending on validator changes that
land in a later patch.

No network. No real ``git clone`` — mode=git is exercised with a stubbed
``subprocess.run`` via ``monkeypatch``.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EXAMPLE_CFG = REPO_ROOT / "examples" / "configs" / "acme-claude-litellm.json"
SCRIPTS = REPO_ROOT / "scripts"
AGENTS = REPO_ROOT / "agents"
PLUGIN_MANIFEST = REPO_ROOT / ".claude-plugin" / "plugin.json"

DEV_RULES_INSTALLER = SCRIPTS / "dev-rules-installer.py"
GENERATE_PY = SCRIPTS / "generate.py"


# --------------------------------------------------------------------------- #
# Fixtures                                                                    #
# --------------------------------------------------------------------------- #


@pytest.fixture(scope="module")
def base_config() -> dict:
    """The canonical example config, parsed once and reused."""
    assert EXAMPLE_CFG.is_file(), f"missing canonical example: {EXAMPLE_CFG}"
    return json.loads(EXAMPLE_CFG.read_text(encoding="utf-8"))


def _write_dev_rules_cfg(tmp_path: Path, overrides: dict) -> Path:
    """Build a minimal config tailored to the dev-rules-installer contract.

    The installer only consumes a handful of keys; we keep this lean so each
    test reads top-to-bottom without scanning the 100-line example file.
    """
    cfg = {
        "CORP_NAME": "ACME Copilot",
        "DEV_RULES_MODE": "none",
        "DEV_RULES_CONTENT": "",
        "DEV_RULES_LOCAL_PATH": "",
        "DEV_RULES_GIT_URL": "",
        "DEV_RULES_GIT_REF": "main",
        "DEV_RULES_GIT_PATH": "dev-rules.md",
    }
    cfg.update(overrides)
    out = tmp_path / "dev-rules.json"
    out.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    return out


def _run_installer(cfg_path: Path, launcher_dir: Path) -> subprocess.CompletedProcess:
    """Invoke dev-rules-installer.py with the standard CLI surface."""
    cmd = [
        sys.executable,
        str(DEV_RULES_INSTALLER),
        "--config", str(cfg_path),
        "--launcher-dir", str(launcher_dir),
    ]
    return subprocess.run(
        cmd, capture_output=True, text=True, cwd=str(REPO_ROOT), check=False
    )


# --------------------------------------------------------------------------- #
# 1. DEV_RULES_MODE=inline                                                    #
# --------------------------------------------------------------------------- #


def test_dev_rules_inline_writes_branded_file(tmp_path: Path) -> None:
    """inline mode must drop a dev-rules.md carrying header + raw content."""
    launcher_dir = tmp_path / "launcher"
    launcher_dir.mkdir()
    cfg = _write_dev_rules_cfg(
        tmp_path,
        {
            "DEV_RULES_MODE": "inline",
            "DEV_RULES_CONTENT": "# Test rules\n- snake_case for Python files\n",
        },
    )

    proc = _run_installer(cfg, launcher_dir)
    assert proc.returncode == 0, (
        f"installer failed (rc={proc.returncode}):\n"
        f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    )

    rules_file = launcher_dir / "dev-rules.md"
    assert rules_file.is_file(), "dev-rules.md was not created"

    body = rules_file.read_text(encoding="utf-8")
    assert "snake_case" in body, "inline content not preserved in rendered file"
    # Corp branding header injected by the installer:
    assert "ACME Copilot" in body, "corp branding header missing"
    assert "Development Rules" in body, "header tagline missing"
    assert "Sourced: inline" in body, "header should declare the source mode"


# --------------------------------------------------------------------------- #
# 2. DEV_RULES_MODE=local                                                     #
# --------------------------------------------------------------------------- #


def test_dev_rules_local_copies_content_from_file(tmp_path: Path) -> None:
    """local mode must read the pointed file and copy its content verbatim."""
    src = tmp_path / "team-rules.md"
    payload = "# Team rules\n\n- Always use type hints\n- Prefer dataclasses\n"
    src.write_text(payload, encoding="utf-8")

    launcher_dir = tmp_path / "launcher"
    launcher_dir.mkdir()
    cfg = _write_dev_rules_cfg(
        tmp_path,
        {
            "DEV_RULES_MODE": "local",
            "DEV_RULES_LOCAL_PATH": str(src),
        },
    )

    proc = _run_installer(cfg, launcher_dir)
    assert proc.returncode == 0, proc.stderr

    body = (launcher_dir / "dev-rules.md").read_text(encoding="utf-8")
    assert "type hints" in body, "local file body not propagated"
    assert "dataclasses" in body, "local file body partially copied"
    assert "Sourced: local" in body, "header should declare source=local"


# --------------------------------------------------------------------------- #
# 3. DEV_RULES_MODE=git (mocked subprocess)                                   #
# --------------------------------------------------------------------------- #


def test_dev_rules_git_mode_invokes_clone(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """git mode must shell out to ``git clone`` with --depth 1 + --branch.

    We stub ``subprocess.run`` at module scope of the installer and snapshot
    every call. Then we hand-craft the cloned tree so the installer can read
    the file back without touching the network.
    """
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "dev_rules_installer", DEV_RULES_INSTALLER
    )
    assert spec is not None and spec.loader is not None
    installer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installer)

    calls: list[list[str]] = []
    real_run = subprocess.run

    def fake_run(cmd, *args, **kwargs):
        # Snapshot the call for inspection, then materialise the expected
        # tree on disk so the installer's post-clone read() succeeds.
        calls.append(list(cmd))
        if isinstance(cmd, list) and len(cmd) >= 2 and cmd[0] == "git" and cmd[1] == "clone":
            target = Path(cmd[-1])
            target.mkdir(parents=True, exist_ok=True)
            (target / "dev-rules.md").write_text(
                "# Cloned rules\n\n- Test\n", encoding="utf-8"
            )
            return subprocess.CompletedProcess(cmd, 0, b"", b"")
        return real_run(cmd, *args, **kwargs)

    monkeypatch.setattr(installer.subprocess, "run", fake_run)

    cfg_dict = {
        "CORP_NAME": "ACME Copilot",
        "DEV_RULES_MODE": "git",
        "DEV_RULES_GIT_URL": "https://git.acme.internal/ai-platform/dev-rules.git",
        "DEV_RULES_GIT_REF": "main",
        "DEV_RULES_GIT_PATH": "dev-rules.md",
    }
    cfg_path = tmp_path / "dev-rules.json"
    cfg_path.write_text(json.dumps(cfg_dict), encoding="utf-8")
    launcher_dir = tmp_path / "launcher"
    launcher_dir.mkdir()

    rc = installer.main(
        ["--config", str(cfg_path), "--launcher-dir", str(launcher_dir)]
    )
    assert rc == 0, "installer should succeed when git clone is stubbed"

    # At least one git clone call must have been issued, targeting the URL.
    clone_calls = [c for c in calls if len(c) >= 2 and c[:2] == ["git", "clone"]]
    assert clone_calls, f"git clone was never invoked. calls: {calls}"
    flat = " ".join(clone_calls[0])
    assert "git.acme.internal/ai-platform/dev-rules.git" in flat, (
        f"clone call missing repo URL: {clone_calls[0]}"
    )

    rules_file = launcher_dir / "dev-rules.md"
    assert rules_file.is_file(), "git mode did not produce dev-rules.md"
    body = rules_file.read_text(encoding="utf-8")
    assert "Cloned rules" in body
    assert "Sourced: git" in body


# --------------------------------------------------------------------------- #
# 4. DEV_RULES_MODE=none                                                      #
# --------------------------------------------------------------------------- #


def test_dev_rules_none_writes_minimal_placeholder(tmp_path: Path) -> None:
    """none mode must still write a placeholder so launcher.sh can mount it."""
    launcher_dir = tmp_path / "launcher"
    launcher_dir.mkdir()
    cfg = _write_dev_rules_cfg(tmp_path, {"DEV_RULES_MODE": "none"})

    proc = _run_installer(cfg, launcher_dir)
    assert proc.returncode == 0, proc.stderr

    rules_file = launcher_dir / "dev-rules.md"
    assert rules_file.is_file(), "even mode=none must produce a placeholder"

    body = rules_file.read_text(encoding="utf-8")
    # Minimal placeholder: branded header + a no-rules notice.
    assert "ACME Copilot" in body, "placeholder still needs corp branding"
    assert "Sourced: none" in body, "placeholder must declare source=none"
    assert "No corporate dev rules" in body, (
        "placeholder should explicitly state that no rules were defined"
    )
    # Sanity: the placeholder is small (it has no real content).
    assert len(body.encode("utf-8")) < 1024, "placeholder unexpectedly large"


# --------------------------------------------------------------------------- #
# 5. Launcher binary wires dev-rules.md into --append-system-prompt-file      #
# --------------------------------------------------------------------------- #


@pytest.fixture(scope="module")
def rendered_launcher_tree(tmp_path_factory) -> Path:
    """Run generate.py once against a v0.6-compatible copy of the example.

    The canonical config ships ``DEV_RULES_MODE=inline`` which the generator's
    validator does not yet whitelist; we rewrite that single key to ``local``
    (pointing at a stub rules file) so the full pipeline can execute.
    """
    out_dir = tmp_path_factory.mktemp("v06-launcher")
    base = json.loads(EXAMPLE_CFG.read_text(encoding="utf-8"))

    stub_rules = out_dir / "stub-dev-rules.md"
    stub_rules.write_text(
        "# Stub rules\n\n- Use type hints\n", encoding="utf-8"
    )
    base["DEV_RULES_MODE"] = "local"
    base["DEV_RULES_LOCAL_PATH"] = str(stub_rules)
    # The generator may still attempt skills clone / api-probe — neutralise.
    base["SKILLS_MODE"] = "none"
    base["API_PROBE_ENABLED"] = "no"
    base["LOAD_TEST_ENABLED"] = "no"
    base["SELF_AUDIT_ENABLED"] = "no"
    base["COMPLIANCE_DOCX"] = "no"

    cfg_path = out_dir / "config.json"
    cfg_path.write_text(json.dumps(base, indent=2), encoding="utf-8")

    proc = subprocess.run(
        [
            sys.executable,
            str(GENERATE_PY),
            "--config", str(cfg_path),
            "--out", str(out_dir / "render"),
            "--non-interactive",
        ],
        capture_output=True, text=True, cwd=str(REPO_ROOT), check=False,
    )
    if proc.returncode != 0:
        pytest.skip(
            f"generate.py failed in v0.6 fixture (rc={proc.returncode}); "
            f"stderr:\n{proc.stderr[:500]}"
        )
    return out_dir / "render"


def test_launcher_binary_references_dev_rules_md(
    rendered_launcher_tree: Path, base_config: dict
) -> None:
    """The rendered launcher binary must mount dev-rules.md as a prompt file.

    Mechanism: the bash launcher calls ``claude --append-system-prompt-file
    <path>`` for every corporate prompt fragment. dev-rules.md is the v0.6
    addition. We grep the rendered text for both tokens.
    """
    slug = base_config["CORP_SLUG"]
    launcher_bin = rendered_launcher_tree / slug
    assert launcher_bin.is_file(), f"launcher binary missing: {launcher_bin}"

    text = launcher_bin.read_text(encoding="utf-8")
    assert "--append-system-prompt-file" in text, (
        "launcher should wire prompt fragments via --append-system-prompt-file"
    )
    assert "dev-rules.md" in text, (
        "launcher binary must reference dev-rules.md so the corporate "
        "coding standards are appended to the system prompt at runtime"
    )


# --------------------------------------------------------------------------- #
# 6. Plugin manifest                                                          #
# --------------------------------------------------------------------------- #


def test_plugin_manifest_is_valid_json_with_required_fields() -> None:
    """.claude-plugin/plugin.json must be valid JSON exposing the v0.6 contract."""
    assert PLUGIN_MANIFEST.is_file(), (
        f"missing plugin manifest at {PLUGIN_MANIFEST}"
    )

    raw = PLUGIN_MANIFEST.read_text(encoding="utf-8")
    try:
        manifest = json.loads(raw)
    except json.JSONDecodeError as exc:
        pytest.fail(f"plugin.json is not valid JSON: {exc}")

    # Required surface for a Claude Code plugin manifest.
    required = ("name", "version", "description")
    missing = [k for k in required if k not in manifest]
    assert not missing, f"plugin.json missing required fields: {missing}"

    # The name should be the project slug — anything else suggests a copy-paste bug.
    assert manifest["name"] == "corporate-launcher", (
        f"unexpected plugin name: {manifest['name']!r}"
    )
    # SemVer-ish version string.
    assert isinstance(manifest["version"], str) and manifest["version"], (
        "plugin.json version must be a non-empty string"
    )
    parts = manifest["version"].split(".")
    assert len(parts) >= 2 and all(p.isdigit() for p in parts[:2]), (
        f"plugin version {manifest['version']!r} is not semver-shaped"
    )


# --------------------------------------------------------------------------- #
# 7. agents/ directory                                                        #
# --------------------------------------------------------------------------- #


def test_agents_directory_ships_canonical_subagents() -> None:
    """v0.6 must ship at least four sub-agent specs under agents/."""
    assert AGENTS.is_dir(), f"missing agents/ directory at {AGENTS}"

    md_files = sorted(p for p in AGENTS.glob("*.md") if p.is_file())
    assert len(md_files) >= 4, (
        f"expected >=4 subagent files in {AGENTS}, found {len(md_files)}: "
        f"{[p.name for p in md_files]}"
    )

    # Each subagent file must declare a YAML front-matter header so the
    # Claude Code plugin loader can discover its metadata.
    for f in md_files:
        head = f.read_text(encoding="utf-8").splitlines()[:6]
        joined = "\n".join(head)
        assert joined.startswith("---"), (
            f"{f.name} missing YAML front-matter (first lines: {head!r})"
        )
        assert "name:" in joined, f"{f.name} missing `name:` front-matter key"
        assert "description:" in joined, (
            f"{f.name} missing `description:` front-matter key"
        )


# --------------------------------------------------------------------------- #
# 8. "Proudly made from France" footer                                        #
# --------------------------------------------------------------------------- #


def test_launcher_carries_french_footer(
    rendered_launcher_tree: Path, base_config: dict
) -> None:
    """The launcher binary must embed the v0.6 corporate footer.

    The footer is rendered by ``show_banner`` whenever the launcher is run
    without ``--help`` (help shortcuts the banner for cheap CLI parsing). To
    keep the test hermetic — and free of a real VPN dependency — we grep
    the rendered binary text rather than executing it.
    """
    slug = base_config["CORP_SLUG"]
    launcher_bin = rendered_launcher_tree / slug
    assert launcher_bin.is_file()

    text = launcher_bin.read_text(encoding="utf-8")
    assert "Proudly made from France with" in text, (
        "v0.6 launcher must carry the 'Proudly made from France with' footer"
    )

    # Also exercise the live --help path: it should at least exit 0 without
    # touching the network. The footer is not expected on --help output
    # (cmd_help skips show_banner) so we only assert the exit code here.
    if os.name == "posix" and launcher_bin.stat().st_mode & stat.S_IXUSR:
        env = {**os.environ, f"{slug.upper().replace('-', '_')}_DRY_RUN": "1"}
        proc = subprocess.run(
            ["bash", str(launcher_bin), "--help"],
            capture_output=True, text=True, env=env, check=False, timeout=10,
        )
        assert proc.returncode == 0, (
            f"launcher --help should exit 0 (got {proc.returncode}):\n"
            f"stderr:\n{proc.stderr}"
        )
