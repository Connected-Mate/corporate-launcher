# Provider matrix

Index of supported AI coding CLIs. Each CLI now has its own reference file with full env vars, config samples, and quirks — this page just helps the skill pick the right one.

## Decision tree

```
Q: Which AI vendor does the user contract with?
  ├─ Anthropic            → see cli-claude-code.md (preferred)
  ├─ OpenAI / Azure OpenAI → see cli-codex-cli.md
  ├─ Google (Vertex / AI Studio) → see cli-gemini-cli.md
  └─ Multi-vendor / LiteLLM gateway → cli-aider.md or cli-opencode.md

Q: Editor / IDE-based vs pure CLI?
  ├─ VS Code or JetBrains (extension-style) → cli-continue-dev.md
  ├─ VS Code or Cursor (agent-style)         → cli-cline.md
  └─ Pure terminal CLI                       → see vendor branch above

Q: Air-gapped / offline / minimal network surface?
  └─ cli-aider.md (Python, pipx, fewer runtime network calls, no Node toolchain)
```

## Tier matrix

Tiers describe how hard the CLI is to wrap onto a corporate gateway, not its quality.

- **Tier S** — wrap trivial, fully ENV-driven. A launcher just exports env vars and writes a small JSON/YAML/TOML file.
- **Tier A** — wrap moderate. CLI is GUI/IDE-driven; the launcher pre-deploys a settings file (extension config, lockdown TOML, etc.) instead of relying on env vars alone.
- **Tier B** — out of scope. Requires server-side infra (self-host, admin GUI, public HTTPS endpoint). Not addressable by a desktop launcher. See `out-of-scope.md` if it exists, otherwise skip.

| Tier | CLIs |
|---|---|
| S | Claude Code, Gemini CLI, Aider, opencode, Continue.dev |
| A | Cline, Codex CLI, Sourcegraph Cody |
| B | Cursor (native), Windsurf, Tabnine Enterprise |

## Pointer table

| CLI | Reference file | When to use |
|---|---|---|
| Claude Code | [cli-claude-code.md](cli-claude-code.md) | Most common; Anthropic direct, AWS Bedrock, GCP Vertex, or LiteLLM gateway. |
| Codex CLI | [cli-codex-cli.md](cli-codex-cli.md) | OpenAI or Azure OpenAI customers; admin lockdown via `requirements.toml`. |
| Gemini CLI | [cli-gemini-cli.md](cli-gemini-cli.md) | Google Cloud customers (Vertex AI or AI Studio). |
| Aider | [cli-aider.md](cli-aider.md) | Python shops, multi-vendor via LiteLLM, air-gapped scenarios. |
| opencode | [cli-opencode.md](cli-opencode.md) | TUI lovers, multi-vendor, `{env:VAR}` substitution in JSON config. |
| Continue.dev | [cli-continue-dev.md](cli-continue-dev.md) | VS Code or JetBrains IDE-based teams; YAML config with proxy/CA support. |
| Cline | [cli-cline.md](cli-cline.md) | Cursor users (and VS Code agent mode); marketplace id `saoudrizwan.claude-dev`. |

## Notes

- Env-var dumps, config-file templates, and known bugs now live in each per-CLI file. Do not duplicate them here.
- If the user is on Cursor and wants the corporate gateway, route to **Cline** inside Cursor — not Cursor's native chat (Tier B).
- For backends that emit SSE artefacts (Bedrock, some LiteLLM setups), see the strip-proxy note in `cli-claude-code.md`.
