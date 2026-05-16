# tests/reports/

Historical reports from one-off audits, smoke tests, integration checks, and polish passes performed against the corporate-launcher skill during its development.

## Purpose

These files are kept for **context and traceability**, not as authoritative documentation. They capture point-in-time findings, rulebook drafts, and self-reviews that informed subsequent fixes to the skill. The state of the codebase, rulebook, and behavior described in any given report reflects the moment that report was written — not the current state of the project.

## Authoritative sources

For the current state of the skill, refer to:

- `../../CHANGELOG.md` — latest results, fixes, and release notes.
- `../../SKILL.md` — current skill specification and behavior contract.
- `../../README.md` — usage and overview.
- `../` — live test files (`*.py`) and fixtures.

## Inventory

| File | Type | Notes |
|---|---|---|
| `SMOKE_REPORT.md` | Smoke test | Initial end-to-end run. |
| `SCRUB_REPORT.md` | Cleanup pass | Anti-pattern scrub findings. |
| `SYNC_REPORT.md` | Sync check | Cross-file consistency review. |
| `FINAL_POLISH_REPORT.md` | Polish pass | Pre-release micro-detail review. |
| `V05_INTEGRATION_REPORT.md` | Integration | v0.5 integration check. |
| `AUDIT_RULEBOOK.md` | Rulebook draft | Criteria used by the audit. |
| `AUDIT_REPORT.md` | Audit v1 | First audit pass. |
| `AUDIT_V2.md` | Audit v2 | Second audit pass. |
| `AUDIT_V2_SELF.md` | Self-audit | v2 self-review. |

## Policy

Do not edit these files. New audit reports go here too; update the inventory above when adding one.
