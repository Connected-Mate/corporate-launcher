# Codex CLI integration

## What

[Codex CLI](https://github.com/openai/codex) is OpenAI's terminal coding agent. It reads project context from `AGENTS.md` and supports custom agents under `.agents/`.

This integration ships the corporate-launcher skill as a Codex **agent** plus a top-level `AGENTS.md` pointer, so you can invoke it from a Codex session by referencing the agent.

## Install the skill into Codex

One-liner — clone the repo and copy the Codex integration files into your project root:

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git
cp corporate-launcher/integrations/codex/AGENTS.md /path/to/your-project/AGENTS.md
cp -R corporate-launcher/integrations/codex/.agents /path/to/your-project/
```

Replace `/path/to/your-project/` with the folder you open with `codex`.

If you already have an `AGENTS.md`, append the corporate-launcher section to it instead of overwriting.

## What gets installed

| File | Role |
| --- | --- |
| `AGENTS.md` | Top-level project file Codex reads on startup — describes the corporate-launcher workflow. |
| `.agents/corporate-launcher.md` | The agent definition Codex loads when you reference it. |

## Invoke

From inside your project:

```bash
codex
```

Then in the Codex chat, ask in natural language (`"wrap claude for my company"`, `"build a white-label launcher"`) — Codex picks up the agent via `AGENTS.md`.

## Verify

```bash
ls -la /path/to/your-project/AGENTS.md
ls -la /path/to/your-project/.agents/corporate-launcher.md
```

Both should exist and be readable. If Codex doesn't surface the agent, restart the Codex session.

## Uninstall

```bash
rm -f AGENTS.md .agents/corporate-launcher.md
```

Leave `.agents/` in place if you have other Codex agents; otherwise remove the whole folder.

## Known gotchas

- **`AGENTS.md` is project-scoped.** Codex reads it from the current working directory. Install per-project unless you symlink a shared file in from `~/`.
- **No slash-command syntax.** Unlike Claude Code, Codex doesn't expose `/corporate-launcher`. Trigger the agent via natural language or by mentioning `corporate-launcher` in the prompt.
- **Backend routing.** Codex routes to the OpenAI API by default — point it at your corporate gateway via `OPENAI_BASE_URL` (set in the launcher's `install.sh`, or export it before `codex` runs).
