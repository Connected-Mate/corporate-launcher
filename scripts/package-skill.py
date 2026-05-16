#!/usr/bin/env python3
"""Package the corporate-launcher skill into a distributable ``.skill`` archive.

A ``.skill`` file is a plain ZIP with a fixed top-level layout::

    corporate-launcher/
        SKILL.md
        MANIFEST.json
        README.md
        LICENSE
        references/...
        templates/...
        scripts/...
        ...

Usage::

    python3 scripts/package-skill.py
    python3 scripts/package-skill.py --version 0.4.0
    python3 scripts/package-skill.py --out dist/corporate-launcher-0.4.0.skill
    python3 scripts/package-skill.py --validate
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path

# --- Configuration ----------------------------------------------------------

SKILL_NAME = "corporate-launcher"

# Top-level files copied verbatim if present.
TOP_LEVEL_FILES: tuple[str, ...] = ("SKILL.md", "README.md", "LICENSE")

# Top-level directories whose contents are included recursively.
INCLUDE_DIRS: tuple[str, ...] = (
    "references",
    "templates",
    "scripts",
    "assets",
    "evals",
    "integrations",
    "schema",
)

# Runtime scripts (anything in scripts/ matching these names is included).
# Everything else inside scripts/ is also included EXCEPT this very packager
# and any obvious dev/test artefacts.
SCRIPTS_EXCLUDE_NAMES: frozenset[str] = frozenset(
    {
        "package-skill.py",  # do not ship the packager itself
    }
)

# Path-fragment denylist: any staged file whose POSIX path matches any of
# these patterns (fnmatch style) is dropped.
DENY_GLOBS: tuple[str, ...] = (
    "**/__pycache__/**",
    "**/__pycache__",
    "**/.pytest_cache/**",
    "**/.mypy_cache/**",
    "**/.ruff_cache/**",
    "**/.git/**",
    "**/.gitignore",
    "**/.DS_Store",
    "**/*.pyc",
    "**/*.pyo",
    "**/.env",
    "**/.env.*",
    "**/*.conf",
    "**/secrets/**",
    "**/dist/**",
    "**/tests/**",
    "tests/**",
)


# --- Helpers ----------------------------------------------------------------


@dataclass(frozen=True)
class FrontMatter:
    """A minimal view of the SKILL.md YAML front-matter."""

    name: str
    description: str


def _denied(rel_posix: str) -> bool:
    """Return True if *rel_posix* matches any deny pattern."""
    return any(fnmatch.fnmatch(rel_posix, pat) for pat in DENY_GLOBS)


def _sha256_file(path: Path, chunk: int = 65536) -> str:
    """Return the hex SHA-256 of *path*."""
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def _read_frontmatter(skill_md: Path) -> FrontMatter:
    """Parse the YAML front-matter block of SKILL.md.

    Only ``name`` and ``description`` are extracted; we do not pull in PyYAML.
    """
    text = skill_md.read_text(encoding="utf-8")
    if not text.startswith("---"):
        raise ValueError(f"{skill_md} does not start with YAML front-matter")
    end = text.find("\n---", 3)
    if end == -1:
        raise ValueError(f"{skill_md} has an unterminated front-matter block")
    block = text[3:end].strip("\n")

    name = ""
    description = ""
    for line in block.splitlines():
        if line.startswith("name:"):
            name = line.split(":", 1)[1].strip()
        elif line.startswith("description:"):
            description = line.split(":", 1)[1].strip()
    if not name:
        raise ValueError(f"{skill_md} front-matter is missing 'name'")
    return FrontMatter(name=name, description=description)


def _version_from_changelog(changelog: Path) -> str | None:
    """Return the latest semver tag from a Keep-a-Changelog file, or None."""
    if not changelog.is_file():
        return None
    pattern = re.compile(r"^##\s*\[(\d+\.\d+\.\d+)\]")
    for line in changelog.read_text(encoding="utf-8").splitlines():
        m = pattern.match(line.strip())
        if m:
            return m.group(1)
    return None


def _version_from_git(repo: Path) -> str | None:
    """Return ``git describe --tags --abbrev=0`` stripped of a leading 'v'."""
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "describe", "--tags", "--abbrev=0"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    tag = out.stdout.strip()
    return tag.lstrip("v") or None


def resolve_version(repo: Path, override: str | None) -> str:
    """Resolve version: CLI flag > CHANGELOG > git tag > '0.0.0'."""
    if override:
        return override.lstrip("v")
    return (
        _version_from_changelog(repo / "CHANGELOG.md")
        or _version_from_git(repo)
        or "0.0.0"
    )


# --- Staging ---------------------------------------------------------------


def _iter_source_files(repo: Path) -> list[Path]:
    """Walk the repo and return the absolute paths to include."""
    chosen: list[Path] = []

    for name in TOP_LEVEL_FILES:
        p = repo / name
        if p.is_file():
            chosen.append(p)

    for d in INCLUDE_DIRS:
        root = repo / d
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(repo).as_posix()
            if _denied(rel):
                continue
            if d == "scripts" and path.name in SCRIPTS_EXCLUDE_NAMES:
                continue
            chosen.append(path)

    return chosen


def stage(repo: Path, staging_root: Path) -> list[tuple[str, Path]]:
    """Copy selected files into ``staging_root / SKILL_NAME / ...``.

    Returns a sorted list of ``(arcname, absolute_path)`` pairs where
    ``arcname`` is the path inside the resulting archive.
    """
    top = staging_root / SKILL_NAME
    top.mkdir(parents=True, exist_ok=True)

    pairs: list[tuple[str, Path]] = []
    for src in _iter_source_files(repo):
        rel = src.relative_to(repo)
        dst = top / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        arcname = f"{SKILL_NAME}/{rel.as_posix()}"
        pairs.append((arcname, dst))
    return sorted(pairs, key=lambda p: p[0])


# --- Manifest + zip --------------------------------------------------------


def build_manifest(
    fm: FrontMatter,
    version: str,
    pairs: list[tuple[str, Path]],
) -> dict:
    """Build the MANIFEST.json contents."""
    files = []
    for arcname, path in pairs:
        rel_inside_skill = arcname.split("/", 1)[1]  # strip "corporate-launcher/"
        files.append(
            {
                "path": rel_inside_skill,
                "size": path.stat().st_size,
                "sha256": _sha256_file(path),
            }
        )
    return {
        "name": fm.name,
        "version": version,
        "description": fm.description,
        "file_count": len(files),
        "files": files,
    }


def write_zip(
    out_path: Path,
    pairs: list[tuple[str, Path]],
    manifest: dict,
) -> None:
    """Write the ``.skill`` zip archive at *out_path*."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_arcname = f"{SKILL_NAME}/MANIFEST.json"
    manifest_bytes = json.dumps(manifest, indent=2, sort_keys=False).encode("utf-8")

    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(manifest_arcname, manifest_bytes)
        for arcname, path in pairs:
            zf.write(path, arcname)


# --- Validation ------------------------------------------------------------


def validate(archive: Path) -> tuple[int, int]:
    """Verify every manifest entry against the archive contents.

    Returns ``(checked, mismatches)``. Raises on structural problems.
    """
    with zipfile.ZipFile(archive, "r") as zf:
        names = set(zf.namelist())
        manifest_arc = f"{SKILL_NAME}/MANIFEST.json"
        if manifest_arc not in names:
            raise RuntimeError(f"missing {manifest_arc} in {archive}")
        manifest = json.loads(zf.read(manifest_arc).decode("utf-8"))

        checked = 0
        mismatches = 0
        for entry in manifest["files"]:
            arcname = f"{SKILL_NAME}/{entry['path']}"
            if arcname not in names:
                print(f"  MISSING  {arcname}", file=sys.stderr)
                mismatches += 1
                continue
            data = zf.read(arcname)
            digest = hashlib.sha256(data).hexdigest()
            if digest != entry["sha256"]:
                print(
                    f"  HASH MISMATCH  {arcname}\n"
                    f"    expected {entry['sha256']}\n"
                    f"    actual   {digest}",
                    file=sys.stderr,
                )
                mismatches += 1
            checked += 1
        return checked, mismatches


# --- CLI -------------------------------------------------------------------


def _human_size(n: int) -> str:
    """Format a byte count in a compact human-readable form."""
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024:
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} {unit}"
        n /= 1024  # type: ignore[assignment]
    return f"{n:.1f} TiB"


def main(argv: list[str] | None = None) -> int:
    """Entry point: parse args, stage, zip, optionally validate."""
    parser = argparse.ArgumentParser(
        description="Package the corporate-launcher skill as a .skill archive.",
    )
    parser.add_argument(
        "--version",
        help="Override the version (else: CHANGELOG.md > git tag > 0.0.0).",
    )
    parser.add_argument(
        "--out",
        type=Path,
        help="Output .skill path (default: dist/<name>-<version>.skill).",
    )
    parser.add_argument(
        "--validate",
        action="store_true",
        help="After packaging, re-open the archive and verify all hashes.",
    )
    args = parser.parse_args(argv)

    repo = Path(__file__).resolve().parent.parent
    skill_md = repo / "SKILL.md"
    if not skill_md.is_file():
        print(f"error: {skill_md} not found", file=sys.stderr)
        return 2

    fm = _read_frontmatter(skill_md)
    version = resolve_version(repo, args.version)
    out_path: Path = (
        args.out
        if args.out is not None
        else repo / "dist" / f"{SKILL_NAME}-{version}.skill"
    )

    with tempfile.TemporaryDirectory(prefix="skillpkg-") as tmp:
        staging = Path(tmp)
        pairs = stage(repo, staging)
        if not pairs:
            print("error: nothing staged — check INCLUDE_DIRS/DENY_GLOBS", file=sys.stderr)
            return 1
        manifest = build_manifest(fm, version, pairs)
        write_zip(out_path, pairs, manifest)

    pkg_size = out_path.stat().st_size
    pkg_sha = _sha256_file(out_path)

    print(f"package : {out_path}")
    print(f"version : {version}")
    print(f"files   : {manifest['file_count']}")
    print(f"size    : {_human_size(pkg_size)} ({pkg_size} bytes)")
    print(f"sha256  : {pkg_sha}")

    if args.validate:
        checked, mismatches = validate(out_path)
        print(f"validate: checked {checked} entries, {mismatches} mismatch(es)")
        if mismatches:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
