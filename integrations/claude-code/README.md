# Claude Code integration

Claude Code loads skills from `~/.claude/skills/<name>/SKILL.md`. The canonical `SKILL.md` for this skill lives at the **repo root**, not under `integrations/`.

## Install

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git \
    ~/.claude/skills/corporate-launcher
```

Then in any Claude Code session:

```
> /corporate-launcher
```

Or trigger it in natural language — phrases like *"wrap claude for my company"*, *"white-label cursor"*, *"my employer doesn't allow Codex"* match the skill description.

## Why this file exists

To keep `integrations/<host>/` symmetric across the 4 supported hosts. The `SKILL.md` itself stays at the repo root because Claude Code's loader expects a single file per skill directory and re-locating it would break every other host that follows the Claude convention.

## Reference

- Anthropic Skills spec: https://docs.claude.com/en/docs/build-with-claude/skills
- Loader path: `~/.claude/skills/<name>/SKILL.md`
- Frontmatter: `name`, `description`, `allowed-tools`
