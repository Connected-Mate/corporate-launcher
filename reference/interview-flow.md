# Interview Flow

Walk the user through every section in order. Use `AskUserQuestion` for each step. Skip a section only if a previous answer made it irrelevant (e.g. no proxy → skip CA bundle).

Save the answers under uppercase snake_case keys (`CORP_NAME`, `LLM_PRIMARY_URL`, etc.) — those are the variables the templates expect.

---

## Section 1 — Identity

| Var | Question | Type | Default |
|---|---|---|---|
| `CORP_NAME` | What's the brand name of your launcher? (e.g. `Acme Copilot`, `Globex Helper`) | string | required |
| `CORP_SLUG` | Short slug for the binary (lowercase, hyphens) | string | derived from `CORP_NAME` |
| `CORP_POWERED_BY` | Who's the internal sponsor / "powered by"? (e.g. `Acme AI Lab`, `Group AI Platform`) | string | required |
| `CORP_ORGANIZATION` | Legal entity / group name | string | required |
| `CORP_TAGLINE` | One-line tagline shown in the banner | string | `Internal AI assistant` |
| `CORP_LICENSE_NOTE` | Internal compliance / license line | string | `Internal use only` |
| `CORP_DOMAIN` | Primary corporate domain (used for VPN probes, mail rewriting) | string | derived from `CORP_ORGANIZATION` |
| `CORP_DOCS_URL` | Public/internal docs landing page for the launcher | url | empty |
| `CORP_DEFAULT_LANGUAGE` | Default assistant language tag (`en`, `fr`, ...) | enum | `en` |

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
7. **Cline** (VS Code / Cursor / VSCodium extension) — settings.json-driven, marketplace id `saoudrizwan.claude-dev`; the pragmatic path when corporate policy bans Cursor's native chat but allows VS Code-family editors with an OpenAI-compatible provider. Cursor is a VS Code fork — same extension, same install command, same settings.json layout.

Save as `WRAPPED_CLIS=["claude-code","codex-cli",...]`. Valid ids: `claude-code`, `codex-cli`, `gemini-cli`, `aider`, `opencode`, `continue-dev`, `cline`.

| Var | Question | Type | Default |
|---|---|---|---|
| `WRAPPED_CLIS` | List of CLIs to wrap (multi-select, see options above) | list | required |
| `UNDERLYING_CLI` | When a single CLI is wrapped, the primary CLI binary name (`claude`, `codex`, `gemini`, `aider`, `opencode`, `continue`, `cline`) | string | derived from first element of `WRAPPED_CLIS` |
| `UNDERLYING_CLI_PIN` | Pinned upstream CLI version (e.g. `1.4.2`) — empty = floating latest | string | empty |
| `UNDERLYING_CLI_URL` | Upstream install URL for the CLI (npm tarball, pypi, GitHub release) | url | derived |

For each selected CLI, ask the CLI-specific questions in Section 3.

---

## Section 3 — Backend (per CLI)

Branch on `WRAPPED_CLIS`:

### 3.A — Claude Code branch

| Var | Question | Type | Default |
|---|---|---|---|
| `CC_BACKEND` | Anthropic direct / AWS Bedrock / Google Vertex / Microsoft Foundry / LiteLLM gateway / Custom OpenAI-compatible | enum | required |
| `CC_PRIMARY_URL` | Gateway URL (e.g. `https://gateway.acme.example`) | url | required |
| `CC_PRIMARY_MODEL` | Default model ID for this gateway | string | `claude-sonnet-4-6` |
| `CC_HAIKU_MODEL` | Small/fast model ID (for compaction, summarization) | string | `claude-haiku-4-5` |
| `CC_NEEDS_STRIP_PROXY` | Does the gateway return Bedrock/LiteLLM SSE artefacts? | yes/no | yes if Bedrock or LiteLLM |
| `CC_CLI_NAME` | Public binary name of the wrapped Claude Code CLI (`claude` by default) | string | `claude` |

### 3.B — Codex CLI branch

| Var | Question | Type | Default |
|---|---|---|---|
| `CX_BACKEND` | OpenAI direct / Azure OpenAI / Amazon Bedrock (gpt models) / Custom OpenAI-compatible | enum | required |
| `CX_PRIMARY_URL` | Gateway URL | url | required |
| `CX_PRIMARY_MODEL` | Default model | string | `gpt-5-codex` |
| `CX_FAST_MODEL` | Small/fast model for plan / summary | string | derived from `CX_PRIMARY_MODEL` |
| `CX_AUTH_ENV_KEY` | Env var name holding the token (e.g. `AZURE_OPENAI_API_KEY`) | string | `OPENAI_API_KEY` |
| `CX_WIRE_API` | `responses` / `chat-completions` | enum | `responses` |
| `CX_REQUIRE_LOCKDOWN` | Generate `/etc/codex/requirements.toml` to ban modifying the provider? | yes/no | yes |
| `CX_PROVIDER_ID` | Stable provider id written to `config.toml` (e.g. `acme-litellm`) | string | derived from `CORP_SLUG` |
| `CX_APPROVAL_POLICY` | `untrusted` / `on-request` / `never` | enum | `on-request` |
| `CX_SANDBOX_MODE` | `read-only` / `workspace-write` / `danger-full-access` | enum | `workspace-write` |
| `CX_REASONING_EFFORT` | `low` / `medium` / `high` for o-series models | enum | `medium` |
| `CX_FORCED_LOGIN_METHOD` | `apikey` / `chatgpt` — pinned login flow | enum | `apikey` |
| `CX_NODE_MIN_VERSION` | Minimum Node version for Codex CLI bootstrap | string | `20` |
| `CX_PROXY_WARNING` | Inline warning shown when corporate proxy is detected | string | derived |

### 3.C — Gemini CLI branch

| Var | Question | Type | Default |
|---|---|---|---|
| `GM_BACKEND` | Vertex AI / AI Studio | enum | required |
| `GM_PRIMARY_MODEL` | Default model | string | `gemini-2.5-pro` |
| `GM_VERTEX_PROJECT` | (Vertex) GCP project | string | required if Vertex |
| `GM_VERTEX_LOCATION` | (Vertex) region — EU compliance use `europe-west4` | string | `europe-west4` |
| `GM_AUTH_MODE` | ADC (gcloud) / service-account / API key | enum | `ADC` if Vertex |
| `GM_AUTH_ENFORCED_TYPE` | Lock the auth type in `settings.json` (`oauth-personal` / `vertex` / `gemini-api-key`) | enum | derived from `GM_BACKEND` |
| `GM_SANDBOX_MODE` | Tool sandbox mode (`docker` / `podman` / `off`) | enum | `off` |
| `GM_TOOLS_EXCLUDE_JSON` | JSON array of tool names to disable (e.g. `["WebFetch"]`) | json | `[]` |

### 3.D — Aider / opencode / Continue.dev / Cline branch

Common questions (all four share the same OpenAI-compatible gateway shape):

| Var | Question | Default |
|---|---|---|
| `LLM_OPENAI_BASE_URL` | OpenAI-compatible base URL (LiteLLM, Azure, etc.) | required |
| `LLM_PRIMARY_MODEL` | Default model name on the gateway | required |
| `LLM_WEAK_MODEL` | Cheap/fast model for plan + summary (aider --weak-model) | derived from `LLM_PRIMARY_MODEL` |
| `LLM_PROVIDER_ID` | Provider id written into config files (`acme-litellm`, `vertex`, ...) | derived from `CORP_SLUG` |
| `LLM_CONTINUE_PROVIDER` | Continue.dev provider key (`openai` / `anthropic` / `litellm`) | `openai` |
| `LLM_BACKEND` | Backend family used by `aider` (`openai-compatible` / `bedrock` / `vertex`) | `openai-compatible` |
| `LLM_TOKEN_URL` | OAuth2 / SSO token endpoint used to mint short-lived gateway tokens | empty |
| `LLM_VERIFY_SSL` | Whether the CLI should verify TLS against `${CORP_CA_BUNDLE_PATH}` | `yes` |

Cline-specific extras (only asked when `cline` is in `WRAPPED_CLIS`) — these are answered at interview time but currently consumed by `scripts/interview.py` for branching only, **not** substituted into any `.tpl`. Capture them in `answers.json` under the bullet keys below; the templates re-derive their effect at install time.

- **CLINE_TARGET_IDES** — Which VS Code-family editors to configure (`code`, `cursor`, `codium`, `code-insiders`). Default: auto-detected at install time by `templates/cline/install.sh.tpl`.
- **CLINE_AUTO_APPROVE** — Allow Cline to auto-execute safe commands without per-step confirmation. Default: `no` (enterprise default).
- **CLINE_DISABLE_MCP_MARKETPLACE** — Hide Cline's public MCP marketplace so users can only use MCP servers preconfigured by the launcher. Default: `yes`.

---

## Section 4 — Network

| Var | Question | Type | Default |
|---|---|---|---|
| `VPN_REQUIRED` | Does the user need a corporate VPN before launching? | yes/no | yes |
| `VPN_PROBE_URL` | Internal-only URL to probe (HTTP code ≠ 000 = VPN OK) | url | derived from gateway hostname |
| `VPN_CLIENT_NAME` | Display name of the VPN client users should connect to | string | empty |
| `VPN_PROFILE_NAME` | Named profile inside the VPN client | string | empty |
| `PROXY_HOST` | Corporate HTTP proxy hostname | string | empty |
| `PROXY_PORT` | Corporate HTTP proxy port | number | `8080` |
| `NO_PROXY_LIST` | Comma-separated bypass list | string | `127.0.0.1,localhost` + gateway hostname |
| `CA_BUNDLE_PATH` | Path to corporate CA bundle (PEM) | path | empty |
| `CA_DETECT_AUTO` | Auto-extract from OS trust store at install time? | yes/no | yes |
| `CA_FILTER_EXTRA` | Extra grep filter for `extract-corp-ca.sh` (e.g. cross-signed roots) | string | empty |
| `CORP_CA_ORG` | `O=...` field used to recognise the corporate root in the OS trust store | string | derived from `CORP_ORGANIZATION` |
| `CORP_CA_BUNDLE_PATH` | Path written by `extract-corp-ca.sh` and consumed by every CLI | path | `${INSTALL_DIR}/corp-ca.pem` |
| `CORP_CLIENT_CERT_PATH` | Optional mTLS client certificate (PEM) | path | empty |
| `CORP_CLIENT_KEY_PATH` | Optional mTLS client key (PEM) | path | empty |
| `CORP_HTTPS_PROXY` | Full `https_proxy` URL to inject in the launcher env | url | derived from `PROXY_HOST`/`PROXY_PORT` |
| `CORP_NO_PROXY` | Effective `NO_PROXY` value emitted by the launcher | string | derived from `NO_PROXY_LIST` |
| `ACCEPT_TLS_INSPECTION` | Allow `NODE_TLS_REJECT_UNAUTHORIZED=0` fallback if no CA found? | yes/no | no |

---

## Section 5 — Cyber

| Var | Question | Type | Default |
|---|---|---|---|
| `CYBER_AUTHORITY` | Name of the corporate cyber authority (e.g. `ACME Group CISO`, `Globex Security Office`) | string | required |
| `CORP_RULES_FILE` | Path to the corporate cyber rules markdown loaded by the wrapped CLI | path | `cyber-rules.md` |
| `CORP_SECRET_MANAGER` | Name of the approved secret manager (e.g. `Vault`, `1Password Business`) | string | empty |
| `RSSI_CLEARANCE_REF` | Reference of the security clearance / ARC ticket for this launcher | string | empty |
| `SSO_PROVIDER` | Corporate SSO provider name (`Okta`, `Azure AD`, ...) | string | empty |
| `TOKEN_PORTAL_URL` | URL where users mint personal tokens for the gateway | url | empty |
| `TOKEN_TTL_DAYS` | Token TTL in days (informational, shown in onboarding) | number | `30` |
| `COST_CURRENCY` | `EUR` / `USD` / `GBP` | enum | `EUR` |

---

## Section 6 — Branding

| Var | Question | Type | Default |
|---|---|---|---|
| `BANNER_COLOR_PRIMARY` | ANSI color code or name (e.g. `208` for orange) | string | `208` |
| `CORP_BRAND_ANSI` | ANSI code used by Codex / Gemini wrappers — usually same as `BANNER_COLOR_PRIMARY` | string | derived from `BANNER_COLOR_PRIMARY` |
| `TERMINAL_TITLE` | String set as terminal title at launch | string | `${CORP_NAME} — Powered by ${CORP_POWERED_BY}` |
| `LANGUAGE` | Default response language | enum (`fr`, `en`, ...) | `en` |
| `FORBIDDEN_TERMS` | Comma-separated words the assistant must never output (e.g. vendor names) | string | `Claude,Anthropic` for Claude Code wrapper |

---

## Section 7 — Install layout (creator's machine)

| Var | Question | Type | Default |
|---|---|---|---|
| `INSTALL_DIR` | Where to install the launcher tree on the user's machine | path | `~/.local/share/${CORP_SLUG}` |
| `SHELL_RC` | Auto-detect (zsh/bash/fish/PowerShell) | enum | auto |
| `LICENSE_TYPE` | Internal-only / Proprietary / MIT / Apache-2.0 | enum | `Internal-only` |
| `NODE_VERSION_MIN` | Minimum Node.js version required by the wrapped CLI | string | `20` |
| `PYTHON_VERSION_MIN` | Minimum Python version (aider, opencode bootstrap) | string | `3.11` |
| `PROVIDER_KIND` | Tag identifying the gateway family (`litellm`, `bedrock`, `vertex`, `azure-openai`, `direct`) | enum | derived from `*_BACKEND` |

---

## Section 8 — Skills bundle (what colleagues get inside the launcher)

See `reference/skills-bundle.md` for the full details. Ask:

```
Which skills do you want to bundle for your colleagues?

  [1] None — bare wrapper only
  [2] Design pack (curated UI/UX skills)
  [3] Pick from a curated list (one-by-one, multi-select)
  [4] From a git repo URL — your own internal skill monorepo
  [5] From a local folder — what's already on this machine
```

| Var | Type | Notes |
|---|---|---|
| `SKILLS_PRESETS` | list | e.g. `["design-pack"]` |
| `SKILLS_PICK` | list | e.g. `["polish","audit","critique"]` |
| `SKILLS_GIT_URL` | URL | private/public git URL |
| `SKILLS_LOCAL_PATH` | path | absolute path on creator's machine |
| `SKILLS_BUNDLE_REF` | string | release tag/branch of the canonical skills monorepo when bundled by the launcher | 

Then ask about MCP servers:

```
Pre-configure MCP servers in the launcher?

  [1] No — colleagues add their own
  [2] Yes — let me list them (name + URL + headers)
```

| Var | Type | Example |
|---|---|---|
| `MCP_SERVERS` | list | `[{"name":"jira","url":"https://mcp.acme/jira","headers":{"Authorization":"Bearer ${env:MCP_TOKEN}"}}]` |

---

## Section 9 — Distribution (how to ship it to the team)

See `reference/distribution-modes.md` for trade-offs. Ask:

```
How do you want to ship this to your team?

  [1] Public GitHub repo
  [2] Private GitHub / GitLab repo
  [3] Tarball + internal artifact registry
  [4] One-liner install URL (host install.sh on your intranet)
  [5] No distribution — local only for now
```

| Var | Type | Example |
|---|---|---|
| `DIST_MODE` | enum | `public-git` / `private-git` / `tarball` / `oneliner` / `none` |
| `DIST_REPO_HOST` | enum | `github` / `gitlab` / `bitbucket` / `internal-gitea` |
| `DIST_REPO_URL` | URL | URL of the repo to create |
| `DIST_REPO_VISIBILITY` | enum | `public` / `internal` / `private` |
| `DIST_REGISTRY_URL` | URL | Nexus / Artifactory base URL (tarball mode) |
| `DIST_ONELINER_HOST` | URL | where install.sh will be hosted |
| `DIST_SIGN_RELEASE` | bool | sign the tarball / install.sh with GPG? |
| `DIST_GPG_KEY_ID` | string | GPG key id (if signing) |
| `DIST_DEFAULT_BRANCH` | string | Default branch name when scaffolding a git repo (`main` / `trunk`) |
| `DIST_GIT_REF` | string | Pinned git ref consumed by `oneliner/install.ps1` |
| `DIST_S3_BUCKET` | string | S3 bucket name used by `dist/oneliner/host-on-s3.sh` |
| `CORP_ORG_GH` | string | GitHub org / user slug (public-git or pages hosting) |
| `INTERNAL_DOCS_URL` | url | Internal portal hosting `README` / install docs |
| `INTERNAL_NPM_MIRROR_URL` | url | Internal npm proxy when bootstrapping Node CLIs offline |

---

## Section 10 — Runtime / derived variables

These variables are **not asked at interview time**. They are produced by the launcher (or the operator) at install / run time and only appear in templates because the generator emits the literal `${VAR}` so the resulting script will dereference them later.

The interview spec lists them here only to satisfy the template-variable audit (`tests/sync-vars.py`). Do **not** prompt the user for them.

| Var | Origin | Notes |
|---|---|---|
| `CORP_API_KEY` | runtime env on user's machine | set by user after first SSO login; consumed by `continue-dev/launcher.sh` and `cline/settings-cline.json` |

> The earlier `revoke-token.sh` runtime locals (`USER_EMAIL`, `ADMIN_TOKEN`, `OPERATOR`, `REASON`, `REQUEST_ID`, `SCOPE`, `STATUS`, `TIMESTAMP`) live in the rendered shell script only — they are now escaped (`$\{VAR\}`) in the `.tpl` so the launcher generator does **not** substitute them. They are intentionally **not** listed as table rows.

---

## Section 11 — Feature-specific variables

Only collected if the matching feature is enabled. They have **no default** when the feature is off and must not appear in the generated launcher in that case.

### 11.A — Token revocation (`shared/revoke-token.sh`)

Required when offboarding automation is included.

| Var | Question | Type | Default |
|---|---|---|---|
| `GATEWAY_ADMIN_API` | Admin REST API base URL of the gateway (LiteLLM `/admin`, Azure APIM control plane, etc.) | url | required |
| `GATEWAY_BACKEND` | `litellm` / `azure` / `vertex` / `bedrock` | enum | required |
| `GATEWAY_ADMIN_TOKEN_ENV` | Name of the env var holding the admin token (never the token itself) | string | `LITELLM_ADMIN_TOKEN` |

> Backend-specific knobs (`AZURE_APIM_NAME`, `AZURE_APIM_RG`, `BEDROCK_USER_POLICY_ARN`, `GCP_PROJECT_ID`) are passed to the rendered `revoke-token.sh` as **escaped** placeholders (`$\{AZURE_APIM_NAME\}`) so the script reads them from its own env at run time. They are intentionally not interview keys.

### 11.B — Tarball uploaders (`dist/tarball/upload-*.sh`)

Only emitted when `DIST_MODE=tarball`. Choose at least one target.

| Var | Question | Type | Default |
|---|---|---|---|
| `NEXUS_USER` | Nexus raw-repo upload user | string | required if Nexus |
| `NEXUS_PASS` | Env var name holding the Nexus password | string | `NEXUS_PASSWORD` |
| `ARTIFACTORY_USER` | Artifactory upload user | string | required if Artifactory |
| `ARTIFACTORY_PASS` | Env var name holding the Artifactory password | string | `ARTIFACTORY_PASSWORD` |
| `ARTIFACTORY_TOKEN` | Env var name holding an Artifactory access token (alternative to user/pass) | string | empty |
| `AWS_PROFILE` | AWS named profile for S3 upload | string | `default` |

### 11.C — Internal corporate references (private-git / INTERNAL.md)

Emitted only when `DIST_MODE=private-git` or `DIST_MODE=tarball` (internal distributions).

| Var | Question | Type | Default |
|---|---|---|---|
| `CORP_INTERNAL_CONTACT` | Internal team owning the launcher (email or alias) | string | required |
| `CORP_SUPPORT_CONTACT` | Public support email shown in user-facing files | email | required |
| `CORP_SECURITY_EMAIL` | Security/PSIRT mailbox for vulnerability reports | email | required |
| `CORP_INCIDENT_CONTACT` | 24/7 incident pager / hotline | string | empty |
| `CORP_DPO_CONTACT` | Data Protection Officer mailbox | email | empty |
| `CORP_PROCUREMENT_CONTACT` | Procurement contact for vendor renewals | string | empty |
| `CORP_AUDIT_SYSTEM` | Name of the SIEM ingesting `audit.log` (`Splunk`, `Elastic`) | string | empty |
| `CORP_AUDIT_LOCATION` | Path or URL where `audit.log` is shipped | string | empty |

---

## Validation rules

Before generating, the skill must check:

1. `CORP_NAME` and `CORP_SLUG` are set and `CORP_SLUG` matches `^[a-z][a-z0-9-]{1,30}$`.
2. For every selected CLI in `WRAPPED_CLIS`, the corresponding `CC_*` / `CX_*` / `GM_*` / `LLM_*` block is complete.
3. `CC_PRIMARY_URL` etc. parse as valid HTTPS URLs.
4. `PROXY_HOST` is empty XOR `PROXY_PORT` is set (no half-config).
5. If `BLOCK_TELEMETRY=yes`, the generated launcher must export ALL the kill switches listed in `reference/env-vars.md` (no partial opt-out).
6. If `CC_BACKEND=Bedrock` or `=LiteLLM`, force `CC_NEEDS_STRIP_PROXY=yes`.
7. If `DIST_MODE=public-git`, refuse if `CC_PRIMARY_URL` contains an internal hostname (`.internal`, `.local`, RFC1918) unless the creator overrides with `DIST_PUBLIC_FORCE=yes`.
8. If `DIST_MODE=oneliner`, refuse if `DIST_ONELINER_HOST` is plain HTTP (force HTTPS).
9. If `SKILLS_MODE=git` and the URL is publicly mirrored, prompt: "is this repo reviewed by your security team?" before continuing.

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

  Skills       : ${SKILLS_MODE}  (${SKILLS_PRESETS} / ${SKILLS_GIT_URL})
  MCP servers  : ${MCP_SERVERS | length} pre-configured
  Distribution : ${DIST_MODE}  (${DIST_REPO_URL || DIST_ONELINER_HOST || "local"})
  Signing      : ${DIST_SIGN_RELEASE}

----------------------------------------------------
  Files that will be written:
    - ${INSTALL_DIR}/${CORP_SLUG}            (launcher binary)
    - ${INSTALL_DIR}/install.sh
    - ${INSTALL_DIR}/uninstall.sh
    - ${INSTALL_DIR}/BRANDING.md
    - ${INSTALL_DIR}/cyber-rules.md
    - ${INSTALL_DIR}/scripts/*.sh, *.py, *.js
    - ${INSTALL_DIR}/settings.json
    - ${INSTALL_DIR}/skills/        (bundled skills for colleagues)
    - ~/.${CORP_SLUG}.conf          (chmod 600 fallback)
    - shell RC block in ${SHELL_RC}

  Distribution artifacts:
    - dist/repo/                    (if DIST_MODE = *-git)
    - dist/${CORP_SLUG}-1.0.0.tar.gz  (if DIST_MODE = tarball)
    - dist/install.sh                  (if DIST_MODE = oneliner)
    - dist/SHA256SUMS                  (always for tarball/oneliner)

----------------------------------------------------
  Generate? [y/N]
====================================================
```

Wait for explicit `y`. Anything else = abort, ask the user what to change.
