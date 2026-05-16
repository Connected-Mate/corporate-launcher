# Changelog

All notable changes to **Corporate Launcher** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] — 2026-05-16

### Added — five-feature audit-grade pass
- **API probe** (Phase 1.5): `scripts/api-probe.py` validates the gateway URL, lists available models, captures TLS cert info, masks the token. Called automatically during install.
- **Load testing** (`scripts/load-test.py`): p50/p95/p99 latency + req/sec + token throughput against the configured gateway. Opt-in via `LOAD_TEST_ENABLED`.
- **Self-audit launcher** (Phase 3.5): `scripts/audit-launcher.py` runs 30+ rules from `scripts/audit-rules.json` against the rendered launcher (no vendor URLs, no plain secrets, VPN check present, telemetry kill switches set, FORBIDDEN_TERMS appear only in BRANDING.md, etc.). Produces a markdown + JSON report.
- **URL purge** (Phase 3.6): `scripts/url-purge.py` + `templates/shared/url-purge-list.json` (123 blocked domains, 29 patterns) scan the launcher for vendor endpoint leaks outside the explicit deny lists. `--patch` mode rewrites violations.
- **Compliance Word doc** (Phase 4.5): `scripts/build-compliance-docx.py` produces a 10-section .docx ready to send to RSSI/CISO/DPO. Sections: executive summary, threat model, cyber controls, network perimeter, data classification, telemetry posture, audit log, offboarding, sign-off.
- **Pixel-art banner** (Phase 3.7): `scripts/pixel-art-logo.py` generates a branded ASCII banner in 6 styles (block, slant, mini, pixel, vintage, tech, auto). Embedded font for offline use. Each launcher's startup screen now carries its own pixel-art identity.
- **"Made for friends · Made from France with ❤️"** footer in README, BRANDING, cyber-rules, banner.

### New tests
- `tests/test_api_probe.py`
- `tests/test_audit_launcher.py`
- `tests/test_compliance_docx.py`
- `tests/test_pixel_art.py`
- `tests/test_url_purge.py`
- `tests/test_load_test.py`

### New references
- `references/api-probe.md`
- `references/self-audit.md`
- `references/compliance-docx.md`
- `references/pixel-art-logo.md`
- `references/url-purge.md`
- `references/load-testing.md`

### Changed
- `scripts/generate.py` orchestration extended with Phases 1.5 / 3.5 / 3.6 / 3.7 / 4.5
- SKILL.md workflow now documents the 5 new phases
- references/interview-flow.md gained ~10 new opt-in/opt-out variables in Sections 4, 5, 6, 8.5
- README.md: new "Quality & testing" section now includes audit + compliance commands

### Note
This release moves the skill from "produces a working launcher" to "produces an audit-ready launcher". The self-audit + compliance docx are the difference between a developer-grade tool and an enterprise-grade tool.

## [0.4.0] — 2026-05-16

### Added
- Per-CLI focused reference docs: `references/cli-claude-code.md`, `cli-codex-cli.md`, `cli-gemini-cli.md`, `cli-aider.md`, `cli-opencode.md`, `cli-continue-dev.md`, `cli-cline.md`.
- `evals/` directory with `evals.json` (8 invocation prompts), `trigger-eval.json` (20 trigger queries), and a README explaining the eval system.
- `scripts/smoke-test.sh` — one-shot end-to-end smoke test.
- `scripts/lint-templates.sh` — template-file linter.
- `scripts/package-skill.py` — produces a `.skill` package with manifest.
- `scripts/host-deploy.sh` — auto-detect available hosts and install.
- `scripts/check-skill-quality.py` — programmatic audit against canonical conventions.
- `tests/test_skills_install.py` — skills-bundle integration test.
- `tests/test_mcp_install.py` — MCP injector integration test.
- TOCs on the 3 large reference docs (`interview-flow`, `security-patterns`, `distribution-modes`).

### Changed
- Directory `reference/` renamed to `references/` (canonical plural form).
- `SKILL.md` description gained the anti-undertriggering imperative + dedup of duplicate triggers.
- `SKILL.md` anti-patterns now carry "because" rationale.
- `cyber-rules.md.tpl` rewritten with per-rule "why" explanations and 4-paragraph preamble.
- Provider matrix split: `provider-matrix.md` is now a short index; per-CLI details moved to `references/cli-*.md`.
- `distribution-modes.md` gained quick-comparison table + "Choosing a mode" section.
- `README.md` refreshed: host install table verified, new "Quality & testing" section.
- `INSTALL.md` refreshed: each host install one-liner re-verified.

### Fixed
- 6 pre-existing failures in `tests/test_generate.py`.
- Stale internal links after the `references/` rename.

## [0.3.0] - 2026-05-16

### Added
- Skills install wiring end-to-end via [`templates/shared/install-skills.sh.tpl`](templates/shared/install-skills.sh.tpl) (modes: `preset`, `pick`, `git`, `local`, `combined`).
- MCP injection across providers via [`templates/shared/install-mcp.sh.tpl`](templates/shared/install-mcp.sh.tpl) with env-substituted headers (e.g. `${env:MCP_TOKEN}`).
- Distribution kits in [`templates/dist/`](templates/dist/) for `public-git`, `private-git`, `tarball`, `oneliner` modes plus `SHA256SUMS` generation.
- PowerShell parity for Windows-first orgs: `launcher.ps1.tpl`, `install.ps1.tpl`, `vpn-check.ps1.tpl`, `proxy-detect.ps1.tpl`, `pre-tool-hook.ps1.tpl`, `cost-tracker.ps1.tpl`, `secrets-store.ps1.tpl`.
- Branding evaluation harness in [`tests/branding/`](tests/branding/) catching vendor-name leaks (Claude / Anthropic / OpenAI / Google).
- JSON schema for the interview answer bag (see Phase 1 in [`SKILL.md`](SKILL.md)).
- Offboarding flow: every wrapper now ships `uninstall.sh` / `uninstall.ps1` with a manifest of files to remove.
- Template-variable audit script [`tests/sync-vars.py`](tests/sync-vars.py) — fails CI when templates and `references/interview-flow.md` drift.
- This `CHANGELOG.md`.

### Changed
- `references/interview-flow.md` Section 8 now distinguishes `SKILLS_MODE=combined` (preset + git + local) and Section 9 captures GPG signing options (`DIST_SIGN_RELEASE`, `DIST_GPG_KEY_ID`).
- Cyber kill-switch list in [`references/env-vars.md`](references/env-vars.md) now enforced atomically when `BLOCK_TELEMETRY=yes` (validation rule #5).

### Fixed
- `CC_NEEDS_STRIP_PROXY` is force-enabled when `CC_BACKEND` is `Bedrock` or `LiteLLM` (validation rule #6).
- Public-git distribution refuses internal hostnames in `CC_PRIMARY_URL` unless `DIST_PUBLIC_FORCE=yes` (validation rule #7).

### Security
- Oneliner distribution refuses plain HTTP hosts (rule #8); GPG signing prompt surfaced before publishing tarballs.

## [0.2.0] - 2026 — commit `51fe503`

### Added
- **Skills bundle** phase (Section 8 of [`references/interview-flow.md`](references/interview-flow.md)) — preset / pick / git / local sources, documented in [`references/skills-bundle.md`](references/skills-bundle.md).
- **Distribution** phase (Section 9) — public-git, private-git, tarball, oneliner; trade-offs in [`references/distribution-modes.md`](references/distribution-modes.md).
- MCP server pre-configuration questions (`MCP_SERVERS` list).

### Changed
- Attribution and creator references generalized away from project-specific names — colleagues can fork without rewriting headers.

## [0.1.0] - 2026 — commit `03f09e9`

### Added
- Initial public release of Corporate Launcher.
- Interview-driven generator that wraps **Claude Code**, **Codex CLI**, **Gemini CLI**, **Aider**, **opencode**, **Continue.dev**.
- Provider matrix for AWS Bedrock / Azure OpenAI / Vertex AI / LiteLLM / OpenAI-compatible gateways ([`references/provider-matrix.md`](references/provider-matrix.md)).
- Corporate-proxy + custom-CA + VPN-gate scripts under [`templates/shared/`](templates/shared/).
- Cyber kill-switches: telemetry, auto-update, feedback commands, voice mode, prompt filter, cost tracking — documented in [`references/env-vars.md`](references/env-vars.md) and [`references/security-patterns.md`](references/security-patterns.md).
- Strip-proxy shims for Bedrock / LiteLLM SSE artefacts.
- Per-CLI launcher + install/uninstall templates under [`templates/{claude-code,codex-cli,gemini-cli,aider,opencode,continue-dev}/`](templates/).
- `BRANDING.md` template with custom system-prompt addendum, banner color, terminal title, forbidden-terms list.

[Unreleased]: https://github.com/your-org/corporate-launcher/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/your-org/corporate-launcher/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/your-org/corporate-launcher/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/your-org/corporate-launcher/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/your-org/corporate-launcher/releases/tag/v0.1.0
