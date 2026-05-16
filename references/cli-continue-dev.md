# Continue.dev — corporate launcher notes

Focused reference loaded only when `WRAPPED_CLIS` contains `continue-dev`. Companion to `templates/continue-dev/` (`config.yaml.tpl`, `install.sh.tpl`, `launcher.sh.tpl`, `uninstall.sh.tpl`).

## Table of contents

- [What Continue.dev actually is](#what-continuedev-actually-is)
- [Why it sits in Tier A](#why-it-sits-in-tier-a)
- [`~/.continue/config.yaml` structure](#continueconfigyaml-structure)
- [`${env:VAR}` runtime substitution](#envvar-runtime-substitution)
- [`requestOptions` — corporate proxy + CA + mTLS](#requestoptions--corporate-proxy--ca--mtls)
- [Provider configuration](#provider-configuration)
- [MCP support — limited](#mcp-support--limited)
- [Embeddings — disable by default](#embeddings--disable-by-default)
- [Telemetry kill switches](#telemetry-kill-switches)
- [Known issues](#known-issues)

---

## What Continue.dev actually is

- **Not a CLI.** Continue.dev is a VS Code / JetBrains IDE extension.
- Install via the IDE marketplace, extension id **`Continue.continue`** (VS Code) or the JetBrains plugin id `com.github.continuedev.continueintellijextension`.
- Official docs: <https://docs.continue.dev>.
- Repo: <https://github.com/continuedev/continue>.
- Reads its config from `~/.continue/config.yaml` (overridable with `$CONTINUE_GLOBAL_DIR`).
- Runs inside the IDE's Node-based extension host, so it inherits `HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS`, `NODE_USE_SYSTEM_CA` from the parent process — *only* if the IDE itself was launched from a shell that has those exported.

## Why it sits in Tier A

Continue is in **Tier A** of `provider-matrix.md`, not Tier S, because:

1. There is no `continue` binary to wrap. The launcher cannot intercept `argv` or `env` at exec time the way it does for Claude Code / Aider / Gemini CLI.
2. The "launch" is really `code --install-extension Continue.continue` followed by writing `~/.continue/config.yaml`.
3. The corporate config is a **pre-deployed YAML file** with `${env:VAR}` placeholders + an IDE opener that ensures the user's shell environment is in scope.
4. The launcher script in `templates/continue-dev/launcher.sh.tpl` does three things:
   - re-export the corporate env block (proxy, CA, telemetry kill, `CORP_API_KEY`),
   - `code .` (or `idea .`) so the IDE inherits that env block,
   - watch for an existing `~/.continue/config.yaml` and refuse to clobber a hand-edited one.

## `~/.continue/config.yaml` structure

Minimum keys the launcher writes (mirrors `templates/continue-dev/config.yaml.tpl`):

```yaml
name: ${CORP_NAME}
version: 1.0.0
schema: v1

models:
  - name: ${CORP_NAME} Primary
    provider: openai          # OpenAI-compatible gateway (LiteLLM/Azure/Bedrock-proxy)
    model: ${LLM_PRIMARY_MODEL}
    apiBase: ${LLM_OPENAI_BASE_URL}
    apiKey: ${env:CORP_API_KEY}
    roles: [chat, edit, apply, summarize]
    defaultCompletionOptions: { temperature: 0.2, maxTokens: 4096 }
    requestOptions: { ... }   # see below

  - name: ${CORP_NAME} Autocomplete
    provider: openai
    model: ${LLM_WEAK_MODEL}
    apiBase: ${LLM_OPENAI_BASE_URL}
    apiKey: ${env:CORP_API_KEY}
    roles: [autocomplete]
    requestOptions: { ... }

embeddingsProvider:
  provider: none              # corp default — no code shipped to embed API

contextProviders:
  - { provider: code }
  - { provider: docs }
  - { provider: diff }
  - { provider: terminal }
  - { provider: problems }
  - { provider: folder }
  - { provider: codebase }

slashCommands:
  - { name: review,  description: Review the current diff for issues }
  - { name: edit,    description: Edit the highlighted code }
  - { name: share,   description: Export the current chat session }

allowAnonymousTelemetry: false
experimental:
  useAlternativePersonality: false
```

Each top-level key is mandatory for a clean install — the older flat-list `models:` schema (`config.json`) is deprecated since 0.9.x; do not emit it.

## `${env:VAR}` runtime substitution

Continue resolves `${env:NAME}` **at extension load time**, reading from `process.env` of the IDE extension host. This is *not* the launcher's renderer — the launcher must keep that placeholder literal in the generated file.

Two substitution syntaxes coexist in `templates/continue-dev/config.yaml.tpl`:

| Syntax | Resolver | When | Example |
|---|---|---|---|
| `${VAR}` | Launcher renderer (envsubst) | at install time | `${LLM_OPENAI_BASE_URL}` → `https://litellm.internal.acme.fr/v1` |
| `${env:VAR}` | Continue.dev at IDE load | every time the extension starts | `${env:CORP_API_KEY}` stays literal on disk, resolved from `process.env.CORP_API_KEY` |

**Rule:** secrets (API keys, certificate passphrases) MUST use `${env:VAR}`. The corporate API key never lands on disk — only the placeholder does. `provider-matrix.md` row "Continue.dev" calls this out explicitly.

The launcher's job is then to make sure `CORP_API_KEY` is in the IDE's environment when it boots. Two patterns work:

1. The shell RC block exports `CORP_API_KEY` (loaded from `~/.${CORP_SLUG}/secrets` or from `secret-tool` / `security find-generic-password`), and the user launches the IDE from a terminal (`code .` / `idea .`). This is what `launcher.sh.tpl` does.
2. The OS keyring is used via a small helper (`security` / `secret-tool` / Windows Credential Manager) called by a desktop-entry wrapper. Heavier — only needed when the user double-clicks the IDE icon instead of starting it from a shell.

## `requestOptions` — corporate proxy + CA + mTLS

Continue's per-model `requestOptions` block carries every knob a corporate network needs. All are honored by the underlying `fetch` shim:

```yaml
requestOptions:
  timeout: 60000
  verifySsl: ${LLM_VERIFY_SSL}            # true in prod — never set false silently
  caBundlePath: ${CORP_CA_BUNDLE_PATH}    # absolute path to corp PEM
  proxy: ${CORP_HTTPS_PROXY}              # http://proxy.acme.fr:8080
  noProxy: ${CORP_NO_PROXY}               # 127.0.0.1,localhost,.internal.acme.fr
  headers:
    User-Agent: ${CORP_SLUG}-launcher/${CORP_LAUNCHER_VERSION}
  clientCertificate:                      # mTLS — only set if tenant uses it
    cert: ${CORP_CLIENT_CERT_PATH}
    key:  ${CORP_CLIENT_KEY_PATH}
    passphrase: ${env:CORP_CLIENT_KEY_PASSPHRASE}
```

Notes:

- `caBundlePath` is per-model — Continue does **not** fall back to `NODE_EXTRA_CA_CERTS` for every code path (autocomplete uses a different HTTP path). Set it on **both** model entries.
- `verifySsl: false` is forbidden by the launcher. If the interview answer says "self-signed cert, no bundle available", the installer must abort and instruct the user to fetch the bundle via `openssl s_client -showcerts`.
- `clientCertificate.passphrase` uses `${env:VAR}` because Continue stores the resolved YAML in IDE state — putting a passphrase literal would leak it into VS Code's `globalState`.
- `noProxy` matches Node's rules (suffix match for `.domain`, exact match otherwise). Always include `127.0.0.1,localhost` so the local strip-proxy used by Bedrock/LiteLLM is not double-proxied.

## Provider configuration

Continue's `provider:` field selects the wire protocol, not the vendor. For a corporate gateway, the value is almost always `openai`:

| Gateway | `provider:` | `apiBase` | Notes |
|---|---|---|---|
| LiteLLM proxy | `openai` | `https://litellm.internal/v1` | Most common — LiteLLM speaks OpenAI on the way in, anything on the way out. |
| Azure OpenAI | `openai` | `https://my-resource.openai.azure.com/openai/v1` | Use the `/v1` shim, not the deployment-scoped URL. |
| Anthropic direct (rare) | `anthropic` | `https://api.anthropic.com` | Only if the gateway terminates as native Anthropic — not via OpenAI shim. |
| Mistral / Codestral | `mistral` | `https://codestral.mistral.ai/v1` | Direct vendor — corporate path usually wraps it in LiteLLM and falls back to `openai`. |
| Bedrock-strip-proxy | `openai` | `http://127.0.0.1:${STRIP_PROXY_PORT}/v1` | Identical pattern to Claude Code's Bedrock path. |

The launcher sets `LLM_CONTINUE_PROVIDER` from the interview answer and template-substitutes it — only `openai` and `anthropic` are validated by the schema in `schema/`.

## MCP support — limited

**Status (May 2026):** Continue.dev does **not** speak MCP natively as a client. The roadmap mentions an experimental flag but no shipped feature in the `1.x` series. Equivalent caveat to `mcp-aider-note.md`.

Implications for the launcher:

- If the interview sets `SKILLS_MODE` to a value that includes `mcp` and `CLI=continue-dev`, the installer must emit a warning (mirrors the Aider pattern):

  ```sh
  if echo "${SKILLS_MODE}" | grep -qi mcp; then
      warn "Continue.dev has no native MCP client (May 2026)."
      warn "MCP-flagged skills will be installed as docs only."
      warn "Track upstream: https://github.com/continuedev/continue/discussions"
  fi
  ```
- Workaround = the same MCP-to-OpenAI bridge pattern (MCP-Bridge / mcpm-bridge). Out-of-tree and breaks the single-gateway audit trail — forbidden by most corporate policies.
- Continue's `contextProviders` cover most of what MCP would provide locally (codebase, diff, terminal, docs) — for corporate use that is usually enough.

## Embeddings — disable by default

```yaml
embeddingsProvider:
  provider: none
```

Rationale:

1. The default embeddings provider in Continue is `transformers.js` (local) but historically defaulted to `openai` — version drift is a real risk.
2. Any non-`none` setting causes Continue to chunk and ship **source code** to the embeddings endpoint. On a corporate gateway that is acceptable; on a non-gateway endpoint it is a data-exfiltration vector.
3. To enable embeddings against the corporate gateway, the tenant explicitly sets `LLM_EMBED_MODEL` in the interview and the template rewrites this block to:

   ```yaml
   embeddingsProvider:
     provider: openai
     model: ${LLM_EMBED_MODEL}
     apiBase: ${LLM_OPENAI_BASE_URL}
     apiKey: ${env:CORP_API_KEY}
     requestOptions: { ... same as primary ... }
   ```

   Never default to this — it must be an opt-in interview answer.

## Telemetry kill switches

| Setting / env | Effect |
|---|---|
| `allowAnonymousTelemetry: false` (in `config.yaml`) | Disable the built-in PostHog client. |
| `experimental.useAlternativePersonality: false` | Block the upstream "personality" A/B test that re-routes prompts. |
| `DO_NOT_TRACK=1` (env, exported by launcher) | Generic Node opt-out, also respected by Continue. |
| `CONTINUE_TELEMETRY_DISABLED=1` (env) | Undocumented but honored — belt-and-suspenders. |
| `DISABLE_AUTOUPDATER=1` (env) | Pin the extension version; combine with `--install-extension Continue.continue@<pinned>`. |

The launcher exports the env block before `code .` so the extension host inherits them at startup, even if the user later opens a workspace via "Recent".

## Known issues

1. **Config schema drift (0.9.x → 1.x).** The flat `config.json` format is deprecated. Only emit `config.yaml` with `schema: v1`. The installer must check the IDE-extension version with `code --list-extensions --show-versions | grep Continue.continue` and refuse to install if it is `< 0.9.250`.
2. **`config.yaml` vs `config.json` precedence.** If both exist, Continue silently picks `config.json` and ignores YAML. The installer's `uninstall.sh.tpl` therefore removes both; the installer also refuses to write `config.yaml` while a `config.json` is present (it would be invisibly shadowed).
3. **`caBundlePath` ignored for autocomplete in some 1.0.x builds.** Known regression — workaround is to also set `NODE_EXTRA_CA_CERTS` in the launcher's exported env. The launcher already does this for every Node CLI.
4. **JetBrains plugin lags VS Code extension by ~2 weeks.** If the tenant targets JetBrains, pin to the last-known-good plugin version and skip the autocomplete model (the JetBrains autocomplete path has its own bugs).
5. **`${env:VAR}` not resolved in `name:`.** Continue resolves `${env:...}` inside string-typed fields but skips the top-level `name`. Do not put secrets there — only the corporate display name.
6. **Workspace-level config (`.continue/config.yaml` in repo root).** Overrides the global file silently. Mention this in the BRANDING.md handed to users — a tenant-leaked repo config could route prompts off the gateway.
