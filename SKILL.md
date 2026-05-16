---
name: corporate-launcher
description: Generates a secure, branded, organization-specific launcher that wraps any AI coding CLI (Claude Code, Codex CLI, Gemini CLI, Aider, opencode, Continue.dev) onto your corporate AI gateway. Use when a user says their company "does not authorize" Claude/Codex/Gemini/Cursor, wants a white-label CLI, needs a wrapper for AWS Bedrock / Azure OpenAI / Vertex AI / LiteLLM, must enforce corporate proxy + SSL inspection + custom CA, or mentions DSI / RSSI / cyber / DPO / compliance / Socle IA constraints. Triggers: "corporate launcher", "wrap claude code", "wrap codex", "wrap gemini", "white label", "marque blanche", "DSI gateway", "bedrock proxy", "azure openai cli", "vertex cli", "internal AI CLI".
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, Glob, Grep
---

# Corporate Launcher

Build a secure, branded, organization-specific launcher around any public AI coding CLI so an employee can use it on their corporate machine without breaching their cyber/legal policy.

The skill runs a structured interview ("DOG" — Document d'Orientation Générale, the corporate policy questionnaire), then generates a complete launcher tree on the user's machine: shell wrapper, install script, settings, branded system prompt, cyber rules, optional strip-proxy, uninstall script.

**Origin**: distilled from [Patrick Code](https://github.com/sncf-connect-tech) (SNCF's production launcher around Claude Code), generalized to any provider × any backend.

---

## When to use

Trigger this skill when the user wants any of:

- a wrapper that hides Claude/Codex/Gemini and re-brands it as `acmecorp-ai`, `pcode`, `bnp-copilot`, etc.
- their CLI to route only through their corporate gateway (Socle IA, LiteLLM, Azure OpenAI, Vertex, Bedrock)
- corporate proxy + SSL inspection + custom CA + VPN gate
- telemetry off, only first-party models from the chosen provider (no leak to a third party)
- a turnkey install for their team (one script, one config, one launcher)

Anti-trigger: do **not** trigger for a personal/hobby setup, a one-off API call, or generic shell scripting — those don't need this skill.

---

## Workflow (always follow in order)

### Phase 0 — Confirm intent (skip if obvious)

If the user only said "wrap claude for my company" with no detail, ask 1-2 quick clarifying questions via `AskUserQuestion`:
- Which CLI to wrap (Claude Code, Codex, Gemini CLI, Aider, opencode, Continue.dev)?
- Which backend gateway (LiteLLM, Bedrock, Azure OpenAI, Vertex, custom OpenAI-compatible)?

If they already named both in their initial message, skip to Phase 1.

### Phase 1 — Run the DOG interview

Read `reference/interview-flow.md` and walk through every section. Use `AskUserQuestion` for each step. Save answers to a session JSON in memory.

Sections in order:
1. **Identity** — brand name, internal sponsor, license note
2. **Provider** — which CLI to wrap (one or many — multi-launcher install supported)
3. **Backend** — gateway URL, auth model, region, model IDs, fallback
4. **Network** — VPN gate, corporate proxy, custom CA, no_proxy list
5. **Cyber** — telemetry kill switches, cost tracking, prompt filter (cyber-guard regex)
6. **Branding** — system prompt overrides, banner, terminal title, color theme
7. **Distribution** — install path, repo host, uninstall behavior

If the user replies "I don't know" to a network/cyber question, mark it `unknown` and continue — generate sane defaults and flag them in the post-install summary so the RSSI can review.

### Phase 2 — Validate the DOG

Before generating anything:
- check every required field has a value (or sane default)
- show a one-screen recap of the final config
- ask: "Generate the launcher? [y/N]"

Don't generate without explicit confirmation.

### Phase 3 — Generate the launcher

For each selected CLI:
1. Pick the matching folder under `templates/<cli-id>/`
2. Substitute every `${VAR}` with the DOG values via `scripts/render.py`
3. Write the rendered files into the install path
4. Render the `shared/` modules once (VPN check, proxy detect, cyber rules, cost tracker)
5. Set executable bits, chmod 600 on the API key store
6. Run a dry-run test (file exists, syntax valid)

### Phase 4 — Post-install

Print:
- the exact command the user runs to launch (`acmecorp-ai`, `pcode`, etc.)
- the path of the install
- the uninstall command
- a checklist of follow-ups (API key not yet set, VPN required, RSSI sign-off pending)

---

## Reference files (read on demand, not all at once)

- `reference/interview-flow.md` — the exhaustive DOG question script
- `reference/provider-matrix.md` — table of which CLI supports which backend, env vars, config files
- `reference/env-vars.md` — env vars per CLI and per backend (Claude/Codex/Gemini × Anthropic/Bedrock/Vertex/Azure/LiteLLM)
- `reference/security-patterns.md` — proxy detection, CA bundle, VPN gate, secret storage cross-OS
- `reference/examples/` — three filled-out examples (SNCF/Claude/Bedrock, ACME/Codex/Azure, Globex/Gemini/Vertex)

Read only what you need for the user's CLI + backend combo.

---

## Templates

Each `templates/<cli-id>/` contains:
- `launcher.sh.tpl` + `launcher.ps1.tpl` — the wrapper binary
- `install.sh.tpl` + `install.ps1.tpl` — the installer wizard
- `<cli-config>.tpl` — the CLI's native config (`settings.json`, `config.toml`, `config.yaml`)
- `BRANDING.md.tpl` — system prompt + identity rules (white-label)
- `uninstall.sh.tpl` — clean removal
- optional: `strip-proxy.js.tpl` — middleware to fix Bedrock/LiteLLM SSE artefacts (Claude Code only)

`templates/shared/` contains modules included by every launcher:
- `vpn-check.sh.tpl` — gate before launch
- `proxy-detect.sh.tpl` — set HTTP_PROXY only if reachable
- `secrets-store.sh.tpl` — keychain/credential-manager/secret-tool with chmod 600 fallback
- `cyber-rules.md.tpl` — 15-control corporate cyber baseline
- `cost-tracker.py.tpl` — EUR/USD cost log via SSE parse
- `pre-tool-hook.py.tpl` — regex prompt filter (PII, secrets, destructive command catcher)

---

## Rendering rules

`scripts/render.py` does plain `${VAR}` substitution. Conventions:
- All variables are uppercase snake_case (`CORP_NAME`, `LLM_PRIMARY_URL`, `PROXY_HOST`).
- Missing variable raises — never silently substitute empty string.
- A variable that should stay literal in the output (e.g. shell `${HOME}`) is escaped as `$\{HOME\}` in the template and unescaped at render time.
- Comments in templates start with `# tpl:` to mark template-only lines that are stripped from the output.

---

## Generated tree (example)

```
~/corporate-launcher-acme/
├── acmecorp-ai                  # the wrapper binary (chmod +x)
├── install.sh / install.ps1
├── uninstall.sh
├── BRANDING.md                  # injected via --append-system-prompt
├── cyber-rules.md               # appended to BRANDING.md
├── scripts/
│   ├── vpn-check.sh
│   ├── proxy-detect.sh
│   ├── strip-proxy.js           # if backend = Bedrock or LiteLLM
│   ├── cost-tracker.py
│   └── pre-tool-hook.py
├── settings.json                # CLI-native settings (hooks, MCP, perms)
└── README.md                    # internal team doc
```

User config (per-user, outside the repo):
- `~/.acmecorp-ai.conf` — API key store, chmod 600
- shell RC block `# >>> ACMECORP-AI >>>` ... `# <<< ACMECORP-AI <<<` adding the launcher to PATH

---

## Quality bar before reporting "done"

- Every templated file must render without `${UNRESOLVED}` left in the output.
- The launcher must `--help` cleanly without launching the underlying CLI.
- A dry-run of the launcher with `CORP_DRY_RUN=1` must print every env var it would set and exit 0.
- The uninstall must remove every file the install created, plus the shell RC block (idempotent).
- The system prompt rebrand must hide every mention of the underlying CLI vendor (Anthropic/OpenAI/Google) and replace with the corporate brand.

If any of these fails, fix it before declaring the install done.

---

## Anti-patterns (do not do)

- Don't generate a launcher that calls `api.anthropic.com` / `api.openai.com` / `generativelanguage.googleapis.com` directly. The corporate gateway is the only allowed egress.
- Don't store the API key in plaintext in the launcher itself or in a world-readable file. Always chmod 600, and prefer keychain/credential-manager when available.
- Don't disable SSL verification globally on the user's machine. Use `NODE_EXTRA_CA_CERTS` / `CODEX_CA_CERTIFICATE` / `REQUESTS_CA_BUNDLE` — process-scoped only.
- Don't modify `/etc/hosts`, `/etc/resolv.conf`, the system trust store, or any global config. Everything must be process-level + reversible by the uninstall.
- Don't ship Patrick Code's SNCF specifics verbatim — those are an example, not a template. Always re-run the DOG interview for the new tenant.
- Don't enable the underlying CLI's auto-update inside the corporate launcher (lock the version, or the next minor release may break the proxy/branding).
