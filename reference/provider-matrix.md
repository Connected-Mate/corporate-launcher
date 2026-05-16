# Provider × Backend Matrix

How each AI coding CLI can be wrapped onto a corporate gateway. Use this to validate the user's DOG answers in Phase 1.

## Tier S — wrap trivial, fully ENV-driven

| CLI | npm/install | Backend | Key env vars | Config file | Notes |
|---|---|---|---|---|---|
| **Claude Code** | `npm i -g @anthropic-ai/claude-code` | Anthropic / Bedrock / Vertex / LiteLLM | `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` | `~/.claude/settings.json` | Bedrock/LiteLLM need a strip-proxy for SSE artefacts. |
| **Gemini CLI** | `npm i -g @google/gemini-cli` | AI Studio / Vertex AI | `GEMINI_API_KEY` (AI Studio) **or** `GOOGLE_GENAI_USE_VERTEXAI=true` + `GOOGLE_CLOUD_PROJECT` + `GOOGLE_CLOUD_LOCATION` (Vertex) | `~/.gemini/settings.json`, `GEMINI.md` | NEVER mix `GEMINI_API_KEY` and Vertex (issue #5585). Prefer ADC via gcloud for keyless. |
| **Aider** | `pipx install aider-install` | OpenAI / Anthropic / Bedrock / Azure / Vertex (via LiteLLM) | `OPENAI_API_KEY`, `OPENAI_API_BASE`, `AIDER_VERIFY_SSL`, `AZURE_API_BASE` | `~/.aider.conf.yml` | The cleanest CLI to wrap. 100% ENV-driven. |
| **opencode** | `npm i -g opencode-ai` | OpenAI / Anthropic / Bedrock / Vertex / Azure | `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `ANTHROPIC_API_KEY` | `~/.config/opencode/opencode.json` | `{env:VAR}` substitution inside JSON config. |
| **Continue.dev** | VS Code / JetBrains extension | All major | (none native — `{env:VAR}` substitution inside YAML) | `~/.continue/config.yaml` | `requestOptions.{proxy, caBundlePath, clientCertificate}` for corp proxy. |

## Tier A — wrap moderate (CLI is GUI/IDE-driven, pre-deploy a config)

| CLI | Approach |
|---|---|
| **Cline** (VS Code) | Pre-deploy `settings.json` with `cline.apiProvider=openai-compatible`, `cline.baseUrl`, `cline.apiKey`. Respects `NODE_EXTRA_CA_CERTS` and `HTTPS_PROXY`. |
| **Sourcegraph Cody** | Site config server-side. The "launcher" pushes `SRC_ENDPOINT` + token. |
| **Codex CLI** | `~/.codex/config.toml` + `requirements.toml` (admin lockdown). Use `CODEX_CA_CERTIFICATE` for corp CA. Known bug: `HTTPS_PROXY` not yet honored everywhere (issue #4242 — workaround = transparent proxy at network level). |

## Tier B — out of scope (need infra deployment, not a launcher)

| CLI | Why excluded |
|---|---|
| **Cursor** | GUI-only Electron app. Requires HTTPS public URL — incompatible with an internal-only gateway unless you expose it via Cloudflare/AWS LB. |
| **Windsurf** | Enterprise variant is full self-host (Docker Compose / Helm). The "launcher" becomes an ops project. |
| **Tabnine Enterprise** | Config via admin GUI server-side. No file to template. |

## Backend × env var reference

### Anthropic direct
```
ANTHROPIC_BASE_URL=https://api.anthropic.com
ANTHROPIC_AUTH_TOKEN=sk-ant-...
ANTHROPIC_MODEL=claude-opus-4-7  # or claude-sonnet-4-6, claude-haiku-4-5
```

### AWS Bedrock (Claude Code)
```
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=eu-west-3
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
ANTHROPIC_MODEL=eu.anthropic.claude-opus-4-7-v1:0   # cross-region inference profile
```

### Google Vertex AI (Claude Code via Vertex)
```
CLAUDE_CODE_USE_VERTEX=1
ANTHROPIC_VERTEX_PROJECT_ID=my-gcp-project
CLOUD_ML_REGION=europe-west4
ANTHROPIC_MODEL=claude-opus-4-7@20260101
```

### Google Vertex AI (Gemini CLI)
```
GOOGLE_GENAI_USE_VERTEXAI=true
GOOGLE_CLOUD_PROJECT=my-gcp-project
GOOGLE_CLOUD_LOCATION=europe-west4
# auth via `gcloud auth application-default login` — no key on disk
unset GEMINI_API_KEY GOOGLE_API_KEY   # important
```

### Azure OpenAI (Codex CLI)
```toml
# ~/.codex/config.toml
model = "gpt-5-codex"
model_provider = "azure"

[model_providers.azure]
name = "Azure OpenAI"
base_url = "https://my-resource.openai.azure.com/openai/v1"
env_key = "AZURE_OPENAI_API_KEY"
wire_api = "responses"
```

### LiteLLM proxy (any CLI, OpenAI-compatible)
```
OPENAI_API_KEY=$LITELLM_TOKEN
OPENAI_BASE_URL=https://litellm.internal.acme.fr/v1
```

## Corporate proxy + CA — universal env vars

```
HTTPS_PROXY=http://proxy.acme.fr:8080
HTTP_PROXY=http://proxy.acme.fr:8080
NO_PROXY=127.0.0.1,localhost,.internal.acme.fr

# Node.js (Claude Code, Gemini CLI, opencode, Cline)
NODE_EXTRA_CA_CERTS=/etc/ssl/acme-corp-bundle.pem

# Python (Aider)
REQUESTS_CA_BUNDLE=/etc/ssl/acme-corp-bundle.pem
SSL_CERT_FILE=/etc/ssl/acme-corp-bundle.pem

# Codex CLI (Rust)
CODEX_CA_CERTIFICATE=/etc/ssl/acme-corp-bundle.pem
```

Never set `NODE_TLS_REJECT_UNAUTHORIZED=0` globally — only inside the launcher process if the CA bundle path is unknown and the user explicitly accepts the risk during the interview.

## Telemetry kill switches (cross-CLI)

| Var | CLI | Effect |
|---|---|---|
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | Claude Code | Master kill switch — blocks Sentry, Statsig, GrowthBook |
| `DO_NOT_TRACK=1` | All Node CLIs | Generic opt-out |
| `STATSIG_DISABLED=1` | Claude Code | Feature flags off |
| `SENTRY_DSN=""` | Claude Code, opencode | Disable Sentry |
| `DD_TRACE_ENABLED=0` | All | Disable Datadog |
| `OTEL_EXPORTER_OTLP_ENDPOINT=""` | All | Block OTLP export |
| `GEMINI_TELEMETRY_ENABLED=false` | Gemini CLI | Native flag |
| `[analytics] enabled = false` | Codex CLI | In `config.toml` |
| `CLAUDE_CODE_SKIP_UPDATE_CHECK=1` | Claude Code | No version probe |
| `DISABLE_AUTOUPDATER=1` | All | Pin the version |
