# Integrations

Host-specific manifests that point every supported AI coding CLI at the **canonical** `SKILL.md` living at the repo root.

## Purpose

Different AI coding hosts load skills, extensions, and rules in incompatible ways:

- Claude Code expects `~/.claude/skills/<name>/SKILL.md`.
- Codex CLI auto-discovers `~/.agents/skills/<name>/SKILL.md` and optionally reads a project-level `AGENTS.md`.
- Gemini CLI installs **extensions** with a `gemini-extension.json` manifest and TOML slash-commands.
- Cline reads `.clinerules/` markdown files (project) or `~/Documents/Cline/Rules/` (global).
- Cursor reads `.cursor/rules/*.mdc` (agent context) and `.cursor/commands/*.md` (slash commands).

Rather than fork the skill into five copies, the repo keeps **one** authoritative `SKILL.md`, `templates/`, `references/`, and `scripts/` at the root, and each `integrations/<host>/` subdirectory contains only the thin manifest or shim that the host's loader expects. The shim points back at the canonical files so a fix to the interview flow or a new template ships everywhere at once.

## Layout

| Host        | Subdir          | Manifest format                                        | Loader docs                                          |
| ----------- | --------------- | ------------------------------------------------------ | ---------------------------------------------------- |
| Claude Code | `claude-code/`  | symlink/copy of root `SKILL.md`                        | https://docs.claude.com/en/docs/build-with-claude/skills |
| Codex CLI   | `codex/`        | `AGENTS.md` + `~/.agents/skills/` auto-discovery        | https://developers.openai.com/codex/skills          |
| Gemini CLI  | `gemini/`       | `gemini-extension.json` + `commands/*.toml` + `GEMINI.md` | https://geminicli.com/docs/extensions/references/   |
| Cline       | `cline/`        | `.clinerules/` + `workflows/`                          | https://docs.cline.bot/customization/cline-rules     |
| Cursor      | `cursor/`       | `.cursor/rules/*.mdc` + `.cursor/commands/*.md`        | https://cursor.com/docs/rules                        |

Each subdir is self-contained: copy its contents to the loader path the host expects and the skill is live. The `INSTALL.md` at the repo root has the exact `cp` / `ln -s` / `gemini extensions install` invocations.

## Universal install (recommended)

The easy path is the universal deploy script — it clones the repo once into `~/.corporate-launcher`, then symlinks each integration into the right loader path for every host installed on the machine:

```bash
./scripts/host-deploy.sh         # auto-detects which hosts are present
./scripts/host-deploy.sh --host gemini --host cursor    # explicit subset
```

The script is idempotent and uses symlinks, so a `git pull` in `~/.corporate-launcher` updates every host simultaneously.

## Per-host install

See [`../INSTALL.md`](../INSTALL.md) for the explicit per-host commands (clone path, `cp -R` targets, verification one-liners). Each host section is self-contained — pick yours and ignore the rest.

## Adding support for a new host

The reference walkthrough is [`../references/add-a-new-cli.md`](../references/add-a-new-cli.md) — it covers researching the CLI's auth model, classifying it on the provider tier matrix, and wiring it into the interview flow. A sister doc `../references/add-a-new-host.md` is reserved for the **host integration layer** (vs. the **provider/CLI templating** layer) and will land when the second class of contribution comes up; until then, follow `add-a-new-cli.md` and adapt the "Step 5 — Manifest" section to your host's loader format.

The minimum viable contribution is:

1. A new `integrations/<host>/` subdir with the host's native manifest.
2. A new row in the **Layout** table above.
3. A new section in `../INSTALL.md`.
4. A new row in the **Compatibility matrix** below.
5. An update to `scripts/host-deploy.sh` so the universal installer detects the host.

## Compatibility matrix

Not every skill primitive maps cleanly across hosts. The launcher generator degrades gracefully — features absent on a host fall back to plain `input()` prompts, hard-coded defaults, or a no-op.

| Feature                          | Claude Code | Codex CLI | Gemini CLI | Cline | Cursor |
| -------------------------------- | :---------: | :-------: | :--------: | :---: | :----: |
| `AskUserQuestion` (rich prompts) | yes         | fallback  | fallback   | fallback | fallback |
| Slash command (`/corporate-launcher`) | yes    | yes       | yes        | yes (`/corporate-launcher.md`) | yes |
| Progressive disclosure (description-triggered) | yes | yes  | yes        | partial | partial |
| Project-scoped install           | yes (`.claude/skills/`) | yes (`AGENTS.md`) | partial | yes (`.clinerules/`) | yes (`.cursor/`) |
| Global install                   | yes         | yes       | yes        | yes   | yes    |
| MCP server injection             | yes (`mcp-injector-claude.py`) | yes (`mcp-injector-codex.py`) | yes (`mcp-injector-gemini.py`) | no | no |
| Multi-step workflows             | yes         | yes       | yes        | yes (workflows) | yes (commands) |
| File-system tool gating          | yes (`allowed-tools`) | yes | partial    | no    | no     |

**Fallback semantics.** When `AskUserQuestion` is unavailable, the generated interview script falls back to plain `input()` prompts with the same question text and validation. When MCP injection is unavailable, the launcher emits a printed checklist of the MCP servers the user must add manually. Refer to `../references/provider-matrix.md` for the equivalent tier breakdown on the **provider** axis (Bedrock / Azure / Vertex / OpenAI-compatible).
