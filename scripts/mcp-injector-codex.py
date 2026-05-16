#!/usr/bin/env python3
"""MCP server injector for Codex CLI (~/.codex/config.toml).

Reads a JSON array of MCP server definitions and merges them into Codex CLI's
TOML config file. Each server becomes a `[mcp_servers.<name>]` section.

Supports three MCP transports per the Codex CLI advanced config docs
(https://developers.openai.com/codex/config-advanced):

  - stdio: { "name": "...", "command": "/path/bin", "args": [...], "env": {...} }
  - http:  { "name": "...", "url": "https://...", "headers": {...} }
  - sse:   { "name": "...", "url": "https://...", "transport": "sse" }

All injected sections include `trust = false` per the corporate cyber baseline.

If `[admin.mcp].allowed_servers` (or `allowed_mcp_servers` at top level) is
present in the existing config, the injector extends that allowlist with the
names of every server it writes.

Usage:
    mcp-injector-codex.py --config ~/.codex/config.toml \
        --servers '[{"name":"foo","command":"/usr/bin/foo","args":[]}]'
    mcp-injector-codex.py --config ~/.codex/config.toml --servers-file servers.json
    mcp-injector-codex.py --config ... --servers '[...]' --force   # overwrite existing

FORMAT RISK (read before modifying):
    The Python stdlib only ships a TOML *reader* (tomllib, 3.11+); there is no
    stdlib writer. Rather than take a third-party dep (tomli-w, tomlkit), this
    script appends new sections as plain text. That works because:

      1. `[mcp_servers.<name>]` sections are leaf tables with simple scalar
         values (strings, bools, arrays of strings, inline tables of strings).
      2. We never need to mutate a key inside an existing non-MCP section.
      3. The allowlist update is a targeted line replacement.

    If you ever need to rewrite arbitrary nested tables, switch to tomli-w or
    tomlkit and replace `_render_server_section` / `_update_allowlist`.

    The script validates that everything it writes round-trips through
    tomllib.loads before renaming the tmp file into place.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:
    print(
        "ERROR: Python 3.11+ required (tomllib not found). "
        "Run with python3.11 or newer.",
        file=sys.stderr,
    )
    sys.exit(2)


# --------------------------------------------------------------------------- #
# TOML value rendering (subset sufficient for MCP server sections)
# --------------------------------------------------------------------------- #


def _toml_string(s: str) -> str:
    """Render a Python str as a TOML basic string with proper escaping."""
    escaped = (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def _toml_array_of_strings(items: list[Any]) -> str:
    return "[" + ", ".join(_toml_string(str(x)) for x in items) + "]"


def _toml_inline_table_of_strings(d: dict[str, Any]) -> str:
    if not d:
        return "{}"
    parts = [f"{k} = {_toml_string(str(v))}" for k, v in d.items()]
    return "{ " + ", ".join(parts) + " }"


def _toml_bare_key(name: str) -> str:
    """Return name as-is if it's a bare TOML key, else quote it."""
    bare_ok = name and all(c.isalnum() or c in "_-" for c in name)
    return name if bare_ok else _toml_string(name)


# --------------------------------------------------------------------------- #
# Server section rendering
# --------------------------------------------------------------------------- #


def _render_server_section(name: str, spec: dict[str, Any]) -> str:
    """Render one MCP server as a [mcp_servers.<name>] TOML block."""
    lines: list[str] = []
    key = _toml_bare_key(name)
    lines.append(f"[mcp_servers.{key}]")

    transport = (spec.get("transport") or "").lower().strip()
    has_command = "command" in spec
    has_url = "url" in spec
    if not transport:
        if has_command:
            transport = "stdio"
        elif has_url:
            # Default URL-based to streamable_http; explicit "sse" must be opt-in
            transport = "http"
        else:
            raise ValueError(
                f"MCP server {name!r}: must provide 'command' (stdio) or 'url' (http/sse)"
            )

    if transport == "stdio":
        if not has_command:
            raise ValueError(f"MCP server {name!r}: stdio requires 'command'")
        lines.append(f"command = {_toml_string(str(spec['command']))}")
        if spec.get("args"):
            lines.append(f"args = {_toml_array_of_strings(list(spec['args']))}")
        if spec.get("env"):
            env = spec["env"]
            if not isinstance(env, dict):
                raise ValueError(f"MCP server {name!r}: 'env' must be an object")
            lines.append(f"env = {_toml_inline_table_of_strings(env)}")
    elif transport in {"http", "streamable_http", "sse"}:
        if not has_url:
            raise ValueError(f"MCP server {name!r}: {transport} requires 'url'")
        lines.append(f"url = {_toml_string(str(spec['url']))}")
        if transport == "sse":
            lines.append('transport = "sse"')
        if spec.get("headers"):
            headers = spec["headers"]
            if not isinstance(headers, dict):
                raise ValueError(f"MCP server {name!r}: 'headers' must be an object")
            lines.append(f"headers = {_toml_inline_table_of_strings(headers)}")
        if spec.get("bearer_token_env_var"):
            lines.append(
                "bearer_token_env_var = "
                + _toml_string(str(spec["bearer_token_env_var"]))
            )
    else:
        raise ValueError(
            f"MCP server {name!r}: unsupported transport {transport!r} "
            "(want stdio|http|sse)"
        )

    # Corporate cyber baseline: trust = false always
    lines.append("trust = false")

    if spec.get("startup_timeout_ms"):
        lines.append(f"startup_timeout_ms = {int(spec['startup_timeout_ms'])}")
    if spec.get("description"):
        lines.append(f"# {spec['description']}")

    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- #
# Allowlist update (line-level rewrite, scoped to known keys)
# --------------------------------------------------------------------------- #


_ALLOWLIST_KEYS = ("allowed_mcp_servers", "allowed_servers")


def _update_allowlist(text: str, new_names: list[str]) -> str:
    """If an allowlist key exists, extend it with new_names (deduped)."""
    if not new_names:
        return text
    out_lines: list[str] = []
    for raw_line in text.splitlines(keepends=True):
        line = raw_line.rstrip("\r\n")
        eol = raw_line[len(line):]
        stripped = line.lstrip()
        replaced = False
        for key in _ALLOWLIST_KEYS:
            prefix = f"{key} = ["
            if stripped.startswith(prefix) and stripped.endswith("]"):
                indent = line[: len(line) - len(stripped)]
                inner = stripped[len(prefix):-1].strip()
                existing: list[str] = []
                if inner:
                    # Best-effort parse: split by comma, strip quotes
                    for item in inner.split(","):
                        item = item.strip().strip('"').strip("'")
                        if item:
                            existing.append(item)
                merged: list[str] = []
                seen: set[str] = set()
                for n in existing + new_names:
                    if n not in seen:
                        seen.add(n)
                        merged.append(n)
                rendered = "[" + ", ".join(_toml_string(n) for n in merged) + "]"
                out_lines.append(f"{indent}{key} = {rendered}{eol}")
                replaced = True
                break
        if not replaced:
            out_lines.append(raw_line)
    return "".join(out_lines)


# --------------------------------------------------------------------------- #
# Main merge logic
# --------------------------------------------------------------------------- #


def _existing_server_names(parsed: dict[str, Any]) -> set[str]:
    servers = parsed.get("mcp_servers")
    if isinstance(servers, dict):
        return set(servers.keys())
    return set()


def merge_servers(
    config_text: str,
    servers: list[dict[str, Any]],
    *,
    force: bool = False,
) -> tuple[str, list[str], list[str]]:
    """Return (new_text, written_names, skipped_names)."""
    parsed = tomllib.loads(config_text) if config_text.strip() else {}
    existing = _existing_server_names(parsed)

    appended: list[str] = []
    written: list[str] = []
    skipped: list[str] = []

    for spec in servers:
        if not isinstance(spec, dict):
            raise ValueError(f"Server entry not an object: {spec!r}")
        name = spec.get("name")
        if not name or not isinstance(name, str):
            raise ValueError(f"Server entry missing 'name': {spec!r}")
        if name in existing and not force:
            skipped.append(name)
            continue
        if name in existing and force:
            # Strip the previous section before appending fresh
            config_text = _strip_section(config_text, f"mcp_servers.{name}")
        appended.append(_render_server_section(name, spec))
        written.append(name)

    if not appended and not skipped:
        return config_text, written, skipped

    new_text = config_text
    if appended:
        if new_text and not new_text.endswith("\n"):
            new_text += "\n"
        new_text += "\n# --- injected MCP servers (corporate launcher) ---\n"
        new_text += "\n".join(appended)

    # Update allowlist if applicable
    new_text = _update_allowlist(new_text, written)

    # Round-trip validation
    try:
        tomllib.loads(new_text)
    except tomllib.TOMLDecodeError as e:
        raise RuntimeError(f"Generated config does not parse as TOML: {e}") from e

    return new_text, written, skipped


def _strip_section(text: str, header: str) -> str:
    """Remove a `[header]` section and its body up to the next section header."""
    target = f"[{header}]"
    out: list[str] = []
    skipping = False
    for raw in text.splitlines(keepends=True):
        stripped = raw.lstrip()
        if not skipping:
            if stripped.startswith(target) and stripped[len(target):].strip() in {"", ""}:
                skipping = True
                continue
            out.append(raw)
        else:
            if stripped.startswith("[") and not stripped.startswith("[["):
                skipping = False
                out.append(raw)
            # else: still inside the section body, drop it
    return "".join(out)


# --------------------------------------------------------------------------- #
# Atomic write
# --------------------------------------------------------------------------- #


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = "w"
    fd, tmp_name = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=str(path.parent),
    )
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, mode, encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        # Preserve original mode if file exists
        if path.exists():
            os.chmod(tmp_path, os.stat(path).st_mode & 0o777)
        else:
            os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, path)
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def _load_servers_arg(servers_inline: str | None, servers_file: Path | None) -> list[dict[str, Any]]:
    if servers_inline and servers_file:
        raise SystemExit("ERROR: pass --servers OR --servers-file, not both")
    if servers_inline:
        data = json.loads(servers_inline)
    elif servers_file:
        data = json.loads(servers_file.read_text(encoding="utf-8"))
    else:
        raise SystemExit("ERROR: --servers or --servers-file is required")
    if not isinstance(data, list):
        raise SystemExit("ERROR: MCP_SERVERS must be a JSON array")
    return data


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--config",
        required=True,
        type=Path,
        help="Path to Codex config.toml (e.g. ~/.codex/config.toml)",
    )
    p.add_argument(
        "--servers",
        type=str,
        help="Inline JSON array of MCP server definitions",
    )
    p.add_argument(
        "--servers-file",
        type=Path,
        help="Path to a JSON file containing the MCP server array",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="Overwrite [mcp_servers.<name>] sections that already exist "
        "(default: skip duplicates)",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the rendered file to stdout instead of writing",
    )
    args = p.parse_args(argv)

    cfg_path = args.config.expanduser()
    servers = _load_servers_arg(args.servers, args.servers_file)

    existing_text = cfg_path.read_text(encoding="utf-8") if cfg_path.exists() else ""

    try:
        new_text, written, skipped = merge_servers(
            existing_text, servers, force=args.force
        )
    except (ValueError, RuntimeError, tomllib.TOMLDecodeError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 3

    if args.dry_run:
        sys.stdout.write(new_text)
    elif new_text != existing_text:
        atomic_write(cfg_path, new_text)

    for n in written:
        print(f"injected: mcp_servers.{n}")
    for n in skipped:
        print(f"skipped (exists, use --force to overwrite): mcp_servers.{n}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
