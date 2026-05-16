---
name: corporate-launcher
description: Generates a secure, branded, organization-specific launcher that wraps Claude Code, Codex CLI, Gemini CLI, Cursor, or Cline onto a corporate AI gateway, then helps the user distribute it to their team. Triggers when a user says their company "does not authorize" Claude / Codex / Gemini / Cursor, asks for a white-label CLI for their team, needs a wrapper for AWS Bedrock / Azure OpenAI / Vertex AI / LiteLLM, must enforce corporate proxy + SSL inspection + custom CA, or wants to bundle a set of internal skills for colleagues. Trigger phrases include "corporate launcher", "wrap claude code", "wrap codex", "wrap gemini", "white-label cursor", "white-label cline", "internal AI CLI", "bedrock gateway", "azure openai cli", "vertex cli", "ship to my team", "internal copilot". Make sure to use this skill whenever the user mentions wanting to wrap, white-label, or deploy an AI coding CLI inside their organization — even if they don't explicitly name the launcher pattern.
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, Glob, Grep
when_to_use: Invoke when an employee of a regulated org (bank, telco, public sector, defense, healthcare) needs an AI coding CLI but cannot use the vendor's public endpoint. The deliverable is always a runnable, branded launcher plus a distribution kit for colleagues — not just shell scripts or a one-off API call. Pair with a corporate gateway (Bedrock, Azure OpenAI, Vertex, LiteLLM).
---

# Corporate Launcher

Build a secure, branded, organization-specific launcher around Claude Code, Codex CLI, or Gemini CLI so the creator can:

1. Run it on their own corporate machine without breaching cyber/legal policy.
2. **Ship it to their team** — with the same gateway, the same cyber rules, and a curated set of bundled skills, on day one.

The skill runs a structured interview, then generates a complete launcher tree plus a distribution kit (git repo, tarball, or one-liner URL).

---

## When to use

Trigger this skill when the user wants any of:

- a wrapper that hides Claude / Codex / Gemini and re-brands it as `acmecorp-ai`, `bnp-copilot`, `globex-helper`, etc.
- their CLI to route only through their corporate gateway (LiteLLM, Azure OpenAI, Vertex, Bedrock)
- corporate proxy + SSL inspection + custom CA + VPN gate
- telemetry off, only first-party models from the chosen provider
- a turnkey install for their team (one script, one config, one launcher)
- a curated set of skills (design pack, internal review skill, MCP servers) shipped inside the launcher

Anti-trigger: do **not** trigger for a personal/hobby setup, a one-off API call, or generic shell scripting.

---

## Workflow (always follow in order)

### Phase 0 — Confirm intent (skip if obvious)

If the user only said "wrap claude for my company" with no detail, ask 1-2 quick clarifying questions via `AskUserQuestion`:
- Which CLI to wrap (Claude Code, Codex CLI, Gemini CLI, Aider, opencode)?
- Which backend gateway (LiteLLM, Bedrock, Azure OpenAI, Vertex, custom OpenAI-compatible)?

If they already named both, skip to Phase 1.

### Phase 1 — Run the config interview

Read `references/interview-flow.md` and walk through every section. Use `AskUserQuestion` for each step. Save answers to a session JSON in memory.

Sections in order:

1. **Identity** — brand name, internal sponsor, license note
2. **Provider** — which CLI(s) to wrap (multi-launcher install supported)
3. **Backend** — gateway URL, auth model, region, model IDs, fallback
4. **Network** — VPN gate, corporate proxy, custom CA, no_proxy list
5. **Cyber** — telemetry kill switches, cost tracking, prompt filter
6. **Branding** — system prompt overrides, banner, terminal title, color theme
7. **Skills bundle** — which skills + MCP servers to include for colleagues
8. **Distribution** — how to ship the launcher to the team (public/private repo, tarball, one-liner)

If the user replies "I don't know" to a network/cyber question, mark it `unknown` and continue — generate sane defaults and flag them in the post-install summary so the security office can review.

### Phase 1.5 — Probe the gateway

> Why: catches typos in URL, expired tokens, missing models, TLS issues before the user invests time in the rest of the interview.

> What: invokes `scripts/api-probe.py` with the user's URL + token. Reports reachable / unreachable, models catalog, latency, TLS cert.

> If the probe fails, the skill should pause and ask: "Continue anyway, or revise the answer?" — never silently proceed with a known-broken gateway.

### Phase 2 — Validate

Before generating anything:
- check every required field has a value (or sane default)
- show a one-screen recap
- ask: "Generate the launcher? [y/N]"

Don't generate without explicit confirmation.

### Phase 3 — Generate the launcher

For each selected CLI:
1. Pick the matching folder under `templates/<cli-id>/`
2. Substitute every `${VAR}` with the answers via `scripts/render.py`
3. Write the rendered files into the install path
4. Render the `shared/` modules once (VPN check, proxy detect, cyber rules, cost tracker, prompt filter, strip-proxy if needed)
5. Render the **skills bundle** — clone or copy the chosen skills under `<install>/skills/`
6. Set executable bits, chmod 600 on the keychain fallback file
7. Run a dry-run test (file exists, syntax valid, `--help` works)

### Phase 3.5 — Self-audit the generated launcher

> Why: the user may not have known every cyber requirement. The skill must verify its own output before declaring success.

> What: runs `scripts/audit-launcher.py` against the rendered tree. 30+ rules (no vendor URLs, no plain secrets, VPN check present, telemetry kill switches all set, etc.). Prints findings ranked P0/P1/P2.

> The skill should present findings interactively: "Here are 3 things I noticed — want me to fix them, ask you, or leave as-is?"

### Phase 3.6 — URL purge sweep

> Defense in depth: a second pass that specifically catches vendor URLs leaked anywhere outside the explicit deny lists.

### Phase 3.7 — Pixel-art banner

> Generate the launcher's startup banner via `scripts/pixel-art-logo.py`. Saved to `<install_dir>/banner.txt`; the launcher's show_banner() prints it at every launch.

### Phase 4 — Generate the distribution kit

Based on the chosen distribution mode:
- **Public / private git repo** — scaffold a clean tree, `.gitignore`, `LICENSE`, `README.md`, with `gh repo create --push` ready to fire.
- **Tarball** — `<slug>-<version>.tar.gz` + `SHA256SUMS`.
- **One-liner URL** — emit a hosted `install.sh` plus the exact `curl ... | bash` command to share. Includes a checksum step.
- **No distribution** — skip.

See `references/distribution-modes.md` for the security caveats of each mode.

### Phase 4.5 — Compliance .docx

> If the user wants to share the launcher's compliance posture with their RSSI/CISO, generate `compliance.docx` ready to send. 10-section Word document covering architecture, threat model, cyber controls, network perimeter, audit log, offboarding.

### Phase 5 — Post-install

Print:
- the exact command the user runs locally (`acmecorp-ai`, `pcode`, etc.)
- the install path
- the uninstall command
- the **distribution artifact** (repo URL, tarball path, or one-liner) the user shares with their team
- a checklist of follow-ups (API key not yet set, VPN required, RSSI sign-off pending)

> "Made for friends · Made from France with ❤️"

---

## Reference files (read on demand)

- `references/interview-flow.md` — exhaustive question script with the 9 sections
- `references/provider-matrix.md` — which CLI supports which backend
- `references/env-vars.md` — env vars per CLI per backend
- `references/security-patterns.md` — proxy detection, CA bundle, VPN gate, secret storage
- `references/skills-bundle.md` — how the skills bundling works, presets available
- `references/distribution-modes.md` — the 4 distribution modes and their trade-offs
- `references/api-probe.md` — pre-flight gateway probe (reachability, models, TLS, latency)
- `references/self-audit.md` — 30+ rule audit of the rendered launcher tree, P0/P1/P2 findings
- `references/url-purge.md` — second-pass sweep for leaked vendor URLs outside deny lists
- `references/compliance-docx.md` — 10-section Word document for RSSI/CISO sign-off
- `references/pixel-art-logo.md` — startup banner generator saved to `<install_dir>/banner.txt`
- `references/load-testing.md` — sustained-throughput and concurrency checks for the gateway
- `references/examples/` — three filled-out examples (Claude/LiteLLM, Codex/Azure, Gemini/Vertex)

Read only what you need for the user's CLI + backend + distribution combo.

---

## Templates

Each `templates/<cli-id>/` contains:
- `launcher.sh.tpl` — the wrapper binary
- `install.sh.tpl` — the installer wizard
- `<cli-config>.tpl` — the CLI's native config (`settings.json`, `config.toml`, `config.yaml`)
- `BRANDING.md.tpl` — system prompt + identity rules
- `uninstall.sh.tpl` — clean removal

`templates/shared/` contains modules included by every launcher:
- `vpn-check.sh.tpl` — gate before launch
- `proxy-detect.sh.tpl` — set HTTP_PROXY only if reachable
- `secrets-store.sh.tpl` — keychain / credential-manager / secret-tool with chmod 600 fallback
- `cyber-rules.md.tpl` — 15-control corporate cyber baseline
- `cost-tracker.py.tpl` — local cost log via SSE parse
- `pre-tool-hook.py.tpl` — regex prompt filter (secrets, destructive commands)
- `strip-proxy.js.tpl` — middleware that fixes Bedrock/LiteLLM SSE artefacts (Claude Code only)

---

## Rendering rules

`scripts/render.py` does plain `${VAR}` substitution.
- All variables are uppercase snake_case (`CORP_NAME`, `LLM_PRIMARY_URL`, `PROXY_HOST`).
- Missing variable raises — never silently substitute empty string.
- A `${...}` that should stay literal in the output (e.g. shell `${HOME}`) is escaped as `$\{HOME\}` in the template and unescaped at render time.
- Lines starting with `# tpl:` (or `// tpl:`) are stripped from the output.

---

## Generated tree (example)

```
~/.local/share/acme-copilot/
├── acme-copilot                  ← the wrapper binary (chmod +x)
├── install.sh / uninstall.sh
├── BRANDING.md                   ← injected via --append-system-prompt
├── cyber-rules.md                ← appended to BRANDING.md
├── settings.json                 ← CLI-native settings (hooks, MCP, perms)
├── skills/                       ← bundled skills for colleagues
│   ├── design-pack/...
│   └── internal-security-review/...
└── scripts/
    ├── vpn-check.sh
    ├── proxy-detect.sh
    ├── strip-proxy.js            ← if backend = Bedrock or LiteLLM
    ├── cost-tracker.py
    └── pre-tool-hook.py
```

Per-user config (outside the repo):
- `~/.acme-copilot.conf` — chmod 600 fallback (used only if no keychain is available)
- shell RC block `# >>> acme-copilot >>>` ... `# <<< acme-copilot <<<`

Distribution kit (separate output):
- `dist/acme-copilot-1.0.0.tar.gz` + `dist/SHA256SUMS`, or
- `dist/repo/` — git-ready tree, or
- `dist/install.sh` + the one-liner string `curl https://acme.internal/install.sh | bash`

---

## Quality bar before reporting "done"

- Every templated file must render without `${UNRESOLVED}` left in the output.
- The launcher must `--help` cleanly without launching the underlying CLI.
- A dry-run with `<SLUG>_DRY_RUN=1` must print every env var it would set and exit 0.
- The uninstall must remove every file the install created, plus the shell RC block (idempotent).
- The system prompt rebrand must hide every mention of the underlying CLI vendor and replace with the corporate brand.
- The distribution kit must include a checksum or signature when shipping via a one-liner.

If any of these fails, fix it before declaring the install done.

---

## Anti-patterns (and the positive rule that replaces them)

Each rule is phrased as an imperative, with the *because* that justifies it. If a rule conflicts with the user's environment, surface the conflict in the post-install summary instead of silently breaking it.

- **Route every request through the corporate gateway** (Bedrock, Azure OpenAI, Vertex, LiteLLM) — never call the vendor's public API directly, *because the corporate gateway is the only contractually-authorized egress* and direct calls bypass DLP, billing attribution, and the legal review the org already signed off on.
- **Store the API key in the OS keychain, with a `chmod 600` dotfile fallback** — never plaintext, never world-readable, *because `chmod 600` + keychain is the documented baseline that the cyber sign-off relies on*; a world-readable key is treated as a leaked key.
- **Scope SSL trust to the process** via `NODE_EXTRA_CA_CERTS` / `CODEX_CA_CERTIFICATE` / `REQUESTS_CA_BUNDLE` — never disable SSL verification globally, *because the corporate CA must be trusted only by the launcher, not by every other tool on the host*; a global toggle is a foot-gun the security team will refuse to ship.
- **Keep every change process-level and reversible by `uninstall.sh`** — never touch `/etc/hosts`, the system trust store, or any global config, *because the uninstall must restore the machine to its pre-install state without root* so endpoint management tools don't flag drift.
- **Lock the wrapped CLI to a pinned version** — never enable the underlying CLI's auto-update inside the launcher, *because an unannounced upstream change can break the brand override, the SSE strip-proxy, or the cyber rules*; upgrades go through a controlled bump + re-distribution.
- **Ship the one-liner with a checksum or signature step** (`SHA256SUMS`, cosign, or minisign) — never publish a bare `curl ... | bash`, *because without integrity verification, a compromised host or MITM can swap the installer* and every colleague becomes a foothold.
- **Bundle only skills the user has reviewed** (or that come from a vetted internal source) — never pull from a random public repo at install time, *because the cyber team needs an audit trail* for every prompt, hook, and MCP server that runs on a corporate machine.
