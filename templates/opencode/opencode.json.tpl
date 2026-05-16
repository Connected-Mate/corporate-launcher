{
  "$schema": "https://opencode.ai/config.json",
  "_comment": "Managed by ${CORP_NAME} — do not edit. Powered by ${CORP_POWERED_BY}.",
  "provider": {
    "${LLM_PROVIDER_ID}": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "${CORP_NAME}",
      "options": {
        "baseURL": "${LLM_OPENAI_BASE_URL}",
        "apiKey": "{env:CORP_API_KEY}"
      },
      "models": {
        "${LLM_PRIMARY_MODEL}": {
          "name": "${LLM_PRIMARY_MODEL}"
        }
      }
    }
  },
  "model": "${LLM_PROVIDER_ID}/${LLM_PRIMARY_MODEL}",
  "share": "disabled",
  "autoupdate": false,
  "disabled_providers": [
    "anthropic",
    "openai",
    "google",
    "github-copilot"
  ]
}
