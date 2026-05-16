# Install — Corporate Launcher

The same skill works from **4 AI coding hosts**. Pick yours, run one command, then invoke `/corporate-launcher` (or just describe the task — the trigger phrases match).

> The canonical skill (`SKILL.md`, `templates/`, `reference/`, `scripts/`) lives at the repo root. Each host has its own manifest under `integrations/<host>/` that points at the canonical files.

---

## Claude Code

Loader: `~/.claude/skills/<name>/SKILL.md`

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git \
    ~/.claude/skills/corporate-launcher
```

Invoke:

```
> /corporate-launcher
```

Docs: https://docs.claude.com/en/docs/build-with-claude/skills

---

## Codex CLI

Loader: `~/.agents/skills/<name>/SKILL.md` (auto-discovered; progressive disclosure via the `description` field).

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git \
    ~/.agents/skills/corporate-launcher
```

Codex picks the skill up automatically when a task matches the description. You can also force it with `/skills corporate-launcher`.

Optional — wire the project-level entry point in any repo where you want stricter triggering:

```bash
cp integrations/codex/AGENTS.md ./AGENTS.md
```

Docs:
- Skills: https://developers.openai.com/codex/skills
- AGENTS.md: https://developers.openai.com/codex/guides/agents-md

---

## Gemini CLI

Loader: `~/.gemini/extensions/<name>/gemini-extension.json` + optional `commands/*.toml`.

```bash
gemini extensions install https://github.com/Connected-Mate/corporate-launcher \
    --path integrations/gemini
```

Or manual install:

```bash
mkdir -p ~/.gemini/extensions/corporate-launcher
cp -R integrations/gemini/* ~/.gemini/extensions/corporate-launcher/
```

Restart Gemini CLI, then invoke `/corporate-launcher` or describe the task in natural language.

Docs: https://geminicli.com/docs/extensions/reference/

---

## Cursor (+ Cline VS Code extension)

Cursor and Cline read **different** files. Install both so the skill triggers regardless of which extension the user has loaded.

### Cursor (project-scoped rules + commands)

```bash
# from your repo root
cp -R integrations/cursor/.cursor ./
```

This drops:
- `.cursor/rules/corporate-launcher.mdc` — Cursor's agent picks this up when the description matches.
- `.cursor/commands/corporate-launcher.md` — adds `/corporate-launcher` slash command.

Global install (works across all projects):

```bash
mkdir -p ~/.cursor/rules ~/.cursor/commands
cp integrations/cursor/.cursor/rules/corporate-launcher.mdc ~/.cursor/rules/
cp integrations/cursor/.cursor/commands/corporate-launcher.md ~/.cursor/commands/
```

Docs:
- Rules: https://cursor.com/docs/rules
- Commands: https://cursor.com/docs/context/commands

### Cline (VS Code extension)

```bash
# project-scoped (recommended — version-controlled with the repo)
cp -R integrations/cline/.clinerules ./
```

Or globally:

```bash
mkdir -p ~/Documents/Cline/Rules ~/Documents/Cline/Rules/workflows
cp integrations/cline/.clinerules/01-corporate-launcher.md ~/Documents/Cline/Rules/
cp integrations/cline/.clinerules/workflows/corporate-launcher.md ~/Documents/Cline/Rules/workflows/
```

Invoke: `/corporate-launcher.md` in the Cline chat input.

Docs:
- Rules: https://docs.cline.bot/customization/cline-rules
- Workflows: https://docs.cline.bot/features/slash-commands/workflows

---

## Universal one-liner (any host)

Clone the repo once, then symlink the integration of your choice. The canonical templates and reference files stay in one place.

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git ~/.corporate-launcher

# pick your host:
ln -s ~/.corporate-launcher                              ~/.claude/skills/corporate-launcher
ln -s ~/.corporate-launcher                              ~/.agents/skills/corporate-launcher
ln -s ~/.corporate-launcher/integrations/gemini          ~/.gemini/extensions/corporate-launcher
ln -s ~/.corporate-launcher/integrations/cursor/.cursor/rules/corporate-launcher.mdc      ~/.cursor/rules/corporate-launcher.mdc
ln -s ~/.corporate-launcher/integrations/cursor/.cursor/commands/corporate-launcher.md    ~/.cursor/commands/corporate-launcher.md
ln -s ~/.corporate-launcher/integrations/cline/.clinerules                                ~/Documents/Cline/Rules
```

---

## After install — triggering the skill

In every host, both methods work:

1. **Slash command** — `/corporate-launcher`
2. **Natural language** — phrases like *"wrap claude for my company"*, *"white-label cursor for my team"*, *"my employer doesn't allow Codex"*, *"build me an internal CLI on Azure OpenAI"*

The skill description includes the trigger phrases for all 4 hosts, so the same prompt fires the skill regardless of which one you use.

---

## Verifying the install

| Host | Verify command |
|---|---|
| Claude Code | `ls ~/.claude/skills/corporate-launcher/SKILL.md` |
| Codex CLI | `ls ~/.agents/skills/corporate-launcher/SKILL.md` |
| Gemini CLI | `gemini extensions list \| grep corporate-launcher` |
| Cursor | `ls .cursor/rules/corporate-launcher.mdc` |
| Cline | `ls .clinerules/workflows/corporate-launcher.md` |

If the file is there but the skill doesn't trigger, restart the host session — most loaders cache the skill index at startup.
