# Cline integration

## What

[Cline](https://cline.bot) is a VS Code agent extension (marketplace id `saoudrizwan.claude-dev`). It runs inside **VS Code**, **Cursor**, **VSCodium**, and **Code-Insiders** — any VS Code-compatible editor.

This integration ships the corporate-launcher skill as a Cline **rule** plus a **slash-command workflow**, so you can trigger it from the Cline chat with `/corporate-launcher`.

## Install the skill into Cline

One-liner — clone the repo and copy `.clinerules/` into your workspace root:

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git
cp -R corporate-launcher/integrations/cline/.clinerules /path/to/your-workspace/
```

Replace `/path/to/your-workspace/` with the workspace folder you open in VS Code / Cursor.

## What gets installed

Two files land under your workspace's `.clinerules/` directory:

| File | Role |
| --- | --- |
| `.clinerules/01-corporate-launcher.md` | The rule — auto-loaded by Cline as system context for every task in this workspace. |
| `.clinerules/workflows/corporate-launcher.md` | The slash-command workflow — invokable on demand via `/corporate-launcher`. |

## Invoke

Open the Cline panel in VS Code / Cursor, then in the chat input type:

```
/corporate-launcher
```

Cline will load the workflow and walk through the launcher generation steps.

## Verify

```bash
ls -la /path/to/your-workspace/.clinerules/01-corporate-launcher.md
ls -la /path/to/your-workspace/.clinerules/workflows/corporate-launcher.md
```

Both files should exist and be readable. If Cline doesn't pick up the rule, reload the VS Code window (`Cmd+Shift+P` → `Developer: Reload Window`).

## Uninstall

```bash
rm -rf .clinerules/01-corporate-launcher.md .clinerules/workflows/corporate-launcher.md
```

Leave the `.clinerules/` directory in place if you have other Cline rules; otherwise remove the whole folder.

## Known gotchas

- **Workspace-scoped, not global.** Cline reads `.clinerules/` from the currently opened workspace. You need to install the skill in each workspace where you plan to build a launcher. There is no global `~/.clinerules` equivalent.
- **Rule ordering matters.** The `01-` prefix ensures the corporate-launcher rule loads before unprefixed rules. Keep the prefix if you add more rules.
- **Slash-commands need workflow files.** Cline only exposes `/<name>` if `.clinerules/workflows/<name>.md` exists — don't move or rename the workflow file.

## Cursor compatibility

Cursor is a VS Code fork, so the same Cline rules apply unchanged. First install the Cline extension inside Cursor:

```bash
cursor --install-extension saoudrizwan.claude-dev
```

Then follow the same install / invoke / verify steps above. The `.clinerules/` directory is read identically by Cline running under Cursor.
