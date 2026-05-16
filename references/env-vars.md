# Environment variable reference

Authoritative catalog of every environment variable a corporate launcher template may set, plus the VS Code `settings.json` keys for Cline (which does not read env vars). Use this when filling in `interview-flow.md` answers, when writing a new template, or when an end-user complains "why is X being exported".

Sources: official 2026 docs of each CLI + the per-CLI deep-dives in `references/cli-*.md`.

---

## Table of contents

- [Universal launcher vars](#universal-launcher-vars)
- [Corporate proxy + CA (all CLIs)](#corporate-proxy--ca-all-clis)
- [Per-CLI env vars](#per-cli-env-vars)
  - [Claude Code](#claude-code)
  - [Codex CLI](#codex-cli)
  - [Gemini CLI](#gemini-cli)
  - [Aider](#aider)
  - [opencode](#opencode)
  - [Continue.dev](#continuedev)
  - [Cline (settings.json, not env)](#cline-settingsjson-not-env)
- [Backend x env var matrix](#backend-x-env-var-matrix)
- [Telemetry kill switches (cross-CLI)](#telemetry-kill-switches-cross-cli)
- [When to set what — decision tree](#when-to-set-what--decision-tree)

---

## Universal launcher vars

Set by every launcher RC block regardless of which CLI is bundled. `${CORP_SLUG_UPPER}` is the rendered slug (e.g. `ACME`).

| Var | Purpose | Notes |
|---|---|---|
| `${CORP_SLUG_UPPER}_HOME` | Install directory of the launcher | exported by the shell RC block |
| `${CORP_SLUG_UPPER}_ACTIVE` | `1` when a launcher session is running | used by status lines, hooks |
| `${CORP_SLUG_UPPER}_DRY_RUN` | `1` = print env and exit, do not exec the CLI | CI / smoke tests |
| `${CORP_SLUG_UPPER}_SESSION_START` | UNIX timestamp of the launch | used by cost tracker |
| `${CORP_SLUG_UPPER}_VERSION` | Launcher version string | used in the User-Agent |
| `INSTALL_DIR` | Resolved root of the rendered template | reused inside `settings.json`, prompts, MCP configs |
| `CORP_API_KEY` | Loaded token (in memory only) | never written to disk by the launcher |
| `CORP_MCP_TOKEN` | Token for corporate MCP servers (optional) | referenced as `{env:CORP_MCP_TOKEN}` in opencode / Cline |
| `CORP_CLIENT_KEY_PASSPHRASE` | mTLS private-key passphrase (optional) | placeholder only; never on disk |
| `ACCEPT_TLS_INSPECTION` | `yes` only if the corp proxy MITMs TLS and the CA is unavoidable | gate for every `*_REJECT_UNAUTHORIZED=0` |

---

## Corporate proxy + CA (all CLIs)

These are universal and apply to every CLI that uses Node, Python, or Rust HTTP stacks.

| Var | Purpose |
|---|---|
| `HTTP_PROXY` / `http_proxy` | Corporate HTTP proxy URL — set only if reachable |
| `HTTPS_PROXY` / `https_proxy` | Corporate HTTPS proxy URL |
| `NO_PROXY` / `no_proxy` | Bypass list (always includes `127.0.0.1,localhost` for the strip-proxy pattern) |
| `NODE_EXTRA_CA_CERTS` | Path to corporate PEM bundle (Node-based CLIs: Claude Code, Gemini, opencode, Continue) |
| `NODE_USE_SYSTEM_CA` | `1` to also trust the OS store (Node 22.15+) |
| `REQUESTS_CA_BUNDLE` | Same path (Python CLIs — Aider) |
| `SSL_CERT_FILE` | Same path (stdlib Python `ssl`, also Codex fallback) |
| `CODEX_CA_CERTIFICATE` | Same path (Codex CLI Rust) |
| `NODE_TLS_REJECT_UNAUTHORIZED` | `0` only if `ACCEPT_TLS_INSPECTION=yes` |
| `PYTHONHTTPSVERIFY` | `0` only if `ACCEPT_TLS_INSPECTION=yes` |

---

## Per-CLI env vars

### Claude Code

See `references/cli-claude-code.md` for the full deep-dive.

| Var | Purpose |
|---|---|
| `ANTHROPIC_BASE_URL` | Gateway URL (or `http://127.0.0.1:9876` if strip-proxy in use) |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token |
| `ANTHROPIC_API_KEY` | Alternative — used when no Bearer |
| `ANTHROPIC_MODEL` | Default model |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Small/fast model (replaces deprecated `ANTHROPIC_SMALL_FAST_MODEL`) |
| `CLAUDE_CODE_USE_BEDROCK` | `1` for direct Bedrock (skip if going through LiteLLM) |
| `CLAUDE_CODE_USE_VERTEX` | `1` for direct Vertex |
| `CLAUDE_CODE_USE_MANTLE` | `1` for Bedrock Mantle |
| `CLAUDE_CODE_SKIP_BEDROCK_AUTH` | `1` if the gateway handles AWS auth |
| `CLAUDE_CODE_SKIP_VERTEX_AUTH` | `1` if the gateway handles GCP auth |
| `CLAUDE_CODE_CERT_STORE` | `bundled,system` (default) — set `system` for OS-only |
| `CLAUDE_CODE_CLIENT_CERT` / `_KEY` / `_KEY_PASSPHRASE` | mTLS |
| `CLAUDE_CODE_SKIP_UPDATE_CHECK` | Pin version |
| `DISABLE_AUTOUPDATER` | Pin version (alt) |

### Codex CLI

See `references/cli-codex-cli.md`. Most settings live in `~/.codex/config.toml`.

| Var | Purpose |
|---|---|
| `OPENAI_API_KEY` | Standard auth (or backend-specific via `env_key` in `config.toml`) |
| `AZURE_OPENAI_API_KEY` | Conventional name for the Azure path |
| `OPENAI_BASE_URL` | Override (when not using `[model_providers]` block) |
| `CODEX_CA_CERTIFICATE` | Corp CA PEM |
| `SSL_CERT_FILE` | Fallback CA |
| `HTTPS_PROXY` | Partial support (issue #4242) |

### Gemini CLI

See `references/cli-gemini-cli.md`.

| Var | Purpose |
|---|---|
| `GEMINI_API_KEY` | AI Studio (consumer) — **unset for Vertex** |
| `GOOGLE_API_KEY` | GCP API key — **unset for Vertex ADC** |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to service-account JSON |
| `GOOGLE_CLOUD_PROJECT` | GCP project |
| `GOOGLE_CLOUD_LOCATION` | GCP region (e.g. `europe-west4`) |
| `GOOGLE_GENAI_USE_VERTEXAI` | `true` to force Vertex |
| `GOOGLE_GEMINI_BASE_URL` | Override gateway |
| `GOOGLE_VERTEX_BASE_URL` | Override Vertex endpoint |
| `GEMINI_MODEL` | Default model |
| `GEMINI_SANDBOX` | `docker` / `podman` for sandboxed tool exec |

### Aider

See `references/cli-aider.md`.

| Var | Purpose |
|---|---|
| `OPENAI_API_BASE` | LiteLLM / gateway URL |
| `OPENAI_API_KEY` | Token |
| `AIDER_MODEL` | Override default model |
| `AIDER_WEAK_MODEL` | Cheap model for commit messages |
| `AIDER_VERIFY_SSL` | `false` only if `ACCEPT_TLS_INSPECTION=yes` |
| `AIDER_SET_ENV` | Forward env vars to subprocess (sandbox) |
| `AZURE_API_BASE` | Direct Azure path |
| `REQUESTS_CA_BUNDLE` | Corp CA |

### opencode

See `references/cli-opencode.md`. Config lives in `~/.config/opencode/opencode.json`; the file supports `{env:VAR}` substitution.

| Var | Purpose |
|---|---|
| `OPENCODE_CONFIG` | Pin the config file path |
| `OPENAI_BASE_URL` | Gateway URL |
| `OPENAI_API_KEY` | Token (or use `{env:CORP_API_KEY}` inside JSON) |
| `ANTHROPIC_API_KEY` | Alt provider |
| `CORP_API_KEY` | Referenced as `{env:CORP_API_KEY}` in `opencode.json` |
| `CORP_MCP_TOKEN` | Referenced in MCP `headers` blocks |

### Continue.dev

See `references/cli-continue-dev.md`. No native env vars — all config in `~/.continue/config.yaml`. Continue resolves `${env:NAME}` at extension load from `process.env` of the IDE host.

| Var | Purpose |
|---|---|
| `CONTINUE_GLOBAL_DIR` | Alternate config root (lets corp config coexist with a personal one) |
| `CORP_API_KEY` | Referenced as `${env:CORP_API_KEY}` in YAML — never written to disk |
| `CORP_CLIENT_KEY_PASSPHRASE` | Referenced as `${env:CORP_CLIENT_KEY_PASSPHRASE}` for mTLS |

### Cline (settings.json, not env)

Cline is a VS Code extension and reads **VS Code settings**, not env vars. The launcher writes these keys into the workspace/user `settings.json`. See `references/cli-cline.md`.

| Key | Value | Purpose |
|---|---|---|
| `cline.apiProvider` | `"openai"` | Force the OpenAI-compatible path (LiteLLM / gateway) |
| `cline.openAiBaseUrl` | `${LLM_OPENAI_BASE_URL}` | Single egress point |
| `cline.openAiApiKey` | `${CORP_API_KEY}` | Token issued by `LLM_TOKEN_URL` (no raw vendor key) |
| `cline.openAiModelId` | `${LLM_PRIMARY_MODEL}` | Hides the model picker once set |
| `cline.openAiModelInfo` | `{supportsImages, contextWindow, maxTokens, …}` | Required when the model id is unknown to Cline's catalog |
| `cline.customInstructions` | path to `${INSTALL_DIR}/BRANDING.md` | Identity rebrand |
| `cline.allowAutoUpdate` | `false` | Pin the version the launcher tested |
| `cline.autoApprove` | `{enabled: false, actions: {all false}}` | No command auto-executes |
| `cline.mcpMarketplaceEnabled` | `false` | Stops users adding arbitrary MCP servers |
| `cline.enableCheckpoints` | `true` | Local git snapshots — safe |

(Telemetry keys for Cline are in the cross-CLI table below.)

---

## Backend x env var matrix

Which vars to set per backend. Each cell lists the **minimum** non-universal vars; proxy + CA always applies. `—` = not applicable.

| Backend | Claude Code | Codex CLI | Gemini CLI | Aider | opencode | Continue.dev |
|---|---|---|---|---|---|---|
| **Anthropic direct** | `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL` | — | — | `OPENAI_API_BASE` (via LiteLLM only) | `ANTHROPIC_API_KEY` | YAML provider `anthropic` + `${env:CORP_API_KEY}` |
| **AWS Bedrock** | `CLAUDE_CODE_USE_BEDROCK=1`, AWS creds or `_SKIP_BEDROCK_AUTH=1` | — | — | via LiteLLM | via LiteLLM | via LiteLLM |
| **GCP Vertex** | `CLAUDE_CODE_USE_VERTEX=1`, `_SKIP_VERTEX_AUTH=1` | — | `GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_APPLICATION_CREDENTIALS` | via LiteLLM | via LiteLLM | via LiteLLM |
| **Azure OpenAI** | via LiteLLM | `AZURE_OPENAI_API_KEY` + `[model_providers.azure]` in `config.toml` | — | `AZURE_API_BASE`, `OPENAI_API_KEY` | `OPENAI_BASE_URL` (Azure-shaped) | YAML provider `openai` pointed at Azure |
| **LiteLLM gateway** | `ANTHROPIC_BASE_URL` -> LiteLLM, `ANTHROPIC_AUTH_TOKEN` | `OPENAI_BASE_URL` -> LiteLLM | `GOOGLE_GEMINI_BASE_URL` -> LiteLLM | `OPENAI_API_BASE` -> LiteLLM | `OPENAI_BASE_URL` -> LiteLLM | YAML `apiBase` -> LiteLLM |

Rule of thumb: when a LiteLLM gateway is in front, **never** set the backend-specific `USE_BEDROCK` / `USE_VERTEX` flags — the gateway speaks the OpenAI / Anthropic protocol and any backend flag will short-circuit and bypass it.

---

## Telemetry kill switches (cross-CLI)

| Switch | Claude Code | Codex CLI | Gemini CLI | Aider | opencode | Continue.dev | Cline |
|---|---|---|---|---|---|---|---|
| Master | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | `disable_response_storage` (toml) | `GEMINI_TELEMETRY_ENABLED=false` | `AIDER_ANALYTICS_DISABLE=1` | `OPENCODE_DISABLE_TELEMETRY=1` | `allowAnonymousTelemetry: false` (yaml) | `cline.telemetryOptOut: true` |
| DNT | `DO_NOT_TRACK=1` | `DO_NOT_TRACK=1` | `DO_NOT_TRACK=1` | `DO_NOT_TRACK=1` | `DO_NOT_TRACK=1` | `DO_NOT_TRACK=1` | n/a |
| Errors | `DISABLE_ERROR_REPORTING=1`, `SENTRY_DSN=` | n/a | n/a | n/a | n/a | n/a | `cline.errorReportingOptOut: true` |
| Auto-update | `DISABLE_AUTOUPDATER=1`, `CLAUDE_CODE_SKIP_UPDATE_CHECK=1` | pin version in installer | — | pin via `pip` | pin via installer | pin via VSIX | `cline.allowAutoUpdate: false` |
| Misc | `STATSIG_DISABLED=1`, `GROWTHBOOK_API_HOST=`, `OTEL_EXPORTER_OTLP_ENDPOINT=`, `DD_TRACE_ENABLED=0`, `BUN_ENABLE_CRASH_REPORTING=0`, `DISABLE_BUG_COMMAND=1`, `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1`, `CLAUDE_CODE_DISABLE_VOICE=1` | — | — | — | — | `CONTINUE_TELEMETRY_DISABLED=1` (belt-and-suspenders) | `cline.mcpMarketplaceEnabled: false` |

---

## When to set what — decision tree

```
Q1. Which CLI is being launched?
    Claude Code -> ANTHROPIC_* + CLAUDE_CODE_* (see Claude Code table)
    Codex CLI   -> OPENAI_* / AZURE_* + ~/.codex/config.toml
    Gemini CLI  -> GEMINI_* + GOOGLE_* (Vertex vs AI Studio is exclusive)
    Aider       -> OPENAI_API_BASE + AIDER_*
    opencode    -> OPENCODE_CONFIG + {env:VAR} inside opencode.json
    Continue    -> no env vars, write ~/.continue/config.yaml with ${env:VAR}
    Cline       -> no env vars, write settings.json with cline.* keys

Q2. Which backend?
    LiteLLM gateway  -> set only the CLI's *_BASE_URL + token; never *_USE_BEDROCK / *_USE_VERTEX
    Direct Bedrock   -> CLAUDE_CODE_USE_BEDROCK=1 (+ skip-auth if gateway handles AWS sig)
    Direct Vertex    -> CLAUDE_CODE_USE_VERTEX=1 or GOOGLE_GENAI_USE_VERTEXAI=true + ADC
    Direct Azure     -> AZURE_OPENAI_API_KEY (Codex) or AZURE_API_BASE (Aider)
    Anthropic direct -> ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN (rare in corp)

Q3. Is there a corp proxy?
    Yes, plain  -> HTTPS_PROXY + NO_PROXY=127.0.0.1,localhost
    Yes, MITM   -> + NODE_EXTRA_CA_CERTS / REQUESTS_CA_BUNDLE / CODEX_CA_CERTIFICATE
    MITM forced -> + ACCEPT_TLS_INSPECTION=yes (then *_REJECT_UNAUTHORIZED=0 is legal)
    None        -> nothing

Q4. Telemetry posture?
    Strict (regulated industry) -> every switch in the cross-CLI table
    Standard                    -> master switch + DO_NOT_TRACK
    Permissive (rare)           -> leave defaults, log a banner

Q5. Auto-update?
    Always pin     -> DISABLE_AUTOUPDATER / CLAUDE_CODE_SKIP_UPDATE_CHECK / cline.allowAutoUpdate=false
    Allow patches  -> only the major-version pin in installer
```

When in doubt: read the relevant `cli-<name>.md` and `provider-matrix.md`, then come back here.
