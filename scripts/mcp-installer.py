#!/usr/bin/env python3
"""MCP server installer dispatcher for Corporate Launcher.

Reads a list of MCP server descriptors and dispatches to the per-CLI injector
that knows how to write them into the CLI's native config format
(``settings.json`` for Claude Code, ``config.toml`` for Codex CLI, etc.).

Called from a generated ``install.sh`` once the launcher is in place::

    python3 mcp-installer.py --cli claude-code \\
        --servers '[{"name":"jira","url":"https://mcp.acme/jira"}]'

Per-CLI logic lives in sibling modules named ``mcp-injector-<cli>.py`` (one of
``claude-code``, ``codex-cli``, ``gemini-cli``, ``aider``, ``opencode``). This
script is a thin wrapper: it validates input, dispatches, prints the aider
limitation banner when relevant, aggregates exit codes, and emits a final
``Configured N MCP servers for <cli>`` summary line.

Server descriptor schema (per ``references/skills-bundle.md``)::

    {
        "name":    "jira",                                   # required
        "url":     "https://mcp.acme.internal/jira",         # required
        "headers": {"Authorization": "Bearer ${env:TOKEN}"}, # optional
        "trust":   false                                     # optional, default false
    }
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType

# Set via --settings on the CLI; honoured by dispatch_via_module for
# claude-code. Avoids touching ~/.claude/settings.json by default.
_MCP_SETTINGS_OVERRIDE: Path | None = None

SUPPORTED_CLIS = ("claude-code", "codex-cli", "gemini-cli", "aider", "opencode")
# Map the public CLI name (used on the --cli flag and in DOG configs) to the
# short module suffix used by the sibling injector files. The names diverge
# because injectors are vendor-grouped (claude-code → mcp-injector-claude.py).
CLI_INJECTOR_MAP = {
    "claude-code": "claude",
    "codex-cli":   "codex",
    "gemini-cli":  "gemini",
    "aider":       "aider",
    "opencode":    "opencode",
}
REQUIRED_FIELDS = ("name", "url")
HERE = Path(__file__).resolve().parent
AIDER_NOTE = HERE.parent / "reference" / "mcp-aider-note.md"


def validate_servers(raw: object) -> list[dict]:
    """Parse and sanity-check the --servers JSON payload."""
    if not isinstance(raw, list):
        raise ValueError("--servers must be a JSON array")
    out: list[dict] = []
    for i, entry in enumerate(raw):
        if not isinstance(entry, dict):
            raise ValueError(f"server[{i}] is not an object")
        for field in REQUIRED_FIELDS:
            if field not in entry or not entry[field]:
                raise ValueError(f"server[{i}] missing required field: {field!r}")
        entry.setdefault("trust", False)
        entry.setdefault("headers", {})
        if not isinstance(entry["headers"], dict):
            raise ValueError(f"server[{i}].headers must be an object")
        out.append(entry)
    return out


def load_injector(cli: str) -> ModuleType | None:
    """Import the sibling ``mcp-injector-<cli>.py`` module, or return None."""
    suffix = CLI_INJECTOR_MAP.get(cli, cli)
    path = HERE / f"mcp-injector-{suffix}.py"
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location(f"mcp_injector_{suffix.replace('-', '_')}", path)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def print_aider_warning() -> None:
    """Emit the aider MCP limitation banner from the reference note."""
    banner = (
        "----------------------------------------------------------------\n"
        "  WARNING: Aider has no native MCP support (as of May 2026).\n"
        "  MCP servers will be installed as documentation only;\n"
        "  the aider CLI itself will not consume them.\n"
    )
    if AIDER_NOTE.is_file():
        banner += f"  See: {AIDER_NOTE}\n"
    banner += "----------------------------------------------------------------"
    print(banner, file=sys.stderr)


def dispatch_via_module(module: ModuleType, servers: list[dict], cli: str) -> int:
    """Call ``module.install(servers)`` and return its int exit code.

    If the injector exposes no ``install`` entry point but does expose
    ``main(argv)``, fall back to invoking it the way a subprocess would —
    this matches the CLI shape used by the per-CLI scripts.
    """
    if hasattr(module, "install"):
        try:
            result = module.install(servers)
        except Exception as e:  # noqa: BLE001 — surface any injector failure
            print(f"ERROR: injector for {cli!r} raised: {e}", file=sys.stderr)
            return 5
        return int(result) if result is not None else 0
    if hasattr(module, "main"):
        # In-process equivalent of the subprocess fallback. Each injector
        # accepts at least --servers; for claude-code we also need --settings.
        argv: list[str] = ["--servers", json.dumps(servers)]
        if cli == "claude-code":
            # Prefer an explicit --settings override (set by the orchestrator);
            # otherwise write inside the launcher install dir, never the
            # operator's personal ~/.claude/settings.json.
            settings = _MCP_SETTINGS_OVERRIDE or (
                Path(os.environ.get("CORP_LAUNCHER_INSTALL_DIR", "."))
                / "settings.json"
            )
            argv.extend(["--settings", str(settings)])
        try:
            result = module.main(argv)
        except SystemExit as e:
            return int(e.code or 0)
        except Exception as e:  # noqa: BLE001
            print(f"ERROR: injector for {cli!r} raised: {e}", file=sys.stderr)
            return 5
        return int(result) if result is not None else 0
    print(
        f"ERROR: injector for {cli!r} has no install(servers) entry point",
        file=sys.stderr,
    )
    return 4


def dispatch_via_subprocess(cli: str, servers: list[dict]) -> int:
    """Fallback: invoke ``mcp-injector-<cli>.py`` as a subprocess."""
    suffix = CLI_INJECTOR_MAP.get(cli, cli)
    path = HERE / f"mcp-injector-{suffix}.py"
    if not path.is_file():
        print(
            f"ERROR: no MCP injector found for {cli!r} (expected {path})",
            file=sys.stderr,
        )
        return 6
    proc = subprocess.run(
        [sys.executable, str(path), "--servers", json.dumps(servers)],
        check=False,
    )
    return proc.returncode


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--cli",
        required=True,
        choices=SUPPORTED_CLIS,
        help="Target CLI to configure",
    )
    p.add_argument(
        "--servers",
        required=True,
        help="JSON array of MCP server descriptors",
    )
    p.add_argument(
        "--mode",
        choices=("import", "subprocess"),
        default="import",
        help="How to invoke the per-CLI injector (default: import)",
    )
    p.add_argument(
        "--settings",
        type=Path,
        default=None,
        help="Path to the CLI settings file to write (claude-code only). "
             "If omitted, defaults to <install_dir>/settings.json — never "
             "to ~/.claude/settings.json.",
    )
    args = p.parse_args(argv)
    global _MCP_SETTINGS_OVERRIDE
    _MCP_SETTINGS_OVERRIDE = args.settings.expanduser().resolve() if args.settings else None

    try:
        servers = validate_servers(json.loads(args.servers))
    except json.JSONDecodeError as e:
        print(f"ERROR: --servers is not valid JSON: {e}", file=sys.stderr)
        return 2
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if not servers:
        print(f"Configured 0 MCP servers for {args.cli}")
        return 0

    # Aider has no native MCP support — warn before doing anything else.
    if args.cli == "aider":
        print_aider_warning()

    # Dispatch.
    if args.mode == "import":
        module = load_injector(args.cli)
        if module is None:
            print(
                f"ERROR: no MCP injector module for {args.cli!r} "
                f"(expected {HERE / f'mcp-injector-{args.cli}.py'})",
                file=sys.stderr,
            )
            return 6
        rc = dispatch_via_module(module, servers, args.cli)
    else:
        rc = dispatch_via_subprocess(args.cli, servers)

    if rc != 0:
        print(
            f"ERROR: MCP injection failed for {args.cli} (exit {rc})",
            file=sys.stderr,
        )
        return rc

    print(f"Configured {len(servers)} MCP servers for {args.cli}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
