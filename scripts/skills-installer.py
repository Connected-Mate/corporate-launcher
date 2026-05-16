#!/usr/bin/env python3
"""Skills installer for Corporate Launcher.

Reads a JSON config describing which skills to install (presets, picks,
custom git repo, or local folder), fetches them, and links each into
`~/.claude/skills/` so the colleague's Claude Code picks them up.

Usage:
    skills-installer.py --config skills.json \\
        --target ~/.local/share/${CORP_SLUG}/skills

    skills-installer.py --config skills.json --target <dir> --update
    skills-installer.py --config skills.json --target <dir> --dry-run

Config schema (skills.json):
    {
      "mode": "combined",          # none | preset | pick | git | local | combined
      "presets": ["design-pack"],  # preset names (resolved via skills-presets.json)
      "pick": ["polish", "audit"], # individual skill names from any preset
      "git_url": "https://...",    # custom skills monorepo (optional)
      "git_ref": "main",           # branch / tag / commit
      "local_path": null           # absolute path to a skills folder (optional)
    }

The installer is stdlib-only (Python 3.10+) and handles network failures
gracefully — a single skill failing does not abort the whole batch.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

# Path resolution: presets file lives next to this script, in ../templates/shared/
SCRIPT_DIR = Path(__file__).resolve().parent
PRESETS_PATH = SCRIPT_DIR.parent / "templates" / "shared" / "skills-presets.json"
CLAUDE_SKILLS_DIR = Path.home() / ".claude" / "skills"


class InstallError(RuntimeError):
    """Recoverable failure for a single skill — logged, not fatal."""


def log(msg: str) -> None:
    """Stderr logger so stdout stays reserved for the final summary."""
    print(msg, file=sys.stderr)


def run_git(args: list[str], cwd: Path | None = None, dry_run: bool = False) -> None:
    """Run a git command, raising InstallError on failure."""
    cmd = ["git", *args]
    if dry_run:
        log(f"[dry-run] {' '.join(cmd)}" + (f"  (cwd={cwd})" if cwd else ""))
        return
    try:
        subprocess.run(
            cmd,
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
            timeout=300,
        )
    except FileNotFoundError as exc:
        raise InstallError("git is not installed or not on PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise InstallError(f"git timed out: {' '.join(cmd)}") from exc
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        raise InstallError(f"git failed ({' '.join(cmd)}): {stderr}") from exc


def load_config(path: Path) -> dict[str, Any]:
    """Load and normalise the skills config."""
    raw = json.loads(path.read_text(encoding="utf-8"))
    return {
        "mode": raw.get("mode", "none"),
        "presets": list(raw.get("presets") or []),
        "pick": list(raw.get("pick") or []),
        "git_url": raw.get("git_url"),
        "git_ref": raw.get("git_ref") or "main",
        "local_path": raw.get("local_path"),
    }


def load_presets() -> dict[str, Any]:
    """Load the curated preset catalogue."""
    if not PRESETS_PATH.exists():
        log(f"warning: presets file not found at {PRESETS_PATH}")
        return {}
    return json.loads(PRESETS_PATH.read_text(encoding="utf-8"))


def install_skill_from_git(
    skill: dict[str, Any],
    target: Path,
    update: bool,
    dry_run: bool,
) -> Path:
    """Clone (or update) a single skill from a git source.

    The preset entry shape is:
        {"name": "polish",
         "source": "https://...",
         "subdir": "polish/",
         "ref": "main"}

    We clone the whole repo once per skill into `<target>/<name>/` and rely
    on the colleague's Claude Code to discover SKILL.md inside. If `subdir`
    is set and differs from the skill name, we clone into a scratch dir and
    move the subfolder into place.
    """
    name = skill["name"]
    source = skill["source"]
    ref = skill.get("ref", "main")
    subdir = (skill.get("subdir") or "").strip("/")

    dest = target / name

    if dest.exists():
        if update:
            log(f"updating {name} (git pull)")
            try:
                run_git(["pull", "--ff-only"], cwd=dest, dry_run=dry_run)
            except InstallError as exc:
                log(f"  ! pull failed for {name}: {exc} — leaving as-is")
            return dest
        log(f"  = {name} already present, skipping (use --update to refresh)")
        return dest

    target.mkdir(parents=True, exist_ok=True)

    if not subdir or subdir == name:
        # Whole repo == the skill: clone straight into <dest>
        run_git(
            ["clone", "--depth", "1", "--branch", ref, source, str(dest)],
            dry_run=dry_run,
        )
        return dest

    # Monorepo: clone into a scratch dir, then move the subdir into place
    scratch = target / f".scratch-{name}"
    if scratch.exists() and not dry_run:
        shutil.rmtree(scratch)
    try:
        run_git(
            ["clone", "--depth", "1", "--branch", ref, source, str(scratch)],
            dry_run=dry_run,
        )
        if dry_run:
            log(f"[dry-run] would move {scratch / subdir} -> {dest}")
            return dest
        src_subdir = scratch / subdir
        if not src_subdir.is_dir():
            raise InstallError(
                f"subdir {subdir!r} not found in {source}@{ref}"
            )
        shutil.move(str(src_subdir), str(dest))
    finally:
        if scratch.exists() and not dry_run:
            shutil.rmtree(scratch, ignore_errors=True)
    return dest


def install_from_git_url(
    git_url: str,
    git_ref: str,
    target: Path,
    update: bool,
    dry_run: bool,
) -> list[Path]:
    """Clone an entire custom skills monorepo into `<target>/internal-skills/`.

    Returns one entry per top-level skill folder discovered inside the repo
    (any directory containing a SKILL.md). If discovery fails we just return
    the repo root.
    """
    dest = target / "internal-skills"
    if dest.exists():
        if update:
            log(f"updating internal-skills (git pull)")
            try:
                run_git(["pull", "--ff-only"], cwd=dest, dry_run=dry_run)
            except InstallError as exc:
                log(f"  ! pull failed: {exc} — leaving as-is")
        else:
            log("  = internal-skills already present, skipping")
    else:
        target.mkdir(parents=True, exist_ok=True)
        run_git(
            ["clone", "--depth", "1", "--branch", git_ref, git_url, str(dest)],
            dry_run=dry_run,
        )

    if dry_run or not dest.exists():
        return [dest]

    # Discover skill subfolders (those that contain a SKILL.md)
    discovered: list[Path] = []
    for child in sorted(dest.iterdir()):
        if child.is_dir() and (child / "SKILL.md").exists():
            discovered.append(child)
    return discovered or [dest]


def install_from_local(
    local_path: Path,
    target: Path,
    dry_run: bool,
) -> list[Path]:
    """Copy a local folder tree into `<target>/local-skills/`.

    Uses rsync if available (preserves attrs, faster on re-runs), otherwise
    falls back to shutil.copytree.
    """
    src = local_path.expanduser().resolve()
    if not src.is_dir():
        raise InstallError(f"local path is not a directory: {src}")

    dest = target / "local-skills"
    target.mkdir(parents=True, exist_ok=True)

    rsync = shutil.which("rsync")
    if dry_run:
        tool = "rsync -a --delete" if rsync else "shutil.copytree"
        log(f"[dry-run] copy {src}/ -> {dest}/ via {tool}")
        return [dest]

    if rsync:
        try:
            subprocess.run(
                [rsync, "-a", "--delete", f"{src}/", f"{dest}/"],
                check=True,
                capture_output=True,
                text=True,
                timeout=300,
            )
        except subprocess.CalledProcessError as exc:
            raise InstallError(
                f"rsync failed: {(exc.stderr or '').strip()}"
            ) from exc
    else:
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(src, dest, symlinks=False)

    # Discover skill subfolders for symlinking
    discovered: list[Path] = []
    for child in sorted(dest.iterdir()):
        if child.is_dir() and (child / "SKILL.md").exists():
            discovered.append(child)
    return discovered or [dest]


def link_into_claude(skill_dir: Path, dry_run: bool) -> None:
    """Symlink (or copy on Windows / cross-FS failure) skill_dir into
    `~/.claude/skills/<name>/`."""
    if dry_run:
        log(f"[dry-run] link {skill_dir} -> {CLAUDE_SKILLS_DIR / skill_dir.name}")
        return
    CLAUDE_SKILLS_DIR.mkdir(parents=True, exist_ok=True)
    link_path = CLAUDE_SKILLS_DIR / skill_dir.name

    # Replace existing link/dir to keep the install idempotent
    if link_path.is_symlink() or link_path.exists():
        if link_path.is_symlink() or link_path.is_file():
            link_path.unlink()
        else:
            shutil.rmtree(link_path)

    try:
        os.symlink(skill_dir, link_path, target_is_directory=True)
    except (OSError, NotImplementedError) as exc:
        log(f"  ! symlink failed for {skill_dir.name} ({exc}); copying instead")
        shutil.copytree(skill_dir, link_path, symlinks=False)


def resolve_skills(
    config: dict[str, Any],
    presets: dict[str, Any],
) -> list[dict[str, Any]]:
    """Build the flat list of skill entries to install from presets + pick.

    Preserves order, deduplicates by skill name (first wins).
    """
    selected: list[dict[str, Any]] = []
    seen: set[str] = set()

    for preset_name in config["presets"]:
        preset = presets.get(preset_name)
        if not preset:
            log(f"warning: unknown preset {preset_name!r} — skipping")
            continue
        for skill in preset.get("skills", []):
            if skill["name"] not in seen:
                selected.append(skill)
                seen.add(skill["name"])

    if config["pick"]:
        wanted = set(config["pick"])
        catalogue: dict[str, dict[str, Any]] = {}
        for preset in presets.values():
            for skill in preset.get("skills", []):
                catalogue.setdefault(skill["name"], skill)
        for name in config["pick"]:
            if name in seen:
                continue
            skill = catalogue.get(name)
            if not skill:
                log(f"warning: pick {name!r} not found in any preset — skipping")
                continue
            selected.append(skill)
            seen.add(name)
        # Warn for any pick that matched nothing at all
        for name in wanted - {s["name"] for s in selected}:
            if name not in catalogue:
                continue  # already warned above

    return selected


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--config", required=True, type=Path,
        help="Path to skills.json",
    )
    parser.add_argument(
        "--target", required=True, type=Path,
        help="Install root (e.g. ~/.local/share/<slug>/skills)",
    )
    parser.add_argument(
        "--update", action="store_true",
        help="Pull/re-fetch existing skill clones",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print actions without touching the filesystem",
    )
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
    except (OSError, json.JSONDecodeError) as exc:
        log(f"ERROR: could not read config {args.config}: {exc}")
        return 2

    target: Path = args.target.expanduser()
    presets = load_presets()
    installed_dirs: list[Path] = []

    # 1) Presets + 2) Pick — both resolved against the preset catalogue
    skill_entries = resolve_skills(config, presets)
    for skill in skill_entries:
        try:
            installed_dirs.append(
                install_skill_from_git(
                    skill, target, update=args.update, dry_run=args.dry_run,
                )
            )
        except InstallError as exc:
            log(f"  ! {skill['name']}: {exc}")

    # 3) Custom git repo
    if config["git_url"]:
        try:
            installed_dirs.extend(
                install_from_git_url(
                    config["git_url"], config["git_ref"], target,
                    update=args.update, dry_run=args.dry_run,
                )
            )
        except InstallError as exc:
            log(f"  ! git_url install failed: {exc}")

    # 4) Local folder
    if config["local_path"]:
        try:
            installed_dirs.extend(
                install_from_local(
                    Path(config["local_path"]), target, dry_run=args.dry_run,
                )
            )
        except InstallError as exc:
            log(f"  ! local_path install failed: {exc}")

    # 5) Symlink each into ~/.claude/skills/
    for skill_dir in installed_dirs:
        try:
            link_into_claude(skill_dir, dry_run=args.dry_run)
        except OSError as exc:
            log(f"  ! could not link {skill_dir.name}: {exc}")

    # 6) One-line summary on stdout
    suffix = " (dry-run)" if args.dry_run else ""
    print(
        f"Installed {len(installed_dirs)} skills into {CLAUDE_SKILLS_DIR}{suffix}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
