# Example — ACME Corp / Claude Code on LiteLLM-over-Bedrock

The flagship example. Claude Code wrapped onto an internal LiteLLM proxy that forwards to AWS Bedrock. This is the most common "large enterprise" configuration: gives the central team a single point of control, billing, and audit, and gives developers the latest Claude family without ever touching the vendor's public endpoint.

## Config answers

```json
{
  "CORP_NAME": "ACME Copilot",
  "CORP_SLUG": "acme-copilot",
  "CORP_POWERED_BY": "ACME AI Platform",
  "CORP_ORGANIZATION": "ACME Industries",
  "CORP_TAGLINE": "Internal AI coding assistant",
  "CORP_LICENSE_NOTE": "Internal use only — ACME confidential",

  "WRAPPED_CLIS": ["claude-code"],

  "CC_BACKEND": "LiteLLM",
  "CC_PRIMARY_URL": "https://litellm.acme.internal",
  "CC_FALLBACK_URL": "",
  "CC_PRIMARY_MODEL": "claude-opus-4-7",
  "CC_HAIKU_MODEL": "claude-haiku-4-5",
  "CC_AUTH_MODEL": "bearer-token",
  "CC_NEEDS_STRIP_PROXY": "yes",

  "VPN_REQUIRED": "yes",
  "VPN_PROBE_URL": "https://litellm.acme.internal",
  "PROXY_HOST": "proxy.acme.internal",
  "PROXY_PORT": "8080",
  "NO_PROXY_LIST": "127.0.0.1,localhost,.acme.internal",
  "CA_BUNDLE_PATH": "/etc/ssl/acme-corp-bundle.pem",
  "CA_DETECT_AUTO": "yes",
  "ACCEPT_TLS_INSPECTION": "no",

  "CYBER_AUTHORITY": "ACME Group CISO",
  "BLOCK_TELEMETRY": "yes",
  "BLOCK_AUTO_UPDATE": "yes",
  "BLOCK_FEEDBACK_CMDS": "yes",
  "BLOCK_VOICE_MODE": "yes",
  "COST_TRACKING_ENABLED": "yes",
  "COST_CURRENCY": "USD",
  "PROMPT_FILTER_ENABLED": "yes",

  "BANNER_COLOR_PRIMARY": "33",
  "TERMINAL_TITLE": "ACME Copilot",
  "LANGUAGE": "en",
  "FORBIDDEN_TERMS": "Claude,Claude Code,Anthropic,api.anthropic.com,claude.ai",

  "INSTALL_DIR": "~/.local/share/acme-copilot",
  "BIN_PATH": "~/.local/bin",
  "LICENSE_TYPE": "Proprietary",
  "INCLUDE_UNINSTALL": "yes",

  "SKILLS_MODE": "combined",
  "SKILLS_PRESETS": ["design-pack"],
  "SKILLS_GIT_URL": "https://git.acme.internal/ai-platform/internal-skills.git",
  "SKILLS_GIT_REF": "main",
  "MCP_SERVERS": [
    { "name": "jira",   "url": "https://mcp.acme.internal/jira",   "trust": false },
    { "name": "github", "url": "https://mcp.acme.internal/github", "trust": false }
  ],

  "DIST_MODE": "private-git",
  "DIST_REPO_HOST": "internal-gitea",
  "DIST_REPO_URL": "https://git.acme.internal/ai-platform/acme-copilot.git",
  "DIST_REPO_VISIBILITY": "internal",
  "DIST_SIGN_RELEASE": false
}
```

## Why those answers

- **`CC_BACKEND=LiteLLM`** — the ACME platform team runs LiteLLM in front of AWS Bedrock to get a single point of control: API keys per team, per-team quotas, audit logs in their SIEM, ability to swap the backend (Bedrock → direct Anthropic → another LiteLLM) without retraining every developer.
- **`CC_NEEDS_STRIP_PROXY=yes`** — LiteLLM-over-Bedrock emits 4 known SSE artefacts that crash the Claude Code parser. The strip-proxy on `127.0.0.1:9876` fixes them locally; no upstream change required.
- **`CC_PRIMARY_MODEL=claude-opus-4-7`** — latest Opus, the right default for serious coding sessions. The launcher exposes `ACME_COPILOT_MODEL` for ad-hoc overrides.
- **`VPN_PROBE_URL=https://litellm.acme.internal`** — strictly internal domain. Returns HTTP `000` if the user is off-VPN, any other code if on-VPN. Cheaper than `ping` (no ICMP), more reliable than `nslookup` (split-DNS).
- **`CA_BUNDLE_PATH=/etc/ssl/acme-corp-bundle.pem`** — ACME provisions the CA bundle on every workstation via MDM, so the launcher never needs to bypass TLS verification.
- **`SKILLS_MODE=combined`** — the launcher bundles the public design pack *plus* ACME's internal skills repo (security-review, sql-review, postmortem, runbook generator). Colleagues install once and get the full set.
- **`MCP_SERVERS`** — Jira and GitHub MCP servers pre-wired so the launcher knows about ACME's projects on day one. `trust: false` means tool calls still need user confirmation.
- **`DIST_MODE=private-git`** — the launcher source goes to ACME's internal Gitea. Colleagues clone with their existing SSO and run `./install.sh`. No public exposure, but full git history and PR review for changes.

## What the colleague sees after the install one-liner

```
$ git clone https://git.acme.internal/ai-platform/acme-copilot.git && cd acme-copilot && ./install.sh
$ acme-copilot
  ╔═══════════════════════════════════════════════╗
  ║  ACME Copilot                                 ║
  ║  Powered by ACME AI Platform                  ║
  ╚═══════════════════════════════════════════════╝

[acme-copilot] VPN check ... OK (HTTP 401)
[acme-copilot] strip-proxy listening on 127.0.0.1:9876
[acme-copilot] 15 bundled skills loaded
[acme-copilot] 2 MCP servers configured: jira, github
> _
```

## Anti-patterns avoided

- The launcher **does not** edit `/etc/hosts` to block the vendor's public domain. The block is in `settings.json`'s `permissions.deny` plus the gateway-only `ANTHROPIC_BASE_URL`.
- The launcher **does not** set `NODE_TLS_REJECT_UNAUTHORIZED=0` globally. The CA bundle path is the right answer.
- The launcher **does not** persist the API key in the binary or in a world-readable file. macOS Keychain first; chmod 600 file as fallback.
- The auto-updater is **disabled** so a vendor minor release doesn't break the proxy or the branding silently.
