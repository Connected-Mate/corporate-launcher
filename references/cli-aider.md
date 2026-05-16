# CLI Reference — Aider

Focused operational notes for wrapping **Aider** behind a corporate gateway.
Loaded only when `WRAPPED_CLIS` contains `aider`. For multi-CLI orchestration
see `provider-matrix.md`; for MCP specifics see `mcp-aider-note.md`.

## Table of contents

- [1. What Aider is](#1-what-aider-is)
- [2. Why Aider is Tier S](#2-why-aider-is-tier-s)
- [3. Required environment variables](#3-required-environment-variables)
- [4. `~/.aider.conf.yml` structure](#4-aiderconfyml-structure)
- [5. Corporate CA bundle (Python TLS)](#5-corporate-ca-bundle-python-tls)
- [6. MCP limitation](#6-mcp-limitation)
- [7. Per-backend cookbook](#7-per-backend-cookbook)
- [8. Telemetry kill switches](#8-telemetry-kill-switches)
- [9. Cost tracking](#9-cost-tracking)
- [10. Git integration](#10-git-integration)
- [11. Known issues](#11-known-issues)

---

## 1. What Aider is

Aider is a **Python CLI** for AI pair-programming in a local git repo. It
edits files in place, runs the test suite, and (optionally) commits.

- **Install**: `pipx install aider-install && aider-install`
  (the `aider-install` shim resolves the right `aider-chat` extras for the
  host Python; do **not** `pip install aider-chat` system-wide).
- **Docs**: <https://aider.chat>
- **Runtime**: pure Python — HTTP stack is `httpx` + `requests` via
  **embedded LiteLLM** (`litellm` is vendored, not a separate proxy).
- **Config discovery order**: CLI flag > env var (`AIDER_*`) >
  `./.aider.conf.yml` > `~/.aider.conf.yml` > built-in defaults.

## 2. Why Aider is Tier S

Aider is the **cleanest CLI to wrap** in the entire matrix:

- 100 % ENV-driven — every config key has an `AIDER_<UPPER_SNAKE>` mirror.
- Native OpenAI-Chat-Completions wire format — works with **any** LiteLLM
  proxy out of the box (no SSE strip-proxy, no header rewriting).
- Supports OpenAI / Anthropic / Bedrock / Azure / Vertex / Ollama / Cohere
  / Mistral / Together / Groq / DeepSeek through the embedded LiteLLM
  layer — the launcher only needs to pick a `model` string.
- File-based identity: a single `~/.aider.conf.yml` survives shell rotation
  even if a child process strips the environment.
- No telemetry once `analytics-disable: true` is set (verified by source —
  Aider's analytics hits `aider.chat/analytics`, gated by one flag).

## 3. Required environment variables

Set by `templates/aider/launcher.sh.tpl` (`setup_gateway_env`):

| Variable | Purpose | Example |
|---|---|---|
| `OPENAI_API_KEY` | Bearer token sent to the gateway | `$CORP_API_KEY` |
| `OPENAI_API_BASE` | Gateway root, **must** end in `/v1` | `https://litellm.internal.acme.fr/v1` |
| `OPENAI_BASE_URL` | Mirror (some libs read this name) | same as above |
| `AIDER_MODEL` | Primary model id (LiteLLM convention) | `openai/claude-opus-4-7` |
| `AIDER_WEAK_MODEL` | Cheap model for commit-msg, summaries | `openai/claude-haiku-4-5` |
| `AIDER_CONFIG` | Path to the managed YAML | `$HOME/.aider.conf.yml` |
| `AIDER_VERIFY_SSL` | TLS verification (mirror of YAML) | `true` |
| `AIDER_ANALYTICS_DISABLE` | Kill switch (belt-and-braces) | `1` |
| `AIDER_CHECK_UPDATE` | Disable update probe | `false` |

The launcher **never** sets `ANTHROPIC_API_KEY`, `AZURE_API_KEY`, etc.
directly — everything is routed through the OpenAI-compatible facade of the
corporate LiteLLM proxy. The backend selection is the **proxy's** job.

## 4. `~/.aider.conf.yml` structure

Written at install time from `templates/aider/aider.conf.yml.tpl`. Key
sections (full template in the repo):

```yaml
openai-api-base: ${LLM_OPENAI_BASE_URL}
model:           ${LLM_PRIMARY_MODEL}
weak-model:      ${LLM_WEAK_MODEL:-${LLM_PRIMARY_MODEL}}

auto-commits:     false   # never commit on behalf of the user
dirty-commits:    false
attribute-author: false

analytics-disable:  true
check-update:       false
show-release-notes: false

verify-ssl: ${ACCEPT_TLS_INSPECTION_INVERTED:-true}

dark-mode: true
pretty:    true
stream:    true
gitignore: true

input-history-file: ${HOME}/.aider.input.history
chat-history-file:  ${HOME}/.aider.chat.history.md
llm-history-file:   ${HOME}/.aider.llm.history

map-tokens:              1024
max-chat-history-tokens: 8192
```

Header marks the file as **launcher-managed** — hand-edits are overwritten
on the next `install.sh` run. The YAML is the persistent line of defense
when a child shell drops the `AIDER_*` env.

## 5. Corporate CA bundle (Python TLS)

Python's `requests` (used by Aider for repo-map probes and litellm's HTTP)
and `httpx` (used by litellm streaming) **do not** read the OpenSSL system
store on macOS / Windows — they use `certifi`. To trust a corporate root
CA, export both:

```sh
export REQUESTS_CA_BUNDLE=/etc/ssl/acme-corp-bundle.pem
export SSL_CERT_FILE=/etc/ssl/acme-corp-bundle.pem
# httpx specifically
export HTTPX_SSL_CERT_FILE=/etc/ssl/acme-corp-bundle.pem
# curl-based subprocesses (if any)
export CURL_CA_BUNDLE=/etc/ssl/acme-corp-bundle.pem
```

When the tenant explicitly accepts TLS inspection without supplying a CA
bundle, the launcher falls back to `AIDER_VERIFY_SSL=false` **inside the
launcher process only** — never globally, never `PYTHONHTTPSVERIFY=0`
exported into the user's shell rc.

## 6. MCP limitation

**Aider has no native MCP support** as of May 2026 (upstream issues
[#3314](https://github.com/Aider-AI/aider/issues/3314),
[#2672](https://github.com/Aider-AI/aider/issues/2672),
[#4506](https://github.com/aider-ai/aider/issues/4506)). Confusingly, the
MCP servers named `aider-mcp-server` go the **opposite** direction — they
let an MCP client *drive* Aider.

Two unsupported workarounds:

1. **MCP-to-OpenAI bridge** (`MCP-Bridge`, `mcpm-aider`) — repoint
   `OPENAI_API_BASE` at the bridge. **Breaks the corporate audit trail**;
   forbidden by most policies.
2. **Pre-fetch + `--read`** — wrap Aider in a shell script that pulls MCP
   context to a tempfile first, then `aider --read /tmp/mcp-ctx.md ...`.
   Read-only, no tool execution, gateway path intact.

When `SKILLS_MODE` includes MCP and `CLI=aider`, the installer emits a
warning and installs MCP-flagged skills as **docs only**. See
`references/mcp-aider-note.md` for the full snippet.

## 7. Per-backend cookbook

All examples assume the model string follows LiteLLM's `provider/name`
convention. Picking the provider prefix tells embedded LiteLLM how to
shape the upstream request.

### OpenAI (direct or via LiteLLM proxy)

```sh
export OPENAI_API_KEY=$CORP_API_KEY
export OPENAI_API_BASE=https://litellm.internal.acme.fr/v1
export AIDER_MODEL=openai/gpt-4.1
```

### Azure OpenAI

```sh
export AZURE_API_KEY=$CORP_API_KEY
export AZURE_API_BASE=https://my-resource.openai.azure.com
export AZURE_API_VERSION=2024-10-21
export AIDER_MODEL=azure/my-deployment-name
```

When fronted by LiteLLM, prefer the OpenAI-compat path above and let the
proxy translate to Azure — single audit trail.

### AWS Bedrock (via LiteLLM proxy, recommended)

```sh
export OPENAI_API_KEY=$LITELLM_TOKEN
export OPENAI_API_BASE=https://litellm.internal.acme.fr/v1
export AIDER_MODEL=openai/bedrock-claude-opus-4-7  # alias defined in LiteLLM
```

Direct-to-Bedrock from Aider is possible (`bedrock/...` model + AWS creds)
but bypasses the gateway — **not used by this launcher**.

### Vertex AI

Same shape as Bedrock — go through the LiteLLM proxy with a `vertex_ai/`
alias on the proxy side. No SDK creds on the user's machine.

## 8. Telemetry kill switches

Layered defense (env + YAML + CLI flag):

```sh
export AIDER_ANALYTICS_DISABLE=1
export AIDER_CHECK_UPDATE=false
export AIDER_SHOW_RELEASE_NOTES=false
# Transitive
export DO_NOT_TRACK=1
export LITELLM_TELEMETRY=False
export LITELLM_LOG=ERROR
export SENTRY_DSN=""
export OTEL_EXPORTER_OTLP_ENDPOINT=""
```

In `~/.aider.conf.yml`:

```yaml
analytics-disable: true
check-update: false
show-release-notes: false
```

Or pass `--no-analytics --no-check-update` on the CLI line (the launcher
relies on the env + YAML pair so users invoking `aider` directly remain
opted-out).

## 9. Cost tracking

Aider prints **per-message cost** in the chat footer (input tokens, output
tokens, $ estimate) based on LiteLLM's pricing table. With a private
LiteLLM proxy the public pricing table may be wrong — supply a custom
`model_info` block on the proxy side, or set:

```sh
export AIDER_MODEL_SETTINGS_FILE=/etc/acme/aider-model-pricing.yml
```

to override locally. `--cost` summarises the running total at any point;
`/clear` resets the chat without clearing the cumulative total.

## 10. Git integration

The launcher disables every auto-commit code path:

```yaml
auto-commits:       false
dirty-commits:      false
attribute-author:   false
attribute-committer: false
```

Rationale: in a corporate setting we cannot let the assistant push commits
under the user's identity without an explicit review step. The user runs
`git add -p && git commit` themselves. Aider still *suggests* commit
messages via `weak-model`; copy-paste is the workflow.

## 11. Known issues

- **None specific to corporate use** at the time of writing — Aider is the
  most predictable of the wrapped CLIs.
- Watch `pipx` upgrades: a `pipx upgrade aider-install` rewrites the
  `aider` shim and may reset behaviour if the user previously did
  `pipx install aider-chat` (two parallel installs). The launcher pins to
  the `aider-install` shim path and refuses to run if it disagrees with
  `which aider` (see `install.sh.tpl`).
- LiteLLM upstream pins inside Aider lag a few weeks behind the standalone
  `litellm` PyPI release. If the corporate proxy enables a brand-new
  feature, test with the wrapped Aider before announcing it tenant-wide.
