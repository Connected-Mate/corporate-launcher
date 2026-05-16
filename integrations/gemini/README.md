# Gemini CLI integration

## What

[Gemini CLI](https://github.com/google-gemini/gemini-cli) is Google's terminal coding agent. It supports **extensions** (declared via `gemini-extension.json`), project-level `GEMINI.md` context, and **slash commands** (markdown files under `commands/`).

This integration ships the corporate-launcher skill as a Gemini **extension** with a `GEMINI.md` pointer and a `/corporate-launcher` slash command.

## Install the skill into Gemini

One-liner — clone the repo and copy the Gemini integration files into your project root:

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git
cp corporate-launcher/integrations/gemini/gemini-extension.json /path/to/your-project/
cp corporate-launcher/integrations/gemini/GEMINI.md /path/to/your-project/
cp -R corporate-launcher/integrations/gemini/commands /path/to/your-project/
cp -R corporate-launcher/integrations/gemini/skills /path/to/your-project/
```

Replace `/path/to/your-project/` with the folder you open with `gemini`.

If you already have a `GEMINI.md`, append the corporate-launcher section to it instead of overwriting.

## What gets installed

| File | Role |
| --- | --- |
| `gemini-extension.json` | Extension manifest Gemini loads on startup. |
| `GEMINI.md` | Project context file — describes the corporate-launcher workflow. |
| `commands/corporate-launcher.md` | The slash command — invokable via `/corporate-launcher`. |
| `skills/` | Bundled skill assets the extension exposes. |

## Invoke

From inside your project:

```bash
gemini
```

Then in the Gemini prompt, type:

```
/corporate-launcher
```

Or ask in natural language — the extension's description triggers on phrases like *"wrap gemini for my company"* or *"build me an internal Gemini launcher"*.

## Verify

```bash
ls -la /path/to/your-project/gemini-extension.json
ls -la /path/to/your-project/commands/corporate-launcher.md
```

Both should exist. If the slash command doesn't appear, restart the Gemini session so the extension manifest reloads.

## Uninstall

```bash
rm -f gemini-extension.json GEMINI.md commands/corporate-launcher.md
rm -rf skills/corporate-launcher
```

## Known gotchas

- **Extension manifest is project-local.** `gemini-extension.json` must sit at the project root Gemini was launched from. Install per-project unless you symlink it in.
- **Slash commands need exact filenames.** Gemini exposes `/<name>` only when `commands/<name>.md` exists — don't rename the file.
- **Backend routing.** Gemini CLI talks to `generativelanguage.googleapis.com` by default. To route through Vertex AI or a corporate gateway, set `GOOGLE_GENAI_USE_VERTEXAI=true` plus the relevant project/location env vars (handled automatically by the launcher's `install.sh`).
- **Auth.** Gemini supports OAuth, API key, or Vertex AI service account auth. The launcher picks the right path based on the backend you selected in the interview.
