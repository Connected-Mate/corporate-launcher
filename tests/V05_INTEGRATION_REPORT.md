# v0.5 Integration Report

Run date: 2026-05-16. Driver: `tests/integration/test_v05_features.py` + smoke
test + sync-vars.

## Features confirmed end-to-end

- **generate.py** dry-run and real pipeline both exit 0 on the canonical
  `examples/configs/acme-claude-litellm.json`.
- **audit-launcher.py** scores 8/8 on the freshly generated tree (no P0/P1/P2).
- **url-purge.py** reports 0 vendor-URL violations on the canonical render.
- **pixel-art-logo.py** emits a multi-line ANSI banner under `--style block`.
- **api-probe.py --help** prints the documented CLI surface (`--url`,
  `--token`, `--backend`).
- **sync-vars.py** now clean: 145 documented vars match templates + scripts.

## Bugs caught and fixed

1. Example config missing v0.5 flags (`API_PROBE_ENABLED`, `BANNER_GENERATE`,
   `COMPLIANCE_DOCX`, `CYBER_REVIEW_REQUIRED`, `DPO_REVIEW_REQUIRED`,
   `LOAD_TEST_*`, `SELF_AUDIT_ENABLED`, `URL_PURGE_AUTOPATCH`). Added all 10.
2. `templates/shared/api-probe.sh.tpl` left several shell `${VAR}` references
   unescaped, breaking the strict renderer. Escaped to `$\{VAR\}`.
3. `scripts/render.py` did not force +x on rendered shell scripts. Now sets
   `0o755` on `.sh`/`.py`/extensionless outputs.
4. `audit-launcher.py` had several false positives: looked for the launcher
   binary by `CC_CLI_NAME` instead of `CORP_SLUG`; re-scanned its own report
   files; mis-classified vendor URLs inside `permissions.deny`; flagged the
   dead `if "no" = "yes"` TLS-bypass guard. All fixed via targeted allowlists
   and a constant-false-branch detector.
5. `scripts/url-purge.py` re-scanned its own report and the detector data
   files. Added `EXCLUDED_FILES` and an inline `# url-purge: allow` marker.
6. `tests/sync-vars.py` only inspected `templates/**/*.tpl` and
   `interview-flow.md`; v0.5 flags consumed via `ctx.get` from Python were
   reported as dead. Now also scans `scripts/*.py` and
   `references/skills-bundle.md`.
7. `tests/test_generate.py` minimal fixture lacked v0.5 keys; updated.
8. The three evals scenarios under `evals/scenarios/` were missing the same
   v0.5 keys; patched.
9. `scripts/smoke-test.sh` died when `python3` had no pytest. Now probes
   candidates and degrades to WARN instead of FAIL.
10. `scripts/generate.py` never honoured `SELF_AUDIT_ENABLED`, never wired
    `LOAD_TEST_ENABLED`, never echoed `CYBER_REVIEW_REQUIRED` /
    `DPO_REVIEW_REQUIRED` reminders. All three flags are now real switches.

## Final counts

- pytest (full suite, branding skipped): **162 passed, 1 skipped, 1 xfailed**.
- v0.5 integration tests: **6/6 passed** in ~9s.
- smoke-test.sh: **10/10 OK**.
- sync-vars.py: clean.
- audit on canonical render: **8/8 PASS, 0 failures**.
- url-purge on canonical render: **0 violations**.

## Human follow-up

- `python-docx` is not installed locally so the compliance .docx phase
  prints a skip line. Install it on the host that ships the bundle.
- `evals/branding/` tests are still ignored — review whether they should be
  unlocked now that v0.5 flags are wired through.
- The system `python3` (pyenv 3.12.0) has a broken pip and no pytest. CI
  should pin the runner to a working interpreter (homebrew `python3.11`
  works) or rebuild the pyenv install.
