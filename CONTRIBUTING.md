# Contributing to corporate-launcher

Thanks for considering a contribution. This project ships a skill that generates **corporate-grade** AI CLI launchers for regulated environments. Quality bar is high — these launchers get reviewed by CISOs and security offices.

## Project values

- **Corporate-grade quality** — every generated artifact is reviewable by a security team. No magic, no shortcuts.
- **No vendor lock-in** — Claude Code, Codex, Gemini, Aider, opencode, Continue.dev all first-class. Adding more is encouraged.
- **Security by default** — no plaintext secrets, no global TLS bypass, no `/etc/hosts` mutation, no unsigned one-liners.
- **No surprise behavior** — if a template sets an env var, `reference/env-vars.md` documents it. If a flow asks a question, `reference/interview-flow.md` lists it.

## Filing an issue

Use one of the two templates:

- **Bug report** — what CLI was being wrapped, what backend, what command failed, full error output, OS + shell, output of `python3 scripts/generate.py --version`.
- **Feature request** — the corporate use case, the CLI/backend involved, why the current flow does not cover it. Reference the section of `reference/interview-flow.md` you would extend.

Do **not** file public issues for security vulnerabilities — see the Security policy below.

## Submitting a pull request

1. Fork and branch from `main`. Branch naming: `feat/<short-slug>`, `fix/<short-slug>`, `docs/<short-slug>`, `cli/<cli-name>` for new CLI support.
2. Tests are required for new logic. Add or update `tests/test_*.py` (pytest). A PR that touches `scripts/` without a test will be asked to add one.
3. Linting must pass:
   - Python: `black scripts/ tests/` then `ruff check scripts/ tests/`
   - Shell templates: `shellcheck` on rendered output (run `python3 scripts/generate.py --config examples/configs/<sample>.json --out build/ && shellcheck build/**/*.sh`)
4. Keep the PR description focused: what changed, why, which `reference/` file you updated to match.

## Local dev setup

```bash
git clone https://github.com/Connected-Mate/corporate-launcher.git
cd corporate-launcher
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"   # installs pytest, black, ruff
pytest -q
```

Render a launcher locally for smoke testing:

```bash
python3 scripts/generate.py --config examples/configs/sample-claude-litellm.json --out /tmp/test-launcher --dry-run
shellcheck /tmp/test-launcher/*.sh
```

## Code style

- **Python 3.10+** (match statements, `X | Y` unions allowed).
- **Bash** always starts with `set -euo pipefail` and uses `[[ ... ]]` over `[ ... ]`.
- **No external runtime deps** in `scripts/` — stdlib only. Renderer and installer must work on a fresh Python 3.10 without `pip install`.
- Templates: `# tpl:` comments are strippable, `$\{VAR\}` escapes a literal `${VAR}`, never use `curl | bash` inside a template.

## Where to look first

- `SKILL.md` — the skill's contract with the harness.
- `reference/` — interview flow, provider matrix, env vars, security patterns. Read this before changing behavior.
- `templates/shared/` — modules every launcher inherits (VPN gate, proxy detect, secrets store, cost tracker).

## Maintainer

Maintained by **Alexandre Cormeraie** ([@ConnectedMate](https://github.com/Connected-Mate)). PR review SLA is best-effort; ping with a comment if a review is stale after 7 days.

## Security policy

Report vulnerabilities **by email to `security@connectedmate.io`** — not via a public issue. Include a repro, the affected template/script, and the impact. Responses within 72 hours. Coordinated disclosure preferred.
