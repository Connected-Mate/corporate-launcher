# Example — Globex / Gemini CLI on Vertex AI Enterprise

A fictional third example to show the Gemini CLI branch and the Vertex AI Enterprise backend with EU data residency.

## DOG answers

```json
{
  "CORP_NAME": "Globex Helper",
  "CORP_SLUG": "globex-helper",
  "CORP_POWERED_BY": "Globex Data Group",
  "CORP_ORGANIZATION": "Globex Industries",
  "CORP_TAGLINE": "European-residency AI for Globex engineers",
  "CORP_LICENSE_NOTE": "Internal use only — Globex confidential",

  "WRAPPED_CLIS": ["gemini-cli"],

  "GM_BACKEND": "Vertex AI",
  "GM_PRIMARY_MODEL": "gemini-2.5-pro",
  "GM_VERTEX_PROJECT": "globex-ai-prod",
  "GM_VERTEX_LOCATION": "europe-west4",
  "GM_AUTH_MODE": "ADC",
  "GM_FORCE_VERTEX": "yes",

  "VPN_REQUIRED": "no",
  "VPN_PROBE_URL": "",
  "PROXY_HOST": "",
  "PROXY_PORT": "",
  "NO_PROXY_LIST": "127.0.0.1,localhost,.googleapis.com",
  "CA_BUNDLE_PATH": "",
  "CA_DETECT_AUTO": "yes",
  "ACCEPT_TLS_INSPECTION": "no",

  "CYBER_AUTHORITY": "Globex DPO Office",
  "BLOCK_TELEMETRY": "yes",
  "BLOCK_AUTO_UPDATE": "yes",
  "BLOCK_FEEDBACK_CMDS": "yes",
  "COST_TRACKING_ENABLED": "yes",
  "COST_CURRENCY": "EUR",
  "PROMPT_FILTER_ENABLED": "yes",

  "BANNER_COLOR_PRIMARY": "39",
  "TERMINAL_TITLE": "Globex Helper",
  "LANGUAGE": "en",
  "FORBIDDEN_TERMS": "Gemini,Google,Bard,gemini.google.com,Vertex,GCP",

  "INSTALL_DIR": "~/.local/share/globex-helper",
  "LICENSE_TYPE": "Proprietary",
  "INCLUDE_UNINSTALL": "yes"
}
```

## Why those answers

- **`GM_BACKEND=Vertex AI`** + **`GM_VERTEX_LOCATION=europe-west4`** — data residency in Netherlands; no prompts/responses leave the EU. Vertex AI Enterprise contract guarantees no training on customer data.
- **`GM_AUTH_MODE=ADC`** — keyless auth via `gcloud auth application-default login`. No service account key on disk. Compatible with org policy `iam.disableServiceAccountKeyCreation`.
- **`GM_PRIMARY_MODEL=gemini-2.5-pro`** — the latest model that's available on `europe-west4`. Gemini 3.x is global-only as of May 2026 — would break data residency.
- **`VPN_REQUIRED=no`** — Globex routes Vertex traffic over the public internet (TLS protects it). No internal-only domain required for the probe.
- **`PROXY_HOST=""`** — Globex doesn't run a corporate proxy on engineering workstations.
- **`FORBIDDEN_TERMS`** includes Vertex/GCP — when the assistant explains "where it runs", it should say "Globex Data Group infrastructure", not "Vertex AI on GCP".

## What the launcher does at startup

```bash
# 1. unset any consumer-mode API keys (anti-pattern: mixing AI Studio + Vertex)
unset GEMINI_API_KEY GOOGLE_API_KEY

# 2. force Vertex mode
export GOOGLE_GENAI_USE_VERTEXAI=true
export GOOGLE_CLOUD_PROJECT=globex-ai-prod
export GOOGLE_CLOUD_LOCATION=europe-west4

# 3. confirm ADC is fresh
gcloud auth application-default print-access-token >/dev/null || \
    gcloud auth application-default login

# 4. telemetry off
export GEMINI_TELEMETRY_ENABLED=false

# 5. exec gemini with the BRANDING + cyber-rules appended
exec gemini "$@"
```

## Why no strip-proxy

Gemini CLI talks Vertex's native protocol directly. No SSE-artefact rewrite needed. The strip-proxy is Claude-Code-on-Bedrock-or-LiteLLM specific.
