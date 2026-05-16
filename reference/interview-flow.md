# Interview Flow — The DOG questionnaire

Walk the user through every section in order. Use `AskUserQuestion` for each step. Skip a section only if a previous answer made it irrelevant (e.g. no proxy → skip CA bundle).

Save the answers under uppercase snake_case keys (`CORP_NAME`, `LLM_PRIMARY_URL`, etc.) — those are the variables the templates expect.

---

## Section 1 — Identity

| Var | Question | Type | Default |
|---|---|---|---|
| `CORP_NAME` | What's the brand name of your launcher? (e.g. `Patrick Code`, `Acme AI`) | string | required |
| `CORP_SLUG` | Short slug for the binary (lowercase, hyphens) | string | derived from `CORP_NAME` |
| `CORP_POWERED_BY` | Who's the internal sponsor / "powered by"? (e.g. `TGV Europe`, `Group AI Lab`) | string | required |
| `CORP_ORGANIZATION` | Legal entity / group name | string | required |
| `CORP_TAGLINE` | One-line tagline shown in the banner | string | `Internal AI assistant` |
| `CORP_LICENSE_NOTE` | Internal compliance / license line | string | `Internal use only` |

If the user is at SNCF, suggest the SNCF example. If at another bank/insurance/telco, default to generic.

---

## Section 2 — Provider (which CLI to wrap)

Ask: "Which AI coding CLI do you want to wrap?"

Multi-select allowed (multiSelect=true) — the install produces one launcher per CLI but a shared config.

Options:
1. **Claude Code** (Anthropic) — most mature, best for Bedrock/Vertex/LiteLLM
2. **Codex CLI** (OpenAI) — Azure OpenAI / OpenAI Enterprise
3. **Gemini CLI** (Google) — Vertex AI / AI Studio
4. **Aider** (Python, multi-provider) — cleanest wrap, LiteLLM-friendly
5. **opencode** (multi-provider TUI) — JSON-config-driven
6. **Continue.dev** (VS Code/JetBrains extension) — YAML-config-driven

Save as `WRAPPED_CLIS=["claude-code","codex-cli",...]`.

For each selected CLI, ask the CLI-specific questions in Section 3.

---

## Section 3 — Backend (per CLI)

Branch on `WRAPPED_CLIS`:

### 3.A — Claude Code branch

| Var | Question | Type | Default |
|---|---|---|---|
| `CC_BACKEND` | Anthropic direct / AWS Bedrock / Google Vertex / Microsoft Foundry / LiteLLM gateway / Custom OpenAI-compatible | enum | required |
| `CC_PRIMARY_URL` | Gateway URL (e.g. `https://socle.ia.acme.fr`) | url | required |
| `CC_FALLBACK_URL` | Optional secondary gateway URL | url | empty |
| `CC_PRIMARY_MODEL` | Default model ID for this gateway | string | `claude-sonnet-4-6` |
| `CC_HAIKU_MODEL` | Small/fast model ID (for compaction, summarization) | string | `claude-haiku-4-5` |
| `CC_AUTH_MODEL` | Bearer token / API key / AWS SDK chain / GCP ADC | enum | required |
| `CC_NEEDS_STRIP_PROXY` | Does the gateway return Bedrock/LiteLLM SSE artefacts? | yes/no | yes if Bedrock or LiteLLM |
| `CC_BEDROCK_REGION` | (Bedrock only) AWS region | string | `eu-west-3` |
| `CC_VERTEX_PROJECT` | (Vertex only) GCP project ID | string | required |
| `CC_VERTEX_REGION` | (Vertex only) GCP region | string | `europe-west4` |

### 3.B — Codex CLI branch

| Var | Question | Type | Default |
|---|---|---|---|
| `CX_BACKEND` | OpenAI direct / Azure OpenAI / Amazon Bedrock (gpt models) / Custom OpenAI-compatible | enum | required |
| `CX_PRIMARY_URL` | Gateway URL | url | required |
| `CX_PRIMARY_MODEL` | Default model | string | `gpt-5-codex` |
| `CX_AUTH_ENV_KEY` | Env var name holding the token (e.g. `AZURE_OPENAI_API_KEY`) | string | `OPENAI_API_KEY` |
| `CX_WIRE_API` | `responses` / `chat-completions` | enum | `responses` |
| `CX_REQUIRE_LOCKDOWN` | Generate `/etc/codex/requirements.toml` to ban modifying the provider? | yes/no | yes |

### 3.C — Gemini CLI branch

| Var | Question | Type | Default |
|---|---|---|---|
| `GM_BACKEND` | Vertex AI / AI Studio | enum | required |
| `GM_PRIMARY_MODEL` | Default model | string | `gemini-2.5-pro` |
| `GM_VERTEX_PROJECT` | (Vertex) GCP project | string | required if Vertex |
| `GM_VERTEX_LOCATION` | (Vertex) region — EU compliance use `europe-west4` | string | `europe-west4` |
| `GM_AUTH_MODE` | ADC (gcloud) / service-account / API key | enum | `ADC` if Vertex |
| `GM_FORCE_VERTEX` | Generate system settings.json forcing Vertex? | yes/no | yes |

### 3.D — Aider / opencode / Continue.dev branch

Common questions:

| Var | Question | Default |
|---|---|---|
| `LLM_OPENAI_BASE_URL` | OpenAI-compatible base URL (LiteLLM, Azure, etc.) | required |
| `LLM_OPENAI_AUTH` | Bearer token / API key | required |
| `LLM_PRIMARY_MODEL` | Default model name on the gateway | required |

---

## Section 4 — Network

| Var | Question | Type | Default |
|---|---|---|---|
| `VPN_REQUIRED` | Does the user need a corporate VPN before launching? | yes/no | yes |
| `VPN_PROBE_URL` | Internal-only URL to probe (HTTP code ≠ 000 = VPN OK) | url | derived from gateway hostname |
| `PROXY_HOST` | Corporate HTTP proxy hostname | string | empty |
| `PROXY_PORT` | Corporate HTTP proxy port | number | `8080` |
| `PROXY_REQUIRE_AUTH` | Does the proxy require basic auth? | yes/no | no |
| `NO_PROXY_LIST` | Comma-separated bypass list | string | `127.0.0.1,localhost` + gateway hostname |
| `CA_BUNDLE_PATH` | Path to corporate CA bundle (PEM) | path | empty |
| `CA_DETECT_AUTO` | Auto-extract from OS trust store at install time? | yes/no | yes |
| `ACCEPT_TLS_INSPECTION` | Allow `NODE_TLS_REJECT_UNAUTHORIZED=0` fallback if no CA found? | yes/no | no |

---

## Section 5 — Cyber

| Var | Question | Type | Default |
|---|---|---|---|
| `CYBER_RULES_FILE` | Path to your corporate cyber rules markdown (or use default 15-control baseline) | path | `shared/cyber-rules.md` |
| `CYBER_AUTHORITY` | Name of the corporate cyber authority (e.g. `Direction Cybersécurité Acme`) | string | required |
| `BLOCK_TELEMETRY` | Disable all telemetry to the CLI vendor? | yes/no | yes |
| `BLOCK_AUTO_UPDATE` | Lock the CLI version (no auto-update)? | yes/no | yes |
| `BLOCK_FEEDBACK_CMDS` | Hide `/bug`, `/feedback` commands? | yes/no | yes |
| `BLOCK_VOICE_MODE` | Disable voice mode (often calls vendor WS directly)? | yes/no | yes |
| `COST_TRACKING_ENABLED` | Log per-request cost (EUR/USD) to a local JSONL? | yes/no | yes |
| `COST_CURRENCY` | `EUR` / `USD` / `GBP` | enum | `EUR` |
| `PROMPT_FILTER_ENABLED` | Block prompts containing secrets/PII patterns? | yes/no | yes |

---

## Section 6 — Branding

| Var | Question | Type | Default |
|---|---|---|---|
| `BRANDING_SYSTEM_PROMPT` | Custom system prompt addendum (rebrand identity) | textarea | generated from `CORP_NAME` |
| `BANNER_COLOR_PRIMARY` | ANSI color code or name (e.g. `208` for orange) | string | `208` |
| `TERMINAL_TITLE` | String set as terminal title at launch | string | `${CORP_NAME} — Powered by ${CORP_POWERED_BY}` |
| `LANGUAGE` | Default response language | enum (`fr`, `en`, ...) | `en` |
| `FORBIDDEN_TERMS` | Comma-separated words the assistant must never output (e.g. vendor names) | string | `Claude,Anthropic` for Claude Code wrapper |

---

## Section 7 — Distribution

| Var | Question | Type | Default |
|---|---|---|---|
| `INSTALL_DIR` | Where to install the launcher tree on the user's machine | path | `~/.local/share/${CORP_SLUG}` |
| `BIN_PATH` | Where to symlink the binary | path | `~/.local/bin` |
| `SHELL_RC` | Auto-detect (zsh/bash/fish/PowerShell) | enum | auto |
| `REPO_HOST` | (Optional) GitHub/GitLab repo to publish the launcher source | url | empty |
| `LICENSE_TYPE` | Internal-only / Proprietary / MIT / Apache-2.0 | enum | `Internal-only` |
| `INCLUDE_UNINSTALL` | Generate `uninstall.sh` and uninstall manifest? | yes/no | yes |

---

## Validation rules

Before generating, the skill must check:

1. `CORP_NAME` and `CORP_SLUG` are set and `CORP_SLUG` matches `^[a-z][a-z0-9-]{1,30}$`.
2. For every selected CLI in `WRAPPED_CLIS`, the corresponding `CC_*` / `CX_*` / `GM_*` / `LLM_*` block is complete.
3. `CC_PRIMARY_URL` etc. parse as valid HTTPS URLs.
4. `PROXY_HOST` is empty XOR `PROXY_PORT` is set (no half-config).
5. If `BLOCK_TELEMETRY=yes`, the generated launcher must export ALL the kill switches listed in `reference/env-vars.md` (no partial opt-out).
6. If `CC_BACKEND=Bedrock` or `=LiteLLM`, force `CC_NEEDS_STRIP_PROXY=yes`.

If a check fails, loop back to the relevant `AskUserQuestion`.

---

## Final recap before generating

Show a one-screen summary:

```
====================================================
  CORPORATE LAUNCHER — Generation plan
====================================================

  Brand        : ${CORP_NAME}  (slug: ${CORP_SLUG})
  Sponsor      : ${CORP_POWERED_BY}
  Org          : ${CORP_ORGANIZATION}

  Wrapping     : ${WRAPPED_CLIS}

  Gateway      : ${CC_PRIMARY_URL}  (${CC_BACKEND})
  Model        : ${CC_PRIMARY_MODEL}
  Strip-proxy  : ${CC_NEEDS_STRIP_PROXY}

  VPN gate     : ${VPN_REQUIRED}  (${VPN_PROBE_URL})
  Corp proxy   : ${PROXY_HOST}:${PROXY_PORT}
  CA bundle    : ${CA_BUNDLE_PATH}
  TLS reject   : ${ACCEPT_TLS_INSPECTION}

  Telemetry    : ${BLOCK_TELEMETRY ? "DISABLED" : "ENABLED"}
  Auto-update  : ${BLOCK_AUTO_UPDATE ? "LOCKED" : "ALLOWED"}
  Cost track   : ${COST_TRACKING_ENABLED}  (${COST_CURRENCY})
  Prompt filter: ${PROMPT_FILTER_ENABLED}

  Install dir  : ${INSTALL_DIR}
  Bin path     : ${BIN_PATH}
  Uninstall    : ${INCLUDE_UNINSTALL}

----------------------------------------------------
  Files that will be written:
    - ${INSTALL_DIR}/${CORP_SLUG}            (launcher binary)
    - ${INSTALL_DIR}/install.sh
    - ${INSTALL_DIR}/uninstall.sh
    - ${INSTALL_DIR}/BRANDING.md
    - ${INSTALL_DIR}/cyber-rules.md
    - ${INSTALL_DIR}/scripts/*.sh, *.py, *.js
    - ${INSTALL_DIR}/settings.json
    - ~/.${CORP_SLUG}.conf  (API key, chmod 600)
    - shell RC block in ${SHELL_RC}

----------------------------------------------------
  Generate? [y/N]
====================================================
```

Wait for explicit `y`. Anything else = abort, ask the user what to change.
