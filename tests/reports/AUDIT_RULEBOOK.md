# Claude Code Skills — Audit Rulebook (2026)

Canonical rules for high-quality `SKILL.md`, extracted from the official Claude Code docs and the official `skill-creator` skill. Sources cited inline.

Sources:
- DOC = https://code.claude.com/docs/en/skills (official Claude Code "Extend Claude with skills")
- SC  = `/Users/0104389S/.claude/plugins/marketplaces/anthropic-agent-skills/skills/skill-creator/SKILL.md` (Anthropic skill-creator)
- STD = https://agentskills.io (open Agent Skills standard, referenced by DOC)

---

## 1. Frontmatter rules

- [ ] **`name`** optional; if omitted, the directory name is used. Lowercase letters, numbers, hyphens only, max 64 chars. [DOC §Frontmatter reference]
- [ ] **`description`** is the only *recommended* field. "All fields are optional. Only `description` is recommended so Claude knows when to use the skill." [DOC §Frontmatter reference]
- [ ] **Description content rule**: must state *what the skill does AND specific contexts for when to use it*. "All 'when to use' info goes here, not in the body." [SC §Write the SKILL.md]
- [ ] **Description length budget**: combined `description` + `when_to_use` is truncated at **1,536 characters** in the skill listing. "Put the key use case first." [DOC §Frontmatter reference, §Skill descriptions are cut short]
- [ ] **Anti-undertrigger phrasing**: be slightly "pushy". Example: append "Make sure to use this skill whenever the user mentions X, Y, Z, even if they don't explicitly ask for it." [SC §Write the SKILL.md]
- [ ] **`when_to_use`** optional, appended to `description`, counts toward the 1,536 char cap. Use it for trigger phrases / example requests. [DOC]
- [ ] **`allowed-tools`** (space-separated string or YAML list) pre-approves tools while the skill is active — does NOT restrict, only grants. Review before trusting. [DOC §Pre-approve tools for a skill]
- [ ] **`disable-model-invocation: true`** for skills with side effects (`/commit`, `/deploy`). Prevents Claude from auto-triggering and from preloading in subagents. [DOC §Control who invokes a skill]
- [ ] **`user-invocable: false`** for background-knowledge-only skills (hides from `/` menu). [DOC]
- [ ] **`model`**, **`effort`**: optional per-skill overrides; apply only for the current turn. [DOC]
- [ ] **`context: fork`** + **`agent`**: run in isolated subagent. Only meaningful if the SKILL.md contains an actionable task, not pure guidelines. [DOC §Run skills in a subagent]
- [ ] **`paths`**: glob patterns to gate auto-loading to relevant files only. [DOC]
- [ ] **`argument-hint`** / **`arguments`**: declare expected positional args for `$N` / `$name` substitution. [DOC §Available string substitutions]

## 2. Progressive disclosure

- [ ] **Three loading levels**: (1) metadata (name+description, ~100 words, always in context), (2) SKILL.md body (loaded when skill triggers, **<500 lines ideal**), (3) bundled resources (loaded/executed on demand, unlimited). [SC §Progressive Disclosure]
- [ ] **Hard guidance**: "Keep `SKILL.md` under 500 lines. Move detailed reference material to separate files." [DOC §Add supporting files, Tip]
- [ ] **If SKILL.md approaches 500 lines**: add another hierarchy layer with explicit pointers ("see `references/X.md` for Y"). [SC §Progressive Disclosure]
- [ ] **Large reference files (>300 lines)**: include a table of contents. [SC]
- [ ] **Domain organization pattern**: when the skill spans variants (AWS/GCP/Azure, React/Vue), put each variant in `references/<variant>.md` so Claude reads only the relevant one. [SC §Progressive Disclosure]
- [ ] **Reference every supporting file from SKILL.md** with explicit "when to read it" guidance. Unreferenced files are dead weight. [DOC §Add supporting files; SC]
- [ ] **Token cost reminder**: once loaded, SKILL.md "stays in context across turns ... every line is a recurring token cost. State what to do rather than narrating how or why." [DOC §Types of skill content]

## 3. Workflow guidance

- [ ] **Imperative voice**: "Prefer using the imperative form in instructions." [SC §Writing Patterns]
- [ ] **Explain the WHY, not heavy-handed MUSTs**: "If you find yourself writing ALWAYS or NEVER in all caps, or using super rigid structures, that's a yellow flag — reframe and explain the reasoning." [SC §How to think about improvements #3]
- [ ] **Output format definition**: use an explicit template block ("ALWAYS use this exact template:") when format matters. [SC §Writing Patterns]
- [ ] **Examples**: include Input/Output pairs for transformations. [SC §Writing Patterns]
- [ ] **Multi-turn / lifecycle**: skill content is rendered once and persists for the session. Write as *standing instructions*, not one-time steps. [DOC §Skill content lifecycle]
- [ ] **Anti-pattern**: "guidelines without a task" + `context: fork` → subagent returns nothing meaningful. [DOC §Run skills in a subagent, Warning]
- [ ] **Dynamic context**: use `` !`<command>` `` and `` ```! `` fenced blocks to inline live data (git diff, gh pr view) into the prompt. [DOC §Inject dynamic context]
- [ ] **`${CLAUDE_SKILL_DIR}`**: always use it for script paths so the skill resolves at personal/project/plugin levels. [DOC §Available string substitutions; Visual output example]

## 4. Skill metadata for discovery

- [ ] **Description = primary triggering mechanism**. [SC §Description Optimization]
- [ ] **Sweet spot**: dense paragraph putting the *key use case first*, then trigger phrases. Hard cap 1,536 chars combined with `when_to_use`. [DOC §Skill descriptions are cut short]
- [ ] **Trigger keywords**: include the verbs/nouns users naturally say, including synonyms and casual phrasing. [DOC §Skill not triggering; SC §Generate trigger eval queries]
- [ ] **Anti-triggers**: keep description specific so adjacent intents don't match. The official remedy for over-triggering is "Make the description more specific" or set `disable-model-invocation: true`. [DOC §Skill triggers too often]
- [ ] **Claude only consults skills for tasks it can't easily handle itself**: simple one-step queries ("read this PDF") may not trigger regardless of description. Design descriptions for *complex/multi-step* invocations. [SC §How skill triggering works]
- [ ] **Alignment rule**: description must accurately reflect what the body actually does. Misalignment = silent under-trigger. [SC §Capture Intent]

## 5. Code conventions (scripts / templates / references)

- [ ] **Canonical layout** [SC §Anatomy of a Skill]:
  ```
  skill-name/
  ├── SKILL.md           (required)
  ├── scripts/           (executable code, deterministic / repetitive tasks)
  ├── references/        (docs loaded into context on demand)
  └── assets/            (template files, icons, fonts used in output)
  ```
- [ ] **`scripts/`** = code Claude *executes*, not loads. Bundle when test runs reveal subagents reinventing the same helper repeatedly. [SC §Look for repeated work; DOC §Generate visual output]
- [ ] **`references/`** = prose Claude *reads on demand*. Use for API specs, large variant tables, schemas. [SC]
- [ ] **`assets/` (a.k.a. `templates/`)** = files copied/filled into outputs. [SC]
- [ ] **SKILL.md stays prose-first**: don't dump full scripts inline — link them via `${CLAUDE_SKILL_DIR}/scripts/x.py`. [DOC §Generate visual output]
- [ ] **Pre-approve narrowly**: `allowed-tools: Bash(git add *) Bash(git commit *)` not `Bash(*)`. [DOC §Pre-approve tools for a skill]

## 6. Top 10 anti-patterns

1. SKILL.md > 500 lines with no progressive disclosure. [DOC Tip; SC]
2. Vague description ("Helps with docs") instead of trigger-rich + push phrasing. [SC]
3. Description and body misaligned (description promises X, body does Y). [SC §Capture Intent]
4. Inline mega-scripts pasted into SKILL.md instead of `scripts/`. [DOC §Generate visual output]
5. Bundled files never referenced from SKILL.md → never loaded. [DOC §Add supporting files]
6. Wall of `ALWAYS` / `NEVER` / `MUST` without explaining why. [SC §How to think about improvements]
7. `context: fork` on a guidelines-only skill (no task → empty output). [DOC Warning]
8. Hardcoded paths instead of `${CLAUDE_SKILL_DIR}`. [DOC §Available string substitutions]
9. `allowed-tools` set too broadly (`Bash(*)`) — security risk on project skills. [DOC §Pre-approve tools]
10. No test cases / evals committed; skill cannot be regression-tested. [SC §Test Cases, §Description Optimization]

---

Use this checklist as the scoring rubric for the corporate-launcher audit. Each unchecked box = a finding to triage P0/P1/P2/P3.
