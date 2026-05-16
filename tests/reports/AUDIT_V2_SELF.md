# AUDIT V2 — Self-inspection (deep, human-grade)

Date: 2026-05-16. Scope: structural / quality issues that automated audits miss.
Tests: **162 passed, 1 skipped, 1 xfailed** (requires `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1` because the host has a broken `langsmith` plugin pulling in `httpx` — not a project bug, but worth a `tests/README.md` note).
`check-skill-quality.py`: **14/15** — one fail (`forbidden brand terms` in 5 references). Example `acme-claude-litellm.json` renders end-to-end with **zero UnresolvedVariable**.

## P0 — Blockers

1. **README ships two non-existent script names.** `README.md:244` calls `scripts/compliance-docx.py`, real file is `build-compliance-docx.py`. `README.md:247` calls `scripts/pixel-art.py`, real file is `pixel-art-logo.py`. Any user copy-pasting from "Quality & testing" hits `No such file`. **Fix:** rename both invocations.

2. **SKILL.md phase numbering inconsistent with `generate.py`.** SKILL.md documents Phase 1.5 / 3.5 / 3.6 / 3.7 / 4.5. `generate.py` docstring uses 1.5 / 2.5 / 4.5 / 4.6 / 7 (load-test) / 6.5. A reader cross-referencing the two gets confused. **Fix:** align the docstring to SKILL.md or, better, drop phase numbers from `generate.py` and reference SKILL.md as the source of truth.

3. **Load-test feature is in CHANGELOG + interview-flow + script + test, but absent from SKILL.md workflow.** SKILL.md only lists it in "Reference files". Chain incomplete. **Fix:** add a Phase 1.6 (or 4.6) "Optional load test" block to SKILL.md, mirroring the api-probe phrasing.

## P1 — Should fix

4. **Brand leaks ("SNCF", "patrick") in 5 reference files** — `references/security-patterns.md:369,387,411,445`, `references/pixel-art-logo.md:23,73,82`, `references/compliance-docx.md:123`, `references/cli-gemini-cli.md:97,206`. Also `tests/test_compliance_docx.py:75-194` and `tests/test_url_purge.py:3`. These survive after the "tenant-agnostic" cleanup the README promises. **Fix:** replace with `<corp>`/`<authority>` placeholders or generic ACME examples; remove `patrick` entirely.

5. **Broken cross-reference in `distribution-modes.md:69`.** Says `templates/dist-readme/public.md.tpl`; real path is `templates/dist/dist-readme/public.md.tpl`. **Fix:** prepend `dist/`.

6. **Duplicate `RSSI_CLEARANCE_REF`** in `references/interview-flow.md` at line 184 (Section 5) and 279 (Section 8.5). `sync-vars.py` ignores dupes. **Fix:** keep the Section 8.5 entry (compliance context), drop the Section 5 row, run `sync-vars.py` to confirm.

7. **CHANGELOG `[0.5.0]` has no compare link** at the bottom; only `[Unreleased]…[0.1.0]` are mapped, and `[Unreleased]` still compares from `v0.4.0`. **Fix:** add `[0.5.0]` line + bump the `Unreleased` base to `v0.5.0`.

8. **`dist/corporate-launcher-0.3.0.skill` (3 MB) committed** even though `dist/` is in `.gitignore`. Stale artifact two minor versions behind. **Fix:** `git rm` the file; let users regenerate via `scripts/package-skill.py`.

9. **6 test reports committed under `tests/`** (`AUDIT_REPORT.md`, `SCRUB_REPORT.md`, `SMOKE_REPORT.md`, `SYNC_REPORT.md`, `FINAL_POLISH_REPORT.md`, `V05_INTEGRATION_REPORT.md`). Only `AUDIT_RULEBOOK.md` is linked from README. The others are one-shot snapshots that will rot. **Fix:** move to `docs/history/` or delete; keep only `AUDIT_RULEBOOK.md` next to the active `check-skill-quality.py`.

10. **`integrations/cline/` and `integrations/cursor/` have no top-level manifest** (only hidden `.clinerules/` / `.cursor/`). The integrations README's "Layout" table promises symmetry. A reader running `ls integrations/cline/` sees an empty directory. **Fix:** add a short `README.md` per host pointing at the hidden manifest path.

## P2 — Polish

11. **Soft orphans confirmed**: `references/offboarding.md` and `templates/dist/dist-readme/*.md.tpl` still unlinked from any workflow code path (only FINAL_POLISH_REPORT flags them). Either wire them into `generate.py` distribution rendering or note them as "reading material".

12. **`CHANGELOG.md` references `your-org/corporate-launcher`** for compare links while INSTALL/README use `Connected-Mate/corporate-launcher`. Single owner, fix to match.

13. **`__pycache__` everywhere** under `tests/` and `scripts/` despite `.gitignore` covering it — they're not tracked (good) but worth `git clean -fdX` before tagging a release.

14. **Hero image loads** (`assets/hero.png` exists, 1 file). README "What it does" 10-step list is internally coherent; install table covers the 5 hosts as advertised.

## Summary

162 tests green, generation pipeline clean, but **3 P0** (broken script names, phase-number drift, load-test missing from workflow) and **6 P1** (brand leaks, broken cross-ref, duplicate var, stale artifacts, missing host READMEs) need a polish pass before declaring v0.5 ready to publish.
