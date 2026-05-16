#!/usr/bin/env python3
"""Corporate Launcher — end-to-end generation orchestrator.

This is the master entry point called by the skill at the end of the
interview. It takes the answers collected from the interview (a JSON
config file) and produces the full launcher tree on disk, plus any
distribution artefacts the creator asked for.

Pipeline:
    1. Load and validate the config file (``${VAR}`` schema, see
       ``references/interview-flow.md`` for the validation rules).
    2. For each CLI in ``WRAPPED_CLIS`` render
       ``templates/<cli>/`` and ``templates/shared/`` into
       ``INSTALL_DIR`` (and ``INSTALL_DIR/scripts/`` for shared bits).
    3. If ``SKILLS_MODE != none`` invoke ``scripts/skills-installer.py``
       with a derived skills config.
    4. If ``MCP_SERVERS`` is non-empty invoke ``scripts/mcp-installer.py``
       once per wrapped CLI.
    5. If ``DIST_MODE != none`` render ``templates/dist/<mode>/``
       into ``dist/``.
    6. For ``public-git`` / ``private-git`` run the rendered
       ``scaffold.sh`` (if any) to push the repo.
    7. For ``tarball`` run the rendered ``build.sh``.
    8. For ``oneliner`` write ``install.sh`` + ``install.sh.sha256``.
    9. Print a final summary (launcher path, launch command,
       distribution artefact URL or path).

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
    print()


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
        help="Override the dist/ directory (default: <out>/../dist)",
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
    args = p.parse_args(argv)

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
        print("\n[1/4] Rendering CLI templates ...")
        render_clis(ctx, install_dir, dry_run=args.dry_run)

        print("\n[2/4] Installing skills bundle ...")
        run_skills_installer(ctx, install_dir, dry_run=args.dry_run)

        print("\n[3/4] Configuring MCP servers ...")
        run_mcp_installer(ctx, install_dir, dry_run=args.dry_run)

        print("\n[4/4] Rendering distribution artefacts ...")
        produced_dist = render_distribution(ctx, install_dir, dist_dir, dry_run=args.dry_run)

    except UnresolvedVariable as e:
        print(f"ERROR: template references an undefined variable: {e}", file=sys.stderr)
        return 3
    except GenerationError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 4
    except FileNotFoundError as e:
        print(f"ERROR: missing file or directory: {e}", file=sys.stderr)
        return 5

    print_summary(ctx, install_dir, produced_dist, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
