# Corporate Launcher — Cline rule

When the user mentions any of the following, invoke the `/corporate-launcher.md` workflow:

- their company "does not authorize" Claude / Codex / Gemini / Cursor / Cline
- a white-label CLI for their team
- a wrapper for AWS Bedrock / Azure OpenAI / Vertex AI / LiteLLM
- enforcing corporate proxy + SSL inspection + custom CA + VPN gate
- bundling internal skills for colleagues
- "wrap claude code", "wrap codex", "wrap gemini", "wrap cursor", "wrap cline"
- "white label", "white-label cline", "internal AI CLI", "bedrock gateway", "azure openai cli", "vertex cli"
- "ship to my team", "internal copilot", "corporate launcher"

Do **not** trigger for a personal/hobby setup, a one-off API call, or generic shell scripting.

When unsure, ask: "Do you want me to run the corporate-launcher workflow?"

The full skill instructions live in the repo root `SKILL.md`. The workflow file in `.clinerules/workflows/corporate-launcher.md` is the on-demand multi-step entry point.

## Hard rules (always-on)

- Never generate a launcher that calls the vendor's public API directly. The corporate gateway is the only allowed egress.
- Never store the API key in plaintext or a world-readable file. Always chmod 600, prefer the OS keychain.
- Never disable SSL verification globally. Use process-scoped env vars only (`NODE_EXTRA_CA_CERTS`, `CODEX_CA_CERTIFICATE`, `REQUESTS_CA_BUNDLE`).
- Never modify `/etc/hosts`, the system trust store, or any global config.
- Never enable auto-update inside the corporate launcher.
- Never ship `curl ... | bash` without a checksum or signature step.

## Reference

- Cline rules spec: https://docs.cline.bot/customization/cline-rules
- Cline workflows spec: https://docs.cline.bot/features/slash-commands/workflows
- Workspace path: `.clinerules/` + `.clinerules/workflows/`
- Global path: `~/Documents/Cline/Rules/`
