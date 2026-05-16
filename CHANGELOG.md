# Changelog

All notable changes to **Corporate Launcher** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-05-16

### Added
- Skills install wiring end-to-end via [`templates/shared/install-skills.sh.tpl`](templates/shared/install-skills.sh.tpl) (modes: `preset`, `pick`, `git`, `local`, `combined`).
- MCP injection across providers via [`templates/shared/install-mcp.sh.tpl`](templates/shared/install-mcp.sh.tpl) with env-substituted headers (e.g. `${env:MCP_TOKEN}`).
- Distribution kits in [`templates/dist/`](templates/dist/) for `public-git`, `private-git`, `tarball`, `oneliner` modes plus `SHA256SUMS` generation.
- PowerShell parity for Windows-first orgs: `launcher.ps1.tpl`, `install.ps1.tpl`, `vpn-check.ps1.tpl`, `proxy-detect.ps1.tpl`, `pre-tool-hook.ps1.tpl`, `cost-tracker.ps1.tpl`, `secrets-store.ps1.tpl`.
- Branding evaluation harness in [`tests/branding/`](tests/branding/) catching vendor-name leaks (Claude / Anthropic / OpenAI / Google).
- JSON schema for the interview answer bag (see Phase 1 in [`SKILL.md`](SKILL.md)).
- Offboarding flow: every wrapper now ships `uninstall.sh` / `uninstall.ps1` with a manifest of files to remove.
- Template-variable audit script [`tests/sync-vars.py`](tests/sync-vars.py) — fails CI when templates and `reference/interview-flow.md` drift.
- This `CHANGELOG.md`.

### Changed
- `reference/interview-flow.md` Section 8 now distinguishes `SKILLS_MODE=combined` (preset + git + local) and Section 9 captures GPG signing options (`DIST_SIGN_RELEASE`, `DIST_GPG_KEY_ID`).
- Cyber kill-switch list in [`reference/env-vars.md`](reference/env-vars.md) now enforced atomically when `BLOCK_TELEMETRY=yes` (validation rule #5).

### Fixed
- `CC_NEEDS_STRIP_PROXY` is force-enabled when `CC_BACKEND` is `Bedrock` or `LiteLLM` (validation rule #6).
- Public-git distribution refuses internal hostnames in `CC_PRIMARY_URL` unless `DIST_PUBLIC_FORCE=yes` (validation rule #7).

### Security
- Oneliner distribution refuses plain HTTP hosts (rule #8); GPG signing prompt surfaced before publishing tarballs.

## [0.2.0] - 2026 — commit `51fe503`

### Added
- **Skills bundle** phase (Section 8 of [`reference/interview-flow.md`](reference/interview-flow.md)) — preset / pick / git / local sources, documented in [`reference/skills-bundle.md`](reference/skills-bundle.md).
- **Distribution** phase (Section 9) — public-git, private-git, tarball, oneliner; trade-offs in [`reference/distribution-modes.md`](reference/distribution-modes.md).
- MCP server pre-configuration questions (`MCP_SERVERS` list).

### Changed
- Attribution and creator references generalized away from project-specific names — colleagues can fork without rewriting headers.

## [0.1.0] - 2026 — commit `03f09e9`

### Added
- Initial public release of Corporate Launcher.
- Interview-driven generator that wraps **Claude Code**, **Codex CLI**, **Gemini CLI**, **Aider**, **opencode**, **Continue.dev**.
- Provider matrix for AWS Bedrock / Azure OpenAI / Vertex AI / LiteLLM / OpenAI-compatible gateways ([`reference/provider-matrix.md`](reference/provider-matrix.md)).
- Corporate-proxy + custom-CA + VPN-gate scripts under [`templates/shared/`](templates/shared/).
- Cyber kill-switches: telemetry, auto-update, feedback commands, voice mode, prompt filter, cost tracking — documented in [`reference/env-vars.md`](reference/env-vars.md) and [`reference/security-patterns.md`](reference/security-patterns.md).
- Strip-proxy shims for Bedrock / LiteLLM SSE artefacts.
- Per-CLI launcher + install/uninstall templates under [`templates/{claude-code,codex-cli,gemini-cli,aider,opencode,continue-dev}/`](templates/).
- `BRANDING.md` template with custom system-prompt addendum, banner color, terminal title, forbidden-terms list.

[Unreleased]: https://github.com/your-org/corporate-launcher/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/your-org/corporate-launcher/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/your-org/corporate-launcher/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/your-org/corporate-launcher/releases/tag/v0.1.0
