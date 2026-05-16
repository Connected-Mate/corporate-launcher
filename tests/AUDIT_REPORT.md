# Audit — corporate-launcher vs. canonical skill conventions

**Source of truth**: `~/.claude/plugins/marketplaces/anthropic-agent-skills/skills/skill-creator/SKILL.md` (Anthropic's official skill-creator skill, May 2026).

**Subject**: `/Users/0104389S/Documents/skills/corporate-launcher/`.

**TL;DR** — the skill is structurally sound (frontmatter present, body under 500 lines, progressive disclosure used). It has **7 fixable gaps** vs the canonical, ranked by impact. None are show-stoppers; all are 30-min fixes.

---

## P0 — convention mismatches that affect discoverability

### 1. Directory named `references/` should be `references/` (plural)

The canonical anatomy from skill-creator:
```
skill-name/
├── SKILL.md
└── Bundled Resources (optional)
    ├── scripts/    - Executable code
    ├── references/ - Docs loaded into context as needed
    └── assets/     - Files used in output
```

We use `references/` (singular). Claude's loader doesn't reject it, but tools and graders that hardcode the canonical name (e.g., `package_skill.py`, future linters) will look in `references/`.

**Fix**: `git mv reference references` + update every internal link (SKILL.md, README, examples). ~20 references to update.

### 2. Description lacks the anti-undertriggering "Make sure to use this skill" phrasing

Canonical guidance (skill-creator line 67):
> "Claude has a tendency to undertrigger skills. To combat this, make descriptions a little bit pushy. e.g. instead of 'How to build a dashboard,' write 'How to build a dashboard. Make sure to use this skill whenever the user mentions dashboards, data visualization, internal metrics, or wants to display company data, even if they don't explicitly ask for a dashboard.'"

Our description has trigger keywords but doesn't open with the explicit imperative.

**Fix**: append a final sentence: *"Make sure to use this skill whenever the user mentions wanting to wrap, white-label, or deploy an AI coding CLI inside their organization — even if they don't explicitly name the launcher pattern."*

---

## P1 — structural improvements

### 3. No `evals/evals.json` in the canonical format

The skill-creator workflow expects:
```json
{
  "skill_name": "corporate-launcher",
  "evals": [
    {"id": 1, "prompt": "...", "expected_output": "...", "files": []}
  ]
}
```

We have `tests/branding/eval_prompts.json` (30 white-label trap prompts) — those are good but they test the **generated launcher**, not the **skill itself**. We need a separate `evals/evals.json` that tests whether *invoking the skill on a user prompt* produces a good launcher.

**Fix**: create `evals/evals.json` with 5 realistic prompts:
1. "My employer won't let me install Claude Code. We have a LiteLLM proxy in front of Bedrock."
2. "Build a corporate launcher around Codex CLI for Azure OpenAI."
3. "We use Cursor and need to route AI through our internal Vertex AI gateway with EU residency."
4. "Wrap Gemini CLI for our team. We have a custom CA at /etc/ssl/corp.pem and a proxy at proxy.acme:8080."
5. "I want to ship a white-label CLI to my team via a private GitHub repo with bundled design-pack skills."

### 4. Large reference files lack a table of contents

`references/interview-flow.md` = 397 lines, `references/security-patterns.md` = 300 lines.
Canonical rule: "For large reference files (>300 lines), include a table of contents."

**Fix**: add a TOC at the top of those two files.

### 5. Workflow phases don't always explain "why"

Canonical: *"Try hard to explain the why behind everything you're asking the model to do. Today's LLMs are smart… if you find yourself writing ALWAYS or NEVER, that's a yellow flag — reframe and explain the reasoning."*

Our SKILL.md has several "Do not do X" lines under Anti-patterns without justification. Examples:
- "Don't generate a launcher that calls the vendor's public API directly" — should add *"because the corporate gateway is the only contractually-authorized egress"*
- "Don't store the API key in plaintext" — should add *"because chmod 600 + keychain is the documented baseline for the cyber sign-off"*

**Fix**: enrich each anti-pattern with the *because* clause.

---

## P2 — polish (nice to have, low impact)

### 6. SKILL.md description is 130 words / 834 chars — at the upper edge

Canonical sweet spot mentioned in multiple places: 60–130 words. We're at 130, with 13 listed trigger phrases. This is OK, but every additional trigger we add will push us over.

**Decision needed**: stay at 130, or trim by removing the most redundant triggers (e.g., "wrap codex" and "wrap codex cli" are duplicative).

### 7. No domain-organized references

Canonical recommendation for multi-domain skills:
```
cloud-deploy/
├── SKILL.md (workflow + selection)
└── references/
    ├── aws.md
    ├── gcp.md
    └── azure.md
```

We have `references/provider-matrix.md` (one big file) instead of per-CLI files (`references/claude-code.md`, `references/codex-cli.md`, etc.). Each `templates/<cli>/` is well-organized but the *narrative documentation* mixes all CLIs in one matrix.

**Fix (optional)**: split `provider-matrix.md` into `references/claude-code.md`, `references/codex-cli.md`, `references/gemini-cli.md`, etc. Each gets a smaller, focused doc. Update SKILL.md to point at the right one based on `WRAPPED_CLIS`.

---

## P3 — observations (not fixes)

- The skill correctly uses progressive disclosure (SKILL.md = 197 lines, reference files loaded on demand).
- Anti-patterns section is good — gives concrete bad behaviors to avoid.
- Frontmatter is minimal (only `name`, `description`, `allowed-tools`) — matches canonical advice to keep it lean.
- The "When to use" and "Anti-trigger" pairing is exactly the pattern the canonical recommends.
- `templates/` is well-structured per CLI.
- The `integrations/` folder (for multi-host install) is a unique addition not in the canonical — it's a strength, not a violation.

---

## Punch list (in order of impact / cost)

| # | Action | Effort | Impact |
|---|---|---|---|
| 1 | Rename `references/` → `references/` and update internal links | 10 min | Convention compliance |
| 2 | Add "Make sure to use this skill whenever…" to description | 2 min | Reduces undertriggering |
| 3 | Create `evals/evals.json` with 5 realistic invocation prompts | 15 min | Enables `skill-creator` eval loop |
| 4 | Add TOC to `interview-flow.md` and `security-patterns.md` | 5 min | Faster navigation |
| 5 | Enrich anti-patterns with "because" rationale | 10 min | Better model compliance |
| 6 | Decide on description length: keep 130 or trim to ~100 words | 5 min | Marginal |
| 7 | Split `provider-matrix.md` into per-CLI files under `references/` | 20 min | Cleaner progressive disclosure |

**Total**: ~70 minutes to be fully canonical.

---

## What to do next

If you only fix two things, fix **#1** (folder rename) and **#2** (pushy description) — they take 12 minutes combined and address the biggest convention violations.

If you fix everything, run `python3 -m pytest tests/test_render.py` afterwards to make sure no internal link breaks during the rename.
