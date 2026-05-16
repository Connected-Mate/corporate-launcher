# Environment variable reference

Authoritative list of every env var the launcher templates may set. Use this when filling in `interview-flow.md` answers, when writing a new template, or when an end-user complains "why is X being exported".

Sources: official 2026 docs of each CLI + the research notes in `reference/research-notes.md`.

---

## Universal

| Var | Purpose | Notes |
|---|---|---|
| `${CORP_SLUG_UPPER}_HOME` | Install directory of the launcher | exported by the shell RC block |
| `${CORP_SLUG_UPPER}_ACTIVE` | `1` when a launcher session is running | used by status lines, hooks |
| `${CORP_SLUG_UPPER}_DRY_RUN` | `1` = print env and exit, do not exec the CLI | for CI / smoke tests |
| `${CORP_SLUG_UPPER}_SESSION_START` | UNIX timestamp of the launch | used by cost tracker |
| `${CORP_SLUG_UPPER}_VERSION` | Launcher version string | used in the User-Agent |
| `CORP_API_KEY` | Loaded token (in memory only) | never written to disk by the launcher |

---

## Corporate network (all CLIs)

| Var | Purpose |
|---|---|
| `HTTP_PROXY` / `http_proxy` | Corporate HTTP proxy URL — set only if reachable |
| `HTTPS_PROXY` / `https_proxy` | Corporate HTTPS proxy URL |
| `NO_PROXY` / `no_proxy` | Bypass list (always includes `127.0.0.1,localhost` for strip-proxy) |
| `NODE_EXTRA_CA_CERTS` | Path to corporate PEM bundle (Node CLIs) |
| `NODE_USE_SYSTEM_CA` | `1` to also trust the OS store (Node 22.15+) |
| `REQUESTS_CA_BUNDLE` | Same path (Python CLIs — Aider) |
| `SSL_CERT_FILE` | Same path (stdlib Python `ssl`) |
| `CODEX_CA_CERTIFICATE` | Same path (Codex CLI Rust) |
| `NODE_TLS_REJECT_UNAUTHORIZED` | `0` only if `ACCEPT_TLS_INSPECTION=yes` |
| `PYTHONHTTPSVERIFY` | `0` only if `ACCEPT_TLS_INSPECTION=yes` |

---

## Claude Code

| Var | Purpose |
|---|---|
| `ANTHROPIC_BASE_URL` | Gateway URL (or `http://127.0.0.1:9876` if strip-proxy in use) |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token |
| `ANTHROPIC_API_KEY` | Alternative — used when no Bearer |
| `ANTHROPIC_MODEL` | Default model |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Small/fast model (replaces deprecated `ANTHROPIC_SMALL_FAST_MODEL`) |
| `CLAUDE_CODE_USE_BEDROCK` | `1` for direct Bedrock (skipped if going through LiteLLM) |
| `CLAUDE_CODE_USE_VERTEX` | `1` for direct Vertex |
| `CLAUDE_CODE_USE_MANTLE` | `1` for Bedrock Mantle |
| `CLAUDE_CODE_SKIP_BEDROCK_AUTH` | `1` if the gateway handles AWS auth |
| `CLAUDE_CODE_SKIP_VERTEX_AUTH` | `1` if the gateway handles GCP auth |
| `CLAUDE_CODE_CERT_STORE` | `bundled,system` (default) — set `system` for OS-only |
| `CLAUDE_CODE_CLIENT_CERT` / `_KEY` / `_KEY_PASSPHRASE` | mTLS |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | Master kill switch |
| `CLAUDE_CODE_SKIP_UPDATE_CHECK` | Pin version |
| `DISABLE_AUTOUPDATER` | Pin version (alt) |
| `DISABLE_TELEMETRY` | Telemetry off |
| `DO_NOT_TRACK` | Generic DNT |
| `DISABLE_ERROR_REPORTING` | No errors to vendor |
| `DISABLE_BUG_COMMAND` | Hide `/bug` |
| `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY` | Hide survey |
| `CLAUDE_CODE_DISABLE_VOICE` | Voice mode off (calls vendor WS directly) |
| `SENTRY_DSN` | Empty string disables Sentry |
| `DD_TRACE_ENABLED` | `0` disables Datadog |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Empty disables OpenTelemetry |
| `STATSIG_DISABLED` | `1` disables feature flags |
| `GROWTHBOOK_API_HOST` | Empty disables GrowthBook |
| `BUN_ENABLE_CRASH_REPORTING` | `0` |

---

## Codex CLI

| Var | Purpose |
|---|---|
| `OPENAI_API_KEY` | Standard auth (or backend-specific via `env_key` in config.toml) |
| `AZURE_OPENAI_API_KEY` | Conventional name for Azure path |
| `OPENAI_BASE_URL` | Override (when not using `[model_providers]` block) |
| `CODEX_CA_CERTIFICATE` | Corp CA PEM |
| `SSL_CERT_FILE` | Fallback CA |
| `HTTPS_PROXY` | Partial support (issue #4242) |

Plus the `~/.codex/config.toml` directives (see `templates/codex-cli/config.toml.tpl`).

---

## Gemini CLI

| Var | Purpose |
|---|---|
| `GEMINI_API_KEY` | AI Studio (consumer) — **unset for Vertex** |
| `GOOGLE_API_KEY` | GCP key — **unset for Vertex ADC** |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to service account JSON |
| `GOOGLE_CLOUD_PROJECT` | GCP project |
| `GOOGLE_CLOUD_LOCATION` | GCP region (e.g. `europe-west4`) |
| `GOOGLE_GENAI_USE_VERTEXAI` | `true` to force Vertex |
| `GOOGLE_GEMINI_BASE_URL` | Override gateway |
| `GOOGLE_VERTEX_BASE_URL` | Override Vertex endpoint |
| `GEMINI_MODEL` | Default model |
| `GEMINI_TELEMETRY_ENABLED` | `false` to disable |
| `GEMINI_SANDBOX` | `docker` / `podman` for sandboxed tool exec |

---

## Aider

| Var | Purpose |
|---|---|
| `OPENAI_API_BASE` | LiteLLM / gateway URL |
| `OPENAI_API_KEY` | Token |
| `AIDER_MODEL` | Override default model |
| `AIDER_WEAK_MODEL` | Cheap model for commit messages |
| `AIDER_VERIFY_SSL` | `false` only if `ACCEPT_TLS_INSPECTION=yes` |
| `AIDER_ANALYTICS_DISABLE` | `1` to disable telemetry |
| `AIDER_SET_ENV` | Forward env vars to subprocess (sandbox) |
| `AZURE_API_BASE` | Direct Azure path |
| `REQUESTS_CA_BUNDLE` | Corp CA |

---

## opencode

| Var | Purpose |
|---|---|
| `OPENAI_BASE_URL` | Gateway URL |
| `OPENAI_API_KEY` | Token |
| `ANTHROPIC_API_KEY` | Alt provider |
| `OPENCODE_DISABLE_TELEMETRY` | `1` |
| `DO_NOT_TRACK` | Honored by opencode |

Plus the `~/.config/opencode/opencode.json` directives.

---

## Continue.dev

No native env vars — all config in `~/.continue/config.yaml`. The launcher writes a project-scoped `config.yaml` and sets `CONTINUE_GLOBAL_DIR` if a parallel install must exist alongside a personal one.
