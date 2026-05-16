"""Tests for scripts/audit-launcher.py.

Each test fabricates a minimal launcher tree under ``tmp_path`` and a
matching JSON config, then drives ``run_audit`` (or the CLI ``main``) and
asserts on the resulting ``AuditReport`` / process exit code.

No network. No subprocess. Stdlib pytest only.
"""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
AUDIT_PATH = REPO_ROOT / "scripts" / "audit-launcher.py"


def _load_audit() -> Any:
    if not AUDIT_PATH.exists():
        pytest.skip("scripts/audit-launcher.py not present")
    spec = importlib.util.spec_from_file_location("audit_launcher", AUDIT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["audit_launcher"] = module
    spec.loader.exec_module(module)
    return module


audit = _load_audit()


# --------------------------------------------------------------------------- #
# Fixture: a clean, fully compliant launcher tree.                            #
# --------------------------------------------------------------------------- #


CLEAN_LAUNCHER_SH = """#!/usr/bin/env bash
# Corporate Launcher — ACME edition.
set -euo pipefail

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export DISABLE_BUG_COMMAND=1
export DISABLE_AUTOUPDATER=1

check_vpn() {
    if ! ip route get 10.0.0.1 >/dev/null 2>&1; then
        echo "VPN required" >&2
        exit 1
    fi
}

check_vpn

exec claude \\
    --append-system-prompt-file "$DIR/BRANDING.md" \\
    --append-system-prompt-file "$DIR/cyber-rules.md" \\
    "$@"
"""

CLEAN_BRANDING = """# BRANDING

This wrapper rebrands the assistant.
Forbidden vendor names: anthropic, openai are NOT to appear externally.
"""

CLEAN_CYBER_RULES = """# Cyber rules

Do not exfiltrate secrets. Respect VPN. Honor permissions.deny.
"""


def _write(p: Path, body: str, mode: int = 0o644) -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(body, encoding="utf-8")
    os.chmod(p, mode)
    return p


def _clean_tree(tmp_path: Path) -> tuple[Path, Path]:
    """Return (launcher_dir, config_path) for a tree that should pass all checks."""
    launcher = tmp_path / "build" / "acme"
    _write(launcher / "launcher.sh", CLEAN_LAUNCHER_SH, mode=0o755)
    _write(launcher / "BRANDING.md", CLEAN_BRANDING)
    _write(launcher / "cyber-rules.md", CLEAN_CYBER_RULES)
    _write(launcher / "cyber-guard.py", "#!/usr/bin/env python3\n", mode=0o555)

    config = {
        "CC_CLI_NAME": "launcher.sh",
        "VPN_REQUIRED": "yes",
        "ACCEPT_TLS_INSPECTION": "no",
        "CORP_RULES_FILE": "cyber-rules.md",
        "FORBIDDEN_TERMS": "",
    }
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(json.dumps(config), encoding="utf-8")
    os.chmod(cfg_path, 0o600)
    return launcher, cfg_path


def _get(report: "audit.AuditReport", name: str) -> "audit.CheckResult":
    for c in report.checks:
        if c.name == name:
            return c
    raise AssertionError(f"check {name!r} not found in report")


# --------------------------------------------------------------------------- #
# 1. Clean tree                                                                #
# --------------------------------------------------------------------------- #


def test_clean_tree_passes_all_checks(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    report = audit.run_audit(launcher, cfg)
    failed = [c.name for c in report.checks if not c.passed]
    assert failed == [], f"unexpected failures: {failed}"
    assert report.failures == 0
    assert report.score == report.total


# --------------------------------------------------------------------------- #
# 2. Vendor URL leak                                                           #
# --------------------------------------------------------------------------- #


def test_vendor_url_in_launcher_triggers_p0(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    leaky = launcher / "launcher.sh"
    leaky.write_text(
        CLEAN_LAUNCHER_SH.replace(
            "exec claude",
            'export ANTHROPIC_BASE_URL="https://api.anthropic.com"\nexec claude',
        ),
        encoding="utf-8",
    )
    os.chmod(leaky, 0o755)
    report = audit.run_audit(launcher, cfg)
    result = _get(report, "hardcoded-vendor-urls")
    assert not result.passed
    assert any("api.anthropic.com" in d for d in result.details)


# --------------------------------------------------------------------------- #
# 3. Plain anthropic key                                                       #
# --------------------------------------------------------------------------- #


def test_plain_anthropic_key_triggers_p0(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    _write(
        launcher / "notes.md",
        "Do not commit: sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJ\n",
    )
    report = audit.run_audit(launcher, cfg)
    result = _get(report, "plain-text-secrets")
    assert not result.passed
    assert any("anthropic-key" in d for d in result.details)


# --------------------------------------------------------------------------- #
# 4. VPN required but no check_vpn                                             #
# --------------------------------------------------------------------------- #


def test_vpn_required_missing_check_triggers_p1(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    no_vpn = CLEAN_LAUNCHER_SH.replace("check_vpn() {", "noop() {").replace(
        "check_vpn\n", ""
    )
    _write(launcher / "launcher.sh", no_vpn, mode=0o755)
    report = audit.run_audit(launcher, cfg)
    result = _get(report, "vpn-check-present")
    assert not result.passed
    assert any("check_vpn" in d for d in result.details)


# --------------------------------------------------------------------------- #
# 5. Missing kill switches                                                     #
# --------------------------------------------------------------------------- #


def test_missing_kill_switch_triggers_p1(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    stripped = CLEAN_LAUNCHER_SH.replace("export DISABLE_TELEMETRY=1\n", "")
    _write(launcher / "launcher.sh", stripped, mode=0o755)
    report = audit.run_audit(launcher, cfg)
    result = _get(report, "telemetry-kill-switches")
    assert not result.passed
    assert any("DISABLE_TELEMETRY" in d for d in result.details)


# --------------------------------------------------------------------------- #
# 6. TLS bypass without explicit acceptance                                    #
# --------------------------------------------------------------------------- #


def test_tls_bypass_without_acceptance_triggers_p1(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    _write(
        launcher / "launcher.sh",
        CLEAN_LAUNCHER_SH.replace(
            "exec claude",
            'export NODE_TLS_REJECT_UNAUTHORIZED=0\nexec claude',
        ),
        mode=0o755,
    )
    report = audit.run_audit(launcher, cfg)
    result = _get(report, "ca-handling")
    assert not result.passed
    assert any("TLS bypass" in d for d in result.details)


def test_tls_bypass_allowed_when_inspection_accepted(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    cfg_data = json.loads(cfg.read_text())
    cfg_data["ACCEPT_TLS_INSPECTION"] = "yes"
    cfg.write_text(json.dumps(cfg_data), encoding="utf-8")
    _write(
        launcher / "launcher.sh",
        CLEAN_LAUNCHER_SH.replace(
            "exec claude",
            'export NODE_TLS_REJECT_UNAUTHORIZED=0\nexec claude',
        ),
        mode=0o755,
    )
    report = audit.run_audit(launcher, cfg)
    assert _get(report, "ca-handling").passed


# --------------------------------------------------------------------------- #
# 7. cyber-guard.py wrong mode                                                 #
# --------------------------------------------------------------------------- #


def test_cyber_guard_wrong_mode_triggers_p2(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    os.chmod(launcher / "cyber-guard.py", 0o755)
    report = audit.run_audit(launcher, cfg)
    result = _get(report, "permissions")
    assert not result.passed
    assert any("cyber-guard" in d and "expected 555" in d for d in result.details)


# --------------------------------------------------------------------------- #
# 8. --strict flag exit code                                                   #
# --------------------------------------------------------------------------- #


def test_strict_flag_exit_code_equals_failure_count(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    # Introduce TWO independent failures: vendor URL leak + plain secret.
    _write(
        launcher / "launcher.sh",
        CLEAN_LAUNCHER_SH.replace(
            "exec claude",
            'export ANTHROPIC_BASE_URL="https://api.anthropic.com"\nexec claude',
        ),
        mode=0o755,
    )
    _write(
        launcher / "leak.md",
        "key=sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJ\n",
    )
    out = tmp_path / "report.md"
    rc = audit.main(
        [
            "--launcher-dir",
            str(launcher),
            "--config",
            str(cfg),
            "--strict",
            "--output",
            str(out),
        ]
    )
    assert rc >= 2
    # Sanity: rc matches the report's failure count.
    report = audit.run_audit(launcher, cfg)
    assert rc == min(report.failures, 125)


def test_non_strict_returns_one_on_failure(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    _write(launcher / "leak.md", "sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJ\n")
    rc = audit.main(["--launcher-dir", str(launcher), "--config", str(cfg)])
    assert rc == 1


def test_clean_tree_cli_exits_zero(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    rc = audit.main(["--launcher-dir", str(launcher), "--config", str(cfg)])
    assert rc == 0


# --------------------------------------------------------------------------- #
# 9. Markdown + JSON sidecar report generation                                 #
# --------------------------------------------------------------------------- #


def test_output_writes_markdown_and_json_sidecar(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    out = tmp_path / "audit.md"
    rc = audit.main(
        [
            "--launcher-dir",
            str(launcher),
            "--config",
            str(cfg),
            "--output",
            str(out),
        ]
    )
    assert rc == 0
    assert out.is_file()
    md = out.read_text(encoding="utf-8")
    assert "Corporate Launcher Audit" in md
    assert "| # | Check | Status |" in md

    sidecar = out.with_suffix(".json")
    assert sidecar.is_file()
    payload = json.loads(sidecar.read_text(encoding="utf-8"))
    assert payload["failures"] == 0
    assert payload["total"] == payload["score"]
    assert isinstance(payload["checks"], list) and payload["checks"]
    names = {c["name"] for c in payload["checks"]}
    assert "hardcoded-vendor-urls" in names
    assert "telemetry-kill-switches" in names


# --------------------------------------------------------------------------- #
# 10. Allowed exception: vendor URL inside permissions.deny array              #
# --------------------------------------------------------------------------- #


def test_vendor_url_inside_deny_array_is_ignored(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    settings = {
        "permissions": {
            "deny": [
                "WebFetch(domain:api.anthropic.com)",
                "WebFetch(domain:api.openai.com)",
            ]
        }
    }
    _write(
        launcher / ".claude" / "settings.json",
        json.dumps(settings, indent=2),
    )
    report = audit.run_audit(launcher, cfg)
    result = _get(report, "hardcoded-vendor-urls")
    assert result.passed, f"deny-list entry mis-flagged: {result.details}"


def test_vendor_url_in_comment_is_ignored(tmp_path: Path) -> None:
    launcher, cfg = _clean_tree(tmp_path)
    _write(
        launcher / "notes.sh",
        "#!/usr/bin/env bash\n# do not call api.anthropic.com directly\n",
        mode=0o644,
    )
    report = audit.run_audit(launcher, cfg)
    assert _get(report, "hardcoded-vendor-urls").passed


# --------------------------------------------------------------------------- #
# CLI error handling                                                           #
# --------------------------------------------------------------------------- #


def test_missing_launcher_dir_returns_2(tmp_path: Path) -> None:
    _, cfg = _clean_tree(tmp_path)
    rc = audit.main(
        ["--launcher-dir", str(tmp_path / "does-not-exist"), "--config", str(cfg)]
    )
    assert rc == 2


def test_missing_config_returns_2(tmp_path: Path) -> None:
    launcher, _ = _clean_tree(tmp_path)
    rc = audit.main(
        ["--launcher-dir", str(launcher), "--config", str(tmp_path / "nope.json")]
    )
    assert rc == 2
