# Skills bundle

When a creator builds a launcher with this skill, they choose which skills travel inside it. Their colleagues install the launcher and get those skills automatically — no extra step.

This file documents what's askable, what's installable, and how it ends up on a colleague's machine.

---

## The interview question

```
Which skills do you want to bundle for your colleagues?

  [1] None — bare wrapper only
  [2] Design pack (curated UI/UX skills)
  [3] Pick from a curated list (one-by-one, multi-select)
  [4] From a git repo URL — your own internal skill monorepo
  [5] From a local folder — what's already on this machine
```

Multi-select allowed for [3]. Options [2], [4], [5] can be combined.

Save the answers as:

| Var | Type | Example |
|---|---|---|
| `SKILLS_MODE` | enum | `none` / `preset` / `pick` / `git` / `local` / `combined` |
| `SKILLS_PRESETS` | list | `["design-pack"]` |
| `SKILLS_PICK` | list | `["polish", "audit", "critique"]` |
| `SKILLS_GIT_URL` | URL | `https://github.acme.internal/ai-platform/skills.git` |
| `SKILLS_GIT_REF` | string | `main` (branch / tag / commit) |
| `SKILLS_LOCAL_PATH` | path | `~/.claude/skills` |
| `MCP_SERVERS` | list | `[{"name":"jira","url":"https://mcp.acme/jira"}, ...]` |

---

## Presets

The skill ships with a small set of curated presets so a creator who doesn't have an internal catalog yet can still ship something useful on day one.

### `design-pack`

UI / UX skills. Suitable for product teams, design engineers, and full-stack developers who write front-end code.

Skills included:
- `polish` — final-pass quality (alignment, spacing, micro-details)
- `audit` — accessibility, performance, responsive checks (P0–P3 scored)
- `critique` — UX review (hierarchy, clarity, cognitive load)
- `distill` — strip a design to its essence
- `clarify` — improve UX copy / microcopy
- `typeset` — typography hierarchy and sizing
- `layout` — spacing, rhythm, visual hierarchy
- `animate` — purposeful motion design
- `colorize` — strategic color additions
- `bolder` / `quieter` — turn the volume up or down on a design
- `harden` — error states, empty states, i18n, edge cases
- `optimize` — UI performance pass
- `delight` — micro-interactions and personality
- `adapt` — responsive / cross-device
- `impeccable` — design vocabulary + project context loader

Source: a publicly maintained skills monorepo. The launcher's `install.sh` clones it into `<install>/skills/design-pack/` and the colleagues' Claude Code picks them up at `~/.claude/skills/design-pack/`.

### Future presets (placeholder — open for contributions)

- `security-pack` — security-review, threat-model, SBOM-check, secret-scan
- `data-pack` — sql-review, dbt-lint, dataframe-explorer
- `ops-pack` — incident-template, postmortem, runbook-generator

---

## Custom skills from a git repo

The most common production setup. The creator maintains an internal repo of skills — vetted by the security team, reviewed by the architecture board — and the launcher clones it into every colleague's install.

```bash
# inside the generated install.sh
SKILLS_REPO_URL="${SKILLS_GIT_URL}"
SKILLS_REPO_REF="${SKILLS_GIT_REF}"

if [ -n "$SKILLS_REPO_URL" ]; then
    git clone --depth 1 --branch "$SKILLS_REPO_REF" \
        "$SKILLS_REPO_URL" "$INSTALL_DIR/skills"
fi
```

The launcher then exposes `<slug> --update-skills` which runs `git pull` inside `<install>/skills/`.

Trade-offs:
- ✅ Easy to roll out a new skill to the whole company.
- ✅ One source of truth for the security team.
- ❌ Requires every colleague's machine to have git + network access to the internal git host.

---

## Skills from a local folder

For air-gapped environments. The creator points to a folder on their machine; the skill *copies* (not symlinks) the folder into the install tree, then the distribution kit packages it as part of the tarball.

Trade-offs:
- ✅ No network dependency for colleagues.
- ❌ The bundle is frozen at install time — no update path without re-shipping the launcher.

---

## MCP servers

The skill can also pre-configure MCP servers for the launcher. These are written into the CLI's native config (`settings.json` for Claude Code, `config.toml` for Codex CLI, `settings.json` for Gemini CLI) so colleagues get them for free.

The interview asks:

```
Pre-configure MCP servers?

  [1] No — colleagues add their own
  [2] Yes — give me the list (name + URL + headers, repeatable)
```

For each server, the creator provides:

| Var | Example |
|---|---|
| `name` | `jira` |
| `url` | `https://mcp.acme.internal/jira` |
| `headers` | `{"Authorization": "Bearer ${env:MCP_TOKEN}"}` |
| `trust` | `false` (always force confirmations for tool calls) |

Pre-configured servers are added to the **allowlist** at the same time, so an enterprise hardened config doesn't silently disable them.

---

## What ends up on a colleague's machine

After the colleague runs the install one-liner:

```
~/.local/share/acme-copilot/
├── acme-copilot                  ← the wrapper
├── install.sh / uninstall.sh
├── BRANDING.md / cyber-rules.md
├── settings.json                 ← includes the pre-configured MCP servers
├── skills/                       ← the bundle from the creator
│   ├── design-pack/...
│   └── internal-skills/...       ← from the SKILLS_GIT_URL
└── scripts/
    └── ...
```

Claude Code's skill loader picks up `skills/` automatically (via the `additionalDirectories` permission setting), and the colleague's Claude Code sees them in the list under `~/.claude/skills/`.

No further setup required.

---

## Security review checklist

When the creator chooses option [4] (git repo URL), the skill prints a reminder:

> ⚠️ Every skill in your repo will run with the colleague's permissions. Make sure the repo is:
> - **owned by a known internal team** (not a random public mirror)
> - **branch-protected** (no direct push to `main`)
> - **scanned for secrets** before each release
> - **reviewed by the security office** if it ships a skill that can execute shell commands

The cyber rules ship a `pre-tool-hook.py` that blocks destructive commands even from a misbehaving skill — but the cleanest defense is a curated, reviewed source.
