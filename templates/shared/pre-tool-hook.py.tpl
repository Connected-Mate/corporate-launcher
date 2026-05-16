#!/usr/bin/env python3
"""${CORP_NAME} — cyber-guard hook.

Reads the PreToolUse event JSON from stdin and decides whether to allow,
ask, or deny the tool call.

Wired into settings.json:
    {
      "hooks": {
        "PreToolUse": [{
          "matcher": "Bash|Edit|Write|MultiEdit",
          "hooks": [{
            "type": "command",
            "command": "/path/to/cyber-guard.py"
          }]
        }]
      }
    }

The hook is locked at chmod 555 so the AI cannot rewrite it.
"""

from __future__ import annotations

import json
import re
import sys
from typing import Final

# tpl: -------------------------------------------------------------------
# tpl: Secret / PII / forbidden patterns. Block these unconditionally.
# tpl: -------------------------------------------------------------------
SECRET_PATTERNS: Final[list[tuple[str, str]]] = [
    (r"sk-ant-[a-zA-Z0-9_-]{20,}", "Anthropic API key"),
    (r"sk-[a-zA-Z0-9]{40,}",       "OpenAI-style API key"),
    (r"AKIA[0-9A-Z]{16}",          "AWS access key id"),
    (r"AIza[0-9A-Za-z_-]{35}",     "Google API key"),
    (r"ghp_[A-Za-z0-9]{36,}",      "GitHub PAT"),
    (r"-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----", "Private key"),
    (r"\b[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}\b", "Card number (16 digits)"),
]

# tpl: -------------------------------------------------------------------
# tpl: Destructive shell commands. Even bypassPermissions cannot override.
# tpl: -------------------------------------------------------------------
DESTRUCTIVE_PATTERNS: Final[list[tuple[str, str]]] = [
    (r"\brm\s+-rf\s+/(?:\s|$)",                        "rm -rf /"),
    (r"\brm\s+-rf\s+\$HOME(?:\s|/|$)",                 "rm -rf $HOME"),
    (r"\bdd\s+if=.*\s+of=/dev/(sd|nvme|hd)",           "dd to raw device"),
    (r"\bmkfs\.[a-z0-9]+\s+/dev/(sd|nvme|hd)",         "filesystem format"),
    (r":\(\)\s*\{[^}]*:\|:&[^}]*\}\s*;?\s*:",          "fork bomb"),
    (r"\bchmod\s+-R\s+777\s+/(?:\s|$)",                "chmod -R 777 /"),
    (r"\bgit\s+push\s+--force.*\b(main|master|prod)",  "force push to main"),
    (r"\bcurl\s+[^|]+\|\s*(?:sudo\s+)?(?:bash|sh)\b",  "curl | bash"),
]

# tpl: -------------------------------------------------------------------


def scan(text: str, patterns: list[tuple[str, str]]) -> tuple[str, str] | None:
    for pat, label in patterns:
        if re.search(pat, text):
            return pat, label
    return None


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        # tpl: Malformed input — let the call through; logging it is a TODO
        print(json.dumps({"permissionDecision": "allow"}))
        return 0

    payload = json.dumps(event.get("tool_input", {}), default=str)

    # tpl: Secrets — deny + explain
    hit = scan(payload, SECRET_PATTERNS)
    if hit:
        _, label = hit
        print(json.dumps({
            "permissionDecision": "deny",
            "reason": f"${CORP_NAME} cyber-guard: detected {label}. "
                      "Use the corporate secret manager instead.",
        }))
        return 0

    # tpl: Destructive — deny + explain
    hit = scan(payload, DESTRUCTIVE_PATTERNS)
    if hit:
        _, label = hit
        print(json.dumps({
            "permissionDecision": "deny",
            "reason": f"${CORP_NAME} cyber-guard: refused destructive command: {label}.",
        }))
        return 0

    print(json.dumps({"permissionDecision": "allow"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
