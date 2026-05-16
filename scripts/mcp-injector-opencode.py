#!/usr/bin/env python3
"""MCP server injector for opencode opencode.json.

Merges a list of MCP server definitions into an existing opencode config
(https://opencode.ai/docs/mcp-servers/), preserving unrelated keys.

opencode schema (verified 2026-05-16 via https://opencode.ai/docs/mcp-servers/):

    {
      "$schema": "https://opencode.ai/config.json",
      "mcp": {
        "<name>": {
          "type": "local",                    # required
          "command": ["npx", "-y", "pkg"],    # required (array of strings)
          "environment": {"K": "V"},          # optional
          "enabled": true,                    # optional
          "timeout": 5000                     # optional
        },
        "<name>": {
          "type": "remote",                   # required
          "url": "https://...",               # required
          "headers": {"Authorization": "..."},# optional
          "enabled": true,                    # optional
          "timeout": 5000                     # optional
        }
      }
    }

Note: opencode uses a single "command" array (command + args combined),
unlike Claude Code which splits command/args. We concatenate accordingly.

Input servers are a JSON array of objects (same shape as the Claude Code
injector for consistency across launchers):

    [
        {"name": "fs", "command": "npx",
         "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
         "transport": "stdio",
         "env": {"FOO": "bar"}},
        {"name": "jira", "url": "https://mcp.acme/jira",
         "headers": {"Authorization": "Bearer {env:MCP_TOKEN}"},
         "transport": "http"}
    ]

Transport mapping:
    - stdio              -> opencode "local"
    - http, sse, remote  -> opencode "remote"

Transport is inferred when absent:
    - `command` present  -> stdio
    - `url` present      -> http (treated as remote)

Usage:
    mcp-injector-opencode.py --config ~/.config/opencode/opencode.json \\
        --servers '[{"name":"jira","url":"https://..."}]'
    cat servers.json | mcp-injector-opencode.py --config ~/.config/opencode/opencode.json

Exit codes:
    0  success
    2  schema / validation error in --servers payload
    3  file I/O error (config unreadable, atomic rename failed, etc.)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any

NAME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_-]{0,63}$")
VALID_TRANSPORTS = {"stdio", "http", "sse", "remote"}
REMOTE_TRANSPORTS = {"http", "sse", "remote"}


class SchemaError(ValueError):
    """Raised when the MCP_SERVERS payload does not match the expected schema."""


def load_config(path: Path) -> dict[str, Any]:
    """Load an existing opencode.json or return an empty dict if missing."""
    if not path.exists():
        return {}
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise OSError(f"cannot read config file {path}: {exc}") from exc
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise OSError(f"config file {path} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise OSError(f"config file {path} must contain a JSON object at top level")
    return data


def parse_servers(payload: str) -> list[dict[str, Any]]:
    """Parse and validate the --servers JSON array."""
    try:
        data = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise SchemaError(f"servers payload is not valid JSON: {exc}") from exc
    if not isinstance(data, list):
        raise SchemaError("servers payload must be a JSON array")
    out: list[dict[str, Any]] = []
    for idx, item in enumerate(data):
        if not isinstance(item, dict):
            raise SchemaError(f"server #{idx} must be a JSON object")
        out.append(validate_server(item, idx))
    names = [s["name"] for s in out]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        raise SchemaError(f"duplicate server name(s): {sorted(dupes)}")
    return out


def validate_server(item: dict[str, Any], idx: int) -> dict[str, Any]:
    """Validate a single server entry and infer transport if absent."""
    name = item.get("name")
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise SchemaError(
            f"server #{idx}: 'name' must match {NAME_RE.pattern!r} (got {name!r})"
        )

    transport = item.get("transport")
    has_command = "command" in item
    has_url = "url" in item

    if transport is None:
        if has_command:
            transport = "stdio"
        elif has_url:
            transport = "http"
        else:
            raise SchemaError(
                f"server {name!r}: must define either 'command' (stdio) or 'url' (remote)"
            )
    if transport not in VALID_TRANSPORTS:
        raise SchemaError(
            f"server {name!r}: transport must be one of {sorted(VALID_TRANSPORTS)} "
            f"(got {transport!r})"
        )

    if transport == "stdio":
        command = item.get("command")
        if not isinstance(command, str) or not command:
            raise SchemaError(
                f"server {name!r}: stdio transport requires a non-empty 'command'"
            )
        args = item.get("args", [])
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            raise SchemaError(f"server {name!r}: 'args' must be a list of strings")
        env = item.get("env", {})
        if not isinstance(env, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in env.items()
        ):
            raise SchemaError(f"server {name!r}: 'env' must be an object of string->string")
    else:
        url = item.get("url")
        if not isinstance(url, str) or not url.startswith(("http://", "https://")):
            raise SchemaError(
                f"server {name!r}: {transport} transport requires an http(s) 'url'"
            )
        headers = item.get("headers", {})
        if not isinstance(headers, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in headers.items()
        ):
            raise SchemaError(f"server {name!r}: 'headers' must be an object of string->string")

    enabled = item.get("enabled", True)
    if not isinstance(enabled, bool):
        raise SchemaError(f"server {name!r}: 'enabled' must be a boolean")

    timeout = item.get("timeout")
    if timeout is not None and (not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0):
        raise SchemaError(f"server {name!r}: 'timeout' must be a positive integer (ms)")

    item["transport"] = transport
    item["enabled"] = enabled
    return item


def build_server_entry(server: dict[str, Any]) -> dict[str, Any]:
    """Translate a validated server dict into an opencode mcp entry."""
    transport = server["transport"]
    entry: dict[str, Any] = {}

    if transport == "stdio":
        entry["type"] = "local"
        # opencode expects a single "command" array combining command + args.
        cmd: list[str] = [server["command"]]
        if server.get("args"):
            cmd.extend(server["args"])
        entry["command"] = cmd
        if server.get("env"):
            entry["environment"] = dict(server["env"])
    else:
        entry["type"] = "remote"
        entry["url"] = server["url"]
        if server.get("headers"):
            entry["headers"] = dict(server["headers"])

    entry["enabled"] = server["enabled"]
    if server.get("timeout") is not None:
        entry["timeout"] = server["timeout"]

    return entry


def merge(config: dict[str, Any], servers: list[dict[str, Any]]) -> dict[str, Any]:
    """Merge server entries into opencode config, preserving unrelated keys."""
    mcp = config.get("mcp")
    if not isinstance(mcp, dict):
        mcp = {}

    for srv in servers:
        mcp[srv["name"]] = build_server_entry(srv)

    config["mcp"] = mcp
    return config


def atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    """Write JSON atomically: serialize, validate, write tmp, fsync, rename, chmod 600."""
    serialized = json.dumps(data, indent=2, sort_keys=False, ensure_ascii=False)
    json.loads(serialized)  # defensive round-trip

    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=str(path.parent),
    )
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(serialized)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_path, stat.S_IRUSR | stat.S_IWUSR)  # 0600
        os.replace(tmp_path, path)
    except OSError:
        try:
            tmp_path.unlink()
        except OSError:
            pass
        raise


def read_servers_arg(arg_value: str | None) -> str:
    """Return raw servers payload from the argument or stdin."""
    if arg_value is not None:
        return arg_value
    if sys.stdin.isatty():
        raise SchemaError("no --servers provided and stdin is a TTY")
    data = sys.stdin.read()
    if not data.strip():
        raise SchemaError("no --servers provided and stdin is empty")
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Inject MCP servers into an opencode opencode.json.",
    )
    parser.add_argument(
        "--config",
        required=True,
        type=Path,
        help="Path to the target opencode.json (created if missing).",
    )
    parser.add_argument(
        "--servers",
        default=None,
        help="JSON array of MCP server definitions; read from stdin if omitted.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the merged config to stdout without writing.",
    )
    args = parser.parse_args(argv)

    config_path: Path = args.config.expanduser()

    try:
        payload = read_servers_arg(args.servers)
        servers = parse_servers(payload)
    except SchemaError as exc:
        print(f"ERROR (schema): {exc}", file=sys.stderr)
        return 2

    try:
        config = load_config(config_path)
    except OSError as exc:
        print(f"ERROR (file): {exc}", file=sys.stderr)
        return 3

    merged = merge(config, servers)

    if args.dry_run:
        json.dump(merged, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    try:
        atomic_write_json(config_path, merged)
    except OSError as exc:
        print(f"ERROR (file): {exc}", file=sys.stderr)
        return 3

    print(
        f"injected {len(servers)} MCP server(s) into {config_path}: "
        + ", ".join(s["name"] for s in servers)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
