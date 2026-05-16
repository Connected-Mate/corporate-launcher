"""Tests for ``scripts/skills-installer.py`` — the Corporate Launcher
skill bundling logic.

The installer reads a ``skills.json`` config and:
  * resolves preset / pick entries against ``templates/shared/skills-presets.json``
  * clones each entry with ``git`` (mocked here — no network)
  * clones an optional custom ``git_url`` into ``<target>/internal-skills/``
  * copies an optional ``local_path`` into ``<target>/local-skills/``
  * symlinks every produced directory into ``~/.claude/skills/``

All ``subprocess.run`` calls are monkeypatched so the suite is hermetic.
We redirect ``CLAUDE_SKILLS_DIR`` to a tmp dir to avoid touching the
real user home.

Limitations:
  * Symlink behaviour on Windows is not exercised — these tests rely on
    POSIX ``os.symlink`` semantics. The installer already has a copy
    fallback for Windows, but exercising it would require platform-
    specific monkeypatching that we skip here.
  * ``rsync`` is forced off in the local-copy test so the assertion is
    deterministic across machines.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable
from unittest.mock import MagicMock

import pytest


# --------------------------------------------------------------------------- #
# Module loader — skills-installer.py is a script with a hyphenated name.     #
# --------------------------------------------------------------------------- #

REPO_ROOT = Path(__file__).resolve().parent.parent
INSTALLER_PATH = REPO_ROOT / "scripts" / "skills-installer.py"


def _load_installer() -> Any:
    """Import ``scripts/skills-installer.py`` as a module."""
    if not INSTALLER_PATH.exists():
        pytest.skip(f"installer not present: {INSTALLER_PATH}")
    spec = importlib.util.spec_from_file_location(
        "skills_installer", INSTALLER_PATH,
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["skills_installer"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def installer() -> Any:
    return _load_installer()


# --------------------------------------------------------------------------- #
# Helpers                                                                     #
# --------------------------------------------------------------------------- #


def _write_config(path: Path, **fields: Any) -> Path:
    """Materialise a minimal skills.json with the given overrides."""
    config: dict[str, Any] = {
        "mode": "none",
        "presets": [],
        "pick": [],
        "git_url": None,
        "git_ref": "main",
        "local_path": None,
    }
    config.update(fields)
    path.write_text(json.dumps(config), encoding="utf-8")
    return path


def _fake_git_factory(
    calls: list[list[str]],
    *,
    create_dirs: bool = True,
    make_subdirs: dict[str, list[str]] | None = None,
) -> Callable[..., subprocess.CompletedProcess[str]]:
    """Build a fake ``subprocess.run`` that records calls.

    If ``create_dirs`` is True, ``git clone ... DEST`` invocations will
    materialise ``DEST/`` so the installer's post-clone checks succeed.
    ``make_subdirs`` lets a test pre-populate a fake monorepo layout
    (mapping ``dest_basename`` -> list of subdir names to create with
    a ``SKILL.md`` inside).
    """
    make_subdirs = make_subdirs or {}

    def fake_run(
        cmd: list[str],
        *_args: Any,
        **_kwargs: Any,
    ) -> subprocess.CompletedProcess[str]:
        calls.append(list(cmd))
        if create_dirs and len(cmd) >= 2 and cmd[0] == "git" and cmd[1] == "clone":
            dest = Path(cmd[-1])
            dest.mkdir(parents=True, exist_ok=True)
            (dest / "SKILL.md").write_text("# fake\n", encoding="utf-8")
            for sub in make_subdirs.get(dest.name, []):
                (dest / sub).mkdir(parents=True, exist_ok=True)
                (dest / sub / "SKILL.md").write_text("# fake\n", encoding="utf-8")
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    return fake_run


@pytest.fixture()
def fake_claude_home(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
) -> Path:
    """Redirect the installer's ~/.claude/skills to a tmp dir."""
    home = tmp_path / "claude-home" / "skills"
    monkeypatch.setattr(installer, "CLAUDE_SKILLS_DIR", home)
    return home


# --------------------------------------------------------------------------- #
# Tests                                                                       #
# --------------------------------------------------------------------------- #


def test_mode_none_creates_nothing(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """mode=none -> exits 0, no clone, no files under target."""
    cfg = _write_config(tmp_path / "skills.json", mode="none")
    target = tmp_path / "target"

    calls: list[list[str]] = []
    monkeypatch.setattr(subprocess, "run", _fake_git_factory(calls))

    rc = installer.main(["--config", str(cfg), "--target", str(target)])

    assert rc == 0
    assert calls == [], "no subprocess should fire in mode=none"
    assert not target.exists() or not any(target.iterdir())
    assert not fake_claude_home.exists() or not any(fake_claude_home.iterdir())
    out = capsys.readouterr().out
    assert "Installed 0 skills" in out


def test_mode_preset_design_pack_clones_each_skill(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """mode=preset / design-pack -> one clone per skill, all materialised."""
    cfg = _write_config(
        tmp_path / "skills.json",
        mode="preset",
        presets=["design-pack"],
    )
    target = tmp_path / "target"

    calls: list[list[str]] = []
    # design-pack uses subdir="<name>/" on a monorepo, so the installer
    # clones into a scratch dir then moves the subdir into place.
    skill_names = [
        "polish", "audit", "critique", "distill", "clarify", "typeset",
        "layout", "animate", "colorize", "bolder", "quieter", "harden",
        "optimize", "delight", "adapt",
    ]
    monkeypatch.setattr(
        subprocess, "run",
        _fake_git_factory(
            calls,
            make_subdirs={f".scratch-{n}": [n] for n in skill_names},
        ),
    )

    rc = installer.main(["--config", str(cfg), "--target", str(target)])

    assert rc == 0
    # One git clone per skill in the preset
    clones = [c for c in calls if c[:2] == ["git", "clone"]]
    assert len(clones) == len(skill_names)
    for clone in clones:
        assert "--depth" in clone and "1" in clone
        assert "--branch" in clone and "main" in clone
        assert clone[-2] == "https://github.com/Connected-Mate/corporate-skills-design"

    # Final layout: <target>/<skill>/SKILL.md present
    for name in skill_names:
        assert (target / name / "SKILL.md").exists(), f"missing {name}"

    # Each is symlinked (or copied) into the fake claude home
    for name in skill_names:
        assert (fake_claude_home / name).exists()


def test_mode_git_custom_url_clones_to_internal_skills(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """mode=git + git_url -> single ``git clone --depth 1 --branch main URL DEST``
    into ``<target>/internal-skills/``."""
    url = "https://example.test/internal-skills.git"
    cfg = _write_config(
        tmp_path / "skills.json",
        mode="git",
        git_url=url,
        git_ref="main",
    )
    target = tmp_path / "target"
    calls: list[list[str]] = []
    monkeypatch.setattr(subprocess, "run", _fake_git_factory(calls))

    rc = installer.main(["--config", str(cfg), "--target", str(target)])

    assert rc == 0
    clones = [c for c in calls if c[:2] == ["git", "clone"]]
    assert len(clones) == 1
    clone = clones[0]
    assert clone[:6] == ["git", "clone", "--depth", "1", "--branch", "main"]
    assert clone[6] == url
    assert Path(clone[7]) == target / "internal-skills"

    internal = target / "internal-skills"
    assert internal.is_dir()
    assert (fake_claude_home / "internal-skills").exists()


def test_mode_local_copies_recursively_no_network(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """mode=local -> recursive copy, no git invocation."""
    src = tmp_path / "src-skills"
    (src / "alpha").mkdir(parents=True)
    (src / "alpha" / "SKILL.md").write_text("# alpha\n", encoding="utf-8")
    (src / "alpha" / "nested" / "deep").mkdir(parents=True)
    (src / "alpha" / "nested" / "deep" / "file.txt").write_text(
        "payload", encoding="utf-8",
    )

    cfg = _write_config(
        tmp_path / "skills.json",
        mode="local",
        local_path=str(src),
    )
    target = tmp_path / "target"

    calls: list[list[str]] = []
    monkeypatch.setattr(subprocess, "run", _fake_git_factory(calls))
    # Force the shutil.copytree path so behaviour is deterministic.
    monkeypatch.setattr(installer.shutil, "which", lambda _name: None)

    rc = installer.main(["--config", str(cfg), "--target", str(target)])

    assert rc == 0
    assert not any(c[:2] == ["git", "clone"] for c in calls), \
        "local mode must not invoke git clone"

    dest = target / "local-skills"
    assert dest.is_dir()
    assert (dest / "alpha" / "SKILL.md").exists()
    assert (dest / "alpha" / "nested" / "deep" / "file.txt").read_text() == "payload"
    # The discovered subdir is what's symlinked into claude home.
    assert (fake_claude_home / "alpha").exists()


def test_mode_combined_runs_preset_and_git(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """mode=combined with both presets and git_url -> both pipelines fire."""
    url = "https://example.test/internal-skills.git"
    cfg = _write_config(
        tmp_path / "skills.json",
        mode="combined",
        presets=["data-pack"],
        git_url=url,
    )
    target = tmp_path / "target"

    calls: list[list[str]] = []
    data_pack_names = ["sql-review", "dbt-lint", "dataframe-explorer"]
    monkeypatch.setattr(
        subprocess, "run",
        _fake_git_factory(
            calls,
            make_subdirs={f".scratch-{n}": [n] for n in data_pack_names},
        ),
    )

    rc = installer.main(["--config", str(cfg), "--target", str(target)])

    assert rc == 0
    clones = [c for c in calls if c[:2] == ["git", "clone"]]
    # 3 preset skills + 1 custom monorepo
    assert len(clones) == len(data_pack_names) + 1
    cloned_urls = {c[-2] for c in clones}
    assert url in cloned_urls
    assert (target / "internal-skills").is_dir()
    for name in data_pack_names:
        assert (target / name / "SKILL.md").exists()


def test_unknown_preset_is_warned_and_skipped(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """Unknown preset name -> logged warning, zero clones, exit 0.

    Note: the current installer treats unknown presets as a soft warning
    rather than a hard error. This test pins that contract.
    """
    cfg = _write_config(
        tmp_path / "skills.json",
        mode="preset",
        presets=["does-not-exist"],
    )
    target = tmp_path / "target"
    calls: list[list[str]] = []
    monkeypatch.setattr(subprocess, "run", _fake_git_factory(calls))

    rc = installer.main(["--config", str(cfg), "--target", str(target)])

    assert rc == 0
    assert not [c for c in calls if c[:2] == ["git", "clone"]]
    err = capsys.readouterr().err
    assert "unknown preset" in err
    assert "does-not-exist" in err


def test_mode_git_without_git_url_is_a_noop(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """mode=git with no git_url -> no clones, exit 0.

    The installer does not raise on a missing URL — it simply has nothing
    to do. This test pins that behaviour so a regression to "silently
    install something else" would be caught.
    """
    cfg = _write_config(tmp_path / "skills.json", mode="git", git_url=None)
    target = tmp_path / "target"
    calls: list[list[str]] = []
    monkeypatch.setattr(subprocess, "run", _fake_git_factory(calls))

    rc = installer.main(["--config", str(cfg), "--target", str(target)])

    assert rc == 0
    assert not [c for c in calls if c[:2] == ["git", "clone"]]


def test_update_flag_pulls_existing_clone_without_duplicating(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """--update on an already-cloned skill -> ``git pull --ff-only`` instead
    of a second clone; directory is not duplicated."""
    url = "https://example.test/internal-skills.git"
    cfg = _write_config(tmp_path / "skills.json", mode="git", git_url=url)
    target = tmp_path / "target"

    # First run: normal clone.
    first_calls: list[list[str]] = []
    monkeypatch.setattr(subprocess, "run", _fake_git_factory(first_calls))
    rc = installer.main(["--config", str(cfg), "--target", str(target)])
    assert rc == 0
    assert any(c[:2] == ["git", "clone"] for c in first_calls)
    snapshot = sorted(p.name for p in target.iterdir())

    # Second run with --update: should issue git pull, not re-clone.
    second_calls: list[list[str]] = []
    monkeypatch.setattr(subprocess, "run", _fake_git_factory(second_calls))
    rc = installer.main(
        ["--config", str(cfg), "--target", str(target), "--update"],
    )
    assert rc == 0
    pulls = [c for c in second_calls if c[:2] == ["git", "pull"]]
    clones = [c for c in second_calls if c[:2] == ["git", "clone"]]
    assert len(pulls) == 1
    assert pulls[0] == ["git", "pull", "--ff-only"]
    assert clones == [], "update must not re-clone an existing destination"
    # Directory layout is unchanged: no duplicate `internal-skills-1` etc.
    assert sorted(p.name for p in target.iterdir()) == snapshot


def test_update_without_existing_clone_still_clones(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """--update on a fresh target -> still performs the initial clone."""
    url = "https://example.test/internal-skills.git"
    cfg = _write_config(tmp_path / "skills.json", mode="git", git_url=url)
    target = tmp_path / "target"
    calls: list[list[str]] = []
    monkeypatch.setattr(subprocess, "run", _fake_git_factory(calls))

    rc = installer.main(
        ["--config", str(cfg), "--target", str(target), "--update"],
    )
    assert rc == 0
    clones = [c for c in calls if c[:2] == ["git", "clone"]]
    assert len(clones) == 1


def test_dry_run_skips_all_filesystem_mutations(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """--dry-run -> no git invocation, no target directory created."""
    cfg = _write_config(
        tmp_path / "skills.json",
        mode="git",
        git_url="https://example.test/internal-skills.git",
    )
    target = tmp_path / "target"
    sentinel = MagicMock(
        return_value=subprocess.CompletedProcess([], 0, "", ""),
    )
    monkeypatch.setattr(subprocess, "run", sentinel)

    rc = installer.main(
        ["--config", str(cfg), "--target", str(target), "--dry-run"],
    )
    assert rc == 0
    sentinel.assert_not_called()
    # The target root may be ``mkdir``-ed eagerly, but no clone should land.
    assert not (target / "internal-skills").exists()
    assert not fake_claude_home.exists() or not any(fake_claude_home.iterdir())


def test_bad_config_returns_exit_code_2(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    installer: Any,
    fake_claude_home: Path,
) -> None:
    """A malformed JSON config -> exit code 2, no clones."""
    cfg = tmp_path / "skills.json"
    cfg.write_text("{not-json", encoding="utf-8")
    target = tmp_path / "target"
    calls: list[list[str]] = []
    monkeypatch.setattr(subprocess, "run", _fake_git_factory(calls))

    rc = installer.main(["--config", str(cfg), "--target", str(target)])

    assert rc == 2
    assert calls == []
