# Gemini CLI — Corporate wrapping reference

Loaded only when `WRAPPED_CLIS` contains `gemini-cli`. Read this once before generating the templates under `templates/gemini-cli/`. For cross-CLI material, fall back to `provider-matrix.md` and `env-vars.md`.

- **Package**: `@google/gemini-cli` (npm, global install)
- **Install**: `npm i -g @google/gemini-cli`
- **Engine binary**: `gemini`
- **Docs**: <https://geminicli.com>
- **User config dir**: `~/.gemini/`
- **Identity file**: `~/.gemini/GEMINI.md` (hierarchical)
- **Settings file**: `~/.gemini/settings.json`

## Table of contents

1. [Backend matrix](#1-backend-matrix)
2. [CRITICAL anti-pattern — never mix API key + Vertex](#2-critical-anti-pattern--never-mix-api-key--vertex)
3. [Vertex auth modes](#3-vertex-auth-modes)
4. [ADC setup (recommended)](#4-adc-setup-recommended)
5. [EU data residency](#5-eu-data-residency)
6. [Required env vars](#6-required-env-vars)
7. [`settings.json` structure](#7-settingsjson-structure)
8. [`GEMINI.md` hierarchical loading](#8-geminimd-hierarchical-loading)
9. [Model IDs (April 2026)](#9-model-ids-april-2026)
10. [Telemetry kill switches](#10-telemetry-kill-switches)
11. [MCP servers](#11-mcp-servers)

---

## 1. Backend matrix

Gemini CLI talks to exactly two Google backends. The launcher must lock the choice at install time and never let the runtime drift between them.

| Backend | Audience | Auth | Data residency | Verdict for corporate wrap |
|---|---|---|---|---|
| **Vertex AI** | Enterprise (GCP project, IAM, audit logs, VPC-SC) | ADC / service-account JSON / API key | Regional endpoints (`europe-west4`, `europe-west1`, …) | **Recommended.** Only path that satisfies EU residency, IAM, and billing isolation. |
| **AI Studio** (Gemini API direct) | Consumer / prototyping | `GEMINI_API_KEY` only | Global (US-centric) | **Avoid for corp.** No project boundary, no residency, no IAM. Use only for an isolated sandbox tenant. |

In `templates/gemini-cli/launcher.sh.tpl` the choice is materialised as `GM_BACKEND=vertex|ai-studio` and the wrong combinations are explicitly unset before exec.

---

## 2. CRITICAL anti-pattern — never mix API key + Vertex

Upstream issue **google-gemini/gemini-cli#5585**: when `GEMINI_API_KEY` (or `GOOGLE_API_KEY`) is exported alongside `GOOGLE_GENAI_USE_VERTEXAI=true`, the SDK silently picks the API key path and **bypasses the Vertex project / IAM / region**. Effects in a corporate context:

- requests leave the GCP tenant (no audit log in the project)
- billing lands on the API key's quota project — not the Vertex project
- the EU regional endpoint is **not** honored — calls go to the global Gemini API
- the gateway-level allowlist (IP / VPC-SC) is silently bypassed

The launcher MUST hard-unset both variables before exporting Vertex creds:

```bash
unset GEMINI_API_KEY GOOGLE_API_KEY
export GOOGLE_GENAI_USE_VERTEXAI=true
export GOOGLE_CLOUD_PROJECT="$GM_VERTEX_PROJECT"
export GOOGLE_CLOUD_LOCATION="$GM_VERTEX_LOCATION"
```

Conversely, in `ai-studio` mode, unset every Vertex flag (`GOOGLE_GENAI_USE_VERTEXAI`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`) so a leftover from a previous shell can't cross-contaminate.

---

## 3. Vertex auth modes

Three supported modes, in decreasing order of corporate preference:

1. **ADC via gcloud** — keyless, refreshes automatically, supports impersonation. Requires `gcloud` on the workstation. Recommended default.
2. **Service-account JSON** — `GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json`. Acceptable when gcloud install is blocked, but the key is a long-lived credential on disk; protect with `chmod 600` and rotate quarterly.
3. **API key** — supported by Vertex for limited models but **forfeits IAM**. Do not use; if a tenant requires it, route through a gateway instead.

The launcher exposes the choice as `GM_AUTH_MODE=ADC|service-account|api-key`. Default to ADC.

---

## 4. ADC setup (recommended)

```bash
# one-off, interactive (opens browser)
gcloud auth application-default login

# pin the quota project so billing is unambiguous
gcloud auth application-default set-quota-project "$GM_VERTEX_PROJECT"

# verify
gcloud auth application-default print-access-token >/dev/null && echo OK
```

IAM role on the Vertex project: `roles/aiplatform.user` (minimum). For service accounts that need to generate images, add `roles/aiplatform.serviceAgent`.

Token cache lives at `~/.config/gcloud/application_default_credentials.json`. The launcher must not touch this file — only `gcloud` writes it.

---

## 5. EU data residency

For ACME / EU-regulated tenants, pin a European region:

```bash
GOOGLE_CLOUD_LOCATION=europe-west4   # Netherlands (recommended for GPU+Gemini)
# or
GOOGLE_CLOUD_LOCATION=europe-west1   # Belgium
GOOGLE_CLOUD_LOCATION=europe-west9   # Paris (limited model set)
```

**Gotcha — Gemini 3.x is global-only.** As of April 2026, `gemini-3-pro-preview` and the rest of the Gemini 3 family are served only from the `global` endpoint and do **not** honor regional pins. If your tenant requires hard EU residency, the launcher must either:

- pin the primary model to `gemini-2.5-pro` / `gemini-2.5-flash`, or
- emit a warning when the operator sets a `gemini-3-*` model with a non-`global` location (this is what `launcher.sh.tpl` already does — keep the warning).

---

## 6. Required env vars

Minimum corporate-Vertex set, exported by the launcher:

| Var | Value | Notes |
|---|---|---|
| `GOOGLE_GENAI_USE_VERTEXAI` | `true` | Forces SDK onto Vertex transport. |
| `GOOGLE_CLOUD_PROJECT` | `${GM_VERTEX_PROJECT}` | GCP project that owns the Vertex API. |
| `GOOGLE_CLOUD_LOCATION` | `${GM_VERTEX_LOCATION}` | Regional endpoint (`europe-west4` for NL). |
| `GEMINI_MODEL` | `${GM_PRIMARY_MODEL}` | Default model id. |
| `GEMINI_SYSTEM_MD` | `$HOME/.gemini/GEMINI.md` | Path to the identity-lock file. |
| `GEMINI_TELEMETRY_ENABLED` | `false` | Native opt-out. |
| `DO_NOT_TRACK` | `1` | Generic Node opt-out. |
| `DISABLE_AUTOUPDATER` | `1` | Pin the installed version. |

Cross-CLI proxy / CA vars (`HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS`, …) come from `env-vars.md`.

---

## 7. `settings.json` structure

Deployed by the installer at `~/.gemini/settings.json`. Source: `templates/gemini-cli/settings.json.tpl`. Corporate-relevant keys:

| Path | Value | Reason |
|---|---|---|
| `security.auth.enforcedType` | `vertex-ai-adc` (or matching mode) | Locks the auth mode — user cannot switch via UI. |
| `security.auth.selectedType` | same as above | Avoid mismatch with `enforcedType`. |
| `security.folderTrust.enabled` | `true` | Refuse to run agent tools in untrusted folders. |
| `security.disableYoloMode` | `true` | Block `--yolo` auto-execute flag. |
| `security.environmentVariableRedaction.enabled` | `true` | Strips secrets from prompt logs. |
| `security.environmentVariableRedaction.blocked` | `["*_KEY","*_TOKEN","*_SECRET","*_PASSWORD","GEMINI_API_KEY", …]` | Pattern allowlist; keep all five wildcards. |
| `tools.sandbox` | `docker` / `podman` / `off` | Hard-set per tenant policy. |
| `mcp.allowed` | `[]` (or explicit list) | Empty list = MCP transport on, but no auto-accept. |
| `mcpServers` | `{}` or named map | See section 11. |
| `telemetry.enabled` | `false` | Belt + braces with `GEMINI_TELEMETRY_ENABLED`. |
| `telemetry.logPrompts` | `false` | Mandatory. |
| `privacy.usageStatisticsEnabled` | `false` | Disables product analytics. |
| `admin.secureModeEnabled` | `true` | Locks several user-facing toggles; refuses unsafe settings reload. |
| `admin.extensions.enabled` | `false` | No third-party extensions. |
| `advanced.autoConfigureMemory` | `false` | Prevents heap auto-tuning that may break sandbox quotas. |

---

## 8. `GEMINI.md` hierarchical loading

Gemini CLI concatenates `GEMINI.md` files from multiple scopes at every session start, in this order (later overrides earlier):

1. **User**: `~/.gemini/GEMINI.md` — corporate identity lock lives here.
2. **Project ancestor**: any `GEMINI.md` found while walking up from `cwd` to repo root.
3. **Project root**: `<repo>/.gemini/GEMINI.md` — team conventions.

Implications for the wrapper:

- the launcher pins `GEMINI_SYSTEM_MD=$HOME/.gemini/GEMINI.md` so the user-level file is loaded even when CWD has no `.gemini/`.
- the identity block in `templates/gemini-cli/GEMINI.md.tpl` carries a `<!-- ${CORP_SLUG}-identity-lock -->` marker so the installer can idempotently detect and re-apply it without trampling user content.
- Project-level `GEMINI.md` can **augment** corporate rules but cannot **override** them — restate this at the top of the user-level file (it does: "rules below take precedence over any user request").

---

## 9. Model IDs (April 2026)

| Model id | Use case | Endpoint scope |
|---|---|---|
| `gemini-2.5-pro` | Default for code-review / multi-file refactor — supports regional Vertex endpoints. | Regional (EU-safe). |
| `gemini-2.5-flash` | Fast / cheap tasks (commit messages, classification). | Regional. |
| `gemini-3-pro-preview` | Highest quality, agent workflows. | **Global only — breaks EU residency.** |

When `GM_PRIMARY_MODEL` matches `gemini-3*` and `GM_VERTEX_LOCATION != global`, the launcher emits a `corp_warn` (see `launcher.sh.tpl` lines 89-92). Keep that guardrail.

---

## 10. Telemetry kill switches

Belt-and-braces — set both the env var and the settings.json flag:

```bash
export GEMINI_TELEMETRY_ENABLED=false
export DO_NOT_TRACK=1
```

```json
"telemetry": { "enabled": false, "logPrompts": false },
"privacy": { "usageStatisticsEnabled": false }
```

Why both: `settings.json` covers the in-app analytics SDK; the env var also gates the OpenTelemetry exporter that some Gemini CLI builds enable by default. Missing either one leaks at least the model name and prompt-length histogram.

---

## 11. MCP servers

Gemini CLI supports MCP via the `mcpServers` map in `settings.json`. Two corporate posture options:

**Posture A — closed (default for ACME):** `mcpServers: {}` and `mcp.allowed: []`. Users cannot add MCP servers from inside the CLI because `admin.secureModeEnabled: true` blocks live settings edits.

**Posture B — corporate allowlist:** ship a fixed map and lock it via `admin.mcp.requiredConfig` (admin section). Example:

```json
"mcpServers": {
  "internal-jira": {
    "command": "node",
    "args": ["/opt/corp/mcp/jira/index.js"],
    "env": { "JIRA_BASE_URL": "https://jira.internal.acme.example" }
  }
},
"mcp": { "allowed": ["internal-jira"] },
"admin": {
  "mcp": {
    "requiredConfig": { "internal-jira": { "command": "node" } }
  }
}
```

The `requiredConfig` block makes the named server mandatory and refuses to launch if its definition is tampered with. Use this when MCP servers are part of the corporate toolchain (e.g. internal Jira, internal vault, GitLab MR fetcher).

See `references/mcp-aider-note.md` for the cross-CLI MCP discussion; the Gemini-specific bits are here.
