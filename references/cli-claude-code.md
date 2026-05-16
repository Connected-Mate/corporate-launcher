# Claude Code — wrapping reference

Loaded by the skill **only when `WRAPPED_CLIS` contains `claude-code`**. Authoritative for every Claude-Code-specific decision the launcher makes: backend choice, env vars, settings.json layout, strip-proxy, model IDs, telemetry, costs.

## Table of contents

1. [What it is](#1-what-it-is)
2. [Backend matrix](#2-backend-matrix)
3. [Required env vars](#3-required-env-vars)
4. [Per-backend env extras](#4-per-backend-env-extras)
5. [settings.json structure](#5-settingsjson-structure)
6. [Strip-proxy requirement](#6-strip-proxy-requirement)
7. [Model IDs (April 2026)](#7-model-ids-april-2026)
8. [Telemetry kill switches](#8-telemetry-kill-switches)
9. [Known issues](#9-known-issues)
10. [Cost reference](#10-cost-reference)

---

## 1. What it is

Claude Code is the official terminal CLI for the Claude family of models. Node.js binary, distributed via npm. Talks to any Anthropic-compatible `/v1/messages` endpoint (direct, Bedrock, Vertex, Foundry, or an OpenAI-compatible proxy like LiteLLM via translation).

- **Install:** `npm i -g @anthropic-ai/claude-code` (Node 18+; Node 22 recommended for system CA support)
- **Official docs:** https://docs.anthropic.com/claude/code
- **Repo:** https://github.com/anthropics/claude-code
- **Config home:** `~/.claude/` (`settings.json`, `CLAUDE.md`, `commands/`, `agents/`, `hooks/`)

The launcher does **not** run Claude Code with the vendor's default config — it shadows `~/.claude/settings.json` (or sets `CLAUDE_CONFIG_DIR`) so the wrapper controls every hook, MCP server, and permission.

---

## 2. Backend matrix

Pick exactly one of the five. Each row tells the launcher which env block to render and whether the SSE strip-proxy is needed.

| Backend | Auth | Strip-proxy? | Pros | Cons |
|---|---|---|---|---|
| **Anthropic direct** | Bearer (`sk-ant-…`) | No | Fastest features, native SSE, cheapest hop | Public egress — usually forbidden in regulated orgs |
| **AWS Bedrock** | SigV4 (AWS creds or IAM role) | **Yes** | Already in many corp AWS accounts; data residency in `eu-west-3`/`us-east-1` | SSE artefacts on tool-use chunks; cross-region inference profile names are mandatory |
| **Google Vertex AI** | ADC (gcloud) or service account | No (usually) | Same GCP project as the rest of the data platform; keyless via ADC | Region availability lags Anthropic direct by 2-6 weeks |
| **Azure AI Foundry** (preview) | Entra ID token / API key | No | Stays inside Azure tenant; reuses existing OpenAI deployment plumbing | Limited model SKUs; quota requests slow |
| **LiteLLM proxy** | Bearer (proxy-issued) | **Yes** | One gateway for *every* CLI in the org (Codex, Aider, opencode, Continue) | SSE artefacts identical to Bedrock; adds a hop |

Decision shortcut:
- The org already has a LiteLLM proxy → **LiteLLM**.
- AWS-first shop → **Bedrock**.
- GCP-first shop → **Vertex**.
- Azure-first shop → **Foundry** if available, else LiteLLM in front of Azure.
- Greenfield with no gateway and signed Anthropic contract → **Anthropic direct** (rare in regulated orgs).

---

## 3. Required env vars

Every Claude Code launch — regardless of backend — must export these three:

```bash
ANTHROPIC_BASE_URL=https://<gateway-or-127.0.0.1:9876>
ANTHROPIC_AUTH_TOKEN=<bearer-from-keychain>
ANTHROPIC_MODEL=<see §7>
```

Optional but recommended for every backend:

```bash
ANTHROPIC_DEFAULT_HAIKU_MODEL=<small-fast-model>   # replaces deprecated ANTHROPIC_SMALL_FAST_MODEL
CLAUDE_CODE_SKIP_UPDATE_CHECK=1                    # pin version, launcher controls upgrades
DISABLE_AUTOUPDATER=1                              # belt & braces
NODE_EXTRA_CA_CERTS=/etc/ssl/<corp-bundle>.pem     # corporate CA, Node-scoped
```

`ANTHROPIC_API_KEY` is accepted as a synonym for `ANTHROPIC_AUTH_TOKEN` but **the launcher prefers `_AUTH_TOKEN`** because some corporate gateways inject a separate `Authorization: Bearer` header and treat `ANTHROPIC_API_KEY` as a fallback.

---

## 4. Per-backend env extras

### Anthropic direct
No extras beyond §3. Token starts with `sk-ant-`.

### AWS Bedrock
```bash
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=eu-west-3                # or us-east-1, ap-northeast-1, etc.
AWS_ACCESS_KEY_ID=...               # or rely on IAM role / SSO profile
AWS_SECRET_ACCESS_KEY=...
AWS_SESSION_TOKEN=...               # if STS / SSO
ANTHROPIC_MODEL=eu.anthropic.claude-opus-4-7-v1:0   # cross-region inference ID — mandatory
CLAUDE_CODE_SKIP_BEDROCK_AUTH=1     # ONLY if the gateway re-signs SigV4 for the user
```

If `ANTHROPIC_BASE_URL` points at a LiteLLM proxy in front of Bedrock, omit the AWS vars (the proxy holds them) and leave `CLAUDE_CODE_USE_BEDROCK` **unset**.

### Google Vertex AI
```bash
CLAUDE_CODE_USE_VERTEX=1
ANTHROPIC_VERTEX_PROJECT_ID=<gcp-project>
CLOUD_ML_REGION=europe-west4        # or us-east5, asia-southeast1
ANTHROPIC_MODEL=claude-opus-4-7@20260101   # Vertex pins a publish date suffix
CLAUDE_CODE_SKIP_VERTEX_AUTH=1      # ONLY if the gateway holds the ADC token
GOOGLE_APPLICATION_CREDENTIALS=/path/sa.json   # or `gcloud auth application-default login`
```

### Azure AI Foundry
```bash
ANTHROPIC_BASE_URL=https://<foundry-endpoint>/openai/v1   # Foundry mounts Anthropic under /openai/v1
ANTHROPIC_AUTH_TOKEN=<entra-or-key>
ANTHROPIC_MODEL=<foundry-deployment-name>
```
No `CLAUDE_CODE_USE_*` flag — Foundry presents an OpenAI-shaped surface.

### LiteLLM proxy
```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:9876   # strip-proxy local listener (NOT the proxy URL!)
ANTHROPIC_AUTH_TOKEN=<litellm-virtual-key>
ANTHROPIC_MODEL=<model-alias-as-defined-in-litellm-yaml>
# strip-proxy.js then forwards to https://litellm.internal.<corp>/v1/messages
```
Do **not** set `CLAUDE_CODE_USE_BEDROCK` or `_USE_VERTEX` — LiteLLM normalizes.

---

## 5. settings.json structure

The launcher writes a single `~/.claude/settings.json` (or `<install>/settings.json` plus `CLAUDE_CONFIG_DIR`). Skeleton:

```jsonc
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "model": "${ANTHROPIC_MODEL}",
  "permissions": {
    "allow": ["Bash(git:*)", "Bash(npm:*)", "Read(**)", "Edit(**)"],
    "deny":  ["Bash(rm -rf:*)", "Bash(curl http*://*.anthropic.com*)"],
    "additionalDirectories": []
  },
  "hooks": {
    "PreToolUse":  [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "${INSTALL}/scripts/pre-tool-hook.py" }] }],
    "PostToolUse": [{ "matcher": "*",    "hooks": [{ "type": "command", "command": "${INSTALL}/scripts/cost-tracker.py" }] }],
    "Stop":        [{ "hooks": [{ "type": "command", "command": "${INSTALL}/scripts/session-end.sh" }] }]
  },
  "mcpServers": {
    "internal-docs": { "command": "node", "args": ["${INSTALL}/mcp/internal-docs.js"], "env": {} }
  },
  "statusLine": { "type": "command", "command": "${INSTALL}/scripts/statusline.sh" },
  "env": {
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_TELEMETRY": "1"
  },
  "includeCoAuthoredBy": false
}
```

Key blocks:
- **`permissions.allow` / `deny`** — gate every tool. `deny` always wins. Use `*` matchers conservatively.
- **`hooks`** — wire the launcher's `pre-tool-hook.py` (prompt filter), `cost-tracker.py` (SSE accounting), and any RSSI-mandated audit hook.
- **`mcpServers`** — the bundled MCP servers; the launcher templates this from the Phase-1 answers.
- **`env`** — these survive across sessions even if the user's shell forgets them.
- **`includeCoAuthoredBy: false`** — strips the vendor's auto-added co-author trailer from commits (brand hygiene).

---

## 6. Strip-proxy requirement

Claude Code expects strict SSE framing: every event line is `event: …\ndata: …\n\n` and `data:` is valid JSON. Both **Bedrock** and **LiteLLM** mangle this in two ways:

1. They emit `message_start` chunks where `usage.cache_creation_input_tokens` is sometimes a *string* — Claude Code's TypeScript types reject this and crashes the session.
2. They flush `data:` lines without the trailing blank line during high-throughput tool-use bursts, causing the client to merge two events.

The launcher's `templates/shared/strip-proxy.js.tpl` is a tiny Node HTTP server (default `127.0.0.1:9876`) that:
- Re-parses every SSE chunk.
- Coerces the offending fields to numbers.
- Re-emits proper `event:`/`data:`/blank-line framing.
- Forwards to the real upstream (`https://bedrock-runtime.<region>.amazonaws.com` or `https://litellm.<corp>.fr/v1/messages`).

When the launcher detects backend ∈ {Bedrock, LiteLLM}:
- `ANTHROPIC_BASE_URL` is set to `http://127.0.0.1:9876`
- `NO_PROXY` must include `127.0.0.1,localhost` (otherwise corp HTTP proxy hijacks the loopback)
- The strip-proxy is spawned by `launcher.sh` and reaped on `EXIT`/`INT`

Anthropic direct, Vertex, and Foundry do **not** need the strip-proxy — they emit clean SSE.

---

## 7. Model IDs (April 2026)

Current generally-available models. The launcher pins these — do not default to "latest".

| Family | Anthropic direct | Bedrock (cross-region inf.) | Vertex |
|---|---|---|---|
| **Opus 4.7** (flagship) | `claude-opus-4-7` | `eu.anthropic.claude-opus-4-7-v1:0` / `us.anthropic.claude-opus-4-7-v1:0` | `claude-opus-4-7@20260101` |
| **Sonnet 4.6** (workhorse) | `claude-sonnet-4-6` | `eu.anthropic.claude-sonnet-4-6-v1:0` | `claude-sonnet-4-6@20260101` |
| **Haiku 4.5** (small/fast) | `claude-haiku-4-5` | `eu.anthropic.claude-haiku-4-5-v1:0` | `claude-haiku-4-5@20260101` |

Notes:
- Bedrock IDs **must** carry the geo prefix (`eu.` / `us.` / `apac.`) — these are *inference profiles*, not raw model IDs. Calling the raw `anthropic.claude-opus-4-7-v1:0` without the profile fails with `ValidationException`.
- Vertex requires the `@<publish-date>` suffix.
- The default-haiku slot uses `ANTHROPIC_DEFAULT_HAIKU_MODEL` (the deprecated `ANTHROPIC_SMALL_FAST_MODEL` still works but emits a warning).
- Foundry deployments are user-named — the launcher asks for the deployment string during Phase 1.

---

## 8. Telemetry kill switches

Set all of these in `settings.json:env` **and** export them from `launcher.sh` (some are read before the JSON is parsed):

```bash
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1   # master switch — blocks Sentry, Statsig, GrowthBook
DISABLE_TELEMETRY=1
DO_NOT_TRACK=1
DISABLE_ERROR_REPORTING=1
DISABLE_BUG_COMMAND=1
CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
CLAUDE_CODE_DISABLE_VOICE=1                  # see §9
SENTRY_DSN=""
STATSIG_DISABLED=1
GROWTHBOOK_API_HOST=""
DD_TRACE_ENABLED=0
OTEL_EXPORTER_OTLP_ENDPOINT=""
BUN_ENABLE_CRASH_REPORTING=0
CLAUDE_CODE_SKIP_UPDATE_CHECK=1
DISABLE_AUTOUPDATER=1
```

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` alone covers most cases, but the explicit individual switches are kept as defense-in-depth (a future release could introduce a new endpoint that the master flag doesn't yet cover).

---

## 9. Known issues

- **Voice mode bypasses the gateway.** When `/voice` is invoked, Claude Code opens a direct WebSocket to `*.anthropic.com` regardless of `ANTHROPIC_BASE_URL`. Kill with `CLAUDE_CODE_DISABLE_VOICE=1` and add `Bash(curl *anthropic.com*)` to `permissions.deny`. The launcher always sets both.
- **`NODE_TLS_REJECT_UNAUTHORIZED=0` leaks.** If set globally it disables TLS verification for every Node process, not just Claude Code. The launcher only sets it inside its own process and only if the user explicitly accepted `ACCEPT_TLS_INSPECTION=yes` during the interview.
- **Bedrock cache token type drift.** Some Bedrock regions still emit `cache_creation_input_tokens` as a string under tool-use. Strip-proxy handles this; do not disable it.
- **MCP server stdout pollution.** Any MCP server that prints to stdout corrupts the JSON-RPC stream and crashes the session. The launcher's MCP wrappers redirect stdout → stderr.
- **`CLAUDE_CONFIG_DIR` vs `~/.claude`.** If the user already has a personal Claude Code install, the launcher sets `CLAUDE_CONFIG_DIR=<install>/.claude` so the corporate session is fully isolated from the personal one.
- **Auto-updater can revert the brand override.** Always pin via `CLAUDE_CODE_SKIP_UPDATE_CHECK=1` + `DISABLE_AUTOUPDATER=1`. Upgrades go through the distribution kit.

---

## 10. Cost reference

Public Anthropic list prices (USD per 1M tokens, April 2026). Bedrock/Vertex/Foundry typically match within ±5 %. The launcher's `cost-tracker.py` reads SSE `message_delta.usage` and writes a local JSONL — **never** ships it off-host.

| Model | Input | Output | Cache write | Cache read |
|---|---:|---:|---:|---:|
| **Opus 4.7** | $15.00 | $75.00 | $18.75 | $1.50 |
| **Sonnet 4.6** | $3.00 | $15.00 | $3.75 | $0.30 |
| **Haiku 4.5** | $0.80 | $4.00 | $1.00 | $0.08 |

Rules of thumb the launcher prints in the post-install summary:
- A heavy day on Opus = $20-$40 / dev. Sonnet for routine work cuts that 5×.
- Prompt caching is on by default in Claude Code — cache-read pricing is what most agent loops actually pay after the first turn.
- Bedrock cross-region inference adds a small surcharge in `eu-*` regions; confirm with FinOps before signing off.
