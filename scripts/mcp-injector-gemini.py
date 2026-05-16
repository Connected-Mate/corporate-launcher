#!/usr/bin/env python3
"""Inject MCP server declarations into a Gemini CLI ``settings.json``.

Reads a JSON array of MCP server definitions (``--servers``) and merges them
into the target settings file (``--settings``) following the Gemini CLI schema
documented at https://google-gemini.github.io/gemini-cli and
https://geminicli.com/docs/tools/mcp-server/ .

For each server entry the script will:

1. Load the existing ``settings.json`` (defaulting to ``{}`` when absent).
2. Write the server config under ``settings["mcpServers"][<name>]`` using the
   correct transport keys:

   - **stdio**   -> ``command``, ``args``, ``env``, ``cwd``
   - **http**    -> ``httpUrl``, ``headers``
   - **sse**     -> ``url``, ``headers``

3. Append ``<name>`` to ``settings["mcp"]["allowed"]`` (the user allowlist).
4. If ``settings["admin"]["mcp"]["requiredConfig"]`` exists (org-enforced
   servers), append ``<name>`` to it as well.
5. Atomically write the result via a temp file + ``os.replace``.
6. Warn (stderr) when an alias does not match Gemini's recommended kebab-case
   convention (``^[a-z][a-z0-9-]*$``).

Server entry schema (input)::

    {
      "name": "code-review-graph",            # required
      "transport": "stdio" | "http" | "sse",  # required
      "command": "node",                       # stdio
      "args": ["server.js"],                   # stdio
      "env": {"FOO": "bar"},                  # stdio (optional)
      "cwd": "/opt/mcp",                      # stdio (optional)
      "httpUrl": "https://...",               # http
      "url": "https://.../sse",               # sse
      "headers": {"Authorization": "Bearer …"}, # http/sse (optional)
      "timeout": 30000,                        # optional (ms)
      "trust": false                           # optional
    }

Usage::

    python3 mcp-injector-gemini.py \\
        --settings ~/.gemini/settings.json \\
        --servers '[{"name":"code-review-graph","transport":"stdio",...}]'

    # or read servers from a file
    python3 mcp-injector-gemini.py \\
        --settings ~/.gemini/settings.json \\
        --servers-file servers.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

# Gemini CLI MCP alias convention: lowercase kebab-case, must start with letter.
ALIAS_RE = re.compile(r"^[a-z][a-z0-9-]*$")

VALID_TRANSPORTS = {"stdio", "http", "sse"}

# Optional pass-through keys allowed on every server entry.
COMMON_OPTIONAL_KEYS = ("timeout", "trust", "description", "includeTools", "excludeTools")


def _load_settings(path: Path) -> dict[str, Any]:
    """Load the settings file; return ``{}`` if missing or empty."""
    if not path.exists():
        return {}
    raw = path.read_text(encoding="utf-8").strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"ERROR: {path} is not valid JSON: {exc}") from None
    if not isinstance(data, dict):
        raise SystemExit(f"ERROR: {path} top-level must be a JSON object")
    return data


def _parse_servers(raw: str) -> list[dict[str, Any]]:
    """Parse the --servers JSON payload into a list of dict entries."""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"ERROR: --servers is not valid JSON: {exc}") from None
    if not isinstance(data, list):
        raise SystemExit("ERROR: --servers must be a JSON array")
    for i, item in enumerate(data):
        if not isinstance(item, dict):
            raise SystemExit(f"ERROR: --servers[{i}] must be a JSON object")
    return data


def _build_server_block(entry: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """Map an input entry to (name, gemini-schema block).

    Raises SystemExit on schema violations.
    """
    name = entry.get("name")
    if not name or not isinstance(name, str):
        raise SystemExit(f"ERROR: server entry missing 'name': {entry!r}")

    transport = (entry.get("transport") or "stdio").lower()
    if transport not in VALID_TRANSPORTS:
        raise SystemExit(
            f"ERROR: server '{name}' has invalid transport={transport!r} "
            f"(expected one of {sorted(VALID_TRANSPORTS)})"
        )

    block: dict[str, Any] = {}

    if transport == "stdio":
        command = entry.get("command")
        if not command:
            raise SystemExit(f"ERROR: stdio server '{name}' missing 'command'")
        block["command"] = command
        if "args" in entry and entry["args"]:
            if not isinstance(entry["args"], list):
                raise SystemExit(f"ERROR: '{name}'.args must be a list")
            block["args"] = list(entry["args"])
        if "env" in entry and entry["env"]:
            if not isinstance(entry["env"], dict):
                raise SystemExit(f"ERROR: '{name}'.env must be an object")
            block["env"] = dict(entry["env"])
        if "cwd" in entry and entry["cwd"]:
            block["cwd"] = entry["cwd"]

    elif transport == "http":
        http_url = entry.get("httpUrl") or entry.get("url")
        if not http_url:
            raise SystemExit(f"ERROR: http server '{name}' missing 'httpUrl'")
        block["httpUrl"] = http_url
        if "headers" in entry and entry["headers"]:
            if not isinstance(entry["headers"], dict):
                raise SystemExit(f"ERROR: '{name}'.headers must be an object")
            block["headers"] = dict(entry["headers"])

    else:  # sse
        url = entry.get("url") or entry.get("httpUrl")
        if not url:
            raise SystemExit(f"ERROR: sse server '{name}' missing 'url'")
        block["url"] = url
        if "headers" in entry and entry["headers"]:
            if not isinstance(entry["headers"], dict):
                raise SystemExit(f"ERROR: '{name}'.headers must be an object")
            block["headers"] = dict(entry["headers"])

    # Optional pass-through keys recognised by Gemini CLI.
    for key in COMMON_OPTIONAL_KEYS:
        if key in entry and entry[key] is not None:
            block[key] = entry[key]

    return name, block


def _ensure_in_list(container: dict[str, Any], path: tuple[str, ...], value: str) -> None:
    """Ensure ``value`` is present in the list at ``container[path[0]][path[1]]...``.

    Creates intermediate dicts as needed. Does nothing if the leaf already
    contains the value. Leaves a non-list leaf untouched (defensive: we never
    overwrite an unexpected shape silently — we raise).
    """
    node: Any = container
    for key in path[:-1]:
        if key not in node or not isinstance(node[key], dict):
            node[key] = {}
        node = node[key]
    leaf = path[-1]
    current = node.get(leaf)
    if current is None:
        node[leaf] = [value]
        return
    if not isinstance(current, list):
        raise SystemExit(
            f"ERROR: settings path {'.'.join(path)} expected to be a list, "
            f"got {type(current).__name__}"
        )
    if value not in current:
        current.append(value)


def _atomic_write(path: Path, data: dict[str, Any]) -> None:
    """Write ``data`` to ``path`` atomically via tmp file + rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    # NamedTemporaryFile in the same dir guarantees rename is atomic on POSIX.
    fd, tmp_name = tempfile.mkstemp(
        prefix=".settings.", suffix=".json.tmp", dir=str(path.parent)
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
        # Preserve mode of an existing file (default 0600 for new ones, settings
        # may contain secrets via env-injected tokens).
        if path.exists():
            os.chmod(tmp_name, os.stat(path).st_mode)
        else:
            os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    except Exception:
        # Best-effort cleanup if rename failed.
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def inject(
    settings_path: Path,
    servers: list[dict[str, Any]],
    *,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Merge ``servers`` into ``settings_path`` and return the resulting dict."""
    settings = _load_settings(settings_path)

    if "mcpServers" not in settings or not isinstance(settings["mcpServers"], dict):
        settings["mcpServers"] = {}

    has_admin_required = (
        isinstance(settings.get("admin"), dict)
        and isinstance(settings["admin"].get("mcp"), dict)
        and "requiredConfig" in settings["admin"]["mcp"]
    )

    for entry in servers:
        name, block = _build_server_block(entry)

        if not ALIAS_RE.match(name):
            print(
                f"warning: MCP alias {name!r} does not match Gemini's kebab-case "
                f"convention (^[a-z][a-z0-9-]*$); CLI may reject it.",
                file=sys.stderr,
            )

        settings["mcpServers"][name] = block
        _ensure_in_list(settings, ("mcp", "allowed"), name)
        if has_admin_required:
            _ensure_in_list(settings, ("admin", "mcp", "requiredConfig"), name)

        print(f"injected: {name} ({entry.get('transport', 'stdio')})", file=sys.stderr)

    if not dry_run:
        _atomic_write(settings_path, settings)
        print(f"wrote: {settings_path}", file=sys.stderr)
    else:
        print("(dry-run: settings.json not written)", file=sys.stderr)

    return settings


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Inject MCP servers into a Gemini CLI settings.json",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--settings",
        required=True,
        type=Path,
        help="Path to settings.json (e.g. ~/.gemini/settings.json)",
    )
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument(
        "--servers",
        help="JSON array of server entries (see module docstring)",
    )
    g.add_argument(
        "--servers-file",
        type=Path,
        help="Path to a JSON file containing the server array",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the resulting JSON to stdout without touching disk",
    )
    args = p.parse_args(argv)

    settings_path = args.settings.expanduser().resolve()

    if args.servers_file:
        servers_raw = args.servers_file.expanduser().read_text(encoding="utf-8")
    else:
        servers_raw = args.servers

    servers = _parse_servers(servers_raw)
    if not servers:
        print("warning: no servers provided; nothing to do", file=sys.stderr)
        return 0

    result = inject(settings_path, servers, dry_run=args.dry_run)

    if args.dry_run:
        json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
