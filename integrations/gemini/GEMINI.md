# Corporate Launcher — Gemini CLI extension

This extension exposes the **corporate-launcher** skill inside Gemini CLI. Use it when the user asks for any of:

- a wrapper that hides Claude / Codex / Gemini / Cursor / Cline and re-brands it as `acmecorp-ai`, `bnp-copilot`, etc.
- their CLI routed only through their corporate gateway (LiteLLM, Azure OpenAI, Vertex, Bedrock)
- corporate proxy + SSL inspection + custom CA + VPN gate
- telemetry off, only first-party models from the chosen provider
- a turnkey install for their team (one script, one config, one launcher)
- a curated set of skills (design pack, internal review skill, MCP servers) shipped inside the launcher

Trigger phrases: `corporate launcher`, `wrap claude code`, `wrap codex`, `wrap gemini`, `wrap cursor`, `wrap cline`, `white label`, `internal AI CLI`, `bedrock gateway`, `azure openai cli`, `vertex cli`, `ship to my team`, `internal copilot`.

## How to invoke

Either:
- type `/corporate-launcher` (custom command registered by this extension)
- or describe the task in natural language — the description above triggers Gemini's planner.

## Workflow

Follow the canonical workflow defined at the repo root (`SKILL.md`):

1. **Phase 0** — confirm intent (which CLI + which backend)
2. **Phase 1** — run the config interview (`references/interview-flow.md`)
3. **Phase 2** — validate, recap, confirm
4. **Phase 3** — render templates (`scripts/render.py`)
5. **Phase 4** — generate the distribution kit
6. **Phase 5** — post-install summary

Read the full instructions, anti-patterns, and quality bar from the repo root `SKILL.md`.

## Reference

- Gemini extensions spec: https://geminicli.com/docs/extensions/references/
- Loader path: `~/.gemini/extensions/<name>/`
- Manifest: `gemini-extension.json`
- Repo: https://github.com/Connected-Mate/corporate-launcher
