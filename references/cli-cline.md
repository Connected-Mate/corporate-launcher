# Cline — corporate launcher notes

Loaded only when the interview answer for `WRAPPED_CLIS` contains `cline`.
Cline is the supported path for **Cursor** users because Cursor's native chat
cannot be routed through an internal-only gateway (see `provider-matrix.md`,
Tier B).

## Table of contents

- [What Cline is](#what-cline-is)
- [Why it's the Cursor path](#why-its-the-cursor-path)
- [Pre-deployed settings.json keys](#pre-deployed-settingsjson-keys)
- [Identity rebrand via global rules](#identity-rebrand-via-global-rules)
- [MCP support](#mcp-support)
- [Folder trust — leave it on](#folder-trust--leave-it-on)
- [AutoApprove — empty by default](#autoapprove--empty-by-default)
- [Custom instructions path](#custom-instructions-path)
- [CA bundle (TLS)](#ca-bundle-tls)
- [HTTPS proxy](#https-proxy)
- [Telemetry kill switches](#telemetry-kill-switches)
- [Operator checklist](#operator-checklist)

## What Cline is

- VS Code extension, marketplace id **`saoudrizwan.claude-dev`** (same id on
  the VS Marketplace and on Open VSX, so it resolves inside any VS Code fork).
- Runs as a Node process **inside the VS Code extension host** — every TLS,
  proxy and certificate setting that VS Code exposes is inherited by Cline.
- Upstream docs: <https://docs.cline.bot>.
- Distribution: not an `npm i -g`. The launcher uses
  `<ide> --install-extension saoudrizwan.claude-dev --force` against every
  detected IDE CLI.

## Why it's the Cursor path

Cursor is a VS Code fork. Its built-in chat ("Cursor Tab", `cursor-small`,
`cursor-fast`) is proxied through Cursor's own infra and **requires a public
HTTPS endpoint** — incompatible with an internal LiteLLM / Bedrock / Vertex
gateway unless the gateway is exposed externally (Cloudflare, AWS LB, etc.).

The supported workaround is to **install Cline inside Cursor**:

```sh
cursor --install-extension saoudrizwan.claude-dev --force
```

The user keeps Cursor as their editor; AI requests now flow through the
corporate gateway via Cline instead of Cursor's hosted backend. The same
command works inside:

| IDE                | CLI binary       | Notes                            |
| ------------------ | ---------------- | -------------------------------- |
| VS Code            | `code`           | First choice when both present.  |
| Cursor             | `cursor`         | Disable native chat features.    |
| VSCodium           | `codium`         | Pulls from Open VSX.             |
| VS Code Insiders   | `code-insiders`  | Same extension id.               |

The launcher's `install.sh.tpl` already loops `code cursor codium
code-insiders` and installs into every one it finds (see step 3 of the
template).

## Pre-deployed settings.json keys

Cline reads every setting from the IDE's `settings.json` (user or workspace).
The launcher merges a managed block via `jq -s '.[0] * .[1]'` — every key
outside the block survives.

| Key                              | Value                                                  | Why                                                       |
| -------------------------------- | ------------------------------------------------------ | --------------------------------------------------------- |
| `cline.apiProvider`              | `"openai"`                                             | Forces the OpenAI-compatible path (LiteLLM, gateway).     |
| `cline.openAiBaseUrl`            | `${LLM_OPENAI_BASE_URL}` (e.g. `https://litellm…/v1`)  | Single egress point.                                      |
| `cline.openAiApiKey`             | `${CORP_API_KEY}` (token issued by `LLM_TOKEN_URL`)    | No raw vendor key on disk.                                |
| `cline.openAiModelId`            | `${LLM_PRIMARY_MODEL}` (e.g. `claude-opus-4-7`)        | Cline UI hides the model picker once this is set.         |
| `cline.openAiModelInfo`          | `{supportsImages, contextWindow, maxTokens, …}`        | Required when the model id is unknown to Cline's catalog. |
| `cline.customInstructions`       | `${INSTALL_DIR}/BRANDING.md` (path, not inline string) | Identity rebrand on every conversation.                   |
| `cline.telemetryOptOut`          | `true`                                                 | Disables Cline's own telemetry.                           |
| `cline.errorReportingOptOut`     | `true`                                                 | Disables Sentry-style error reporting.                    |
| `cline.allowAutoUpdate`          | `false`                                                | Pin the version the launcher tested.                      |
| `cline.autoApprove`              | `{enabled: false, actions: {all false}}`               | No command auto-executes (see below).                     |
| `cline.mcpMarketplaceEnabled`    | `false`                                                | Stops users adding arbitrary MCP servers from the GUI.    |
| `cline.enableCheckpoints`        | `true`                                                 | Local git snapshots — safe, useful.                       |

See `templates/cline/settings-cline.json.tpl` for the canonical block.

## Identity rebrand via global rules

Cline loads instruction files from two locations:

1. **Global rules** — `~/Documents/Cline/Rules/` (macOS, Linux with a
   `Documents` folder, WSL). Applied to **every workspace** the user opens.
2. **Workspace rules** — `.clinerules/` at the project root. Applied only to
   that project.

The launcher writes:

```
~/Documents/Cline/Rules/00-${CORP_SLUG}-identity.md   # BRANDING.md
~/Documents/Cline/Rules/10-${CORP_SLUG}-cyber.md      # cyber-rules.md
```

Numeric prefixes guarantee load order. The `00-` identity file is the same
content Claude Code receives in `~/.claude/CLAUDE.md` — keep one source of
truth in the launcher and template both targets.

## MCP support

Cline speaks MCP natively. Two switches matter:

- `cline.mcpMarketplaceEnabled = false` — disables the in-app marketplace so
  users cannot fetch arbitrary servers (this is the corp default).
- Per-server entries are added to `cline_mcp_settings.json` inside the IDE's
  Cline storage dir. The launcher's `install-mcp.sh` (shared module) writes
  this file when `SKILLS_MODE` contains `mcp`.

When MCP is disabled at install time, leave the marketplace flag `false` and
do not create `cline_mcp_settings.json` at all.

## Folder trust — leave it on

```jsonc
"security.workspace.trust.enabled": true,
"security.workspace.trust.untrustedFiles": "prompt"
```

Disabling workspace trust would let Cline **auto-execute shell commands**
(via the terminal tool) inside any untrusted clone the user opens — a
straight remote-code-execution path. Keep both keys as shown.

## AutoApprove — empty by default

`cline.autoApprove` accepts either a list of action names or an object with
per-action booleans (recent versions). Either way the launcher ships:

```json
"cline.autoApprove": {
  "enabled": false,
  "actions": {
    "readFiles": false,
    "editFiles": false,
    "executeSafeCommands": false,
    "executeAllCommands": false,
    "useBrowser": false,
    "useMcp": false
  },
  "maxRequests": 20,
  "enableNotifications": true
}
```

Every approval becomes interactive. Users can toggle individual actions
later inside the Cline UI — that's their own audit trail.

## Custom instructions path

`cline.customInstructions` accepts either an inline string **or a file
path**. The launcher always points it at the rendered `BRANDING.md`:

```jsonc
"cline.customInstructions": "${INSTALL_DIR}/BRANDING.md"
```

Why a path and not the string itself:

- Editing `BRANDING.md` is a single-file change — no JSON re-merge needed.
- The `${CORP_SLUG} --refresh` command can rewrite `BRANDING.md` without
  touching the IDE's `settings.json`.
- Keeps `settings.json` short and reviewable.

## CA bundle (TLS)

Cline runs in the VS Code extension host (Node). Two layers cover TLS:

```sh
# OS / shell level — inherited by the extension host
export NODE_EXTRA_CA_CERTS=/etc/ssl/${CORP_SLUG}-corp-bundle.pem
```

```jsonc
// VS Code level — covers update checks, MS marketplace, extension downloads
"http.systemCertificates": true
```

Never set `NODE_TLS_REJECT_UNAUTHORIZED=0`. If the CA bundle cannot be found
during `install.sh`, warn and stop — do **not** silently disable verification.

## HTTPS proxy

VS Code's own proxy setting is the single source of truth for the extension
host:

```jsonc
"http.proxy": "${CORP_HTTPS_PROXY}",
"http.proxyStrictSSL": true,
"http.proxySupport": "on"
```

`HTTPS_PROXY` / `HTTP_PROXY` shell vars are honored as fallback when VS Code
is launched from a terminal, but the JSON keys above take precedence and
work for every launch method (Dock, Spotlight, GNOME shortcut). The launcher
sets both.

## Telemetry kill switches

Three layers, all set by the launcher:

| Layer            | Setting                              | Effect                          |
| ---------------- | ------------------------------------ | ------------------------------- |
| Cline extension  | `cline.telemetryOptOut: true`        | Disables Cline analytics.       |
| Cline extension  | `cline.errorReportingOptOut: true`   | Disables Sentry error capture.  |
| VS Code host     | `telemetry.telemetryLevel: "off"`    | Stops Microsoft telemetry.      |
| RH plugin (opt.) | `redhat.telemetry.enabled: false`    | Common co-installed extension.  |
| Shell env        | `DO_NOT_TRACK=1`                     | Honored by most Node CLIs.      |

`telemetry.telemetryLevel = "off"` is inherited by every other extension in
the host — a free win.

## Operator checklist

Before declaring the install done:

- [ ] `code --list-extensions` (and/or `cursor --list-extensions`) shows
      `saoudrizwan.claude-dev`.
- [ ] `settings.json` contains the managed marker comment
      (`${CORP_SLUG}-managed: generated by ${CORP_NAME} launcher`).
- [ ] `~/Documents/Cline/Rules/00-${CORP_SLUG}-identity.md` exists and
      starts with the rebrand block.
- [ ] Opening the Cline panel shows the corporate model name; the model
      picker is hidden.
- [ ] First `Plan` action triggers an approval prompt (proves AutoApprove
      is disabled).
- [ ] An outbound request shows the corporate gateway hostname — not
      `api.anthropic.com` or `api.openai.com` — in the IDE's developer
      console (`Help → Toggle Developer Tools → Network`).
