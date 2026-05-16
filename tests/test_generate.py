"""Tests for scripts/generate.py — the corporate-launcher orchestrator.

The orchestrator is expected to expose the CLI::

    python3 generate.py --config dog.json --out PATH [--dry-run]

It must, given a validated DOG JSON config:
  1. Resolve the wrapped CLIs and copy/render the right template trees.
  2. Run optional sub-installers (skills, mcp) via subprocess.
  3. Produce the chosen distribution artefacts under ``<out>/dist/``.

These tests pin the behaviour described in ``reference/interview-flow.md``
section *Validation rules* and ``reference/distribution-modes.md``.

All subprocess calls are monkeypatched — no network, no real ``gh``/``git``.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Any, Callable

import pytest

# --------------------------------------------------------------------------- #
# Module loader — generate.py is a script, not a package member.              #
# --------------------------------------------------------------------------- #

REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATE_PATH = REPO_ROOT / "scripts" / "generate.py"


def _load_generate() -> Any:
    """Import scripts/generate.py as a module; skip the whole suite if absent."""
    if not GENERATE_PATH.exists():
        pytest.skip(
            f"generate.py not yet implemented at {GENERATE_PATH}", allow_module_level=False
        )
    spec = importlib.util.spec_from_file_location("generate", GENERATE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["generate"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def generate() -> Any:
    return _load_generate()


# --------------------------------------------------------------------------- #
# Config fixtures                                                              #
# --------------------------------------------------------------------------- #


def _minimal_config(**overrides: Any) -> dict[str, Any]:
    """Smallest DOG payload that should pass validation for a claude-code wrap."""
    base: dict[str, Any] = {
        "CORP_NAME": "Acme Copilot",
        "CORP_SLUG": "acme-copilot",
        "CORP_POWERED_BY": "Acme AI Lab",
        "CORP_ORGANIZATION": "Acme Group",
        "CORP_TAGLINE": "Internal AI assistant",
        "CORP_LICENSE_NOTE": "Internal use only",
        "WRAPPED_CLIS": ["claude-code"],
        "CC_BACKEND": "Anthropic",
        "CC_PRIMARY_URL": "https://api.acme.example",
        "CC_FALLBACK_URL": "",
        "CC_PRIMARY_MODEL": "claude-sonnet-4-6",
        "CC_HAIKU_MODEL": "claude-haiku-4-5",
        "CC_AUTH_MODEL": "Bearer",
        "CC_NEEDS_STRIP_PROXY": "no",
        "VPN_REQUIRED": "yes",
        "VPN_PROBE_URL": "https://api.acme.example",
        "PROXY_HOST": "",
        "PROXY_PORT": 8080,
        "PROXY_REQUIRE_AUTH": "no",
        "NO_PROXY_LIST": "127.0.0.1,localhost",
        "CA_BUNDLE_PATH": "",
        "CA_DETECT_AUTO": "yes",
        "ACCEPT_TLS_INSPECTION": "no",
        "CYBER_RULES_FILE": "shared/cyber-rules.md",
        "CYBER_AUTHORITY": "Acme CISO",
        "BLOCK_TELEMETRY": "yes",
        "BLOCK_AUTO_UPDATE": "yes",
        "BLOCK_FEEDBACK_CMDS": "yes",
        "BLOCK_VOICE_MODE": "yes",
        "COST_TRACKING_ENABLED": "yes",
        "COST_CURRENCY": "EUR",
        "PROMPT_FILTER_ENABLED": "yes",
        "BRANDING_SYSTEM_PROMPT": "You are Acme Copilot.",
        "BANNER_COLOR_PRIMARY": "208",
        "TERMINAL_TITLE": "Acme Copilot",
        "LANGUAGE": "en",
        "FORBIDDEN_TERMS": "Claude,Anthropic",
        "INSTALL_DIR": "~/.local/share/acme-copilot",
        "BIN_PATH": "~/.local/bin",
        "SHELL_RC": "auto",
        "LICENSE_TYPE": "Internal-only",
        "INCLUDE_UNINSTALL": "yes",
        "SKILLS_MODE": "none",
        "SKILLS_PRESETS": [],
        "SKILLS_PICK": [],
        "SKILLS_GIT_URL": "",
        "SKILLS_GIT_REF": "main",
        "SKILLS_LOCAL_PATH": "",
        "MCP_SERVERS": [],
        "DIST_MODE": "none",
        "DIST_REPO_HOST": "github",
        "DIST_REPO_URL": "",
        "DIST_REPO_VISIBILITY": "private",
        "DIST_REGISTRY_URL": "",
        "DIST_ONELINER_HOST": "",
        "DIST_SIGN_RELEASE": False,
        "DIST_GPG_KEY_ID": "",
    }
    base.update(overrides)
    return base


def _write_config(tmp_path: Path, **overrides: Any) -> Path:
    cfg = tmp_path / "dog.json"
    cfg.write_text(json.dumps(_minimal_config(**overrides), indent=2), encoding="utf-8")
    return cfg


# --------------------------------------------------------------------------- #
# Subprocess capture helper                                                    #
# --------------------------------------------------------------------------- #


class SubprocessRecorder:
    """Replacement for subprocess.run / check_call — records, never runs."""

    def __init__(self) -> None:
        self.calls: list[list[str]] = []

    def __call__(self, cmd: Any, *args: Any, **kwargs: Any) -> subprocess.CompletedProcess:
        argv = list(cmd) if isinstance(cmd, (list, tuple)) else [str(cmd)]
        self.calls.append([str(a) for a in argv])
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    def saw(self, needle: str) -> bool:
        return any(any(needle in part for part in call) for call in self.calls)


@pytest.fixture()
def recorder(monkeypatch: pytest.MonkeyPatch) -> SubprocessRecorder:
    rec = SubprocessRecorder()
    monkeypatch.setattr(subprocess, "run", rec)
    monkeypatch.setattr(subprocess, "check_call", rec)
    monkeypatch.setattr(subprocess, "check_output", rec)
    return rec


# --------------------------------------------------------------------------- #
# Test 1 — dry-run on a minimal config                                         #
# --------------------------------------------------------------------------- #


def test_dry_run_lists_files_without_writing(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    generate: Any,
) -> None:
    """--dry-run prints the planned files; nothing lands on disk."""
    cfg = _write_config(tmp_path)
    out = tmp_path / "build"

    rc = generate.main(["--config", str(cfg), "--out", str(out), "--dry-run"])

    assert rc == 0
    assert not out.exists() or not any(out.rglob("*")), "dry-run must not write files"

    captured = capsys.readouterr().out
    # The plan must mention the launcher binary, install.sh and settings.json.
    for expected in ("acme-copilot", "install.sh", "settings.json"):
        assert expected in captured, f"dry-run plan missing {expected!r}"


# --------------------------------------------------------------------------- #
# Test 2 — end-to-end on claude-code only                                      #
# --------------------------------------------------------------------------- #


def test_end_to_end_claude_code(
    tmp_path: Path,
    recorder: SubprocessRecorder,
    generate: Any,
) -> None:
    """Real render of a claude-code wrap produces the expected artefacts."""
    cfg = _write_config(tmp_path)
    out = tmp_path / "build"

    rc = generate.main(["--config", str(cfg), "--out", str(out)])

    assert rc == 0, "generation must succeed on a valid minimal config"

    launcher = out / "acme-copilot"
    install = out / "install.sh"
    settings = out / "settings.json"

    assert launcher.exists(), f"launcher binary missing at {launcher}"
    assert install.exists(), f"install.sh missing at {install}"
    assert settings.exists(), f"settings.json missing at {settings}"

    # settings.json must be valid JSON and rebranded.
    parsed = json.loads(settings.read_text(encoding="utf-8"))
    assert isinstance(parsed, dict)
    assert "Acme Copilot" in settings.read_text(encoding="utf-8")


# --------------------------------------------------------------------------- #
# Test 3 — validation                                                          #
# --------------------------------------------------------------------------- #


def test_validation_rejects_missing_corp_name(tmp_path: Path, generate: Any) -> None:
    cfg_data = _minimal_config()
    cfg_data.pop("CORP_NAME")
    cfg = tmp_path / "dog.json"
    cfg.write_text(json.dumps(cfg_data), encoding="utf-8")

    rc = generate.main(["--config", str(cfg), "--out", str(tmp_path / "out")])
    assert rc != 0, "missing CORP_NAME must be rejected"


def test_validation_rejects_bad_slug(tmp_path: Path, generate: Any) -> None:
    cfg = _write_config(tmp_path, CORP_SLUG="NOT_a_valid_Slug!")
    rc = generate.main(["--config", str(cfg), "--out", str(tmp_path / "out")])
    assert rc != 0, "uppercase / non-conforming slug must be rejected"


def test_litellm_forces_strip_proxy(tmp_path: Path, generate: Any) -> None:
    """Rule #6: CC_BACKEND=LiteLLM with CC_NEEDS_STRIP_PROXY=no → autocorrect or error."""
    cfg = _write_config(tmp_path, CC_BACKEND="LiteLLM", CC_NEEDS_STRIP_PROXY="no")
    out = tmp_path / "build"
    rc = generate.main(["--config", str(cfg), "--out", str(out)])

    if rc == 0:
        # Auto-correction path: the final settings/launcher must reflect strip-proxy=yes.
        # Either a derived config file is dumped or the launcher embeds the strip-proxy module.
        evidence_files: list[Path] = []
        if out.exists():
            evidence_files = [p for p in out.rglob("*") if p.is_file()]
        blob = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in evidence_files)
        assert "strip-proxy" in blob or "STRIP_PROXY" in blob, (
            "LiteLLM backend must enable strip-proxy when generation succeeds"
        )
    else:
        # Strict-rejection path is also acceptable.
        assert rc != 0


# --------------------------------------------------------------------------- #
# Test 4 — skills-installer dispatch                                           #
# --------------------------------------------------------------------------- #


def test_skills_preset_invokes_installer(
    tmp_path: Path,
    recorder: SubprocessRecorder,
    generate: Any,
) -> None:
    cfg = _write_config(
        tmp_path,
        SKILLS_MODE="preset",
        SKILLS_PRESETS=["design-pack"],
    )
    out = tmp_path / "build"

    rc = generate.main(["--config", str(cfg), "--out", str(out)])
    assert rc == 0

    assert recorder.saw("skills-installer"), (
        f"skills-installer.py was not invoked; calls={recorder.calls!r}"
    )


# --------------------------------------------------------------------------- #
# Test 5 — mcp-installer dispatch                                              #
# --------------------------------------------------------------------------- #


def test_mcp_servers_invokes_installer(
    tmp_path: Path,
    recorder: SubprocessRecorder,
    generate: Any,
) -> None:
    cfg = _write_config(
        tmp_path,
        MCP_SERVERS=[
            {
                "name": "jira",
                "url": "https://mcp.acme.example/jira",
                "headers": {"Authorization": "Bearer ${env:MCP_TOKEN}"},
            }
        ],
    )
    out = tmp_path / "build"

    rc = generate.main(["--config", str(cfg), "--out", str(out)])
    assert rc == 0

    assert recorder.saw("mcp-installer") or recorder.saw("mcp-injector"), (
        f"mcp-installer.py was not invoked; calls={recorder.calls!r}"
    )


# --------------------------------------------------------------------------- #
# Test 6 — DIST_MODE=tarball                                                   #
# --------------------------------------------------------------------------- #


def test_dist_tarball_emits_archive_and_checksum(
    tmp_path: Path,
    recorder: SubprocessRecorder,
    generate: Any,
) -> None:
    cfg = _write_config(
        tmp_path,
        DIST_MODE="tarball",
        DIST_REGISTRY_URL="https://nexus.acme.example/repository/raw/",
    )
    out = tmp_path / "build"

    rc = generate.main(["--config", str(cfg), "--out", str(out)])
    assert rc == 0

    dist = out / "dist"
    assert dist.exists(), "tarball mode must create <out>/dist/"

    tarballs = list(dist.glob("*.tar.gz"))
    assert tarballs, f"no .tar.gz produced under {dist}"

    sums = dist / "SHA256SUMS"
    assert sums.exists(), "SHA256SUMS companion file missing"

    # Sanity: the tarball should be a real gzip archive.
    with tarfile.open(tarballs[0], "r:gz") as tf:
        names = tf.getnames()
    assert names, "tarball is empty"


# --------------------------------------------------------------------------- #
# Test 7 — DIST_MODE=public-git refuses .internal URLs                         #
# --------------------------------------------------------------------------- #


def test_public_git_refuses_internal_hostname(
    tmp_path: Path,
    recorder: SubprocessRecorder,
    generate: Any,
) -> None:
    cfg = _write_config(
        tmp_path,
        CC_PRIMARY_URL="https://socle.ia.acme.internal",
        DIST_MODE="public-git",
        DIST_REPO_URL="https://github.com/acme/copilot",
        DIST_REPO_VISIBILITY="public",
    )
    out = tmp_path / "build"

    rc = generate.main(["--config", str(cfg), "--out", str(out)])
    assert rc != 0, "public-git with .internal gateway must be refused (rule #7)"
    assert not recorder.saw("gh repo create"), "no public repo must be created on refusal"


def test_public_git_force_override(
    tmp_path: Path,
    recorder: SubprocessRecorder,
    generate: Any,
) -> None:
    """DIST_PUBLIC_FORCE=yes bypasses the .internal guard (escape hatch)."""
    cfg = _write_config(
        tmp_path,
        CC_PRIMARY_URL="https://socle.ia.acme.internal",
        DIST_MODE="public-git",
        DIST_REPO_URL="https://github.com/acme/copilot",
        DIST_REPO_VISIBILITY="public",
        DIST_PUBLIC_FORCE="yes",
    )
    out = tmp_path / "build"

    rc = generate.main(["--config", str(cfg), "--out", str(out)])
    assert rc == 0, "explicit override must allow public-git"
