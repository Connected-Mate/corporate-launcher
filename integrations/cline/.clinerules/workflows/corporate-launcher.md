# /corporate-launcher

Build a secure, branded, organization-specific launcher around an AI coding CLI (Claude Code, Codex CLI, Gemini CLI, Cursor, or Cline) so the user can:

1. Run it on their own corporate machine without breaching cyber/legal policy.
2. Ship it to their team — same gateway, same cyber rules, curated bundled skills, on day one.

## Phase 0 — Confirm intent

If the user only said "wrap claude for my company" with no detail, ask 1-2 quick clarifying questions:

- Which CLI to wrap? (Claude Code, Codex CLI, Gemini CLI, Cursor, Cline, Aider, opencode)
- Which backend gateway? (LiteLLM, Bedrock, Azure OpenAI, Vertex, custom OpenAI-compatible)

If both already named, skip to Phase 1.

## Phase 1 — Run the config interview

Walk through every section. Save answers to a session JSON in memory.

1. **Identity** — brand name, internal sponsor, license note
2. **Provider** — which CLI(s) to wrap (multi-launcher install supported)
3. **Backend** — gateway URL, auth model, region, model IDs, fallback
4. **Network** — VPN gate, corporate proxy, custom CA, no_proxy list
5. **Cyber** — telemetry kill switches, cost tracking, prompt filter
6. **Branding** — system prompt overrides, banner, terminal title, color theme
7. **Skills bundle** — which skills + MCP servers to include for colleagues
8. **Distribution** — public/private repo, tarball, one-liner URL

If user replies "I don't know" to a network/cyber question, mark `unknown`, generate sane default, and flag in post-install summary.

## Phase 2 — Validate

- Check every required field has a value (or sane default)
- Show one-screen recap
- Ask: "Generate the launcher? [y/N]"
- Do not generate without explicit confirmation.

## Phase 3 — Generate the launcher

For each selected CLI:

1. Pick matching folder under `templates/<cli-id>/`
2. Substitute every `${VAR}` via `scripts/render.py`
3. Write rendered files into install path
4. Render `shared/` modules (VPN check, proxy detect, cyber rules, cost tracker, prompt filter, strip-proxy)
5. Render skills bundle — clone or copy chosen skills under `<install>/skills/`
6. Set executable bits, chmod 600 on keychain fallback
7. Dry-run test (file exists, syntax valid, `--help` works)

## Phase 4 — Generate the distribution kit

- **Public/private git repo** — scaffold tree, `.gitignore`, `LICENSE`, `README.md`, `gh repo create --push` ready
- **Tarball** — `<slug>-<version>.tar.gz` + `SHA256SUMS`
- **One-liner URL** — hosted `install.sh` + checksum step
- **No distribution** — skip

## Phase 5 — Post-install

Print:

- exact local run command (`acme-copilot`, `pcode`, etc.)
- install path
- uninstall command
- distribution artifact (repo URL, tarball path, one-liner)
- follow-up checklist (API key not set, VPN required, RSSI sign-off pending)

## Quality bar

- Every templated file renders without `${UNRESOLVED}` left over
- Launcher `--help` works without launching the underlying CLI
- Dry-run with `<SLUG>_DRY_RUN=1` prints every env var and exits 0
- Uninstall removes every installed file plus the shell RC block (idempotent)
- System prompt rebrand hides every mention of the vendor and replaces with corporate brand
- Distribution kit includes checksum or signature when shipping via one-liner

## Anti-patterns

- Never call vendor's public API directly. Gateway is only allowed egress.
- Never store API key in plaintext or world-readable file. chmod 600, prefer keychain.
- Never disable SSL globally. Use process-scoped CA bundle env vars.
- Never modify `/etc/hosts` or system trust store.
- Never enable auto-update.
- Never ship `curl ... | bash` without checksum.
- Never bundle a skill from an unreviewed source.
