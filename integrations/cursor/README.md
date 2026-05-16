# corporate-launcher — Cursor integration

## What

[Cursor](https://cursor.com) is a VS Code fork with native AI built in. Cursor's chat and Tab features run on **Cursor's own infrastructure** (their cloud gateway), so the `corporate-launcher` skill is installed via **Cursor Rules** (`.cursor/rules/`) and **Cursor Commands** (`.cursor/commands/`) — the two extension points Cursor exposes to customize its native AI.

## Two paths

### a. Cursor native

Drop the rules + commands into your workspace and invoke `/corporate-launcher` from Cursor's chat panel.

> **Heads up:** the native path only works if your AI traffic routes through Cursor's gateway (the default), which means prompts transit Cursor's cloud. **Check your corporate policy** before using this path — many cyber teams will not sign off on it.

### b. Cline in Cursor (recommended for corporate use)

Install the [Cline](https://cline.bot) extension inside Cursor and follow the Cline path: see [`../cline/README.md`](../cline/README.md). This routes AI calls through **your corporate gateway** via Cline's `openai-compatible` provider, bypassing Cursor's cloud entirely.

## Install (native path)

One-liner from your workspace root:

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git
cp -R corporate-launcher/integrations/cursor/.cursor /path/to/your-workspace/
```

## What gets installed

```
.cursor/
├── rules/
│   └── corporate-launcher.mdc      # always-on context rule
└── commands/
    └── corporate-launcher.md       # /corporate-launcher slash command
```

## Invoke

In Cursor:

1. Open the **Chat** panel (`Cmd/Ctrl + L`)
2. Type `/corporate-launcher`
3. Send

The rule provides ambient context; the command triggers the full launcher flow.

## Uninstall

```bash
rm -rf .cursor/rules/corporate-launcher.mdc .cursor/commands/corporate-launcher.md
```

(Leave the `.cursor/` directory if you have other rules or commands in it.)

## Recommended corporate path

**Use Cline-in-Cursor.** See [`../cline/README.md`](../cline/README.md).

This is the path most enterprise cybersecurity teams will sign off on because:

- AI calls go through **your corporate gateway** (Cline's `openai-compatible` provider), not Cursor's cloud
- You keep Cursor's editor UX (Tab completions, fast navigation) while routing reasoning traffic through infrastructure you control
- Audit, DLP, and prompt-logging policies apply at your gateway

The native path remains available for personal projects or teams whose policy explicitly allows Cursor's cloud.
