# opencode — corporate wrapping reference

Loaded only when `WRAPPED_CLIS` contains `opencode`. Companion to
`provider-matrix.md` (row "opencode") and `templates/opencode/*`.

## Table of contents

1. [Overview](#overview)
2. [Why Tier S](#why-tier-s)
3. [Required env vars](#required-env-vars)
4. [opencode.json structure](#opencodejson-structure)
5. [CA bundle](#ca-bundle)
6. [MCP support](#mcp-support)
7. [Provider lockdown](#provider-lockdown)
8. [Telemetry kill switches](#telemetry-kill-switches)
9. [Share / collab features](#share--collab-features)
10. [Model IDs and pricing](#model-ids-and-pricing)

## Overview

`opencode` is a multi-provider terminal UI (TUI) for AI-assisted coding.
Node-based, OpenAI-compatible by default, distributed via npm.

- **Install** : `npm i -g opencode-ai`
- **Binary** : `opencode`
- **Docs** : <https://opencode.ai/docs>
- **Config file** : `~/.config/opencode/opencode.json`
- **Source** : <https://github.com/sst/opencode>

## Why Tier S

opencode wraps cleanly because:

1. **`{env:VAR}` substitution inside JSON config.** The config file can
   reference environment variables literally as `"apiKey": "{env:CORP_API_KEY}"`.
   No secret on disk — the launcher exports `CORP_API_KEY` at process start
   and opencode resolves it at read time.
2. **OpenAI-compatible by default.** Any corporate LiteLLM / Azure / custom
   gateway that speaks `/v1/chat/completions` plugs in through
   `OPENAI_BASE_URL` + `OPENAI_API_KEY` without provider-specific glue.
3. **No system mutation needed.** The launcher only exports env vars and
   writes one JSON file under `~/.config/opencode/`.

See `templates/opencode/launcher.sh.tpl` lines 60-83 for the full env-var
preamble used in the generated launcher.

## Required env vars

The launcher sets these before `exec opencode "$@"`:

```sh
export OPENAI_BASE_URL="${LLM_OPENAI_BASE_URL}"   # corporate gateway URL
export OPENAI_API_KEY="$CORP_API_KEY"             # loaded from keychain
export OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
```

`OPENCODE_CONFIG` is pinned so the user cannot accidentally read a
user-edited config from `$PWD/opencode.json` (opencode also searches the
current directory and walks upward).

## opencode.json structure

The template at `templates/opencode/opencode.json.tpl` produces:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "${LLM_PROVIDER_ID}": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "${CORP_NAME}",
      "options": {
        "baseURL": "${LLM_OPENAI_BASE_URL}",
        "apiKey": "{env:CORP_API_KEY}"
      },
      "models": {
        "${LLM_PRIMARY_MODEL}": { "name": "${LLM_PRIMARY_MODEL}" }
      }
    }
  },
  "model": "${LLM_PROVIDER_ID}/${LLM_PRIMARY_MODEL}",
  "share": "disabled",
  "autoupdate": false,
  "disabled_providers": ["anthropic", "openai", "google", "github-copilot"]
}
```

Key fields:

- **`provider.<id>.npm`** — the AI SDK adapter package. For
  OpenAI-compatible gateways, always `@ai-sdk/openai-compatible`.
- **`provider.<id>.name`** — display label in the TUI (rebranded to
  `${CORP_NAME}` so users see the corporate identity, not "OpenAI").
- **`model`** — fully qualified default (`<provider-id>/<model-id>`).
- **`share: "disabled"`** — kills cloud session sharing (see below).
- **`autoupdate: false`** — pins the version. Updates flow through the
  corporate npm registry, not opencode's own update path.
- **`disabled_providers`** — defense-in-depth (see below).

Permissions on the written file are `0600` (`install.sh.tpl` line 109)
since the config holds a baseURL that may leak internal hostnames.

## CA bundle

opencode runs on Node.js, so it honors the standard Node CA bundle var:

```sh
export NODE_EXTRA_CA_CERTS=/etc/ssl/acme-corp-bundle.pem
```

The launcher calls `setup_ca_bundle` (from `scripts/proxy-detect.sh`)
which exports `NODE_EXTRA_CA_CERTS` when `CA_BUNDLE_PATH` is configured.
Same variable as Claude Code, Gemini CLI, Continue.dev, Cline — see
`references/provider-matrix.md` § "Corporate proxy + CA".

Never set `NODE_TLS_REJECT_UNAUTHORIZED=0` globally.

## MCP support

opencode has **native MCP support** via the `mcp` top-level key in
`opencode.json`. Two transports:

- **`type: "local"`** — stdio MCP server, launched as a subprocess.
- **`type: "remote"`** — HTTP MCP server, contacted over the network.

Example block (added by `scripts/install-mcp.sh` when the interview asks
for MCP servers):

```json
{
  "mcp": {
    "code-graph": {
      "type": "local",
      "command": ["uvx", "code-review-graph-mcp"],
      "environment": { "GRAPH_DB": "/var/lib/code-graph.db" }
    },
    "internal-wiki": {
      "type": "remote",
      "url": "https://mcp.internal.acme.fr/wiki",
      "headers": { "Authorization": "Bearer {env:CORP_MCP_TOKEN}" }
    }
  }
}
```

`{env:...}` substitution works inside MCP `headers` and `environment`
blocks too — same mechanism as the provider block.

## Provider lockdown

If `OPENAI_API_KEY` ever ends up looking like a real OpenAI key (e.g. a
user pastes a personal `sk-...` into their shell), opencode would happily
route to public OpenAI. `disabled_providers` blocks this:

```json
"disabled_providers": ["anthropic", "openai", "google", "github-copilot"]
```

These entries disable opencode's built-in adapters for public providers,
even if matching env vars are present. The only reachable provider is the
custom one defined in the `provider` block, which points at the corporate
`baseURL`. Defense-in-depth against accidental data exfiltration.

## Telemetry kill switches

Exported in `launcher.sh.tpl` lines 67-74:

```sh
export OPENCODE_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export SENTRY_DSN=""
export OTEL_EXPORTER_OTLP_ENDPOINT=""
export OTEL_EXPORTER_OTLP_HEADERS=""
```

- `OPENCODE_DISABLE_TELEMETRY=1` — project-specific master switch.
- `DO_NOT_TRACK=1` — generic Node ecosystem opt-out, also honored.
- `SENTRY_DSN=""` — blanks the embedded Sentry DSN at runtime.
- `OTEL_*` — blocks OpenTelemetry export to upstream collectors.

Combined with `autoupdate: false` in the JSON, no outbound traffic leaves
the corporate gateway path.

## Share / collab features

opencode ships a built-in "share session" feature that uploads transcripts
to opencode's hosted backend for collaboration. **Always disabled** in
the corporate config:

```json
"share": "disabled"
```

Accepted values: `"manual"` (default — opt-in per session),
`"auto"` (every session shared), `"disabled"` (locked off). For a
corporate launcher only `"disabled"` is acceptable — sharing a session
would exfiltrate source code, prompts, and any embedded secrets through
a third-party endpoint outside the audited gateway.

## Model IDs and pricing

opencode itself does not impose a model catalog when using the
OpenAI-compatible adapter — the available model IDs are entirely
determined by what the corporate gateway exposes at `OPENAI_BASE_URL`.

Examples:

- LiteLLM gateway: model IDs are the LiteLLM aliases configured
  server-side (e.g. `claude-opus-4-7`, `gpt-5-codex`,
  `mistral-large-latest`).
- Azure OpenAI passthrough: the Azure deployment name.
- Vertex/Bedrock behind a LiteLLM proxy: the upstream model ID
  (e.g. `eu.anthropic.claude-opus-4-7-v1:0`).

Pricing is **never** computed by opencode in this setup — it is the
corporate gateway's job (and `scripts/cost-tracker.py` reads the
gateway's response headers, not opencode's local log).

## Cross-references

- `references/provider-matrix.md` — row "opencode" + § "Telemetry kill
  switches".
- `references/env-vars.md` — full env-var catalog.
- `references/security-patterns.md` — process isolation, `{env:VAR}`
  substitution rationale.
- `templates/opencode/` — generated files (launcher, installer, config,
  uninstaller).
