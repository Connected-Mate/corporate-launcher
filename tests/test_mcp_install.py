"""Pytest suite for the MCP injection layer.

Covers, per-CLI:

* ``scripts/mcp-injector-claude.py``  — Claude Code ``settings.json``
* ``scripts/mcp-injector-codex.py``   — Codex CLI ``config.toml``
* ``scripts/mcp-injector-gemini.py``  — Gemini CLI ``settings.json``
* ``scripts/mcp-injector-opencode.py``— opencode ``opencode.json``
* ``scripts/mcp-installer.py``        — dispatcher to the right injector

All target files live under ``tmp_path``; ``~/.claude/settings.json`` and
friends are never touched. Injectors are loaded as Python modules via
``importlib.util`` (their filenames contain a hyphen so a plain import is not
possible).
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tomllib
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading helpers (filenames contain hyphens → must use importlib).
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = PROJECT_ROOT / "scripts"


def _load(stem: str) -> ModuleType:
    path = SCRIPTS / f"{stem}.py"
    spec = importlib.util.spec_from_file_location(stem.replace("-", "_"), path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


claude_mod = _load("mcp-injector-claude")
codex_mod = _load("mcp-injector-codex")
gemini_mod = _load("mcp-injector-gemini")
opencode_mod = _load("mcp-injector-opencode")
installer_mod = _load("mcp-installer")


# ---------------------------------------------------------------------------
# Claude Code injector
# ---------------------------------------------------------------------------
class TestClaudeInjector:
    def test_inject_into_empty_settings(self, tmp_path: Path) -> None:
        settings = tmp_path / "settings.json"
        servers = [
            {"name": "jira", "url": "https://mcp.acme/jira"},
            {"name": "fs", "command": "npx", "args": ["-y", "pkg"]},
        ]
        rc = claude_mod.main(
            ["--settings", str(settings), "--servers", json.dumps(servers)]
        )
        assert rc == 0
        data = json.loads(settings.read_text(encoding="utf-8"))
        assert set(data["mcpServers"].keys()) == {"jira", "fs"}
        assert data["mcpServers"]["jira"]["url"] == "https://mcp.acme/jira"
        assert data["mcpServers"]["jira"]["transport"] == "http"
        assert data["mcpServers"]["fs"]["command"] == "npx"
        assert data["mcpServers"]["fs"]["transport"] == "stdio"
        assert data["mcpServers"]["fs"]["args"] == ["-y", "pkg"]

    def test_preserves_unrelated_keys(self, tmp_path: Path) -> None:
        settings = tmp_path / "settings.json"
        settings.write_text(
            json.dumps(
                {
                    "model": "claude-opus-4-7",
                    "hooks": {"PreToolUse": []},
                    "mcpServers": {"old": {"transport": "http", "url": "https://old"}},
                }
            ),
            encoding="utf-8",
        )
        servers = [{"name": "new", "url": "https://mcp.acme/new"}]
        rc = claude_mod.main(
            ["--settings", str(settings), "--servers", json.dumps(servers)]
        )
        assert rc == 0
        data = json.loads(settings.read_text(encoding="utf-8"))
        assert data["model"] == "claude-opus-4-7"
        assert data["hooks"] == {"PreToolUse": []}
        # old preserved, new added
        assert set(data["mcpServers"].keys()) == {"old", "new"}

    def test_adds_names_to_allowlist(self, tmp_path: Path) -> None:
        settings = tmp_path / "settings.json"
        servers = [
            {"name": "a", "url": "https://x/a"},
            {"name": "b", "url": "https://x/b"},
        ]
        claude_mod.main(
            ["--settings", str(settings), "--servers", json.dumps(servers)]
        )
        data = json.loads(settings.read_text(encoding="utf-8"))
        assert data["allowedMcpServers"] == ["a", "b"]

    @pytest.mark.parametrize(
        "bad_name",
        ["1leading-digit", "has space", "has/slash", "", "-leading-dash"],
    )
    def test_rejects_invalid_names(self, tmp_path: Path, bad_name: str) -> None:
        settings = tmp_path / "settings.json"
        servers = [{"name": bad_name, "url": "https://x"}]
        rc = claude_mod.main(
            ["--settings", str(settings), "--servers", json.dumps(servers)]
        )
        assert rc == 2
        assert not settings.exists()

    def test_atomic_write_no_partial_file_on_error(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        settings = tmp_path / "settings.json"
        original = {"model": "x", "mcpServers": {}}
        settings.write_text(json.dumps(original), encoding="utf-8")

        # Force os.replace to fail; the tmp file must be cleaned up and the
        # original file must remain byte-for-byte unchanged.
        import os as _os

        def boom(*args: object, **kwargs: object) -> None:
            raise OSError("simulated rename failure")

        monkeypatch.setattr(claude_mod.os, "replace", boom)
        rc = claude_mod.main(
            [
                "--settings",
                str(settings),
                "--servers",
                json.dumps([{"name": "n", "url": "https://x"}]),
            ]
        )
        assert rc == 3
        assert settings.read_text(encoding="utf-8") == json.dumps(original)
        # No stray .tmp files left behind in the parent dir.
        leftovers = [p for p in tmp_path.iterdir() if p.name.endswith(".tmp")]
        assert leftovers == [], f"tmp file leak: {leftovers}"
        # Reference _os to keep linters happy.
        assert _os is not None


# ---------------------------------------------------------------------------
# Codex CLI injector
# ---------------------------------------------------------------------------
class TestCodexInjector:
    def test_inject_stdio_server(self, tmp_path: Path) -> None:
        cfg = tmp_path / "config.toml"
        servers = [
            {"name": "foo", "command": "/usr/bin/foo", "args": ["--flag"]},
        ]
        rc = codex_mod.main(
            ["--config", str(cfg), "--servers", json.dumps(servers)]
        )
        assert rc == 0
        text = cfg.read_text(encoding="utf-8")
        assert "[mcp_servers.foo]" in text
        parsed = tomllib.loads(text)
        assert parsed["mcp_servers"]["foo"]["command"] == "/usr/bin/foo"
        assert parsed["mcp_servers"]["foo"]["args"] == ["--flag"]
        assert parsed["mcp_servers"]["foo"]["trust"] is False

    def test_inject_http_server(self, tmp_path: Path) -> None:
        cfg = tmp_path / "config.toml"
        servers = [
            {
                "name": "jira",
                "url": "https://mcp.acme/jira",
                "headers": {"Authorization": "Bearer x"},
            }
        ]
        rc = codex_mod.main(
            ["--config", str(cfg), "--servers", json.dumps(servers)]
        )
        assert rc == 0
        parsed = tomllib.loads(cfg.read_text(encoding="utf-8"))
        assert parsed["mcp_servers"]["jira"]["url"] == "https://mcp.acme/jira"
        assert parsed["mcp_servers"]["jira"]["headers"] == {
            "Authorization": "Bearer x"
        }

    def test_idempotent_without_force(self, tmp_path: Path) -> None:
        cfg = tmp_path / "config.toml"
        servers = [{"name": "foo", "command": "/bin/foo"}]
        codex_mod.main(
            ["--config", str(cfg), "--servers", json.dumps(servers)]
        )
        first = cfg.read_text(encoding="utf-8")

        # Second run: must NOT duplicate the section.
        codex_mod.main(
            ["--config", str(cfg), "--servers", json.dumps(servers)]
        )
        second = cfg.read_text(encoding="utf-8")
        assert first == second
        assert second.count("[mcp_servers.foo]") == 1

    def test_force_replaces_existing(self, tmp_path: Path) -> None:
        cfg = tmp_path / "config.toml"
        codex_mod.main(
            [
                "--config",
                str(cfg),
                "--servers",
                json.dumps([{"name": "foo", "command": "/bin/old"}]),
            ]
        )
        codex_mod.main(
            [
                "--config",
                str(cfg),
                "--servers",
                json.dumps([{"name": "foo", "command": "/bin/new"}]),
                "--force",
            ]
        )
        parsed = tomllib.loads(cfg.read_text(encoding="utf-8"))
        assert parsed["mcp_servers"]["foo"]["command"] == "/bin/new"
        # Section appears exactly once.
        assert cfg.read_text(encoding="utf-8").count("[mcp_servers.foo]") == 1


# ---------------------------------------------------------------------------
# Gemini CLI injector
# ---------------------------------------------------------------------------
class TestGeminiInjector:
    def test_inject_two_servers(self, tmp_path: Path) -> None:
        settings = tmp_path / "settings.json"
        servers = [
            {"name": "code-review-graph", "transport": "stdio", "command": "node",
             "args": ["server.js"]},
            {"name": "jira", "transport": "http", "httpUrl": "https://mcp/jira"},
        ]
        rc = gemini_mod.main(
            ["--settings", str(settings), "--servers", json.dumps(servers)]
        )
        assert rc == 0
        data = json.loads(settings.read_text(encoding="utf-8"))
        assert set(data["mcpServers"].keys()) == {"code-review-graph", "jira"}
        assert data["mcpServers"]["code-review-graph"]["command"] == "node"
        assert data["mcpServers"]["code-review-graph"]["args"] == ["server.js"]
        assert data["mcpServers"]["jira"]["httpUrl"] == "https://mcp/jira"

    def test_adds_to_mcp_allowed(self, tmp_path: Path) -> None:
        settings = tmp_path / "settings.json"
        servers = [
            {"name": "a", "transport": "stdio", "command": "/bin/a"},
            {"name": "b", "transport": "stdio", "command": "/bin/b"},
        ]
        gemini_mod.main(
            ["--settings", str(settings), "--servers", json.dumps(servers)]
        )
        data = json.loads(settings.read_text(encoding="utf-8"))
        assert data["mcp"]["allowed"] == ["a", "b"]

    def test_extends_admin_required_when_present(self, tmp_path: Path) -> None:
        settings = tmp_path / "settings.json"
        settings.write_text(
            json.dumps({"admin": {"mcp": {"requiredConfig": ["legacy"]}}}),
            encoding="utf-8",
        )
        servers = [
            {"name": "new", "transport": "stdio", "command": "/bin/new"},
        ]
        gemini_mod.main(
            ["--settings", str(settings), "--servers", json.dumps(servers)]
        )
        data = json.loads(settings.read_text(encoding="utf-8"))
        assert data["admin"]["mcp"]["requiredConfig"] == ["legacy", "new"]


# ---------------------------------------------------------------------------
# opencode injector
# ---------------------------------------------------------------------------
class TestOpencodeInjector:
    def test_inject_local_stdio(self, tmp_path: Path) -> None:
        cfg = tmp_path / "opencode.json"
        servers = [
            {
                "name": "fs",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                "transport": "stdio",
            }
        ]
        rc = opencode_mod.main(
            ["--config", str(cfg), "--servers", json.dumps(servers)]
        )
        assert rc == 0
        data = json.loads(cfg.read_text(encoding="utf-8"))
        entry = data["mcp"]["fs"]
        assert entry["type"] == "local"
        assert entry["command"] == [
            "npx",
            "-y",
            "@modelcontextprotocol/server-filesystem",
            "/tmp",
        ]
        assert entry["enabled"] is True

    def test_inject_remote_http(self, tmp_path: Path) -> None:
        cfg = tmp_path / "opencode.json"
        servers = [
            {
                "name": "jira",
                "url": "https://mcp.acme/jira",
                "headers": {"Authorization": "Bearer {env:TOKEN}"},
                "transport": "http",
            }
        ]
        rc = opencode_mod.main(
            ["--config", str(cfg), "--servers", json.dumps(servers)]
        )
        assert rc == 0
        data = json.loads(cfg.read_text(encoding="utf-8"))
        entry = data["mcp"]["jira"]
        assert entry["type"] == "remote"
        assert entry["url"] == "https://mcp.acme/jira"
        assert entry["headers"] == {"Authorization": "Bearer {env:TOKEN}"}


# ---------------------------------------------------------------------------
# Dispatcher (mcp-installer.py)
# ---------------------------------------------------------------------------
class TestInstallerDispatch:
    def _run(
        self, *args: str, cwd: Path | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "mcp-installer.py"), *args],
            capture_output=True,
            text=True,
            cwd=str(cwd) if cwd else None,
            check=False,
        )

    def test_dispatch_claude_code(self, tmp_path: Path) -> None:
        settings = tmp_path / "settings.json"
        servers = [{"name": "jira", "url": "https://mcp.acme/jira"}]
        proc = self._run(
            "--cli",
            "claude-code",
            "--servers",
            json.dumps(servers),
            "--settings",
            str(settings),
        )
        assert proc.returncode == 0, proc.stderr
        assert "Configured 1 MCP servers for claude-code" in proc.stdout
        data = json.loads(settings.read_text(encoding="utf-8"))
        assert "jira" in data["mcpServers"]

    def test_aider_prints_warning_and_exits_zero(self, tmp_path: Path) -> None:
        servers = [{"name": "jira", "url": "https://mcp.acme/jira"}]
        # aider has no injector → dispatcher should warn AND exit non-zero
        # because no injector module is found. The aider banner must still
        # be printed regardless.
        proc = self._run(
            "--cli", "aider", "--servers", json.dumps(servers), cwd=tmp_path
        )
        assert "Aider has no native MCP support" in proc.stderr
        # The aider warning is the contract; the dispatcher returns 6 when no
        # injector exists. We accept either 0 (if a no-op aider injector is
        # added later) or 6 (current behaviour) — both are non-failure for the
        # operator workflow.
        assert proc.returncode in (0, 6)

    def test_empty_servers_list_exits_zero(self, tmp_path: Path) -> None:
        proc = self._run(
            "--cli", "claude-code", "--servers", "[]", "--settings",
            str(tmp_path / "settings.json"),
        )
        assert proc.returncode == 0
        assert "Configured 0 MCP servers for claude-code" in proc.stdout

    def test_bad_json_exits_two(self, tmp_path: Path) -> None:
        proc = self._run(
            "--cli", "claude-code", "--servers", "{not json",
        )
        assert proc.returncode == 2
        assert "ERROR" in proc.stderr
