# v0.6 Final Verification Report

## Summary

All hard gates green. Score 15/15, sync clean, generate clean, smoke 10/10, branding clean in active code.

## Check results

| Check | Result | Detail |
|---|---|---|
| `check-skill-quality.py` | **15/15** | All checks pass after fixes |
| `tests/sync-vars.py` | **exit 0** | clean — templates and interview in sync |
| `scripts/smoke-test.sh` | **10/10 OK** | All steps green after dev-rules-tpl fix |
| `scripts/generate.py --dry-run` (acme-claude-litellm) | **exit 0** | works after DEV_RULES_MODE=inline support |
| `scripts/lint-templates.sh` | 33 errors / 583 warnings | Pre-existing; out of v0.6 scope |
| Branding leak grep (active code) | **0** | All hits confined to `tests/reports/` historical artifacts |

## Top 5 lint offenders (flagged, not fixed)

1. `templates/dist/tarball/upload-artifactory.sh.tpl` — 7 errors
2. `templates/shared/secrets-store.ps1.tpl` — 5 errors
3. `templates/dist/tarball/upload-nexus.sh.tpl` — 5 errors
4. `templates/dist/tarball/upload-s3.sh.tpl` — 4 errors
5. `templates/shared/extract-corp-ca.sh.tpl` / `secrets-store.sh.tpl` / `strip-proxy.js.tpl` — 2 errors each

## Fixes applied

1. **`scripts/generate.py`** — added `inline` to allowed `DEV_RULES_MODE` set; added `DEV_RULES_CONTENT` precondition. Unblocked generate against the example config.
2. **`SKILL.md`** — appended pushy-phrase trigger ("Use this skill whenever a user needs to wrap a vendor CLI onto a corporate AI gateway.") to satisfy quality check.
3. **`tests/sync-vars.py`** — added `DEV_RULES_CONTENT`, `DEV_RULES_GIT_PATH`, `DEV_RULES_GIT_REF` to `DOC_ALIASES` (they are config-time keys read by `dev-rules-installer.py`, never expanded as template vars). Cleared dead-spec drift.
4. **`templates/shared/dev-rules.md.tpl`** — escaped literal `${VAR}` example inside `<!-- tpl: -->` comment as `$\{VAR\}` so strict render no longer trips on an undefined variable. Unblocked smoke step 6 (real generate) and 7/8 (launcher).
5. **Brand scrub** (active code):
   - `references/url-purge.md` — `socle.ia.sncf.fr`, `nexus.sncf.fr` -> `gateway.acme.example`, `nexus.acme.example`.
   - `scripts/url-purge.py` — module docstring "Patrick Code / TGV Europe" -> "corporate launcher generator".
   - `scripts/dev-rules-installer.py` — config example `"SNCF"` -> `"Acme Corp"`.
   - `scripts/audit-rules.json` — remediation example `'Patrick Code'` -> `'Acme Copilot'`; slug example `'patrick-code'` -> `'acme-copilot'`.
   - `templates/shared/url-purge-list.json` — description / maintainer / 4 reason fields and the 2 `allowed_corp_endpoints` rows rebranded to acme.example.
   - `agents/compliance-docx-subagent.md` — "Cyber Controls (SNCF Cybersécurité)" -> "(Corporate Security Office)".
   - `tests/test_dev_rules.py` — docstring rebrand.
   - `CHANGELOG.md` — "SNCF/Patrick re-leaked" -> "Brand placeholders re-leaked".

## Residual brand mentions (acceptable)

7 lines remain in `tests/reports/SCRUB_REPORT.md` and `tests/reports/AUDIT_V2_SELF.md`. These are immutable historical audit artifacts that *describe* the prior scrubbing operations (e.g. "replaced `Patrick Code` -> `Acme Copilot`"). They are out of scope for `check-skill-quality.py` (which scans `references/`, `scripts/`, `templates/`, `SKILL.md`) and rewriting them would falsify audit history.

## Git status

29 modified files (CHANGELOG, README, SKILL.md, references, scripts, templates), 8 renames (tests/* -> tests/reports/*), 5 untracked dirs/files (`.claude-plugin/`, `agents/`, integration READMEs, `references/dev-rules.md`, `scripts/dev-rules-installer.py`). No surprise binaries or generated trees.
