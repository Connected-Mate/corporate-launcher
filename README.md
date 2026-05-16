<div align="center">

# Corporate Launcher

**Build a secure, branded, organization-specific launcher around any AI coding CLI — in minutes.**

*A Claude Code skill that turns a 10-question interview into a turnkey corporate wrapper.*

[Why](#why) · [What it does](#what-it-does) · [Install](#install) · [How it works](#how-it-works) · [Supported CLIs](#supported-clis) · [Examples](#examples) · [FAQ](#faq) · [Origin](#origin-patrick-code-sncf)

</div>

---

## Why

Most large organizations don't allow employees to install Claude Code, Codex CLI, or Gemini CLI as-is. The reasons are valid:

- The default endpoints leak prompts to the vendor's public infrastructure.
- The CLI brand is wrong for an internal product.
- Telemetry / auto-update / feedback commands violate the corporate cyber policy.
- The corporate API gateway (Socle IA, LiteLLM, Azure OpenAI, Vertex, Bedrock, ...) needs proxy + custom CA + VPN gating that a `brew install` won't set up.
- The legal team wants a clear answer to "which models, on which infrastructure, billed to whom".

So either employees go without — or someone builds a wrapper. Internally, the wrapper takes weeks to design, a quarter to harden, and rots the day the underlying CLI publishes a new env var.

**Corporate Launcher is the wrapper, distilled.** It encodes years of production lessons from [Patrick Code](#origin-patrick-code-sncf) (SNCF's launcher around Claude Code) into a skill any team can run on their workstation.

```
You:  /corporate-launcher
Skill: What's the brand name?
You:  ACME Copilot
Skill: Which CLI? [Claude Code / Codex / Gemini / Aider / opencode / Continue.dev]
You:  Claude Code
Skill: Which gateway?
You:  https://litellm.acme.internal
...
Skill: Generate the launcher? [y/N]
You:  y
Skill: Done. Run: acme-copilot
```

---

## What it does

In the **same shell session**, the skill:

1. Runs a structured interview — the "DOG" (Document d'Orientation Générale) — covering identity, provider, backend, network, cyber, branding, distribution.
2. Validates the answers, defaults the unknowns, and shows you a one-screen plan.
3. Generates a complete launcher tree on your machine:
   - the wrapper binary (`acme-copilot`, `pcode`, ...)
   - the install / uninstall scripts
   - the white-label system prompt (BRANDING.md)
   - the 15-control cyber-rules markdown
   - per-CLI settings file (`settings.json` / `config.toml` / `config.yaml`)
   - the shared modules: VPN check, proxy detection, secret storage, cost tracker, prompt filter, strip-proxy (when needed)
4. Wires everything into the user's shell RC with an idempotent `# >>> name >>>` block.
5. Stores the API token in the OS keychain (macOS Keychain / Windows Credential Manager / Linux libsecret), with a `chmod 600` file as fallback.
6. Prints the exact command to launch + a working `--status` diagnostic.

Nothing it does is irreversible. The uninstall command removes every file, restores the shell RC from backup, stops the strip-proxy, deletes the keychain entry.

---

## Install

The skill is meant to live in your Claude Code skills directory.

```bash
git clone https://github.com/Alex-Connected-Mate/corporate-launcher.git ~/.claude/skills/corporate-launcher
```

Then in any Claude Code session:

```
> /corporate-launcher
```

Or just ask in natural language — the skill description triggers on phrases like *"wrap claude for my company"*, *"my employer doesn't allow Claude Code"*, *"build me an internal launcher for Codex on Azure"*.

> **Requirements**: Claude Code, Python 3.10+, Node.js 18+. The wrapped CLI gets installed by the generated `install.sh` if it's not present.

---

## How it works

```
┌────────────────────────────────────────────────────────────────────────┐
│  USER                                                                  │
│   │                                                                    │
│   ▼                                                                    │
│  Claude Code  ──invokes──▶  corporate-launcher (SKILL.md)              │
│                                  │                                     │
│                                  ▼                                     │
│                          interview-flow.md  ──questions──▶  USER       │
│                                  │                                     │
│                                  ▼                                     │
│                          DOG answers (JSON)                            │
│                                  │                                     │
│                                  ▼                                     │
│                          scripts/render.py   ──reads──▶  templates/    │
│                                  │                                     │
│                                  ▼                                     │
│                          ~/.local/share/${CORP_SLUG}/                  │
│                          + shell RC block                              │
│                          + OS keychain entry                           │
│                                  │                                     │
│                                  ▼                                     │
│                          $ ${CORP_SLUG}                                │
│                          (launches the wrapped CLI)                    │
└────────────────────────────────────────────────────────────────────────┘
```

The wrapper at runtime:

```
$ acme-copilot
  ▶ source vpn-check.sh         ── probes internal-only URL, fails fast if off-VPN
  ▶ source proxy-detect.sh      ── exports HTTP_PROXY only if reachable
  ▶ source secrets-store.sh     ── loads API token from keychain
  ▶ ensure_strip_proxy           ── starts middleware on 127.0.0.1:9876 (if Bedrock/LiteLLM)
  ▶ export 20+ env vars         ── gateway URL, model, telemetry kill switches
  ▶ exec claude --append-system-prompt-file BRANDING.md --append-system-prompt-file cyber-rules.md
```

Nothing is globally installed. Every env var is scoped to the launcher process. The system trust store is never modified. `/etc/hosts` is never touched.

---

## Supported CLIs

| CLI | Tier | Backends | Status |
|---|---|---|---|
| **Claude Code** | S | Anthropic, AWS Bedrock, Google Vertex, MS Foundry, LiteLLM | ✅ full templates + strip-proxy |
| **Codex CLI** (OpenAI) | A | OpenAI, Azure OpenAI, AWS Bedrock | ✅ full templates + admin lockdown |
| **Gemini CLI** (Google) | S | AI Studio, Vertex AI Enterprise | ✅ full templates + ADC auth |
| **Aider** | S | OpenAI / Anthropic / Azure / Bedrock / Vertex via LiteLLM | ✅ full templates |
| **opencode** | S | Same as Aider | ✅ full templates |
| **Continue.dev** | A | Same as Aider | 🔧 config.yaml only |
| Cursor | B | — | ❌ GUI-only, requires HTTPS-public gateway |
| Windsurf | B | — | ❌ requires self-host infra |
| Tabnine Enterprise | B | — | ❌ admin GUI server-side |

Tier S = wrap trivial, full ENV-driven. Tier A = wrap moderate, requires a pre-deployed config. Tier B = out of scope for a shell launcher.

---

## Examples

Three filled-out examples ship under `reference/examples/`:

- [`sncf-patrick-code.md`](reference/examples/sncf-patrick-code.md) — the reference: SNCF / Claude Code / LiteLLM-on-Bedrock with strip-proxy
- [`acme-codex-azure.md`](reference/examples/acme-codex-azure.md) — Codex CLI on Azure OpenAI with admin lockdown
- [`globex-gemini-vertex.md`](reference/examples/globex-gemini-vertex.md) — Gemini CLI on Vertex AI with EU data residency and ADC auth

Each file contains the JSON DOG answers + a "why those choices" commentary. The fastest way to learn the skill is to read them.

---

## FAQ

**Q: Does this replace `claude` / `codex` / `gemini`?**
A: No. The launcher *wraps* them. The underlying CLI is installed normally; the launcher just sets the right env vars before exec.

**Q: Can a user bypass it?**
A: A determined power-user can always `unset` env vars. The launcher is a usability and policy device, not a security perimeter. The actual perimeter is the corporate gateway (only known tokens accepted) and the cyber-guard hook (denies destructive commands even under `bypassPermissions`).

**Q: What about MCP servers?**
A: The generated `settings.json` ships with an empty `mcpServers` block. Add yours through the normal `claude mcp add` flow. For Codex CLI, MCP allowlist is managed by `requirements.toml`.

**Q: Does it ship a strip-proxy by default?**
A: Only for Claude Code on Bedrock or LiteLLM, where 4 known SSE artefacts would crash the CLI parser. For Anthropic-direct, Vertex, Foundry, and the other CLIs, the launcher talks to the gateway directly.

**Q: What about Windows?**
A: PowerShell templates ship alongside bash. Tested on Windows 11 + PowerShell 7+ and WSL2. Native cmd.exe is not supported.

**Q: How do I update the underlying CLI?**
A: The auto-updater is disabled by default. Re-run the launcher's `install.sh` (or `--update` flag) to pull a newer CLI version and re-validate compatibility.

**Q: What about cost tracking?**
A: A JSONL log of every request is written under `/tmp/${CORP_SLUG}-usage.jsonl`. Run `${CORP_SLUG} --cost session|today|history` to summarize in your chosen currency. Pricing tables live in `templates/shared/cost-tracker.py.tpl` — adjust to match your contracted rates.

---

## Origin: Patrick Code (SNCF)

This skill is a generalization of [Patrick Code](https://github.com/sncf-connect-tech) — a production launcher built at SNCF, used daily by the engineering teams of Europe's largest passenger rail operator. Patrick Code wraps Claude Code on top of *Socle IA SNCF* (an internal LiteLLM-on-Bedrock gateway) and ships with:

- white-label identity ("Patrick", named after the very first TGV train)
- 15-control cyber baseline from Direction Cybersécurité SNCF
- 23 design skills (Emil + Impeccable + Taste)
- per-session cost tracking in EUR
- a strip-proxy middleware that fixes the SSE artefacts emitted by LiteLLM-on-Bedrock

Patrick Code shipped in production, passed RSSI / DSI / DPO review, and is in active use. The Corporate Launcher skill distills that work into a general-purpose generator so other teams don't have to start from zero.

---

## License

MIT — see [LICENSE](LICENSE). Patrick Code remains the property of SNCF; only the abstracted patterns are reused here.

## Contributing

Issues, PRs, and new CLI templates welcome. If you ship a Corporate Launcher in your org, send a 1-paragraph case study — the more examples, the better the skill gets at the interview phase.

---

<div align="center">

**Built by [ConnectedMate](https://github.com/Alex-Connected-Mate).**

Released after evangelizing Patrick Code: a corporate launcher pattern that should be a commodity, not a quarterly project.

</div>
