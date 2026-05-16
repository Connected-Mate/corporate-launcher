<div align="center">

# Corporate Launcher

**A Claude Code skill that builds a secure, branded corporate launcher around Claude Code, Codex CLI, or Gemini CLI — and helps you ship it to your team.**

[Why](#why) · [What it does](#what-it-does) · [Install](#install) · [How it works](#how-it-works) · [Skills bundle](#skills-bundle) · [Distribution](#distribution) · [Examples](#examples) · [FAQ](#faq) · [A word from the creator](#a-word-from-the-creator)

</div>

---

## Why

Most large organizations don't allow employees to install Claude Code, Codex CLI, or Gemini CLI as-is. The reasons are valid:

- The default endpoints leak prompts to the vendor's public infrastructure.
- The CLI brand is wrong for an internal product.
- Telemetry, auto-update, and feedback commands violate the corporate cyber policy.
- The corporate AI gateway (LiteLLM, Azure OpenAI, Vertex, Bedrock, ...) needs proxy + custom CA + VPN gating that a `brew install` won't set up.
- The legal team wants a clear answer to "which models, on which infrastructure, billed to whom".

So either employees go without — or someone builds a wrapper. Internally, the wrapper takes weeks to design, a quarter to harden, and rots the day the underlying CLI publishes a new env var.

**Corporate Launcher is that wrapper, made repeatable.**

```
You:  /corporate-launcher
Skill: What's the brand name of your launcher?
You:  ACME Copilot
Skill: Which CLI do you want to wrap? [Claude Code / Codex CLI / Gemini CLI]
You:  Claude Code
Skill: Which gateway URL? Which models? Which proxy?
You:  ...
Skill: Which skills should ship inside it for your colleagues?
You:  Design pack + our internal security-review skill
Skill: How do you want to distribute it to your team?
You:  Private GitHub repo + one-liner install URL
Skill: Generate? [y/N]
You:  y
Skill: Done. Run "acme-copilot" yourself, and share this URL with your team:
       https://acme.internal/install
```

---

## What it does

In one Claude Code session, the skill:

1. **Asks you the questions** — identity, provider, backend, network, cyber, branding, skills bundle, distribution.
2. **Validates** the answers, defaults the unknowns, and shows you a one-screen plan.
3. **Generates the launcher tree** on your machine:
   - the wrapper binary (`acme-copilot`, your name, your slug)
   - the install + uninstall scripts
   - the white-label system prompt (BRANDING.md)
   - the 15-control cyber rules
   - the CLI's native config (`settings.json` / `config.toml` / `config.yaml`)
   - the shared modules: VPN check, proxy detection, secret storage, cost tracker, prompt filter, strip-proxy (when needed)
   - the **bundled skills** (design pack, custom skills, MCP servers) you chose for your team
4. **Wires the shell** with an idempotent `# >>> name >>>` block.
5. **Stores the token** in the OS keychain (macOS Keychain / Windows Credential Manager / Linux libsecret), with `chmod 600` fallback.
6. **Generates the distribution kit** — git repo scaffold, install one-liner, or tarball — so you can hand the launcher to your team without re-running the skill yourself.

Nothing is irreversible. The uninstaller restores every file and the shell RC from backup.

---

## Install

The skill lives in your Claude Code skills directory.

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git \
    ~/.claude/skills/corporate-launcher
```

Then in any Claude Code session:

```
> /corporate-launcher
```

Or just ask in natural language — the skill description triggers on phrases like *"wrap claude for my company"*, *"my employer doesn't allow Claude Code"*, *"build me an internal launcher for Codex on Azure"*, *"I need a white-label CLI for my team"*.

> **Requirements**: Claude Code, Python 3.10+, Node.js 18+. The wrapped CLI gets installed by the generated `install.sh` if it's not present.

---

## How it works

```
┌────────────────────────────────────────────────────────────────────────┐
│  YOU (creator) talk to Claude Code                                     │
│       │                                                                │
│       ▼                                                                │
│  /corporate-launcher  (skill loaded)                                   │
│       │                                                                │
│       ▼                                                                │
│  Structured interview → JSON config                                    │
│       │                                                                │
│       ▼                                                                │
│  render.py walks templates/, substitutes ${VAR}                        │
│       │                                                                │
│       ▼                                                                │
│  ~/.local/share/<your-slug>/                                           │
│  ├── <your-slug>              ← the wrapper binary                     │
│  ├── install.sh / uninstall.sh                                         │
│  ├── BRANDING.md + cyber-rules.md                                      │
│  ├── settings.json (CLI-native)                                        │
│  ├── skills/                  ← bundled for your colleagues            │
│  └── scripts/                 ← VPN/proxy/secrets/cost/filter          │
│       │                                                                │
│       ▼                                                                │
│  Distribution kit (git repo, tarball, or one-liner URL)                │
│       │                                                                │
│       ▼                                                                │
│  YOUR COLLEAGUES run the install one-liner — they get the same         │
│  launcher, the same skills, the same cyber rules, on day one.          │
└────────────────────────────────────────────────────────────────────────┘
```

At runtime the wrapper sources the shared modules, sets ~20 env vars, optionally starts a strip-proxy on `127.0.0.1:9876` (Bedrock/LiteLLM only), then `exec`s the underlying CLI with `--append-system-prompt-file BRANDING.md`. Nothing is globally installed. Every env var is scoped to the launcher process. The system trust store is never modified.

---

## Skills bundle

When you build a launcher for your team, you choose which skills travel inside it. The skill asks you a single question:

```
Which skills do you want to bundle for your colleagues?

  [1] None — bare wrapper only
  [2] Design pack (50+ UI/UX skills: layout, typography, color, animation, audit, polish, ...)
  [3] Pick from a curated list (one-by-one)
  [4] From a git repo URL — your own internal monorepo of skills
  [5] From a local folder — what's already on this machine
```

Picking option 4 lets you maintain a private skill catalog inside your company. The generated `install.sh` clones (or pulls) that repo into `~/.claude/skills/` for every colleague who installs the launcher.

You can also pre-configure MCP servers the same way: the launcher's `settings.json` ships with your team's MCP server list, so day-one developers get the right context (Jira, GitHub Enterprise, your internal docs).

See [`reference/skills-bundle.md`](reference/skills-bundle.md) for the full options.

---

## Distribution

Once your launcher is generated locally, the skill asks:

```
How do you want to ship this to your team?

  [1] Public GitHub repo            — best for open evangelism
  [2] Private GitHub / GitLab repo  — most common for internal use
  [3] Tarball + internal artifact registry (Nexus, Artifactory)
  [4] One-liner install URL          — host install.sh on your intranet
  [5] No distribution — local only for now
```

For each option, the skill generates the matching artifacts:

- **GitHub repo** → a clean tree, `.gitignore`, `LICENSE`, ready to `gh repo create --push`.
- **Tarball** → `<slug>-<version>.tar.gz` with a `SHA256SUMS` file you can publish.
- **One-liner** → a checked, signed `install.sh` and the exact `curl ... | bash` command to share. Includes a `--verify-checksum` step so users don't run an untrusted blob.

The generated install one-liner is the same install script you ran locally — your colleagues land on the **same** launcher, with the **same** skills, the **same** cyber rules, and a fresh token prompted from the keychain.

See [`reference/distribution-modes.md`](reference/distribution-modes.md) for the security caveats of each mode.

---

## Supported CLIs

| CLI | Tier | Backends |
|---|---|---|
| **Claude Code** | S | Anthropic, AWS Bedrock, Google Vertex, MS Foundry, LiteLLM |
| **Codex CLI** (OpenAI) | A | OpenAI, Azure OpenAI, AWS Bedrock |
| **Gemini CLI** (Google) | S | AI Studio, Vertex AI Enterprise |
| **Aider** | S | OpenAI / Anthropic / Azure / Bedrock / Vertex via LiteLLM |
| **opencode** | S | Same as Aider |

Tier S = wrap trivial, full env-var driven. Tier A = wrap moderate, requires a pre-deployed config file. The first three are the recommended path — they're the most mature, the most documented, and the most likely to satisfy a corporate review.

---

## Examples

Three filled-out examples ship under [`reference/examples/`](reference/examples/):

- [`acme-claude-litellm.md`](reference/examples/acme-claude-litellm.md) — Claude Code on a LiteLLM-on-Bedrock gateway with strip-proxy
- [`acme-codex-azure.md`](reference/examples/acme-codex-azure.md) — Codex CLI on Azure OpenAI with admin lockdown
- [`globex-gemini-vertex.md`](reference/examples/globex-gemini-vertex.md) — Gemini CLI on Vertex AI with EU data residency and ADC auth

Each file contains the JSON config + a "why those choices" commentary. Reading them is the fastest way to learn the skill.

---

## FAQ

**Does this replace `claude` / `codex` / `gemini`?**
No. The launcher wraps them. The underlying CLI is installed normally; the launcher sets the right env vars before `exec`.

**Can a user bypass it?**
A determined power user can always `unset` env vars. The launcher is a usability and policy device, not a security perimeter. The actual perimeter is the corporate gateway (only known tokens accepted) and the cyber-guard hook (denies destructive commands even under `bypassPermissions`).

**What about MCP servers?**
The generated `settings.json` ships with an empty `mcpServers` block, or with the list you chose in the skills-bundle step. For Codex CLI, the MCP allowlist is managed by `requirements.toml`.

**Does it ship a strip-proxy by default?**
Only for Claude Code on Bedrock or LiteLLM, where 4 known SSE artefacts crash the CLI parser. For Anthropic-direct, Vertex, Foundry, and the other CLIs, the launcher talks to the gateway directly.

**What about Windows?**
PowerShell templates are on the roadmap. Today: Windows via WSL2 is supported. Native cmd.exe is not.

**How do I update the underlying CLI?**
The auto-updater is disabled by default. Re-run the launcher's `install.sh --update` to pull a newer CLI version and re-validate compatibility.

**How is cost tracked?**
A JSONL log of every request is written under `/tmp/<slug>-usage.jsonl`. Run `<slug> --cost session|today|history` to summarize in your chosen currency. The pricing table lives in `templates/shared/cost-tracker.py.tpl` — adjust it to match your contracted rates.

**Is my team locked into Claude Code as the host?**
No. The launcher you ship is standalone — your colleagues don't need to install Claude Code to use it. Only **you**, the creator, need Claude Code to *build* the launcher.

---

## A word from the creator

Hi — I'm **Alexandre Meret** ([ConnectedMate](https://github.com/Connected-Mate)).

I built this skill because I needed it at work. My employer wouldn't authorize the public AI coding CLIs as-is, so I built an internal launcher for my team — gated VPN, corporate gateway, white-label identity, telemetry off, the works. It ran in production for a while, and after a few months I realized the pattern is generic. Every large org has the same gateway, the same cyber rules, the same need to re-brand. The work is mostly the same; only the names change.

So instead of keeping it closed, I extracted the pattern into a Claude Code skill — open, free, and tenant-agnostic. You answer a handful of questions, the skill generates your launcher, you decide which skills to bundle for your team, and you ship it however you ship internal tools.

If you adopt it, ship something with it, or hit a sharp edge, please open an issue — the more case studies the skill sees, the better the interview gets.

— Alex

---

## License

MIT — see [LICENSE](LICENSE). Use it, fork it, ship your own.

## Contributing

Issues, PRs, and new CLI templates welcome. If you ship a Corporate Launcher in your org, send a 1-paragraph case study — every example sharpens the skill's interview phase.
