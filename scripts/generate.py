#!/usr/bin/env python3
"""Corporate Launcher — end-to-end generation orchestrator.

This is the master entry point called by the skill at the end of the
interview. It takes the answers collected from the interview (a JSON
config file) and produces the full launcher tree on disk, plus any
distribution artefacts the creator asked for.

Pipeline (phase numbers match SKILL.md — source of truth):
    1.  Load and validate the config file (``${VAR}`` schema, see
        ``references/interview-flow.md`` for the validation rules).
    1.5 If ``API_PROBE_ENABLED=yes`` call ``scripts/api-probe.py``
        against the configured gateway; save report to
        ``INSTALL_DIR/.api-probe-report.json``. Failures prompt
        the operator unless ``--ignore-probe`` / ``--non-interactive``.
    1.6 Optional smoke load-test (``LOAD_TEST_ENABLED=yes``) via
        ``scripts/load-test.py``.
    2.  For each CLI in ``WRAPPED_CLIS`` render ``templates/<cli>/``
        into ``INSTALL_DIR``.
    2.5 If ``DEV_RULES_MODE != none`` invoke
        ``scripts/dev-rules-installer.py`` to inject corporate dev
        rules into the launcher tree (NEW).
    3.  Render ``templates/shared/`` into ``INSTALL_DIR/scripts/``
        (skills + MCP installers + ancillary helpers).
    3.5 Run ``scripts/audit-launcher.py`` and save
        ``INSTALL_DIR/audit-report.{md,json}``. P0 findings warn
        (or abort under ``--strict``).
    3.6 Run ``scripts/url-purge.py``. Auto-patches when
        ``URL_PURGE_AUTOPATCH=yes``; aborts under ``--strict``.
    3.7 If ``BANNER_GENERATE=yes`` invoke ``scripts/pixel-art-logo.py``
        and write ``INSTALL_DIR/banner.txt`` (consumed by show_banner).
    4.  If ``DIST_MODE != none`` render ``templates/dist/<mode>/``
        into ``dist/`` and run the matching scaffold/build/oneliner
        post-render action.
    4.5 If ``COMPLIANCE_DOCX=yes`` call
        ``scripts/build-compliance-docx.py`` → ``compliance.docx``.
        Soft-fails when python-docx is missing.
    5.  Print the post-install summary (launcher path, launch command,
        distribution artefact URL or path, and the "Proudly made from
        France" footer).

Usage:
    python3 generate.py --config config.json
    python3 generate.py --config config.json --out ~/.local/share/<slug>
    python3 generate.py --config config.json --dry-run

Pure Python 3.10+, stdlib only. Always delegates rendering to
``scripts/render.py`` (no inline ``${VAR}`` substitution).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Any, Mapping

# Local import — render.py lives next to this script.
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from render import (  # noqa: E402  (sys.path tweak required first)
    UnresolvedVariable,
    load_context,
    render_tree,
    validate as render_validate,
)

REPO_ROOT = HERE.parent
TEMPLATES = REPO_ROOT / "templates"
SUPPORTED_CLIS = ("claude-code", "codex-cli", "gemini-cli", "aider", "opencode", "continue-dev")
SUPPORTED_DIST = ("public-git", "private-git", "tarball", "oneliner", "none")

# Truthy values accepted in config flags (case-insensitive).
_TRUTHY = ("yes", "true", "1", "on")


def _is_truthy(value: object) -> bool:
    return str(value or "").strip().lower() in _TRUTHY


def _script_exists(name: str) -> Path | None:
    """Return the script path if present, else None (with a soft warning)."""
    path = HERE / name
    if path.is_file():
        return path
    print(f"  skip: companion script not found — {path}")
    return None


def _skill_dir() -> Path:
    """Return the root of the corporate-launcher skill (parent of scripts/).

    Honour ``CLAUDE_SKILL_DIR`` if it points at a real directory; otherwise
    fall back to the repository root inferred from this file's location.
    Subprocesses spawned by generate.py inherit ``CLAUDE_SKILL_DIR`` from
    the env propagation step at the start of ``main()``.
    """
    env_root = os.environ.get("CLAUDE_SKILL_DIR")
    if env_root:
        candidate = Path(env_root).expanduser()
        if candidate.is_dir():
            return candidate.resolve()
    return REPO_ROOT
INTERNAL_HOST_RE = re.compile(
    r"(\.internal\b|\.local\b|\.intra\b|^10\.|^192\.168\.|^172\.(1[6-9]|2\d|3[0-1])\.)",
    re.IGNORECASE,
)


class GenerationError(RuntimeError):
    """A user-actionable failure during orchestration."""


# ----------------------------------------------------------------------- #
# Validation                                                              #
# ----------------------------------------------------------------------- #


def validate_config(ctx: Mapping[str, object]) -> list[str]:
    """Apply the validation rules from ``references/interview-flow.md``.

    Returns a list of human-readable error strings (empty = OK).
    """
    errs: list[str] = list(render_validate(ctx))

    # Rule 2 — every wrapped CLI must have its own block.
    wrapped = ctx.get("WRAPPED_CLIS") or []
    if isinstance(wrapped, str):
        wrapped = [wrapped]
    if not wrapped:
        errs.append("WRAPPED_CLIS is empty — pick at least one CLI to wrap")
    for cli in wrapped:
        if cli not in SUPPORTED_CLIS:
            errs.append(f"unsupported CLI in WRAPPED_CLIS: {cli!r}")
        prefix = {
            "claude-code": "CC_",
            "codex-cli": "CX_",
            "gemini-cli": "GM_",
            "aider": "LLM_",
            "opencode": "LLM_",
            "continue-dev": "LLM_",
        }.get(cli)
        required_by_cli = {
            "CC_": ("CC_BACKEND", "CC_PRIMARY_URL", "CC_PRIMARY_MODEL", "CC_AUTH_MODEL"),
            "CX_": ("CX_BACKEND", "CX_PRIMARY_URL", "CX_PRIMARY_MODEL", "CX_AUTH_ENV_KEY"),
            "GM_": ("GM_BACKEND", "GM_PRIMARY_MODEL", "GM_AUTH_MODE"),
            "LLM_": ("LLM_OPENAI_BASE_URL", "LLM_OPENAI_AUTH", "LLM_PRIMARY_MODEL"),
        }.get(prefix or "", ())
        for key in required_by_cli:
            if not ctx.get(key):
                errs.append(f"{cli}: missing required field {key}")

    # Rule 3 — primary URLs must be HTTPS.
    for url_key in ("CC_PRIMARY_URL", "CX_PRIMARY_URL", "LLM_OPENAI_BASE_URL"):
        url = ctx.get(url_key)
        if url and not str(url).startswith("https://"):
            errs.append(f"{url_key} must be HTTPS (got {url!r})")

    # Rule 4 — proxy is all-or-nothing.
    host = ctx.get("PROXY_HOST")
    port = ctx.get("PROXY_PORT")
    if bool(host) != bool(port):
        errs.append("PROXY_HOST and PROXY_PORT must both be set or both empty")

    # Rule 6 — Bedrock / LiteLLM force strip-proxy.
    backend = str(ctx.get("CC_BACKEND", "")).lower()
    if ("bedrock" in backend or "litellm" in backend) and str(
        ctx.get("CC_NEEDS_STRIP_PROXY", "yes")
    ).lower() in ("no", "false", "0"):
        errs.append("CC_BACKEND={Bedrock,LiteLLM} requires CC_NEEDS_STRIP_PROXY=yes")

    # Rule 7 — public git refuses internal hostnames without override.
    if ctx.get("DIST_MODE") == "public-git" and str(
        ctx.get("DIST_PUBLIC_FORCE", "no")
    ).lower() not in ("yes", "true", "1"):
        for url_key in ("CC_PRIMARY_URL", "CX_PRIMARY_URL", "LLM_OPENAI_BASE_URL"):
            url = str(ctx.get(url_key, ""))
            if url and INTERNAL_HOST_RE.search(url):
                errs.append(
                    f"DIST_MODE=public-git refuses internal hostname in {url_key}={url!r}. "
                    "Set DIST_PUBLIC_FORCE=yes to override."
                )

    # Rule 8 — oneliner host must be HTTPS.
    if ctx.get("DIST_MODE") == "oneliner":
        host_url = str(ctx.get("DIST_ONELINER_HOST", ""))
        if not host_url.startswith("https://"):
            errs.append(f"DIST_MODE=oneliner requires HTTPS for DIST_ONELINER_HOST (got {host_url!r})")

    dist_mode = ctx.get("DIST_MODE")
    if dist_mode and dist_mode not in SUPPORTED_DIST:
        errs.append(f"unsupported DIST_MODE: {dist_mode!r}")

    # Rule 9 — DEV_RULES_MODE: each non-trivial source needs its own pointer.
    dev_rules_mode = str(ctx.get("DEV_RULES_MODE", "none") or "none").lower()
    if dev_rules_mode not in ("none", "inline", "local", "git"):
        errs.append(
            f"unsupported DEV_RULES_MODE: {ctx.get('DEV_RULES_MODE')!r} "
            "(expected one of: none, inline, local, git)"
        )
    if dev_rules_mode == "inline" and not ctx.get("DEV_RULES_CONTENT"):
        errs.append("DEV_RULES_MODE=inline requires DEV_RULES_CONTENT")
    if dev_rules_mode == "local" and not ctx.get("DEV_RULES_LOCAL_PATH"):
        errs.append("DEV_RULES_MODE=local requires DEV_RULES_LOCAL_PATH")
    if dev_rules_mode == "git" and not ctx.get("DEV_RULES_GIT_URL"):
        errs.append("DEV_RULES_MODE=git requires DEV_RULES_GIT_URL")

    return errs


# ----------------------------------------------------------------------- #
# Helpers                                                                 #
# ----------------------------------------------------------------------- #


def expand_path(raw: str, ctx: Mapping[str, object]) -> Path:
    """Expand ``~`` and ``${VAR}`` substitutions in a config path."""
    s = raw
    for k, v in ctx.items():
        s = s.replace("${" + k + "}", str(v))
    return Path(os.path.expandvars(os.path.expanduser(s))).resolve()


def resolve_install_dir(ctx: Mapping[str, object], cli_override: Path | None) -> Path:
    if cli_override is not None:
        return cli_override.expanduser().resolve()
    raw = ctx.get("INSTALL_DIR") or f"~/.local/share/{ctx['CORP_SLUG']}"
    return expand_path(str(raw), ctx)


def run_step(cmd: list[str], *, dry_run: bool, cwd: Path | None = None) -> int:
    """Execute a subprocess step, honouring --dry-run."""
    label = " ".join(cmd)
    if cwd:
        label += f"  (cwd={cwd})"
    if dry_run:
        print(f"[dry-run] {label}")
        return 0
    print(f"  $ {label}")
    proc = subprocess.run(cmd, cwd=cwd, check=False)
    return proc.returncode


def write_file(path: Path, content: str, *, dry_run: bool, executable: bool = False) -> None:
    if dry_run:
        print(f"[dry-run] would write {path} ({len(content)} bytes)")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    if executable:
        path.chmod(0o755)


# ----------------------------------------------------------------------- #
# Pipeline steps                                                          #
# ----------------------------------------------------------------------- #


def render_clis(
    ctx: Mapping[str, object], install_dir: Path, *, dry_run: bool
) -> list[Path]:
    """Render templates/<cli>/ → INSTALL_DIR for every wrapped CLI."""
    written: list[Path] = []
    wrapped = ctx.get("WRAPPED_CLIS") or []
    if isinstance(wrapped, str):
        wrapped = [wrapped]
    # Provide PROVIDER_KIND for shared templates (launcher-update.sh references
    # it as a fall-back when the runtime manifest is absent). Defaults to the
    # first wrapped CLI; can be overridden in the config.
    ctx = dict(ctx)
    if "PROVIDER_KIND" not in ctx:
        ctx["PROVIDER_KIND"] = wrapped[0] if wrapped else "claude-code"
    for cli in wrapped:
        src = TEMPLATES / cli
        if not src.is_dir():
            raise GenerationError(f"no template directory for CLI {cli!r}: {src}")
        if dry_run:
            for f in src.rglob("*.tpl"):
                rel = f.relative_to(src).with_suffix("")
                print(f"[dry-run] would render {f} → {install_dir / rel}")
            continue
        written.extend(render_tree(src, install_dir, ctx))

    # Shared helpers always go under INSTALL_DIR/scripts/.
    shared_src = TEMPLATES / "shared"
    shared_dst = install_dir / "scripts"
    if dry_run:
        for f in shared_src.rglob("*"):
            if f.is_file():
                rel = f.relative_to(shared_src)
                if str(rel).endswith(".tpl"):
                    rel = Path(str(rel)[:-4])
                print(f"[dry-run] would render {f} → {shared_dst / rel}")
    else:
        written.extend(render_tree(shared_src, shared_dst, ctx))
    return written


def run_dev_rules(
    ctx: Mapping[str, object],
    install_dir: Path,
    config_path: Path,
    *,
    dry_run: bool,
) -> int:
    """Phase 2.5 — inject corporate dev rules into the launcher tree.

    Delegates the heavy lifting to ``scripts/dev-rules-installer.py``. The
    installer reads ``DEV_RULES_MODE`` (``local`` | ``git`` | ``none``) plus
    the matching pointer (``DEV_RULES_LOCAL_PATH`` / ``DEV_RULES_GIT_URL``)
    out of the config and writes one or more rule sections into the rendered
    launcher.

    Returns the number of rules sections written (0 when disabled / missing).
    """
    mode = str(ctx.get("DEV_RULES_MODE", "none") or "none").lower()
    if mode == "none":
        return 0

    installer = _skill_dir() / "scripts" / "dev-rules-installer.py"
    if not installer.is_file():
        print(f"  warning: dev-rules-installer.py not found at {installer} — skipping")
        return 0

    cmd = [
        "python3",
        str(installer),
        "--config",
        str(config_path),
        "--launcher-dir",
        str(install_dir),
    ]
    if dry_run:
        print(f"[dry-run] would run dev-rules-installer ({mode}) → {install_dir}")
        return 0

    print(f"  $ python3 {installer.name} --config {config_path} --launcher-dir {install_dir}")
    proc = subprocess.run(cmd, check=False, capture_output=True, text=True)

    # The installer prints a line of the form
    # ``Installed <N> rules sections into <path>`` on success.
    written = 0
    for line in (proc.stdout or "").splitlines():
        m = re.match(r"^Installed\s+(\d+)\s+rules sections\b", line)
        if m:
            written = int(m.group(1))
            break

    if proc.returncode != 0:
        msg = (proc.stderr or proc.stdout or "").strip()[:200]
        print(f"  warning: dev-rules-installer exited {proc.returncode}: {msg}")
    print(f"[2.5] Dev rules: {mode} — {written} rules sections written")
    return written


def run_skills_installer(
    ctx: Mapping[str, object], install_dir: Path, *, dry_run: bool
) -> None:
    """Materialise a skills config and call scripts/skills-installer.py."""
    mode = str(ctx.get("SKILLS_MODE", "none"))
    if mode == "none":
        return
    skills_cfg = {
        "mode": mode,
        "presets": ctx.get("SKILLS_PRESETS") or [],
        "pick": ctx.get("SKILLS_PICK") or [],
        "git_url": ctx.get("SKILLS_GIT_URL") or None,
        "git_ref": ctx.get("SKILLS_GIT_REF") or "main",
        "local_path": ctx.get("SKILLS_LOCAL_PATH") or None,
    }
    cfg_path = install_dir / "skills.config.json"
    write_file(cfg_path, json.dumps(skills_cfg, indent=2), dry_run=dry_run)
    rc = run_step(
        [
            sys.executable,
            str(HERE / "skills-installer.py"),
            "--config",
            str(cfg_path),
            "--target",
            str(install_dir / "skills"),
            *(["--dry-run"] if dry_run else []),
        ],
        dry_run=False,  # the installer itself honours --dry-run
    )
    if rc != 0 and not dry_run:
        raise GenerationError(f"skills-installer exited with code {rc}")


def run_mcp_installer(
    ctx: Mapping[str, object], install_dir: Path, *, dry_run: bool
) -> None:
    """Call scripts/mcp-installer.py once per wrapped CLI."""
    servers = ctx.get("MCP_SERVERS") or []
    if not servers:
        return
    wrapped = ctx.get("WRAPPED_CLIS") or []
    if isinstance(wrapped, str):
        wrapped = [wrapped]
    for cli in wrapped:
        if cli == "continue-dev":
            print(f"  skip MCP installer for {cli} (no native MCP support yet)")
            continue
        # Target the launcher's own settings.json, never the operator's
        # personal ~/.claude/settings.json.
        cli_settings = install_dir / "settings.json"
        cmd = [
            sys.executable,
            str(HERE / "mcp-installer.py"),
            "--cli",
            cli,
            "--servers",
            json.dumps(servers),
        ]
        if cli == "claude-code":
            cmd.extend(["--settings", str(cli_settings)])
        rc = run_step(cmd, dry_run=dry_run)
        if rc != 0 and not dry_run:
            raise GenerationError(f"mcp-installer for {cli} exited with code {rc}")


def render_distribution(
    ctx: Mapping[str, object], install_dir: Path, dist_dir: Path, *, dry_run: bool
) -> Path | None:
    """Render templates/dist/<mode>/ → dist/ and run any scaffolding step."""
    mode = str(ctx.get("DIST_MODE", "none"))
    if mode == "none":
        return None

    src = TEMPLATES / "dist" / mode
    if not src.is_dir():
        raise GenerationError(f"no dist template for mode {mode!r}: {src}")

    if dry_run:
        for f in src.rglob("*.tpl"):
            rel = f.relative_to(src).with_suffix("")
            print(f"[dry-run] would render {f} → {dist_dir / rel}")
    else:
        render_tree(src, dist_dir, ctx)

    # Mode-specific post-render actions.
    if mode in ("public-git", "private-git"):
        # If the templates contain a scaffold.sh.tpl it has already been
        # rendered into dist/scaffold.sh; run it from dist/.
        scaffold = dist_dir / "scaffold.sh"
        if scaffold.is_file() or dry_run:
            run_step(["bash", str(scaffold)], dry_run=dry_run, cwd=dist_dir)
        else:
            print(f"  note: no scaffold.sh for {mode} — skipping auto-push")

    elif mode == "tarball":
        if not dry_run:
            slug = str(ctx.get("CORP_SLUG", "launcher"))
            version = str(ctx.get("CORP_LAUNCHER_VERSION") or ctx.get("VERSION") or "0.0.0")
            archive_name = f"{slug}-{version}.tar.gz"
            archive_path = dist_dir / archive_name
            arcroot = f"{slug}-{version}"
            with tarfile.open(archive_path, "w:gz") as tf:
                if install_dir.is_dir():
                    tf.add(install_dir, arcname=arcroot)
            digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
            (dist_dir / "SHA256SUMS").write_text(
                f"{digest}  {archive_name}\n", encoding="utf-8"
            )
        build = dist_dir / "build.sh"
        if build.is_file() or dry_run:
            run_step(["bash", str(build)], dry_run=dry_run, cwd=dist_dir)
        elif not dry_run:
            print("  note: no build.sh produced for reproducible rebuilds")

    elif mode == "oneliner":
        # Render install.sh from a dedicated template if present, then
        # write a companion .sha256 file next to it.
        install_sh = dist_dir / "install.sh"
        if not install_sh.is_file() and not dry_run:
            print("  warning: oneliner mode but no install.sh template found")
        elif not dry_run:
            digest = hashlib.sha256(install_sh.read_bytes()).hexdigest()
            checksum = f"{digest}  install.sh\n"
            write_file(dist_dir / "install.sh.sha256", checksum, dry_run=False)

    return dist_dir


# ----------------------------------------------------------------------- #
# Phase 1.4 — Legal compliance check                                      #
# ----------------------------------------------------------------------- #


# Map (cli, raw backend string) to a key in legal-matrix.json.
# Anthropic-flavoured backends are recognised by substring so "bedrock",
# "aws-bedrock", "bedrock-proxy" all collapse to bedrock-anthropic for
# Claude Code (which is the only Anthropic-branded CLI we ship). For
# litellm, missing "anthropic-only" / "openai-only" / "gemini-only"
# hints default to "litellm-mixed" which forces an ambiguous verdict
# and a legal review.
def _legal_backend_key(cli: str, raw: str) -> str:
    raw = raw.lower().strip()
    if cli == "claude-code":
        if raw in ("", "anthropic", "anthropic-api"): return "anthropic-api"
        if "bedrock" in raw: return "bedrock-anthropic"
        if "vertex" in raw and "anthropic" in raw: return "vertex-anthropic"
        if raw == "vertex": return "vertex-anthropic"
        if "foundry" in raw: return "foundry-anthropic"
        if "azure" in raw: return "azure-openai"
        if raw in ("openai", "openai-api"): return "openai"
        if raw in ("ai-studio", "ai-studio-gemini"): return "ai-studio-gemini"
        if "gemini" in raw and "vertex" in raw: return "vertex-gemini"
        if "litellm" in raw:
            for suf in ("anthropic-only", "openai-only", "gemini-only", "mixed"):
                if suf in raw: return f"litellm-{suf}"
            return "litellm-mixed"
        if raw in ("self-hosted", "ollama", "vllm", "llama-cpp"): return "self-hosted-oss"
        return raw
    if cli == "codex-cli":
        if "azure" in raw: return "azure-openai"
        if raw == "openai": return "openai"
        if "bedrock" in raw: return "bedrock-anthropic"
        return raw or "openai"
    if cli == "gemini-cli":
        if raw == "vertex": return "vertex-gemini"
        if raw in ("ai-studio", ""): return "ai-studio-gemini"
        return raw
    # aider / opencode / continue-dev / cline — LLM_BACKEND is a free-form
    # gateway label; map only the well-known cases.
    if "azure" in raw: return "azure-openai"
    if "openai" in raw and "azure" not in raw: return "openai"
    if "anthropic" in raw or "bedrock" in raw: return "bedrock-anthropic" if "bedrock" in raw else "anthropic-api"
    if "vertex" in raw or "gemini" in raw: return "vertex-gemini"
    if "litellm" in raw: return "litellm-mixed"
    return raw or "litellm-mixed"


def _load_legal_matrix() -> dict[str, Any]:
    path = _skill_dir() / "scripts" / "legal-matrix.json"
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise GenerationError(f"legal-matrix.json is invalid JSON: {e}")


def run_legal_check(
    ctx: Mapping[str, object],
    install_dir: Path,
    *,
    legal_reviewed: str | None,
    legal_reviewer: str | None,
    legal_override: str | None,
    dry_run: bool,
) -> None:
    """Phase 1.4 — refuse breach-of-contract configurations.

    Reads scripts/legal-matrix.json. For each wrapped CLI:
      - status=forbidden → block unless --legal-override="<reason>"
      - status=ambiguous → block unless --legal-reviewed=YYYY-MM-DD
        and --legal-reviewer="Name <email>"
      - status=allowed → silent pass

    Stamps install_dir/.legal-attestation.json on success.
    """
    matrix = _load_legal_matrix()
    if not matrix:
        print("  warning: legal-matrix.json missing — skipping legal check")
        return

    # Freshness — refuse if the matrix is older than reverify_after_days.
    import datetime as _dt
    today = _dt.date.today()
    try:
        read_date = _dt.date.fromisoformat(str(matrix.get("last_read_date", "")))
    except ValueError:
        raise GenerationError("legal-matrix.json: invalid last_read_date")
    reverify = int(matrix.get("reverify_after_days", 180))
    age = (today - read_date).days
    if age > reverify:
        raise GenerationError(
            f"legal-matrix.json is {age} days old (max {reverify}). "
            "Rerun the TOS-reading agent and commit a refreshed matrix before generating."
        )

    wrapped = ctx.get("WRAPPED_CLIS") or []
    if isinstance(wrapped, str):
        wrapped = [wrapped]

    findings: list[tuple[str, str, str, str]] = []  # (cli, backend_key, status, rationale)
    for cli in wrapped:
        cli_row = matrix.get("matrix", {}).get(cli)
        if not cli_row:
            print(f"  warning: no legal row for CLI {cli!r} — skipping")
            continue
        backend_raw = (
            ctx.get({"claude-code": "CC_BACKEND",
                     "codex-cli": "CX_BACKEND",
                     "gemini-cli": "GM_BACKEND"}.get(cli, "LLM_BACKEND")) or ""
        )
        key = _legal_backend_key(cli, str(backend_raw))
        status = cli_row.get(key, "ambiguous")
        rationale = (
            matrix.get("rationale", {}).get(f"{cli}:{key}")
            or matrix.get("rationale", {}).get(f"{cli}:any-non-{cli.split('-')[0]}", "")
            or "no rationale recorded"
        )
        findings.append((cli, key, status, rationale))

    forbidden = [f for f in findings if f[2] == "forbidden"]
    ambiguous = [f for f in findings if f[2] == "ambiguous"]

    for cli, key, status, rationale in findings:
        marker = {"allowed": "  [OK]  ", "ambiguous": "  [??]  ", "forbidden": "  [KO]  "}.get(status, "  [?]  ")
        print(f"{marker}{cli} → {key}: {status}")

    if forbidden:
        if not legal_override:
            msg = ["legal-check: FORBIDDEN configurations detected (would breach vendor TOS):"]
            for cli, key, _, rationale in forbidden:
                msg.append(f"  • {cli} → {key}")
                msg.append(f"      {rationale}")
            msg.append("Refusing to generate. To proceed under documented exception, rerun with:")
            msg.append('  --legal-override="<reason approved by your legal counsel>"')
            raise GenerationError("\n".join(msg))
        print(f"  legal-override accepted: {legal_override}")

    if ambiguous:
        if not legal_reviewed or not legal_reviewer:
            msg = ["legal-check: AMBIGUOUS configurations detected (legal review required):"]
            for cli, key, _, rationale in ambiguous:
                msg.append(f"  • {cli} → {key}")
                msg.append(f"      {rationale}")
            msg.append("Rerun with:")
            msg.append('  --legal-reviewed=YYYY-MM-DD --legal-reviewer="Name <email>"')
            raise GenerationError("\n".join(msg))
        try:
            _dt.date.fromisoformat(legal_reviewed)
        except ValueError:
            raise GenerationError(
                f"--legal-reviewed must be ISO date YYYY-MM-DD (got {legal_reviewed!r})"
            )

    # Stamp attestation for audit trail.
    if not dry_run:
        install_dir.mkdir(parents=True, exist_ok=True)
        attestation = {
            "matrix_version": matrix.get("version"),
            "matrix_last_read_date": str(matrix.get("last_read_date")),
            "checked_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            "findings": [
                {"cli": c, "backend_key": k, "status": s} for c, k, s, _ in findings
            ],
            "legal_reviewed": legal_reviewed,
            "legal_reviewer": legal_reviewer,
            "legal_override": legal_override,
        }
        (install_dir / ".legal-attestation.json").write_text(
            json.dumps(attestation, indent=2, sort_keys=True), encoding="utf-8"
        )


# ----------------------------------------------------------------------- #
# Phase 1.5 — API gateway probe                                           #
# ----------------------------------------------------------------------- #


def _pick_probe_target(ctx: Mapping[str, object]) -> tuple[str, str, str]:
    """Return (url, token, backend_hint) from the first CLI block that has them.

    The token is resolved from a literal value OR from an env var name stored
    in the config (e.g. CC_AUTH_ENV_KEY=ANTHROPIC_API_KEY).
    """
    url_keys = (
        ("CC_PRIMARY_URL", "CC_AUTH_TOKEN", "CC_AUTH_ENV_KEY", "CC_BACKEND"),
        ("CX_PRIMARY_URL", "CX_AUTH_TOKEN", "CX_AUTH_ENV_KEY", "CX_BACKEND"),
        ("LLM_OPENAI_BASE_URL", "LLM_OPENAI_AUTH", "LLM_OPENAI_AUTH_ENV", "LLM_BACKEND"),
    )
    for url_k, tok_k, env_k, backend_k in url_keys:
        url = str(ctx.get(url_k) or "")
        if not url:
            continue
        token = str(ctx.get(tok_k) or "")
        if not token:
            env_name = str(ctx.get(env_k) or "")
            if env_name:
                token = os.environ.get(env_name, "")
        backend = str(ctx.get(backend_k) or "auto").lower()
        return url, token, backend
    return "", "", "auto"


def run_api_probe(
    ctx: Mapping[str, object],
    install_dir: Path,
    *,
    dry_run: bool,
    ignore_probe: bool,
    non_interactive: bool,
) -> dict[str, Any] | None:
    """Phase 1.5 — probe the corporate AI gateway before generation."""
    if not _is_truthy(ctx.get("API_PROBE_ENABLED")):
        return None
    script = _script_exists("api-probe.py")
    if script is None:
        return None

    url, token, backend = _pick_probe_target(ctx)
    if not url or not token:
        print("  skip: API_PROBE_ENABLED=yes but no gateway URL/token resolved")
        return None

    cmd = [
        sys.executable, str(script),
        "--url", url,
        "--token", token,
    ]
    # Map common backend strings to api-probe's --backend choices.
    backend_map = {
        "anthropic": "anthropic",
        "openai": "openai",
        "azure": "azure",
        "vertex": "vertex",
        "litellm": "litellm",
        "bedrock": "bedrock-proxy",
        "bedrock-proxy": "bedrock-proxy",
    }
    if backend in backend_map:
        cmd.extend(["--backend", backend_map[backend]])
    model = str(
        ctx.get("CC_PRIMARY_MODEL")
        or ctx.get("CX_PRIMARY_MODEL")
        or ctx.get("LLM_PRIMARY_MODEL")
        or ""
    )
    if model:
        cmd.extend(["--model", model])

    report_path = install_dir / ".api-probe-report.json"
    if dry_run:
        print(f"[dry-run] would run api-probe and write {report_path}")
        return None

    print(f"  $ {sys.executable} {script.name} --url {url} --token *** ...")
    proc = subprocess.run(cmd, check=False, capture_output=True, text=True)
    report: dict[str, Any]
    try:
        report = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        report = {"ok": False, "error": "non-json-output", "raw": proc.stdout[-500:]}
    report["exit_code"] = proc.returncode

    install_dir.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    print(f"  probe report: {report_path}")

    if proc.returncode != 0 or not report.get("ok", False):
        err = report.get("error", f"exit={proc.returncode}")
        print(f"  WARNING: api-probe failed: {err}")
        if ignore_probe:
            print("  --ignore-probe set, continuing.")
        elif non_interactive:
            raise GenerationError(
                f"api-probe failed ({err}); rerun with --ignore-probe to bypass."
            )
        else:
            try:
                ans = input("  Continue anyway? [y/N] ").strip().lower()
            except EOFError:
                ans = ""
            if ans not in ("y", "yes"):
                raise GenerationError("aborted by operator after failed api-probe")
    return report


# ----------------------------------------------------------------------- #
# Phase 4.5 — Self-audit                                                  #
# ----------------------------------------------------------------------- #


def run_self_audit(
    ctx: Mapping[str, object],
    install_dir: Path,
    config_path: Path,
    *,
    dry_run: bool,
    strict: bool,
) -> tuple[Path | None, dict[str, Any] | None]:
    """Phase 4.5 — audit the rendered launcher; returns (report_md_path, json_report)."""
    script = _script_exists("audit-launcher.py")
    if script is None:
        return None, None

    report_md = install_dir / "audit-report.md"
    report_json = report_md.with_suffix(".json")

    cmd = [
        sys.executable, str(script),
        "--launcher-dir", str(install_dir),
        "--config", str(config_path),
        "--output", str(report_md),
    ]
    if dry_run:
        print(f"[dry-run] would run audit-launcher → {report_md}")
        return None, None

    print(f"  $ {sys.executable} {script.name} --launcher-dir {install_dir} ...")
    rc = subprocess.run(cmd, check=False).returncode

    audit_json: dict[str, Any] | None = None
    if report_json.is_file():
        try:
            audit_json = json.loads(report_json.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            audit_json = None

    if audit_json:
        failures = int(audit_json.get("failures", 0))
        p0_checks: list[str] = []
        for chk in audit_json.get("checks", []):
            severity = str(chk.get("severity", "")).upper()
            status = str(chk.get("status", "")).lower()
            if severity == "P0" and status not in ("pass", "ok"):
                p0_checks.append(str(chk.get("name", "?")))
        if p0_checks:
            print("  WARNING: P0 audit findings:")
            for n in p0_checks:
                print(f"    - {n}")
            if strict:
                raise GenerationError(
                    f"audit found {len(p0_checks)} P0 issue(s); --strict aborts generation"
                )
        if failures and strict:
            raise GenerationError(
                f"audit reported {failures} failing check(s); --strict aborts generation"
            )
    elif rc != 0:
        print(f"  warning: audit-launcher exited with code {rc}")

    print(f"  audit report: {report_md}")
    return report_md, audit_json


# ----------------------------------------------------------------------- #
# Phase 4.6 — URL purge scan                                              #
# ----------------------------------------------------------------------- #


def run_url_purge(
    ctx: Mapping[str, object],
    install_dir: Path,
    config_path: Path,
    *,
    dry_run: bool,
    strict: bool,
) -> None:
    """Phase 4.6 — scan for vendor URL leaks; optionally auto-patch."""
    script = _script_exists("url-purge.py")
    if script is None:
        return

    autopatch = _is_truthy(ctx.get("URL_PURGE_AUTOPATCH"))
    report_md = install_dir / "url-purge-report.md"

    cmd = [
        sys.executable, str(script),
        "--launcher-dir", str(install_dir),
        "--config", str(config_path),
        "--report", str(report_md),
        "--strict",
    ]
    if autopatch:
        cmd.append("--patch")
    if dry_run:
        print(f"[dry-run] would run url-purge → {report_md} (autopatch={autopatch})")
        return

    print(f"  $ {sys.executable} {script.name} --launcher-dir {install_dir} ...")
    proc = subprocess.run(cmd, check=False)
    violations = proc.returncode  # --strict returns #violations

    if violations > 0:
        print(f"  WARNING: {violations} vendor URL violation(s) found.")
        if autopatch:
            print("  URL_PURGE_AUTOPATCH=yes — violations patched in place.")
        else:
            print(
                "  Re-run with URL_PURGE_AUTOPATCH=yes (or "
                f"`python3 {script} --launcher-dir {install_dir} "
                f"--config {config_path} --patch`) to rewrite them."
            )
        if strict:
            raise GenerationError(
                f"url-purge found {violations} violation(s); --strict aborts generation"
            )


# ----------------------------------------------------------------------- #
# Phase 5.5 — Compliance .docx                                            #
# ----------------------------------------------------------------------- #


def run_compliance_docx(
    ctx: Mapping[str, object],
    install_dir: Path,
    config_path: Path,
    audit_report_md: Path | None,
    *,
    dry_run: bool,
) -> Path | None:
    """Phase 5.5 — render the compliance .docx if requested in the config."""
    if not _is_truthy(ctx.get("COMPLIANCE_DOCX")):
        return None
    script = _script_exists("build-compliance-docx.py")
    if script is None:
        return None

    out_path = install_dir / "compliance.docx"
    cmd = [
        sys.executable, str(script),
        "--config", str(config_path),
        "--launcher-dir", str(install_dir),
        "--out", str(out_path),
    ]
    # build-compliance-docx prefers the JSON sidecar if present.
    audit_json = (
        audit_report_md.with_suffix(".json")
        if audit_report_md is not None
        else install_dir / "audit-report.json"
    )
    if audit_json.is_file():
        cmd.extend(["--audit-report", str(audit_json)])

    if dry_run:
        print(f"[dry-run] would run build-compliance-docx → {out_path}")
        return None

    print(f"  $ {sys.executable} {script.name} --out {out_path} ...")
    proc = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if proc.returncode != 0:
        msg = (proc.stderr or proc.stdout or "").strip()
        if "python-docx" in msg.lower():
            print("  python-docx not installed — skipping compliance.docx.")
            print("    install with:  pip install python-docx")
        else:
            print(f"  warning: build-compliance-docx exited {proc.returncode}: {msg[:200]}")
        return None
    if proc.stdout:
        print(f"  {proc.stdout.strip()}")
    return out_path if out_path.is_file() else None


# ----------------------------------------------------------------------- #
# Phase 6 — Pixel-art banner                                              #
# ----------------------------------------------------------------------- #


def run_load_test_smoke(
    ctx: Mapping[str, object],
    install_dir: Path,
    *,
    dry_run: bool,
) -> Path | None:
    """Phase 6.5 — optional smoke load-test against the gateway.

    Off by default. When ``LOAD_TEST_ENABLED=yes`` the corporate launcher
    fires a tiny burst (``LOAD_TEST_CONCURRENCY`` workers × ``LOAD_TEST_TOTAL``
    requests) to confirm the gateway can answer under nominal load before the
    bundle is signed off for distribution.
    """
    if not _is_truthy(ctx.get("LOAD_TEST_ENABLED")):
        return None
    script = _script_exists("load-test.py")
    if script is None:
        return None
    url_keys = ("CC_PRIMARY_URL", "CX_PRIMARY_URL", "LLM_OPENAI_BASE_URL")
    url = next((str(ctx.get(k)) for k in url_keys if ctx.get(k)), "")
    if not url:
        print("  skip: LOAD_TEST_ENABLED=yes but no gateway URL resolved")
        return None
    concurrency = str(ctx.get("LOAD_TEST_CONCURRENCY") or "2")
    total = str(ctx.get("LOAD_TEST_TOTAL") or "10")
    out_path = install_dir / "load-test-report.json"
    cmd = [
        sys.executable, str(script),
        "--url", url,
        "--concurrency", concurrency,
        "--total", total,
        "--out", str(out_path),
    ]
    if dry_run:
        print(f"[dry-run] would run load-test → {out_path}")
        return None
    print(f"  $ {sys.executable} {script.name} --url {url} -c {concurrency} -n {total}")
    subprocess.run(cmd, check=False)
    return out_path if out_path.is_file() else None


def emit_review_gates(ctx: Mapping[str, object]) -> None:
    """Echo cyber/DPO review obligations recorded in the config.

    These flags drive *external* workflow (ticketing, governance docs) and
    do not change the rendered launcher, but they MUST be surfaced so the
    operator can attach the right approval before distribution.
    """
    if _is_truthy(ctx.get("CYBER_REVIEW_REQUIRED")):
        authority = str(ctx.get("CYBER_AUTHORITY") or "Corporate cybersecurity")
        print(f"  REMINDER: cyber review required by {authority} before distribution.")
    if _is_truthy(ctx.get("DPO_REVIEW_REQUIRED")):
        dpo = str(ctx.get("CORP_DPO_CONTACT") or "Data Protection Officer")
        print(f"  REMINDER: DPO sign-off required ({dpo}).")


def run_pixel_art_banner(
    ctx: Mapping[str, object],
    install_dir: Path,
    *,
    dry_run: bool,
) -> Path | None:
    """Phase 6 — render an ASCII banner.txt read by launcher.sh's show_banner."""
    if not _is_truthy(ctx.get("BANNER_GENERATE")):
        return None
    script = _script_exists("pixel-art-logo.py")
    if script is None:
        return None

    text = str(ctx.get("CORP_NAME") or ctx.get("CORP_SLUG") or "")
    if not text:
        print("  skip: BANNER_GENERATE=yes but no CORP_NAME/CORP_SLUG to render")
        return None

    style = str(ctx.get("BANNER_STYLE") or "auto")
    color = str(ctx.get("BANNER_COLOR_PRIMARY") or "")
    out_path = install_dir / "banner.txt"
    cmd = [
        sys.executable, str(script),
        "--text", text,
        "--style", style,
        "--out", str(out_path),
    ]
    if color:
        cmd.extend(["--color", color])

    if dry_run:
        print(f"[dry-run] would render pixel-art banner → {out_path}")
        return None

    print(f"  $ {sys.executable} {script.name} --text {text!r} --style {style} ...")
    rc = subprocess.run(cmd, check=False).returncode
    if rc != 0 or not out_path.is_file():
        print(f"  warning: pixel-art-logo exited {rc}; no banner.txt written")
        return None
    print(f"  banner: {out_path}")
    return out_path


# ----------------------------------------------------------------------- #
# Summary                                                                 #
# ----------------------------------------------------------------------- #


def print_summary(
    ctx: Mapping[str, object],
    install_dir: Path,
    dist_dir: Path | None,
    *,
    dry_run: bool,
) -> None:
    """Print the post-generation cheat sheet."""
    slug = str(ctx.get("CORP_SLUG"))
    bar = "=" * 60
    print()
    print(bar)
    print(f"  {ctx.get('CORP_NAME')} — generation {'PLAN' if dry_run else 'COMPLETE'}")
    print(bar)
    print(f"  Install dir : {install_dir}")
    print(f"  Launcher    : {install_dir / slug}")
    print(f"  Launch with : {slug}  (after PATH refresh)")
    if dist_dir:
        mode = ctx.get("DIST_MODE")
        target = (
            ctx.get("DIST_REPO_URL")
            or ctx.get("DIST_ONELINER_HOST")
            or ctx.get("DIST_REGISTRY_URL")
            or "(local)"
        )
        print(f"  Dist mode   : {mode}")
        print(f"  Dist target : {target}")
        print(f"  Dist dir    : {dist_dir}")
    print(bar)
    if dry_run:
        print("  Dry run — no files were written.")
    print("\n  Proudly made from France with ❤️\n")


# ----------------------------------------------------------------------- #
# main                                                                    #
# ----------------------------------------------------------------------- #


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--config", required=True, type=Path, help="JSON config file (interview answers)")
    p.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Override INSTALL_DIR from the config",
    )
    p.add_argument(
        "--dist-dir",
        type=Path,
        default=None,
        help="Override the dist/ directory (default: <out>/dist)",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print every action but write no files and run no subprocesses",
    )
    p.add_argument(
        "--skip-validate",
        action="store_true",
        help="Skip the config validation rules (use with care)",
    )
    p.add_argument(
        "--ignore-probe",
        action="store_true",
        help="Continue generation even if the api-probe phase fails",
    )
    p.add_argument(
        "--non-interactive",
        action="store_true",
        help="Never prompt; treat any prompt as a refusal (CI-friendly)",
    )
    p.add_argument(
        "--strict",
        action="store_true",
        help="Abort if the self-audit or url-purge phases report issues",
    )
    p.add_argument(
        "--legal-reviewed",
        type=str,
        default=None,
        metavar="YYYY-MM-DD",
        help="ISO date of internal legal review (required for ambiguous configurations)",
    )
    p.add_argument(
        "--legal-reviewer",
        type=str,
        default=None,
        metavar='"Name <email>"',
        help="Reviewer identity recorded in the attestation log",
    )
    p.add_argument(
        "--legal-override",
        type=str,
        default=None,
        metavar='"reason"',
        help="Documented exception that bypasses a forbidden legal verdict (rare)",
    )
    args = p.parse_args(argv)

    # Propagate the skill root to every subprocess we spawn so companion
    # scripts (api-probe, dev-rules-installer, audit-launcher, ...) can
    # resolve their own siblings via ``${CLAUDE_SKILL_DIR}/scripts/...``.
    os.environ["CLAUDE_SKILL_DIR"] = str(_skill_dir())

    if not args.config.is_file():
        print(f"ERROR: config not found: {args.config}", file=sys.stderr)
        return 2

    try:
        ctx: dict[str, Any] = load_context(args.config)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON in {args.config}: {e}", file=sys.stderr)
        return 2

    if not args.skip_validate:
        errs = validate_config(ctx)
        if errs:
            print("Config validation failed:", file=sys.stderr)
            for e in errs:
                print(f"  - {e}", file=sys.stderr)
            return 2

    install_dir = resolve_install_dir(ctx, args.out)
    dist_dir = (
        args.dist_dir.expanduser().resolve()
        if args.dist_dir
        else install_dir / "dist"
    )

    # Dynamic, render-time defaults the templates expect.
    import datetime as _dt
    _now = _dt.datetime.now(_dt.timezone.utc)
    ctx.setdefault("DIST_GENERATED_AT", _now.strftime("%Y-%m-%dT%H:%M:%SZ"))
    ctx.setdefault("DIST_YEAR", str(_now.year))

    print(f"Generating launcher for {ctx.get('CORP_NAME')!r} (slug={ctx.get('CORP_SLUG')!r})")
    print(f"  install_dir = {install_dir}")
    print(f"  dist_dir    = {dist_dir}")
    print(f"  dry_run     = {args.dry_run}")

    try:
        config_path = args.config.resolve()

        print("\n[1.4] Legal compliance check ...")
        run_legal_check(
            ctx, install_dir,
            legal_reviewed=args.legal_reviewed,
            legal_reviewer=args.legal_reviewer,
            legal_override=args.legal_override,
            dry_run=args.dry_run,
        )

        print("\n[1.5] Probing corporate AI gateway ...")
        run_api_probe(
            ctx, install_dir,
            dry_run=args.dry_run,
            ignore_probe=args.ignore_probe,
            non_interactive=args.non_interactive,
        )

        # Phase 1.6 — optional smoke load test (off by default).
        print("\n[1.6] Smoke load-test (if enabled) ...")
        run_load_test_smoke(ctx, install_dir, dry_run=args.dry_run)

        print("\n[2] Rendering launcher tree ...")
        render_clis(ctx, install_dir, dry_run=args.dry_run)

        print("\n[2.5] Injecting corporate dev rules ...")
        run_dev_rules(ctx, install_dir, config_path, dry_run=args.dry_run)

        print("\n[3] Rendering shared modules (skills + MCP) ...")
        run_skills_installer(ctx, install_dir, dry_run=args.dry_run)
        run_mcp_installer(ctx, install_dir, dry_run=args.dry_run)

        print("\n[3.5] Self-auditing rendered launcher ...")
        if _is_truthy(ctx.get("SELF_AUDIT_ENABLED", "yes")):
            audit_md, _audit_json = run_self_audit(
                ctx, install_dir, config_path,
                dry_run=args.dry_run, strict=args.strict,
            )
        else:
            print("  skip: SELF_AUDIT_ENABLED=no")
            audit_md, _audit_json = None, None

        print("\n[3.6] Scanning for vendor URL leaks ...")
        run_url_purge(
            ctx, install_dir, config_path,
            dry_run=args.dry_run, strict=args.strict,
        )

        print("\n[3.7] Generating pixel-art banner ...")
        run_pixel_art_banner(ctx, install_dir, dry_run=args.dry_run)

        print("\n[4] Rendering distribution artefacts ...")
        produced_dist = render_distribution(ctx, install_dir, dist_dir, dry_run=args.dry_run)

        print("\n[4.5] Building compliance .docx (if requested) ...")
        run_compliance_docx(
            ctx, install_dir, config_path, audit_md,
            dry_run=args.dry_run,
        )

        # External review reminders (cyber / DPO) — pure stdout side effect.
        emit_review_gates(ctx)

    except UnresolvedVariable as e:
        print(f"ERROR: template references an undefined variable: {e}", file=sys.stderr)
        return 3
    except GenerationError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 4
    except FileNotFoundError as e:
        print(f"ERROR: missing file or directory: {e}", file=sys.stderr)
        return 5

    print("\n[5] Post-install summary ...")
    print_summary(ctx, install_dir, produced_dist, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
