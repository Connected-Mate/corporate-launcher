Build a secure, branded, organization-specific launcher around an AI coding CLI (Claude Code, Codex CLI, Gemini CLI, Cursor, or Cline) so the user can:

1. Run it on their own corporate machine without breaching cyber/legal policy.
2. Ship it to their team — same gateway, same cyber rules, curated bundled skills, on day one.

## Phase 0 — Confirm intent

If only "wrap claude for my company" with no detail, ask 1-2 quick clarifying questions:
- Which CLI to wrap? (Claude Code, Codex CLI, Gemini CLI, Cursor, Cline, Aider, opencode)
- Which backend gateway? (LiteLLM, Bedrock, Azure OpenAI, Vertex, custom OpenAI-compatible)

If both already named, skip to Phase 1.

## Phase 1 — Run the config interview

Walk every section. Save answers to a session JSON in memory.

1. **Identity** — brand name, internal sponsor, license note
2. **Provider** — which CLI(s) to wrap
3. **Backend** — gateway URL, auth, region, model IDs, fallback
4. **Network** — VPN gate, proxy, custom CA, no_proxy
5. **Cyber** — telemetry kill switches, cost tracking, prompt filter
6. **Branding** — system prompt overrides, banner, terminal title
7. **Skills bundle** — which skills + MCP servers to include
8. **Distribution** — public/private repo, tarball, one-liner

"I don't know" → mark `unknown`, sane default, flag in post-install.

## Phase 2 — Validate

- Check every required field
- One-screen recap
- Ask "Generate? [y/N]" — don't generate without explicit y.

## Phase 3 — Generate the launcher

For each selected CLI:
1. Pick `templates/<cli-id>/`
2. Substitute `${VAR}` via `scripts/render.py`
3. Write rendered files into install path
4. Render `shared/` modules
5. Render skills bundle
6. Set chmod bits, 600 on keychain fallback
7. Dry-run test

## Phase 4 — Distribution kit

Public/private repo, tarball + SHA256SUMS, one-liner URL with checksum, or skip.

## Phase 5 — Post-install

Print: run command, install path, uninstall command, distribution artifact, follow-up checklist.

## Anti-patterns

- Never call vendor's public API directly.
- Never store API key in plaintext.
- Never disable SSL globally.
- Never modify `/etc/hosts` or system trust store.
- Never enable auto-update.
- Never ship `curl ... | bash` without checksum.
- Never bundle an unreviewed skill.

## Canonical instructions

Read the full workflow, templates, and reference files from the repo root `SKILL.md`:
https://github.com/Connected-Mate/corporate-launcher
