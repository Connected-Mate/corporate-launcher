# Interview Flow

Walk the user through every section in order. Use `AskUserQuestion` for each step. Skip a section only if a previous answer made it irrelevant (e.g. no proxy → skip CA bundle).

Save the answers under uppercase snake_case keys (`CORP_NAME`, `LLM_PRIMARY_URL`, etc.) — those are the variables the templates expect.

---

## Table of contents

- [Section 1 — Identity](#section-1--identity)
- [Section 2 — Provider (which CLI to wrap)](#section-2--provider-which-cli-to-wrap)
- [Section 3 — Backend (per CLI)](#section-3--backend-per-cli)
- [Section 4 — Network](#section-4--network)
- [Section 5 — Cyber](#section-5--cyber)
- [Section 5.5 — Corporate dev rules](#section-55--corporate-dev-rules)
- [Section 6 — Branding](#section-6--branding)
- [Section 7 — Install layout (creator's machine)](#section-7--install-layout-creators-machine)
- [Section 8 — Skills bundle (what colleagues get inside the launcher)](#section-8--skills-bundle-what-colleagues-get-inside-the-launcher)
- [Section 8.5 — Compliance & audit posture](#section-85--compliance--audit-posture)
- [Section 9 — Distribution (how to ship it to the team)](#section-9--distribution-how-to-ship-it-to-the-team)
- [Section 10 — Runtime / derived variables](#section-10--runtime--derived-variables)
- [Section 11 — Feature-specific variables](#section-11--feature-specific-variables)
- [Validation rules](#validation-rules)
- [Final recap](#final-recap-before-generating)

---

## Section 1 — Identity

This section captures who the launcher is for and how it presents itself. The answers drive every banner, file path, ANSI title, docs link, and compliance footer in the generated artefacts — get them right and the rest of the interview flows naturally from these names.

| Var | Question | Type | Default |
|---|---|---|---|
| `CORP_NAME` | What's the brand name of your launcher? (e.g. `Acme Copilot`, `Globex Helper`) | string | required |
| `CORP_SLUG` | What short slug should we use for the binary? (lowercase, hyphens only) | string | derived from `CORP_NAME` |
| `CORP_POWERED_BY` | Who's the internal sponsor or "powered by" entity? (e.g. `Acme AI Lab`, `Group AI Platform`) | string | required |
| `CORP_ORGANIZATION` | What's the legal entity or group name behind this launcher? | string | required |
| `CORP_TAGLINE` | What one-line tagline should appear in the banner? | string | `Internal AI assistant` |
| `CORP_LICENSE_NOTE` | What internal compliance or license line should we show? | string | `Internal use only` |
| `CORP_DOMAIN` | What's your primary corporate domain? (used for VPN probes and mail rewriting) | string | derived from `CORP_ORGANIZATION` |
| `CORP_DOCS_URL` | What's the docs landing page URL for this launcher? (public or internal) | url | empty |
| `CORP_DEFAULT_LANGUAGE` | What's the default assistant language? Choose: `en`, `fr`, `de`, `es`, `it`, `pt`, `nl` | enum | `en` |

---

## Section 2 — Provider (which CLI to wrap)

This section decides which upstream AI coding CLIs you want to repackage under your corporate launcher. Each choice unlocks a dedicated backend sub-section in Section 3. Multi-select is allowed so a single launcher can ship several CLIs sharing one corporate gateway and one set of cyber rules.

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
| `WRAPPED_CLIS` | Which AI coding CLIs do you want to wrap? Pick one or more: Claude Code, Codex CLI, Gemini CLI, Aider, opencode, Continue.dev, Cline | list | required |
| `UNDERLYING_CLI` | What's the primary CLI binary name? Choose: `claude`, `codex`, `gemini`, `aider`, `opencode`, `continue`, `cline` | string | derived from first element of `WRAPPED_CLIS` |
| `UNDERLYING_CLI_PIN` | Do you want to pin the upstream CLI to a specific version? (e.g. `1.4.2`, or leave empty for floating latest) | string | empty |
| `UNDERLYING_CLI_URL` | What's the upstream install URL for the CLI? (npm tarball, pypi, or GitHub release) | url | derived |

For each selected CLI, ask the CLI-specific questions in Section 3.

---

## Section 3 — Backend (per CLI)

This section wires every selected CLI to its corporate gateway. Each sub-section only triggers if the matching CLI was picked in Section 2. The answers here decide model IDs, auth env vars, SSE-stripping, sandbox policy and lockdown flags — anything that prevents the CLI from talking to its public default endpoint.

Branch on `WRAPPED_CLIS`:

### 3.A — Claude Code branch

| Var | Question | Type | Default |
|---|---|---|---|
| `CC_BACKEND` | Which Claude Code backend will you use? Choose: Anthropic direct, AWS Bedrock, Google Vertex, Microsoft Foundry, LiteLLM gateway, or Custom OpenAI-compatible | enum | required |
| `CC_PRIMARY_URL` | What's the gateway URL? (e.g. `https://gateway.acme.example`) | url | required |
| `CC_PRIMARY_MODEL` | Which default model ID should we use on this gateway? | string | `claude-sonnet-4-6` |
| `CC_HAIKU_MODEL` | Which small/fast model ID handles compaction and summarisation? | string | `claude-haiku-4-5` |
| `CC_NEEDS_STRIP_PROXY` | Does your gateway return Bedrock or LiteLLM SSE artefacts that need stripping? Choose: yes or no | yes/no | yes if Bedrock or LiteLLM |
| `CC_CLI_NAME` | What public binary name should the wrapped Claude Code CLI use? | string | `claude` |

### 3.B — Codex CLI branch

| Var | Question | Type | Default |
|---|---|---|---|
| `CX_BACKEND` | Which Codex backend will you use? Choose: OpenAI direct, Azure OpenAI, Amazon Bedrock (gpt models), or Custom OpenAI-compatible | enum | required |
| `CX_PRIMARY_URL` | What's the Codex gateway URL? | url | required |
| `CX_PRIMARY_MODEL` | Which default model should Codex use? | string | `gpt-5-codex` |
| `CX_FAST_MODEL` | Which small/fast model should handle plan and summary steps? | string | derived from `CX_PRIMARY_MODEL` |
| `CX_AUTH_ENV_KEY` | Which env var name holds the auth token? (e.g. `AZURE_OPENAI_API_KEY`) | string | `OPENAI_API_KEY` |
| `CX_WIRE_API` | Which wire API does the gateway speak? Choose: `responses` or `chat-completions` | enum | `responses` |
| `CX_REQUIRE_LOCKDOWN` | Should we generate `/etc/codex/requirements.toml` to ban modifying the provider? Choose: yes or no | yes/no | yes |
| `CX_PROVIDER_ID` | What stable provider id should we write to `config.toml`? (e.g. `acme-litellm`) | string | derived from `CORP_SLUG` |
| `CX_APPROVAL_POLICY` | What's the default approval policy? Choose: `untrusted`, `on-request`, or `never` | enum | `on-request` |
| `CX_SANDBOX_MODE` | What sandbox mode should Codex run in? Choose: `read-only`, `workspace-write`, or `danger-full-access` | enum | `workspace-write` |
| `CX_REASONING_EFFORT` | What reasoning effort should o-series models use? Choose: `low`, `medium`, or `high` | enum | `medium` |
| `CX_FORCED_LOGIN_METHOD` | Which login flow do you want to pin? Choose: `apikey` or `chatgpt` | enum | `apikey` |
| `CX_NODE_MIN_VERSION` | What minimum Node version is required for Codex CLI bootstrap? | string | `20` |
| `CX_PROXY_WARNING` | What inline warning should appear when a corporate proxy is detected? | string | derived |

### 3.C — Gemini CLI branch

| Var | Question | Type | Default |
|---|---|---|---|
| `GM_BACKEND` | Which Gemini backend will you use? Choose: Vertex AI or AI Studio | enum | required |
| `GM_PRIMARY_MODEL` | Which default Gemini model should we use? | string | `gemini-2.5-pro` |
| `GM_VERTEX_PROJECT` | What's your GCP project for Vertex? | string | required if Vertex |
| `GM_VERTEX_LOCATION` | Which Vertex region? (use `europe-west4` for EU compliance) | string | `europe-west4` |
| `GM_AUTH_MODE` | How should Gemini authenticate? Choose: `ADC` (gcloud), `service-account`, or `api-key` | enum | `ADC` if Vertex |
| `GM_AUTH_ENFORCED_TYPE` | Which auth type should we lock in `settings.json`? Choose: `oauth-personal`, `vertex`, or `gemini-api-key` | enum | derived from `GM_BACKEND` |
| `GM_SANDBOX_MODE` | What tool sandbox mode should Gemini use? Choose: `docker`, `podman`, or `off` | enum | `off` |
| `GM_TOOLS_EXCLUDE_JSON` | Which tool names should be disabled? (JSON array, e.g. `["WebFetch"]`) | json | `[]` |

### 3.D — Aider / opencode / Continue.dev / Cline branch

Common questions (all four share the same OpenAI-compatible gateway shape):

| Var | Question | Default |
|---|---|---|
| `LLM_OPENAI_BASE_URL` | What's the OpenAI-compatible base URL? (LiteLLM, Azure OpenAI, etc.) | required |
| `LLM_PRIMARY_MODEL` | Which default model name on the gateway should we use? | required |
| `LLM_WEAK_MODEL` | Which cheap/fast model handles plan + summary? (aider --weak-model) | derived from `LLM_PRIMARY_MODEL` |
| `LLM_PROVIDER_ID` | What provider id should we write into config files? (e.g. `acme-litellm`, `vertex`) | derived from `CORP_SLUG` |
| `LLM_CONTINUE_PROVIDER` | Which Continue.dev provider key applies? Choose: `openai`, `anthropic`, or `litellm` | `openai` |
| `LLM_BACKEND` | Which backend family does aider talk to? Choose: `openai-compatible`, `bedrock`, or `vertex` | `openai-compatible` |
| `LLM_TOKEN_URL` | What's the OAuth2/SSO token endpoint that mints short-lived gateway tokens? | empty |
| `LLM_VERIFY_SSL` | Should the CLI verify TLS against `${CORP_CA_BUNDLE_PATH}`? Choose: yes or no | `yes` |

Cline-specific extras (only asked when `cline` is in `WRAPPED_CLIS`) — these are answered at interview time but currently consumed by `scripts/interview.py` for branching only, **not** substituted into any `.tpl`. Capture them in `answers.json` under the bullet keys below; the templates re-derive their effect at install time.

- **CLINE_TARGET_IDES** — Which VS Code-family editors to configure (`code`, `cursor`, `codium`, `code-insiders`). Default: auto-detected at install time by `templates/cline/install.sh.tpl`.
- **CLINE_AUTO_APPROVE** — Allow Cline to auto-execute safe commands without per-step confirmation. Default: `no` (enterprise default).
- **CLINE_DISABLE_MCP_MARKETPLACE** — Hide Cline's public MCP marketplace so users can only use MCP servers preconfigured by the launcher. Default: `yes`.

---

## Section 4 — Network

This section configures everything the launcher needs to reach the corporate gateway through your network perimeter: VPN gating, HTTP proxy, CA trust bundle, mTLS, and TLS inspection fallback. Skip a question only when a previous answer rules it out (e.g. no proxy → no `NO_PROXY_LIST`).

| Var | Question | Type | Default |
|---|---|---|---|
| `VPN_REQUIRED` | Do users need to connect to a corporate VPN before launching? Choose: yes or no | yes/no | yes |
| `VPN_PROBE_URL` | What internal-only URL should we probe to confirm VPN is up? (HTTP code ≠ 000 = VPN OK) | url | derived from gateway hostname |
| `VPN_CLIENT_NAME` | What's the display name of the VPN client users should connect to? | string | empty |
| `VPN_PROFILE_NAME` | What's the named profile inside that VPN client? | string | empty |
| `PROXY_HOST` | What's your corporate HTTP proxy hostname? (leave empty if none) | string | empty |
| `PROXY_PORT` | What port does the corporate HTTP proxy listen on? | number | `8080` |
| `NO_PROXY_LIST` | Which hosts should bypass the proxy? (comma-separated) | string | `127.0.0.1,localhost` + gateway hostname |
| `CA_BUNDLE_PATH` | What's the path to your corporate CA bundle? (PEM format) | path | empty |
| `CA_DETECT_AUTO` | Should we auto-extract the CA from the OS trust store at install time? Choose: yes or no | yes/no | yes |
| `CA_FILTER_EXTRA` | Any extra grep filter for `extract-corp-ca.sh`? (e.g. cross-signed roots) | string | empty |
| `CORP_CA_ORG` | What's the `O=...` field used to recognise the corporate root in the OS trust store? | string | derived from `CORP_ORGANIZATION` |
| `CORP_CA_BUNDLE_PATH` | What path will `extract-corp-ca.sh` write to (and every CLI read from)? | path | `${INSTALL_DIR}/corp-ca.pem` |
| `CORP_CLIENT_CERT_PATH` | Do you use mTLS? If so, what's the client certificate path? (PEM, leave empty if none) | path | empty |
| `CORP_CLIENT_KEY_PATH` | What's the matching mTLS client key path? (PEM, leave empty if none) | path | empty |
| `CORP_HTTPS_PROXY` | What full `https_proxy` URL should the launcher inject into its env? | url | derived from `PROXY_HOST`/`PROXY_PORT` |
| `CORP_NO_PROXY` | What effective `NO_PROXY` value should the launcher emit? | string | derived from `NO_PROXY_LIST` |
| `ACCEPT_TLS_INSPECTION` | Should we allow a `NODE_TLS_REJECT_UNAUTHORIZED=0` fallback if no CA is found? Choose: yes or no | yes/no | no |
| `API_PROBE_ENABLED` | Probe the gateway during install (recommended)? | yes/no | yes |

---

## Section 5 — Cyber

This section captures the security context the launcher must reference: the cyber authority signing off on the deployment, where users mint tokens, which secret manager they should use, and which SSO provider sits behind it. These values appear in onboarding text, `cyber-rules.md`, and audit log headers.

| Var | Question | Type | Default |
|---|---|---|---|
| `CYBER_AUTHORITY` | Who's your corporate cyber authority? (e.g. `ACME Group CISO`, `Globex Security Office`) | string | required |
| `CORP_RULES_FILE` | What path to the corporate cyber rules markdown should the wrapped CLI load? | path | `cyber-rules.md` |
| `CORP_SECRET_MANAGER` | Which approved secret manager do you use? (e.g. `Vault`, `1Password Business`) | string | empty |
| `SSO_PROVIDER` | Which SSO provider does your organisation use? (e.g. `Okta`, `Azure AD`, `Ping`) | string | empty |
| `TOKEN_PORTAL_URL` | Where do users mint personal tokens for the gateway? (URL) | url | empty |
| `TOKEN_TTL_DAYS` | How many days is a personal token valid for? (shown in onboarding) | number | `30` |
| `COST_CURRENCY` | Which currency should cost reporting use? Choose: `EUR`, `USD`, or `GBP` | enum | `EUR` |
| `COST_TRACKING_ENABLED` | Track token cost per session and emit a per-CLI ledger? (default on — recommended for every launcher) | yes/no | yes |
| `COST_ALERT_THRESHOLD` | Daily cost threshold (in `COST_CURRENCY`) that triggers a non-fatal warning when reached. `0` disables. | number | `0` |
| `COST_TENANT_ENDPOINT` | Optional HTTPS endpoint to POST daily aggregated totals to (`<launcher> --cost push`). Empty disables. | url | empty |
| `BLOCK_TELEMETRY` | Disable upstream telemetry (`STATSIG_DISABLED`, `DISABLE_TELEMETRY=1`, ...)? | yes/no | yes |
| `BLOCK_AUTO_UPDATE` | Lock the CLI to its pinned version (no upstream auto-update)? | yes/no | yes |
| `SELF_AUDIT_ENABLED` | Run a self-audit on the generated launcher before finishing? | yes/no | yes |
| `URL_PURGE_AUTOPATCH` | Auto-patch any leaked vendor URLs found in the launcher? | yes/no | no |
| `COMPLIANCE_DOCX` | Generate a Word document for your security office? | yes/no | yes |
| `LOAD_TEST_ENABLED` | Run a small load test against the gateway after install? | yes/no | no |
| `LOAD_TEST_TOTAL` | Number of test requests if load test enabled | number | 50 |
| `LOAD_TEST_CONCURRENCY` | Concurrent requests if load test enabled | number | 5 |

---

## Section 5.5 — Corporate dev rules

What it does: lets the AI assistant pick up your company's coding conventions, naming rules, framework preferences, banned patterns. Injected into the launcher's system prompt alongside cyber-rules.md. See `references/dev-rules.md` for full details.

Ask:

| Var | Question | Type | Default |
|---|---|---|---|
| `DEV_RULES_MODE` | How should we source your corporate dev rules? `none` / `inline` (paste markdown) / `local` (file path) / `git` (private repo) | enum | `none` |
| `DEV_RULES_CONTENT` | (if inline) Paste your dev rules markdown here | textarea | empty |
| `DEV_RULES_LOCAL_PATH` | (if local) Path to your dev-rules.md file | path | empty |
| `DEV_RULES_GIT_URL` | (if git) Repo URL containing the rules | url | empty |
| `DEV_RULES_GIT_REF` | (if git) Branch / tag / commit | string | `main` |
| `DEV_RULES_GIT_PATH` | (if git) Path inside the repo | path | `dev-rules.md` |
| `DEV_RULES_BACKEND_STACK` | (optional) One-line description of the preferred backend stack | string | empty |
| `DEV_RULES_FRONTEND_STACK` | (optional) One-line description of the preferred frontend stack | string | empty |
| `DEV_RULES_ARCH_CHANNEL` | (optional) Slack / Teams channel for architecture decisions | string | empty |
| `DEV_RULES_DOC_HUB` | (optional) URL of your internal docs hub | url | empty |

---

## Section 6 — Branding

This section controls the visual identity of the launcher at runtime: terminal colours, window title, default response language, and the list of vendor names the assistant must never reveal. These appear in every banner, prompt, and terminal session your colleagues will see.

| Var | Question | Type | Default |
|---|---|---|---|
| `BANNER_COLOR_PRIMARY` | Which ANSI color should the banner use? (e.g. `208` for orange, `33` for blue) | string | `208` |
| `CORP_BRAND_ANSI` | Which ANSI code should Codex/Gemini wrappers use? (usually same as `BANNER_COLOR_PRIMARY`) | string | derived from `BANNER_COLOR_PRIMARY` |
| `TERMINAL_TITLE` | What string should be set as the terminal title at launch? | string | `${CORP_NAME} — Powered by ${CORP_POWERED_BY}` |
| `LANGUAGE` | What's the default response language? Choose: `en`, `fr`, `de`, `es`, `it`, `pt`, `nl` | enum | `en` |
| `FORBIDDEN_TERMS` | Which words must the assistant never output? (comma-separated, e.g. vendor names) | string | `Claude,Anthropic` for Claude Code wrapper |
| `BANNER_GENERATE` | Generate an ASCII pixel-art banner for the launcher? | yes/no | yes |
| `BANNER_STYLE` | block / slant / mini / pixel / vintage / tech / auto | enum | `auto` |

---

## Section 7 — Install layout (creator's machine)

This section sets the physical layout of the install on each colleague's machine: where the launcher files live, which shell rc to patch, which runtime versions are required, and the license string surfaced in `BRANDING.md`. These answers shape `install.sh` and `uninstall.sh`.

| Var | Question | Type | Default |
|---|---|---|---|
| `INSTALL_DIR` | Where should we install the launcher tree on the user's machine? | path | `~/.local/share/${CORP_SLUG}` |
| `SHELL_RC` | Which shell rc should we patch? Choose: `zsh`, `bash`, `fish`, `powershell`, or `auto` | enum | auto |
| `LICENSE_TYPE` | Which license applies to the launcher? Choose: `Internal-only`, `Proprietary`, `MIT`, or `Apache-2.0` | enum | `Internal-only` |
| `NODE_VERSION_MIN` | What's the minimum Node.js version required by the wrapped CLI? | string | `20` |
| `PYTHON_VERSION_MIN` | What's the minimum Python version? (for aider / opencode bootstrap) | string | `3.11` |
| `PROVIDER_KIND` | Which gateway family tag applies? Choose: `litellm`, `bedrock`, `vertex`, `azure-openai`, or `direct` | enum | derived from `*_BACKEND` |

---

## Section 8 — Skills bundle (what colleagues get inside the launcher)

This section decides which additional skills (and optional MCP servers) ship inside the launcher so colleagues get a curated experience out-of-the-box, rather than a bare CLI. The answers populate `skills/` inside `INSTALL_DIR` and pre-seed the MCP server list.

See `references/skills-bundle.md` for the full details. Ask:

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

## Section 8.5 — Compliance & audit posture

This section captures the review chain attached to the launcher: which internal authorities must sign off before it ships, whether the DPO is in the loop for PII-handling scenarios, and any pre-existing clearance reference to attach to audit headers and `INTERNAL.md`.

| Var | Question | Type | Default |
|---|---|---|---|
| `CYBER_REVIEW_REQUIRED` | Will the cyber team review this launcher? | yes/no | yes |
| `DPO_REVIEW_REQUIRED` | Will the DPO review the launcher (PII processing)? | yes/no | no |
| `RSSI_CLEARANCE_REF` | Existing ticket / reference for cyber clearance | string | empty |

---

## Section 9 — Distribution (how to ship it to the team)

This section determines how colleagues will actually get the launcher onto their machines: a public/private git repo, an internal tarball mirror, a one-liner install URL, or local-only. Each mode unlocks a different sub-set of variables (repo host, registry URL, signing key, etc.). See `references/distribution-modes.md` for trade-offs. Ask:

```
How do you want to ship this to your team?

  [1] Public GitHub repo
  [2] Private GitHub / GitLab repo
  [3] Tarball + internal artifact registry
  [4] One-liner install URL (host install.sh on your intranet)
  [5] No distribution — local only for now
```

| Var | Question | Type | Default |
|---|---|---|---|
| `DIST_MODE` | How do you want to distribute the launcher? Choose: `public-git`, `private-git`, `tarball`, `oneliner`, or `none` | enum | required |
| `DIST_REPO_HOST` | Which repo host will you use? Choose: `github`, `gitlab`, `bitbucket`, or `internal-gitea` | enum | `github` |
| `DIST_REPO_URL` | What's the URL of the repo to create? | URL | required if git mode |
| `DIST_REPO_VISIBILITY` | What visibility should the repo have? Choose: `public`, `internal`, or `private` | enum | `private` |
| `DIST_REGISTRY_URL` | What's the Nexus / Artifactory base URL? (tarball mode) | URL | required if tarball |
| `DIST_ONELINER_HOST` | Where will the install.sh one-liner be hosted? (URL) | URL | required if oneliner |
| `DIST_SIGN_RELEASE` | Should we sign the tarball / install.sh with GPG? Choose: yes or no | bool | no |
| `DIST_GPG_KEY_ID` | What GPG key id should we use to sign releases? | string | empty |
| `DIST_DEFAULT_BRANCH` | What's the default branch name when scaffolding the git repo? (e.g. `main`, `trunk`) | string | `main` |
| `DIST_GIT_REF` | Which pinned git ref should `oneliner/install.ps1` consume? | string | `main` |
| `DIST_S3_BUCKET` | What S3 bucket should `dist/oneliner/host-on-s3.sh` upload to? | string | empty |
| `CORP_ORG_GH` | What's your GitHub org or user slug? (public-git or pages hosting) | string | empty |
| `INTERNAL_DOCS_URL` | What's the URL of the internal portal hosting README / install docs? | url | empty |
| `INTERNAL_NPM_MIRROR_URL` | What's your internal npm proxy URL for offline Node CLI bootstrap? | url | empty |

---

## Section 10 — Runtime / derived variables

This section is documentation-only — there are no questions to ask. It lists variables produced by the launcher (or the operator) at install/run time, which appear in templates as literal `${VAR}` so the resulting shell script dereferences them later. It exists purely so the template-variable audit knows these names are intentional.

These variables are **not asked at interview time**. They are produced by the launcher (or the operator) at install / run time and only appear in templates because the generator emits the literal `${VAR}` so the resulting script will dereference them later.

The interview spec lists them here only to satisfy the template-variable audit (`tests/sync-vars.py`). Do **not** prompt the user for them.

| Var | Origin | Notes |
|---|---|---|
| `CORP_API_KEY` | runtime env on user's machine | set by user after first SSO login; consumed by `continue-dev/launcher.sh` and `cline/settings-cline.json` |

> The earlier `revoke-token.sh` runtime locals (`USER_EMAIL`, `ADMIN_TOKEN`, `OPERATOR`, `REASON`, `REQUEST_ID`, `SCOPE`, `STATUS`, `TIMESTAMP`) live in the rendered shell script only — they are now escaped (`$\{VAR\}`) in the `.tpl` so the launcher generator does **not** substitute them. They are intentionally **not** listed as table rows.

---

## Section 11 — Feature-specific variables

This section groups variables that are only asked when a matching feature is enabled (token revocation, tarball uploaders, internal references). They have **no default** when the feature is off and must not appear in the generated launcher in that case. Skip an entire sub-section unless the feature flag justifies asking.

Only collected if the matching feature is enabled. They have **no default** when the feature is off and must not appear in the generated launcher in that case.

### 11.A — Token revocation (`shared/revoke-token.sh`)

Required when offboarding automation is included. These values let the launcher revoke a departing user's gateway token from the admin plane.

| Var | Question | Type | Default |
|---|---|---|---|
| `GATEWAY_ADMIN_API` | What's the admin REST API base URL of the gateway? (e.g. LiteLLM `/admin`, Azure APIM control plane) | url | required |
| `GATEWAY_BACKEND` | Which gateway backend handles revocation? Choose: `litellm`, `azure`, `vertex`, or `bedrock` | enum | required |
| `GATEWAY_ADMIN_TOKEN_ENV` | Which env var name holds the admin token? (never the token itself) | string | `LITELLM_ADMIN_TOKEN` |

> Backend-specific knobs (`AZURE_APIM_NAME`, `AZURE_APIM_RG`, `BEDROCK_USER_POLICY_ARN`, `GCP_PROJECT_ID`) are passed to the rendered `revoke-token.sh` as **escaped** placeholders (`$\{AZURE_APIM_NAME\}`) so the script reads them from its own env at run time. They are intentionally not interview keys.

### 11.B — Tarball uploaders (`dist/tarball/upload-*.sh`)

Only emitted when `DIST_MODE=tarball`. Choose at least one target. The answers determine which uploader scripts get scaffolded and which credentials the CI pipeline must provide.

| Var | Question | Type | Default |
|---|---|---|---|
| `NEXUS_USER` | What's the Nexus raw-repo upload user? | string | required if Nexus |
| `NEXUS_PASS` | Which env var name holds the Nexus password? | string | `NEXUS_PASSWORD` |
| `ARTIFACTORY_USER` | What's the Artifactory upload user? | string | required if Artifactory |
| `ARTIFACTORY_PASS` | Which env var name holds the Artifactory password? | string | `ARTIFACTORY_PASSWORD` |
| `ARTIFACTORY_TOKEN` | Which env var name holds an Artifactory access token? (alternative to user/pass) | string | empty |
| `AWS_PROFILE` | Which AWS named profile should be used for S3 upload? | string | `default` |

### 11.C — Internal corporate references (private-git / INTERNAL.md)

Emitted only when `DIST_MODE=private-git` or `DIST_MODE=tarball` (internal distributions). These values populate `INTERNAL.md` and the audit headers so colleagues know whom to contact for security, support, and compliance.

| Var | Question | Type | Default |
|---|---|---|---|
| `CORP_INTERNAL_CONTACT` | Which internal team owns this launcher? (email or alias) | string | required |
| `CORP_SUPPORT_CONTACT` | What public support email should appear in user-facing files? | email | required |
| `CORP_SECURITY_EMAIL` | What's the security/PSIRT mailbox for vulnerability reports? | email | required |
| `CORP_INCIDENT_CONTACT` | What's the 24/7 incident pager or hotline? | string | empty |
| `CORP_DPO_CONTACT` | What's the Data Protection Officer mailbox? | email | empty |
| `CORP_PROCUREMENT_CONTACT` | Who's the procurement contact for vendor renewals? | string | empty |
| `CORP_AUDIT_SYSTEM` | Which SIEM ingests `audit.log`? (e.g. `Splunk`, `Elastic`) | string | empty |
| `CORP_AUDIT_LOCATION` | What path or URL is `audit.log` shipped to? | string | empty |

---

## Validation rules

This section lists the cross-field checks the skill must run before generating any file. If any check fails, the skill must loop back to the relevant `AskUserQuestion` instead of producing a broken launcher.

Before generating, the skill must check:

1. `CORP_NAME` and `CORP_SLUG` are set and `CORP_SLUG` matches `^[a-z][a-z0-9-]{1,30}$`.
2. For every selected CLI in `WRAPPED_CLIS`, the corresponding `CC_*` / `CX_*` / `GM_*` / `LLM_*` block is complete.
3. `CC_PRIMARY_URL` etc. parse as valid HTTPS URLs.
4. `PROXY_HOST` is empty XOR `PROXY_PORT` is set (no half-config).
5. If `BLOCK_TELEMETRY=yes`, the generated launcher must export ALL the kill switches listed in `references/env-vars.md` (no partial opt-out).
6. If `CC_BACKEND=Bedrock` or `=LiteLLM`, force `CC_NEEDS_STRIP_PROXY=yes`.
7. If `DIST_MODE=public-git`, refuse if `CC_PRIMARY_URL` contains an internal hostname (`.internal`, `.local`, RFC1918) unless the creator overrides with `DIST_PUBLIC_FORCE=yes`.
8. If `DIST_MODE=oneliner`, refuse if `DIST_ONELINER_HOST` is plain HTTP (force HTTPS).
9. If `SKILLS_MODE=git` and the URL is publicly mirrored, prompt: "is this repo reviewed by your security team?" before continuing.

If a check fails, loop back to the relevant `AskUserQuestion`.

---

## Final recap before generating

This section defines the one-screen summary the skill shows the user before generating anything. It surfaces the key decisions in a single glance so the operator can spot mistakes before files are written to disk. Wait for an explicit `y` to proceed.

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
