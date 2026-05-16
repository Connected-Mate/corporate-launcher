# Corporate Launcher — Smoke Report

End-to-end run of `scripts/generate.py` against `examples/configs/acme-claude-litellm.json`, then exercising the produced launcher.

## What worked first try

- `--dry-run` traversal of the template tree.
- Validation rules in `validate_config` (the example config already satisfied them — proxy pair, HTTPS gateway, internal hostname check, etc.).
- Distribution scaffolding (`templates/dist/private-git/`) once render-time vars existed.
- `test_render.py` once `render.py` was patched (16/16 pass).

## What broke and what was fixed

1. **`PROVIDER_KIND` unresolved.** Referenced only by `templates/shared/launcher-update.sh.tpl` but never set. Fix in `scripts/generate.py::render_clis` — defaults to the first entry in `WRAPPED_CLIS`.
2. **Runtime shell vars mis-treated as render-time.** Multiple `.tpl` files (`launcher-update.sh.tpl`, `revoke-token.sh.tpl`, `extract-corp-ca.sh.tpl`, `strip-proxy.js.tpl`) used `${CC_PIN_VERSION}`, `${ADMIN_TOKEN}`, `${REQUEST_ID}`, `${PORT}`, etc. without `$\{...\}` escapes. Fixed by escaping those occurrences in the templates (kept render-time corp vars unescaped).
3. **Missing config keys.** Added sensible defaults to `examples/configs/acme-claude-litellm.json`: `CA_FILTER_EXTRA`, `CORP_CA_ORG`, `DIST_ONELINER_HOST`, `DIST_REGISTRY_URL`, `GATEWAY_ADMIN_TOKEN_ENV`, `GATEWAY_BACKEND`, `SKILLS_PICK`, `SKILLS_LOCAL_PATH`. Dynamic vars `DIST_GENERATED_AT` and `DIST_YEAR` are now set by the orchestrator.
4. **List / bool serialization.** `render.py::repl` used `str(value)` which produced `['design-pack']` (single quotes) — broke `_skills_parse_list`. Switched to `json.dumps` for lists/dicts, lower-case for booleans.
5. **MCP injector module-name mismatch.** Public CLI names (`claude-code`, `codex-cli`, `gemini-cli`) didn't match injector filenames (`mcp-injector-claude.py`, etc.). Added `CLI_INJECTOR_MAP` in `scripts/mcp-installer.py` and a `main(argv)` fallback when no `install()` entry point exists.
6. **MCP injector wrote to operator's real `~/.claude/settings.json`.** Added `--settings` flag to `mcp-installer.py`; `generate.py::run_mcp_installer` now passes `<install_dir>/settings.json`. Restored the operator's file by hand.
7. **Launcher binary not produced.** `install.sh` expects `<install_dir>/acme-copilot`, but the template was `launcher.sh.tpl`. Renamed to `${CORP_SLUG}.tpl` so `render_tree` path substitution emits the slugged file.
8. **Escape regex too greedy.** `ESCAPED_RE` consumed nested `$\{...\}` escapes (case: `$\{OUTER:-$\{INNER\}\}`). Rewrote to forbid `$\{` and `\}` inside the body, plus an iterative loop in `render()` so escapes unwrap inside-out. This was the bug that produced `unexpected EOF while looking for matching "'`.
9. **Dry-run blocked by VPN check.** `ACME_COPILOT_DRY_RUN=1` couldn't bypass `check_vpn`. Moved the dry-run short-circuit ahead of the VPN/isolation block in `templates/claude-code/${CORP_SLUG}.tpl`.

## Final results

- `python3 scripts/generate.py --config examples/configs/acme-claude-litellm.json --out /tmp/test-launcher` exits 0.
- `bash /tmp/test-launcher/acme-copilot --help` prints help and exits 0.
- `ACME_COPILOT_DRY_RUN=1 bash /tmp/test-launcher/acme-copilot` dumps `ACME_COPILOT_*` env vars and exits 0.
- `pytest tests/test_render.py` — 16 passed, 1 deprecation warning.

## Remaining issues (follow-up)

- `tests/test_generate.py` — 6 of 10 pre-existing failures (validation tightened around proxy pairing and DOG → config rename). Out of scope for this smoke; flag for follow-up.
- `setup_isolation` still prompts for a token under `DRY_RUN=1` (token prompt prints, then exits 0). Cosmetic — consider short-circuiting `setup_isolation` entirely when dry-run is set.
- Skills installer prints `Repository not found` warnings for design-pack presets (the public GitHub URL hard-coded in `templates/shared/skills-presets.json` returns 404). Doesn't fail the build but pollutes output.
- Render's `\{` escape sequence still triggers a `DeprecationWarning` in the module docstring (`render.py:2`). Cosmetic; raw-string the docstring or rephrase.
