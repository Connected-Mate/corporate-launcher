# Corporate Launcher — Codex CLI integration

This file is the Codex CLI hook for the **corporate-launcher** skill. Codex auto-loads `AGENTS.md` at three levels (`~/.codex/AGENTS.md`, repo root, subdirectories). The skill itself lives under `.agents/skills/corporate-launcher/SKILL.md`.

## Available skill

**corporate-launcher** — Generates a secure, branded, organization-specific launcher that wraps Claude Code, Codex CLI, Gemini CLI, or Cursor/Cline onto a corporate AI gateway, then helps the user distribute it to their team.

Trigger this skill when the user mentions any of:
- their company "does not authorize" Claude / Codex / Gemini / Cursor
- a white-label CLI for their team
- a wrapper for AWS Bedrock / Azure OpenAI / Vertex AI / LiteLLM
- enforcing corporate proxy + SSL inspection + custom CA
- bundling internal skills for colleagues

Trigger phrases: `corporate launcher`, `wrap claude code`, `wrap codex`, `wrap gemini`, `wrap cursor`, `wrap cline`, `white label`, `white-label cline`, `internal AI CLI`, `bedrock gateway`, `azure openai cli`, `vertex cli`, `ship to my team`, `internal copilot`.

The full skill instructions live in `.agents/skills/corporate-launcher/SKILL.md`. Codex loads them automatically when the task matches.

## Reference

- Codex Skills spec: https://developers.openai.com/codex/skills
- Codex AGENTS.md spec: https://developers.openai.com/codex/guides/agents-md
- Skill resolution order: `$CWD/.agents/skills` → `$REPO_ROOT/.agents/skills` → `$HOME/.agents/skills` → `/etc/codex/skills`
