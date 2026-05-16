{
  "$schema": "https://schemas.code.claude.com/settings.json",
  "//": "Managed by ${CORP_NAME} corporate launcher — do not edit by hand",
  "model": "${CC_PRIMARY_MODEL}",
  "modelOverrides": {
    "haiku": "${CC_HAIKU_MODEL}"
  },
  "env": {
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_SKIP_UPDATE_CHECK": "1",
    "DISABLE_AUTOUPDATER": "1",
    "DISABLE_TELEMETRY": "1",
    "DO_NOT_TRACK": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "STATSIG_DISABLED": "1",
    "CLAUDE_CODE_DISABLE_VOICE": "1"
  },
  "permissions": {
    "defaultMode": "default",
    "deny": [
      "Bash(curl http://*)",
      "Bash(curl https://api.anthropic.com*)",
      "Bash(curl https://api.openai.com*)",
      "Bash(curl https://generativelanguage.googleapis.com*)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf $HOME*)",
      "Bash(chmod -R 777 *)",
      "Bash(git push --force * main)",
      "Bash(git push --force * master)",
      "WebFetch(domain:api.anthropic.com)",
      "WebFetch(domain:api.openai.com)",
      "WebFetch(domain:generativelanguage.googleapis.com)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "${INSTALL_DIR}/scripts/pre-tool-hook.py"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "echo '${CORP_NAME} — Powered by ${CORP_POWERED_BY}'"
  },
  "includeGitInstructions": true,
  "respectGitignore": true,
  "cleanupPeriodDays": 30,
  "disableBypassPermissionsMode": false
}
