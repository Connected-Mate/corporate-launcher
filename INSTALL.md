# Install — Corporate Launcher

The same skill ships to **5 AI coding hosts**: Claude Code, Codex CLI, Gemini CLI, Cursor, and Cline. Pick yours below, run one command, then invoke `/corporate-launcher` (or just describe the task — the trigger phrases match).

> The canonical skill (`SKILL.md`, `templates/`, `references/`, `scripts/`) lives at the repo root. Each host has its own manifest under `integrations/<host>/` that points at the canonical files.

---

## Easiest path: `bash scripts/host-deploy.sh`

If you want everything wired up without thinking about paths, the auto-installer detects which hosts are present on your machine and installs the skill to each one:

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git
cd corporate-launcher
bash scripts/host-deploy.sh            # interactive — installs to every detected host
bash scripts/host-deploy.sh --host claude-code,codex   # non-interactive subset
bash scripts/host-deploy.sh --uninstall                # remove from every host
```

The script is idempotent (re-running is safe), uses symlinks where possible so `git pull` updates every host at once, and prints a verify-line per host at the end. If you'd rather do it by hand, the per-host recipes below cover all 5 hosts.

---

## Summary

| Host         | Install one-liner                                                                                            | Invoke              |
|--------------|--------------------------------------------------------------------------------------------------------------|---------------------|
| Claude Code  | `git clone https://github.com/Connected-Mate/corporate-launcher.git ~/.claude/skills/corporate-launcher`     | `> /corporate-launcher` |
| Codex CLI    | `git clone https://github.com/Connected-Mate/corporate-launcher.git ~/.agents/skills/corporate-launcher`     | `/skills corporate-launcher` |
| Gemini CLI   | `gemini extensions install https://github.com/Connected-Mate/corporate-launcher --path integrations/gemini`  | `/corporate-launcher` |
| Cursor       | `cp -R integrations/cursor/.cursor ./` (from a clone of the repo)                                            | `/corporate-launcher` |
| Cline        | `cp -R integrations/cline/.clinerules ./` (from a clone of the repo)                                         | `/corporate-launcher.md` |

---

## Install in Claude Code

Loader path: `~/.claude/skills/<name>/SKILL.md` (Anthropic's progressive-disclosure skill spec).

**Install one-liner:**

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git \
    ~/.claude/skills/corporate-launcher
```

**Verify:**

```bash
ls -la ~/.claude/skills/corporate-launcher/SKILL.md
```

**Invoke** (inside a Claude Code session):

```
> /corporate-launcher
```

Natural-language triggers also work — phrases like *"wrap claude for my company"* or *"white-label cursor for my team"* match the skill description.

**Uninstall:**

```bash
rm -rf ~/.claude/skills/corporate-launcher
```

**Known gotchas:**
- Restart the Claude Code session after install — the skill index is cached at startup.
- The skill must live at `~/.claude/skills/<name>/SKILL.md` (not nested under `integrations/`); cloning the repo root directly into that path satisfies this.

Docs: https://docs.claude.com/en/docs/build-with-claude/skills

---

## Install in Codex CLI

Loader path: `~/.agents/skills/<name>/SKILL.md` (auto-discovered via the `description` field on every Codex turn).

**Install one-liner:**

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git \
    ~/.agents/skills/corporate-launcher
```

**Verify:**

```bash
ls -la ~/.agents/skills/corporate-launcher/SKILL.md
```

**Invoke** (inside Codex CLI):

```
/skills corporate-launcher
```

Codex also picks the skill up automatically when a task matches the description. Optionally, drop `integrations/codex/AGENTS.md` into the repo root of any project where you want stricter project-level triggering:

```bash
cp integrations/codex/AGENTS.md ./AGENTS.md
```

**Uninstall:**

```bash
rm -rf ~/.agents/skills/corporate-launcher
rm -f ./AGENTS.md   # only if you copied it
```

**Known gotchas:**
- The `~/.agents/` directory (not `~/.codex/`) is the Codex skills root.
- `AGENTS.md` is per-project and version-controlled with the repo; don't drop it in `$HOME`.

Docs:
- Skills: https://developers.openai.com/codex/skills
- AGENTS.md: https://developers.openai.com/codex/guides/agents-md

---

## Install in Gemini CLI

Loader path: `~/.gemini/extensions/<name>/gemini-extension.json` plus optional `commands/*.toml` slash-commands.

**Install one-liner** (preferred — uses Gemini's native extension installer):

```bash
gemini extensions install https://github.com/Connected-Mate/corporate-launcher \
    --path integrations/gemini
```

Manual fallback if `gemini extensions install` is unavailable:

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git /tmp/corporate-launcher && \
  mkdir -p ~/.gemini/extensions/corporate-launcher && \
  cp -R /tmp/corporate-launcher/integrations/gemini/* ~/.gemini/extensions/corporate-launcher/
```

**Verify:**

```bash
gemini extensions list | grep corporate-launcher
# or:
ls -la ~/.gemini/extensions/corporate-launcher/gemini-extension.json
```

**Invoke** (inside Gemini CLI, after restart):

```
/corporate-launcher
```

**Uninstall:**

```bash
gemini extensions uninstall corporate-launcher
# or manual:
rm -rf ~/.gemini/extensions/corporate-launcher
```

**Known gotchas:**
- Restart Gemini CLI after install — extensions are loaded once on startup.
- The extension is shipped from the `integrations/gemini/` subdirectory, not the repo root. Use the `--path` flag or copy that subdirectory specifically.

Docs: https://geminicli.com/docs/extensions/references/

---

## Install in Cursor

Cursor reads `.cursor/rules/*.mdc` (agent rules) and `.cursor/commands/*.md` (slash commands) — by default **workspace-scoped**, i.e. read from the open repo, not from `$HOME`.

**Install one-liner** (project-scoped — recommended, version-controlled with the repo):

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git /tmp/corporate-launcher && \
  cp -R /tmp/corporate-launcher/integrations/cursor/.cursor ./
```

Run this from the root of the project where you want the skill available.

Global install (across all projects):

```bash
mkdir -p ~/.cursor/rules ~/.cursor/commands && \
  cp /tmp/corporate-launcher/integrations/cursor/.cursor/rules/corporate-launcher.mdc ~/.cursor/rules/ && \
  cp /tmp/corporate-launcher/integrations/cursor/.cursor/commands/corporate-launcher.md ~/.cursor/commands/
```

**Verify:**

```bash
ls -la .cursor/rules/corporate-launcher.mdc .cursor/commands/corporate-launcher.md
# or, for the global install:
ls -la ~/.cursor/rules/corporate-launcher.mdc ~/.cursor/commands/corporate-launcher.md
```

**Invoke** (inside Cursor's agent chat):

```
/corporate-launcher
```

The rule also fires automatically when the user describes a matching task (white-label CLI, internal copilot, etc.).

**Uninstall:**

```bash
rm -f .cursor/rules/corporate-launcher.mdc .cursor/commands/corporate-launcher.md
# global:
rm -f ~/.cursor/rules/corporate-launcher.mdc ~/.cursor/commands/corporate-launcher.md
```

**Known gotchas:**
- Cursor's primary scope is **the workspace-scoped `.cursor/` directory**, *not* `~/.cursor/`. The project-scoped install is the recommended one; the global install is a secondary convenience.
- The rule file must end in `.mdc` (not `.md`) — Cursor only reads `.mdc` files under `rules/`.

Docs:
- Rules: https://cursor.com/docs/rules
- Commands: https://cursor.com/docs/context/commands

---

## Install in Cline (VS Code extension)

Cline reads `.clinerules/*.md` (rules) and `.clinerules/workflows/*.md` (slash-command workflows).

**Install one-liner** (project-scoped — recommended):

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git /tmp/corporate-launcher && \
  cp -R /tmp/corporate-launcher/integrations/cline/.clinerules ./
```

Global install:

```bash
mkdir -p ~/Documents/Cline/Rules/workflows && \
  cp /tmp/corporate-launcher/integrations/cline/.clinerules/01-corporate-launcher.md ~/Documents/Cline/Rules/ && \
  cp /tmp/corporate-launcher/integrations/cline/.clinerules/workflows/corporate-launcher.md ~/Documents/Cline/Rules/workflows/
```

**Verify:**

```bash
ls -la .clinerules/01-corporate-launcher.md .clinerules/workflows/corporate-launcher.md
# or, global:
ls -la ~/Documents/Cline/Rules/01-corporate-launcher.md ~/Documents/Cline/Rules/workflows/corporate-launcher.md
```

**Invoke** (inside the Cline chat input):

```
/corporate-launcher.md
```

(Cline's slash-command convention keeps the `.md` suffix.)

**Uninstall:**

```bash
rm -rf .clinerules
# global:
rm -f ~/Documents/Cline/Rules/01-corporate-launcher.md \
      ~/Documents/Cline/Rules/workflows/corporate-launcher.md
```

**Known gotchas:**
- The slash-command syntax is `/corporate-launcher.md` (with extension), not `/corporate-launcher`.
- Global rules live under `~/Documents/Cline/Rules/` (a VS Code convention), not `~/.cline/` — surprising but correct.
- The numeric prefix on `01-corporate-launcher.md` controls rule ordering; keep it if you have other Cline rules.

Docs:
- Rules: https://docs.cline.bot/customization/cline-rules
- Workflows: https://docs.cline.bot/features/slash-commands/workflows

---

## Universal symlink install (any subset of hosts)

Clone the repo once, then symlink the integration of your choice. `git pull` then updates every host at once. (This is what `scripts/host-deploy.sh` does under the hood.)

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git ~/.corporate-launcher

# Claude Code
ln -s ~/.corporate-launcher                                                            ~/.claude/skills/corporate-launcher
# Codex CLI
ln -s ~/.corporate-launcher                                                            ~/.agents/skills/corporate-launcher
# Gemini CLI
ln -s ~/.corporate-launcher/integrations/gemini                                        ~/.gemini/extensions/corporate-launcher
# Cursor (global)
ln -s ~/.corporate-launcher/integrations/cursor/.cursor/rules/corporate-launcher.mdc   ~/.cursor/rules/corporate-launcher.mdc
ln -s ~/.corporate-launcher/integrations/cursor/.cursor/commands/corporate-launcher.md ~/.cursor/commands/corporate-launcher.md
# Cline (global)
ln -s ~/.corporate-launcher/integrations/cline/.clinerules/01-corporate-launcher.md          ~/Documents/Cline/Rules/01-corporate-launcher.md
ln -s ~/.corporate-launcher/integrations/cline/.clinerules/workflows/corporate-launcher.md   ~/Documents/Cline/Rules/workflows/corporate-launcher.md
```

---

## After install — triggering the skill

In every host, both methods work:

1. **Slash command** — `/corporate-launcher` (or `/corporate-launcher.md` in Cline).
2. **Natural language** — phrases like *"wrap claude for my company"*, *"white-label cursor for my team"*, *"my employer doesn't allow Codex"*, *"build me an internal CLI on Azure OpenAI"*.

The skill description includes the trigger phrases for all 5 hosts, so the same prompt fires the skill regardless of which one you're in.

If the file is in place but the skill doesn't trigger, **restart the host session** — every host caches its skill/rule index at startup.
