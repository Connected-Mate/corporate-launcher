# Example — ACME Corp / Codex CLI on Azure OpenAI

A fictional second example to show the Codex CLI branch and the Azure OpenAI backend.

## Config answers

```json
{
  "CORP_NAME": "ACME Copilot",
  "CORP_SLUG": "acme-copilot",
  "CORP_POWERED_BY": "ACME AI Lab",
  "CORP_ORGANIZATION": "ACME Corp",
  "CORP_TAGLINE": "Internal AI coding assistant",
  "CORP_LICENSE_NOTE": "Internal use only — ACME confidential",

  "WRAPPED_CLIS": ["codex-cli"],

  "CX_BACKEND": "Azure OpenAI",
  "CX_PRIMARY_URL": "https://acme-prod.openai.azure.com/openai/v1",
  "CX_PRIMARY_MODEL": "gpt-5-codex",
  "CX_AUTH_ENV_KEY": "AZURE_OPENAI_API_KEY",
  "CX_WIRE_API": "responses",
  "CX_REQUIRE_LOCKDOWN": "yes",

  "VPN_REQUIRED": "yes",
  "VPN_PROBE_URL": "https://intranet.acme.local/health",
  "PROXY_HOST": "proxy.acme.local",
  "PROXY_PORT": "3128",
  "NO_PROXY_LIST": "127.0.0.1,localhost,.acme.local,.azure.com",
  "CA_BUNDLE_PATH": "/etc/ssl/acme-corp-ca.pem",
  "CA_DETECT_AUTO": "yes",
  "ACCEPT_TLS_INSPECTION": "no",

  "CYBER_AUTHORITY": "ACME Group CISO",
  "BLOCK_TELEMETRY": "yes",
  "BLOCK_AUTO_UPDATE": "yes",
  "BLOCK_FEEDBACK_CMDS": "yes",
  "COST_TRACKING_ENABLED": "yes",
  "COST_CURRENCY": "USD",
  "PROMPT_FILTER_ENABLED": "yes",

  "BANNER_COLOR_PRIMARY": "33",
  "TERMINAL_TITLE": "ACME Copilot — Internal",
  "LANGUAGE": "en",
  "FORBIDDEN_TERMS": "Codex,OpenAI,ChatGPT,GPT-5",

  "INSTALL_DIR": "~/.local/share/acme-copilot",
  "LICENSE_TYPE": "Proprietary",
  "INCLUDE_UNINSTALL": "yes"
}
```

## Why those answers

- **Azure base URL ends in `/openai/v1`** — the new responses API path (April 2026+). No `api-version` query parameter required at this path.
- **`CX_WIRE_API=responses`** — Azure Foundry/OpenAI dropped chat-completions for the new responses API. Codex CLI defaults to it.
- **`CX_REQUIRE_LOCKDOWN=yes`** — generates `/etc/codex/requirements.toml` that pins the provider, blocks `bypassPermissions`, locks the MCP allowlist, and disables ChatGPT account login. Without this, a savvy user could swap `model_provider` back to direct OpenAI.
- **`CA_BUNDLE_PATH=/etc/ssl/acme-corp-ca.pem`** — Codex CLI is Rust, so it reads `CODEX_CA_CERTIFICATE` (set automatically from `CA_BUNDLE_PATH` by the shared proxy-detect module).
- **`ACCEPT_TLS_INSPECTION=no`** — ACME provisions the CA bundle on every machine via MDM, so we never need to bypass TLS verification.
- **`PROXY_HOST=proxy.acme.local`** — note the proxy port `3128` (Squid default) rather than `8080`.

## Known limitations (April 2026)

- Codex CLI HTTPS_PROXY support is partial (issue #4242). On networks where the proxy must be honored at all costs, run the launcher inside a container with a transparent proxy at the network layer.
- ChatGPT account login is disabled via `forced_login_method = "api"` in `requirements.toml`.
- Entra ID auth is not natively supported by Codex CLI; the launcher stores a static `AZURE_OPENAI_API_KEY` minted from the Azure portal.
