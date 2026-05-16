# Final Polish Report

## Scenarios

Three fixtures under `evals/scenarios/`:

- `scenario-claude-bedrock.json` — Claude Code + Bedrock + strip-proxy + private-git.
- `scenario-codex-azure.json` — Codex CLI + Azure OpenAI + admin lockdown + security-pack.
- `scenario-cline-cursor.json` — Cline-in-Cursor (Claude Code behind LiteLLM) + 2 MCP servers + git skills.

Each carries the full config, `expected_files`, `expected_dist_files`, and `expected_branding_check`. `tests/integration/test_scenarios.py` renders each, asserts every expected path exists, runs `--help`, and word-boundary-greps stdout for forbidden vendor terms. All 4 tests pass.

## Fixes

- `tests/sync-vars.py`: path `reference/` → `references/`, added 6 distribution credentials to `DOC_ALIASES`. Exits 0.
- `templates/codex-cli/{install,launcher,uninstall}.sh.tpl`: escaped runtime `${C_*}` / `${MARKER_*}` so render leaves them for bash.

## Orphans (reported, not deleted)

- `references/offboarding.md` — no direct link points to it.
- `templates/dist/dist-readme/*.md.tpl` — never rendered by `scripts/generate.py`.
