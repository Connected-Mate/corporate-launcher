---
name: corporate-launcher
description: Generates a secure, branded, organization-specific launcher that wraps Claude Code, Codex CLI, Gemini CLI, Cursor, or Cline onto a corporate AI gateway, then helps the user distribute it to their team. Triggers when a user says their company "does not authorize" Claude / Codex / Gemini / Cursor, asks for a white-label CLI for their team, needs a wrapper for AWS Bedrock / Azure OpenAI / Vertex AI / LiteLLM, must enforce corporate proxy + SSL inspection + custom CA, or wants to bundle a set of internal skills for colleagues. Trigger phrases include "corporate launcher", "wrap claude code", "wrap codex", "wrap gemini", "wrap cursor", "wrap cline", "white label", "white-label cline", "internal AI CLI", "bedrock gateway", "azure openai cli", "vertex cli", "ship to my team", "internal copilot".
---

# Corporate Launcher

The canonical skill instructions, templates, and reference files live in the repo root:
- repo root: https://github.com/Connected-Mate/corporate-launcher
- canonical SKILL.md: `<repo-root>/SKILL.md`
- templates: `<repo-root>/templates/`
- reference: `<repo-root>/references/`

On Codex CLI this file acts as the **entry point**. When the skill is triggered, follow the workflow defined in the canonical `SKILL.md`:

1. **Phase 0** — confirm intent (which CLI + which backend)
2. **Phase 1** — run the config interview via `references/interview-flow.md`
3. **Phase 2** — validate, show recap, ask confirmation
4. **Phase 3** — render templates via `scripts/render.py`
5. **Phase 4** — generate the distribution kit
6. **Phase 5** — post-install summary

The full instructions, anti-patterns, and quality bar are in the canonical `SKILL.md`. Read it once when the skill is triggered, then proceed through the phases.

## Install

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git \
    ~/.agents/skills/corporate-launcher
```

After clone, Codex auto-detects the skill from `~/.agents/skills/corporate-launcher/SKILL.md` (this file).
