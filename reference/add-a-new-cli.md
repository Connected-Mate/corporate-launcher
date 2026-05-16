# Adding a new AI CLI to the supported set

This walkthrough shows the full path to add a new CLI — e.g. "I want corporate-launcher to wrap Cursor CLI" — from research to merged PR. Plan on 1-2 hours for a Tier S CLI (fully ENV-driven), more for a CLI with a custom config language.

The supported set lives in `reference/provider-matrix.md`. The interview branches live in `reference/interview-flow.md`. Both must stay in lockstep with `templates/<cli-name>/`.

---

## Step 1 — Research the CLI

Before writing any template, document the CLI in plain prose. You need three answers:

- **Environment variables** the CLI reads (auth, base URL, model, telemetry kill switches, CA bundle).
- **Native config file** path and format (`~/.foo/config.toml`, `~/.config/foo/foo.json`, …).
- **Auth model** — bearer token, API key, AWS SDK chain, GCP ADC, OAuth device flow.

Add a new row to `reference/provider-matrix.md` under the right tier:

- **Tier S** = fully ENV-driven, no config file mutation needed.
- **Tier A** = needs a pre-deployed config file (Codex, Cline).
- **Tier B** = out of scope (GUI-only, server-side admin, full self-host).

If the CLI lands in Tier B, document why and stop — do not create templates for it.

---

## Step 2 — Create the template directory

```
templates/<cli-name>/
├── launcher.sh.tpl          # the wrapper binary
├── install.sh.tpl           # installer wizard
├── <native-config>.tpl      # e.g. config.toml.tpl, settings.json.tpl
├── BRANDING.md.tpl          # system prompt + identity rules
└── uninstall.sh.tpl         # clean removal
```

Copy from the closest existing CLI (`templates/aider/` for a Python ENV-driven CLI, `templates/claude-code/` for a Node CLI with hooks, `templates/codex-cli/` for a Rust CLI with a TOML config). Replace the CLI invocation and rename the config file.

Conventions reminders:

- Lines starting with `# tpl:` are stripped at render time — use them for inline docs.
- `$\{HOME\}` in a template renders as literal `${HOME}` in the output (escape backslash form).
- `${UPPER_VAR}` is substituted from the interview answers. Unresolved → renderer raises.
- Bash templates start with `set -euo pipefail`. No `curl | bash` inside templates.

---

## Step 3 — Add the PowerShell counterparts

For each `.sh.tpl` create a `.ps1.tpl` sibling: `launcher.ps1.tpl`, `install.ps1.tpl`. The skill produces Windows launchers from the same context JSON. Copy patterns from `templates/claude-code/launcher.ps1.tpl` — use `$ErrorActionPreference = 'Stop'`, dot-source the shared `.ps1` modules from `templates/shared/`.

---

## Step 4 — Wire the interview flow

Open `reference/interview-flow.md`.

- **Section 2** — add the new CLI to the multi-select list with a one-line pitch ("**Cursor CLI** (Anysphere) — JSON-config-driven, OpenAI-compatible only").
- **Section 3** — add a new branch (`3.E — Cursor CLI branch`) with a table of CLI-specific questions. Use a 2-letter prefix per CLI for the variable names (`CC_*` for Claude Code, `CX_*` for Codex, etc. — pick an unused pair).

Every branch must cover: backend choice, gateway URL, default model, auth env var name, any unique-per-CLI toggles (e.g. lockdown file, wire API selection).

---

## Step 5 — Document the env vars

Add a subsection to `reference/env-vars.md` listing every env var the new templates set. Group by purpose: auth, network, telemetry kill, model selection. Cross-link to the row in `provider-matrix.md`.

---

## Step 6 — Add a worked example

Create `reference/examples/<corp>-<cli>-<backend>.md` showing the full interview answers, the rendered tree, and the final launcher command. Use a realistic fake company (`acme-`, `globex-`) consistent with existing examples.

---

## Step 7 — Add validation rules

Open `scripts/render.py` (or `schema/config.schema.json` if you add a JSON Schema in a future iteration). Add validation for any unique constraint of the new CLI — e.g. "Cursor CLI requires `OPENAI_API_BASE` to end in `/v1`". Validation failures should match the existing error style in `render.py` (`UnresolvedVariable` for missing, `ValueError` for malformed).

---

## Step 8 — Add a test fixture

Drop a sample config at `examples/configs/sample-<cli>-<backend>.json` covering the most common path (the corporate gateway case). Keep it minimal but realistic — the test suite renders this fixture end-to-end.

---

## Step 9 — Smoke test

```bash
python3 scripts/generate.py \
  --config examples/configs/sample-<cli>-<backend>.json \
  --out /tmp/test-<cli> \
  --dry-run
```

Verify:

- Every `${VAR}` resolved — no `${UNRESOLVED}` strings in the output.
- `shellcheck /tmp/test-<cli>/*.sh` clean.
- The rendered `launcher.sh --help` returns 0 without exec'ing the underlying CLI.
- The rendered `uninstall.sh` is idempotent (running it twice is safe).

---

## Step 10 — Open a PR

Branch `cli/<cli-name>`. PR description must list: provider-matrix row, interview-flow sections touched, env-vars subsection, example file, fixture path. Maintainer review will replay the smoke test on their side before merge.
