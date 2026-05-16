"""Tests for `.claude-plugin/plugin.json` manifest.

Validates structure, required fields, cross-file consistency
(CHANGELOG, LICENSE, SKILL.md frontmatter) and basic semver.

Written defensively: if the manifest does not yet exist (sibling
worker may still be authoring it) every test is skipped instead of
failing hard.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / ".claude-plugin" / "plugin.json"
CHANGELOG_PATH = REPO_ROOT / "CHANGELOG.md"
LICENSE_PATH = REPO_ROOT / "LICENSE"
SKILL_PATH = REPO_ROOT / "SKILL.md"

REPO_URL = "https://github.com/Connected-Mate/corporate-launcher"
EXPECTED_AUTHOR = "Alexandre Cormeraie"
EXPECTED_LICENSE = "MIT"
REQUIRED_KEYWORDS = {"corporate", "launcher", "claude-code"}
REQUIRED_FIELDS = ("name", "version", "description", "author", "license")

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?$")
# A very forgiving semver-range matcher: bare semver, ^x.y.z, ~x.y.z,
# >=x.y.z, comparator chains, "*", "x", or "latest".
SEMVER_RANGE_RE = re.compile(
    r"^("
    r"\*|x|latest|"
    r"(?:[~^]|>=?|<=?|=)?\d+(?:\.\d+){0,2}(?:[-+][0-9A-Za-z.\-]+)?"
    r"(?:\s+(?:[~^]|>=?|<=?|=)?\d+(?:\.\d+){0,2}(?:[-+][0-9A-Za-z.\-]+)?)*"
    r")$"
)


# --------------------------------------------------------------------------- #
# fixtures
# --------------------------------------------------------------------------- #
@pytest.fixture(scope="module")
def manifest() -> dict:
    if not MANIFEST_PATH.exists():
        pytest.skip(f"manifest not yet authored: {MANIFEST_PATH}")
    try:
        return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:  # pragma: no cover
        pytest.fail(f"plugin.json is not valid JSON: {exc}")


def _changelog_latest_version() -> str | None:
    if not CHANGELOG_PATH.exists():
        return None
    pattern = re.compile(r"^##\s*\[(\d+\.\d+\.\d+)\]", re.MULTILINE)
    matches = pattern.findall(CHANGELOG_PATH.read_text(encoding="utf-8"))
    return matches[0] if matches else None


def _skill_frontmatter_name() -> str | None:
    if not SKILL_PATH.exists():
        return None
    text = SKILL_PATH.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return None
    end = text.find("---", 3)
    if end < 0:
        return None
    for line in text[3:end].splitlines():
        if line.strip().startswith("name:"):
            return line.split(":", 1)[1].strip()
    return None


# --------------------------------------------------------------------------- #
# 1. valid JSON
# --------------------------------------------------------------------------- #
def test_manifest_is_valid_json():
    if not MANIFEST_PATH.exists():
        pytest.skip("manifest not authored yet")
    json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


# --------------------------------------------------------------------------- #
# 2. required fields
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("field", REQUIRED_FIELDS)
def test_required_field_present(manifest, field):
    assert field in manifest, f"plugin.json missing required field: {field}"
    assert manifest[field] not in (None, "", [], {}), f"field '{field}' is empty"


# --------------------------------------------------------------------------- #
# 3. name matches skill dir + SKILL.md frontmatter
# --------------------------------------------------------------------------- #
def test_name_matches_directory_and_skill_frontmatter(manifest):
    assert manifest["name"] == REPO_ROOT.name, (
        f"plugin.name={manifest['name']!r} != directory {REPO_ROOT.name!r}"
    )
    skill_name = _skill_frontmatter_name()
    if skill_name is None:
        pytest.skip("SKILL.md frontmatter `name` not found")
    assert manifest["name"] == skill_name, (
        f"plugin.name={manifest['name']!r} != SKILL.md name={skill_name!r}"
    )


# --------------------------------------------------------------------------- #
# 4. version == latest CHANGELOG entry
# --------------------------------------------------------------------------- #
def test_version_matches_changelog(manifest):
    latest = _changelog_latest_version()
    if latest is None:
        pytest.skip("CHANGELOG has no [X.Y.Z] entry yet")
    assert manifest["version"] == latest, (
        f"plugin.version={manifest['version']!r} != CHANGELOG latest {latest!r}"
    )
    assert SEMVER_RE.match(manifest["version"]), "version is not valid semver"


# --------------------------------------------------------------------------- #
# 5. description concise
# --------------------------------------------------------------------------- #
def test_description_is_concise(manifest):
    desc = manifest["description"]
    assert isinstance(desc, str) and desc.strip(), "description must be non-empty string"
    assert len(desc) < 200, f"description too long: {len(desc)} chars (>=200)"


# --------------------------------------------------------------------------- #
# 6. author.name
# --------------------------------------------------------------------------- #
def test_author_name(manifest):
    author = manifest["author"]
    # Accept either string or object form per spec.
    name = author["name"] if isinstance(author, dict) else author
    assert name == EXPECTED_AUTHOR, f"author.name={name!r} != {EXPECTED_AUTHOR!r}"


# --------------------------------------------------------------------------- #
# 7. license matches LICENSE file
# --------------------------------------------------------------------------- #
def test_license_is_mit_and_matches_license_file(manifest):
    assert manifest["license"] == EXPECTED_LICENSE, (
        f"plugin.license={manifest['license']!r} != {EXPECTED_LICENSE!r}"
    )
    if not LICENSE_PATH.exists():
        pytest.skip("LICENSE file missing")
    head = LICENSE_PATH.read_text(encoding="utf-8").splitlines()[:3]
    assert any("MIT" in line for line in head), (
        "LICENSE file does not declare MIT in its header"
    )


# --------------------------------------------------------------------------- #
# 8. homepage + repository URL
# --------------------------------------------------------------------------- #
def test_homepage_points_to_repo(manifest):
    if "homepage" not in manifest:
        pytest.skip("homepage not declared")
    assert manifest["homepage"].rstrip("/") == REPO_URL, (
        f"homepage={manifest['homepage']!r} should point to {REPO_URL}"
    )


def test_repository_points_to_repo(manifest):
    if "repository" not in manifest:
        pytest.skip("repository not declared")
    repo = manifest["repository"]
    url = repo["url"] if isinstance(repo, dict) else repo
    # tolerate trailing .git / slash
    normalized = url.rstrip("/").removesuffix(".git")
    assert normalized == REPO_URL, (
        f"repository url={url!r} should point to {REPO_URL}"
    )


# --------------------------------------------------------------------------- #
# 9. keywords coverage
# --------------------------------------------------------------------------- #
def test_keywords_contains_required(manifest):
    keywords = manifest.get("keywords") or []
    assert isinstance(keywords, list), "keywords must be a list"
    missing = REQUIRED_KEYWORDS - {k.lower() for k in keywords}
    assert not missing, f"keywords missing required entries: {sorted(missing)}"


# --------------------------------------------------------------------------- #
# 10. entries paths resolve
# --------------------------------------------------------------------------- #
def test_entries_resolve_to_real_files(manifest):
    entries = manifest.get("entries")
    if not entries:
        pytest.skip("no entries declared")
    assert isinstance(entries, list), "entries must be a list"
    missing = []
    for entry in entries:
        path = entry.get("path") if isinstance(entry, dict) else entry
        if not path:
            missing.append(repr(entry))
            continue
        resolved = (REPO_ROOT / path).resolve()
        if not resolved.exists():
            missing.append(str(resolved))
    assert not missing, f"entries reference missing paths: {missing}"


# --------------------------------------------------------------------------- #
# 11. compatibility.claude-code is a valid semver range
# --------------------------------------------------------------------------- #
def test_compatibility_claude_code_is_semver_range(manifest):
    compat = manifest.get("compatibility")
    if not compat or "claude-code" not in compat:
        pytest.skip("no compatibility.claude-code declared")
    rng = compat["claude-code"].strip()
    assert SEMVER_RANGE_RE.match(rng), (
        f"compatibility.claude-code={rng!r} is not a recognized semver range"
    )
