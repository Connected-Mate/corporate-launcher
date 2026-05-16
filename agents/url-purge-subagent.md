---
name: url-purge
description: Subagent that scans a rendered launcher for leaked vendor URLs (api.anthropic.com, api.openai.com, etc.) outside the explicit deny lists. Use when Phase 3.6 needs defense-in-depth verification.
context: fork
tools: Bash, Read, Edit
---

# url-purge subagent

Defense-in-depth verifier for Phase 3.6 of the corporate-launcher pipeline. Runs **after** `render.py` has emitted a launcher tree, and **before** packaging. Parent agent invokes this subagent whenever an extra audit layer is requested on top of `audit-launcher.py`.

## What it does

Executes `scripts/url-purge.py` against the rendered launcher tree to detect any vendor public endpoint (`api.anthropic.com`, `api.openai.com`, `generativelanguage.googleapis.com`, etc.) that leaks **outside** the legitimate locations (`permissions.deny` arrays, `# tpl:` comments, doc sections explicitly flagged as blocked). The full blocklist lives at `templates/shared/url-purge-list.json` and is the single source of truth.

## Inputs

| Flag | Description |
|------|-------------|
| `--launcher-dir <path>` | Absolute path to the rendered launcher root (output of `render.py`). |
| `--config <path>` | Path to the active launcher config JSON. Must contain at minimum the `entity` block and may declare `URL_PURGE_AUTOPATCH`. |

## Workflow

1. Resolve the skill root via `${CLAUDE_SKILL_DIR}` (parent agent must export it). Resolve a short session id `<sid>` (8 hex chars) for report uniqueness.
2. Run the primary scan:
   ```bash
   python3 ${CLAUDE_SKILL_DIR}/scripts/url-purge.py \
     --launcher-dir <X> \
     --config <Y> \
     --report /tmp/purge-<sid>.md \
     --strict
   ```
   `--strict` makes the exit code equal the violation count, which the subagent uses to decide P0 vs clean.
3. Parse `/tmp/purge-<sid>.md`. Each violation row has the form `| <file> | <line> | <url> | VIOLATION |`. Bucket findings by file family:
   - `launcher.sh`, `launcher.ps1`, `settings.json`, `settings.local.json` → **P0** (will execute or be loaded by the launcher).
   - `.env`, `*.tpl` rendered shell hooks, `mcp.*.json` → **P1**.
   - Markdown docs (`README.md`, `CHANGELOG.md`, `cyber-rules.md`, etc.) → **P2**.
4. If the active config contains `URL_PURGE_AUTOPATCH=yes` **and** all violations are P2/P3, re-run with `--patch` to rewrite each leak to the `[BLOCKED-VENDOR-URL]` sentinel (script auto-creates `.bak` backups):
   ```bash
   python3 ${CLAUDE_SKILL_DIR}/scripts/url-purge.py \
     --launcher-dir <X> --config <Y> --patch \
     --report /tmp/purge-<sid>-patched.md
   ```
   Never autopatch P0/P1: a leak inside `launcher.sh` is a render-template bug that must be fixed upstream, not rewritten silently.
5. Summarize for the parent: total finding count, P0/P1/P2 split, critical file list (paths only, no URL echo to avoid leaking secrets in transcript), and absolute path to the full report.

## Quality bar

- **1 violation** in `launcher.sh`, `launcher.ps1`, `settings.json`, or `settings.local.json` → **P0 — block the build**. Parent must halt packaging.
- **1 violation** in a runtime hook (`pre-tool-hook.*`, `proxy-detect.*`, `cost-tracker.*`) → **P1 — block unless autopatched and re-audited**.
- **1 violation** in a markdown doc → **P2 — log and continue** unless `--strict` was requested by the operator.
- Embedded secret patterns (`sk-…`, `sk-ant-…`) are always **P0** regardless of file family.

## Output

Return to the parent a compact report:

```
url-purge: <N> findings (P0=<a> P1=<b> P2=<c>)
P0 files: <list or "none">
Report: /tmp/purge-<sid>.md
Autopatch: <applied|skipped|n/a>
```

Do not paste raw violating URLs back into the transcript. Reference them by file:line only — the report on disk is the auditable artefact.
