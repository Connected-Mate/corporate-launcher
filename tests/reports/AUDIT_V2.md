# Audit V2 — corporate-launcher vs canonical skill conventions (May 2026)

**Sources of truth**
- DOC = https://code.claude.com/docs/en/skills (Extend Claude with skills, May 2026)
- PLG = https://code.claude.com/docs/en/plugins (Create plugins)
- SC  = `~/.claude/plugins/marketplaces/anthropic-agent-skills/skills/skill-creator/SKILL.md`
- GH  = https://github.com/anthropics/skills

**Subject** — `/Users/0104389S/Documents/skills/corporate-launcher/` (SKILL.md 236 lines, 19 reference files, `evals/` already canonical, no `.claude-plugin/plugin.json`).

**Verdict** — V1 gaps (#1 folder name, #2 pushy description, #3 evals/evals.json) are CLOSED. What remains are *plugin-era* and *operational* gaps that V1 didn't cover. 13 specific findings below, prioritised P0→P3.

---

## P0 — blocks marketplace / multi-host distribution

### 1. No `.claude-plugin/plugin.json` manifest
- **Canonical**: every plugin lives in a dir containing `.claude-plugin/plugin.json` with `name`, `description`, `version`, `author`, optional `homepage`, `repository`, `license` (PLG §Create your first plugin; PLG §full manifest schema).
- **Today**: only `SKILL.md`. The skill works standalone but cannot be installed via `claude --plugin-dir`, cannot be namespaced, cannot be submitted to the official marketplace (claude.ai/settings/plugins/submit).
- **Should**: create `.claude-plugin/plugin.json` with `name: corporate-launcher`, `version: 0.3.0` (matches `dist/`), `description`, `author`, `homepage`, `repository`, `license: MIT`. Move SKILL.md into `skills/corporate-launcher/SKILL.md` if you go plugin-route, OR ship dual (standalone + plugin wrapper).
- **Effort**: M (decide single vs dual layout, then 30 min).

### 2. Missing `license:` declaration in frontmatter / manifest
- **Canonical**: PLG manifest accepts `license`. GH example skills include a LICENSE file at skill root (we have one — good) but no field linking it.
- **Today**: `LICENSE` file present (MIT inferred), no `license` field in SKILL.md frontmatter or any manifest.
- **Should**: add `license: MIT` to the future `plugin.json` and reference SPDX identifier.
- **Effort**: S.

### 3. No `version:` field anywhere machine-readable
- **Canonical**: PLG §version management — "If set, users only receive updates when you bump this field. If omitted and your plugin is distributed via git, the commit SHA is used and every commit counts as a new version."
- **Today**: version lives only in `dist/corporate-launcher-0.3.0.skill` filename and `CHANGELOG.md`. Nothing programmatic.
- **Should**: `version: 0.3.0` in `plugin.json`. Update CI bump script.
- **Effort**: S.

---

## P1 — discoverability & runtime correctness

### 4. `description` lacks `when_to_use:` split (1,536-char budget pressure)
- **Canonical** (DOC §Frontmatter reference): `description` + `when_to_use` are concatenated and truncated at 1,536 chars; put key use case first.
- **Today**: description is one block of ~870 chars; trigger phrases buried mid-paragraph; `when_to_use` field is present but written as a separate paragraph (good) — yet the *key use case* sits behind a 130-word preamble.
- **Should**: front-load the use case in the first sentence ("Generate a branded corporate launcher wrapping any AI coding CLI onto an internal gateway."), then move trigger phrases to `when_to_use`. Run `/doctor` to confirm no truncation.
- **Effort**: S.

### 5. `${CLAUDE_SKILL_DIR}` not used in script paths
- **Canonical** (DOC §Available string substitutions; Visual output example): "Use this in bash injection commands to reference scripts or files bundled with the skill, regardless of the current working directory."
- **Today**: SKILL.md references `scripts/render.py`, `scripts/api-probe.py`, `scripts/audit-launcher.py`, `scripts/pixel-art-logo.py` with relative paths. Works when cwd = skill root, breaks when invoked from a user project.
- **Should**: rewrite all script refs as `${CLAUDE_SKILL_DIR}/scripts/x.py`.
- **Effort**: S.

### 6. No dynamic context injection (`` !`command` ``)
- **Canonical** (DOC §Inject dynamic context): pre-execute shell to inline live data (e.g. git diff, gh pr view).
- **Today**: Phase 1.5 "Probe the gateway" launches `api-probe.py` *during* the conversation. Phase 3.5 self-audit too. Both could surface a baseline (`!\`uname -a\``, `!\`which claude codex gemini\``, `!\`echo $HTTPS_PROXY\``) at skill-load time — saves a round trip.
- **Should**: add a `## Environment snapshot` section with ` ```! ` fenced block dumping host/CLI/proxy state.
- **Effort**: S.

### 7. No `paths:` glob to gate auto-loading
- **Canonical** (DOC §Frontmatter reference): "Glob patterns that limit when this skill is activated. Claude loads the skill automatically only when working with files matching the patterns."
- **Today**: skill is repo-agnostic so triggers everywhere. If a user adds it to `~/.claude/skills/`, Claude considers it on every prompt.
- **Should**: leave blank (we *want* repo-agnostic invocation) but document the explicit choice in a comment — auditors will flag the omission. Alternatively gate to `paths: ["**/launcher*", "**/*.tpl", "**/install.sh"]` to reduce false-positive load on unrelated work.
- **Effort**: S (decision call, not code).

### 8. No `disable-model-invocation` / `user-invocable` posture declared
- **Canonical** (DOC §Control who invokes a skill): every skill ships with explicit answers; security-side-effect skills (commit, deploy) should set `disable-model-invocation: true`.
- **Today**: implicit defaults (both true). The launcher *writes files to disk* and *creates GitHub repos via `gh repo create --push`* — these are side effects.
- **Should**: explicitly set `disable-model-invocation: false` (you want auto-trigger, justify it) but document the side-effects in SKILL.md so the user grants trust knowingly. Consider splitting Phase 4 (distribution) into its own user-invocable-only sub-skill `/corporate-launcher:publish`.
- **Effort**: M (architectural decision).

---

## P2 — operational hygiene

### 9. No `agents/` directory despite spawning subagents via `context: fork`
- **Canonical** (DOC §Run skills in a subagent; PLG §plugin structure): subagents live in `agents/` at plugin root. Skills with `context: fork` pair with an `agent:` type.
- **Today**: SKILL.md describes interactive flow; no `context: fork`, no `agent:` field, no `agents/` dir. Phase 3.5 audit, Phase 3.6 URL purge, Phase 4.5 compliance.docx are each candidate sub-skills that could run isolated.
- **Should**: extract Phase 3.5/3.6/4.5 into `skills/audit-launcher/SKILL.md` with `context: fork`, `agent: general-purpose`. Saves main-context tokens.
- **Effort**: L.

### 10. No `hooks:` declared despite generating launchers with hooks
- **Canonical** (DOC §Frontmatter; https://docs.claude.com/en/hooks): `hooks:` field scopes hooks to the skill's lifecycle (`PreToolUse`, `PostToolUse`, `Stop`).
- **Today**: `templates/shared/pre-tool-hook.py.tpl` generates a hook for the *output* launcher but the skill itself declares none. We could `PostToolUse(Write)` → re-run `audit-launcher.py` automatically after every template write, instead of asking the model to remember.
- **Should**: add `hooks: { PostToolUse: [{ matcher: "Write|Edit", command: "${CLAUDE_SKILL_DIR}/scripts/audit-launcher.py --quiet" }] }`.
- **Effort**: M.

### 11. No `argument-hint:` / `arguments:` for `/corporate-launcher` invocation
- **Canonical** (DOC §Frontmatter): `argument-hint: [cli] [backend]` shows during autocomplete; named `arguments` enables `$name` substitution.
- **Today**: skill always runs the full interview. Power user who types `/corporate-launcher claude-code bedrock` gets no shortcut.
- **Should**: `argument-hint: "[cli-id] [backend] [dist-mode]"` + `arguments: [cli, backend, dist]` so `$cli` / `$backend` / `$dist` pre-fill the interview.
- **Effort**: S.

### 12. `allowed-tools` too broad
- **Canonical** (DOC §Pre-approve tools): "Pre-approve narrowly: `Bash(git add *) Bash(git commit *)` not `Bash(*)`."
- **Today**: `allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, Glob, Grep` — `Bash` unrestricted grants every shell command without prompt.
- **Should**: scope to the commands we actually run: `Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/*)`, `Bash(gh repo create*)`, `Bash(chmod *)`, `Bash(curl -fsSL*)`, `Bash(tar *)`, `Bash(shasum *)`, `Bash(gpg *)`, `Bash(git *)`.
- **Effort**: M (need to inventory every shell-out).

---

## P3 — polish

### 13. No `compatibility:` field for Claude Code version pinning
- **Canonical**: not yet in DOC frontmatter table, BUT PLG §version management implies future use; some marketplace plugins (`anthropic-agent-skills/skill-creator`) already ship a `compatibility` clause in CHANGELOG.
- **Today**: nothing — we ship `${CLAUDE_SKILL_DIR}`, `disable-model-invocation`, `paths`, all of which require Claude Code ≥ 2.0.x. A user on 1.x will silently mis-parse.
- **Should**: add a `## Compatibility` section to README + a `claude-code: ">=2.0.0"` field in `plugin.json` when manifest lands.
- **Effort**: S.

### 14. No `assets/` for hero.png / banner art (currently `assets/hero.png` is correct, but no other assets)
- **Canonical** (DOC §canonical layout; GH examples): `assets/` is for files copied/filled into outputs. We have `templates/banner/` doing that job.
- **Today**: `assets/hero.png` is README art (correct location). But `templates/banner/` palette files would conceptually fit `assets/banner/`. Split is defensible.
- **Should**: leave as-is, document the convention choice in CONTRIBUTING.md so contributors don't mix them.
- **Effort**: S.

### 15. SKILL.md still narrates "why" where canonical wants "do"
- **Canonical** (DOC §Types of skill content): "State what to do rather than narrating how or why ... every line is a recurring token cost."
- **Today**: Phase 1.5 / 3.5 / 3.6 / 3.7 / 4.5 have `> Why:` / `> What:` blockquotes — readable for humans, dead weight in context. ~30 lines of prose.
- **Should**: collapse each phase to 2-3 imperative lines, move the "why" to `references/workflow-rationale.md` linked from the section header.
- **Effort**: M (~20 min, surgical edit).

---

## Punch list

| # | Action | Effort | Priority |
|---|---|---|---|
| 1 | Create `.claude-plugin/plugin.json` | M | P0 |
| 2 | Add `license: MIT` to manifest | S | P0 |
| 3 | Add `version: 0.3.0` to manifest | S | P0 |
| 4 | Front-load use case in `description`, demote triggers to `when_to_use` | S | P1 |
| 5 | Replace relative script paths with `${CLAUDE_SKILL_DIR}/` | S | P1 |
| 6 | Add ` ```! ` env snapshot block | S | P1 |
| 7 | Decide on `paths:` (omit + comment, or scope) | S | P1 |
| 8 | Set explicit `disable-model-invocation: false` + document side effects | M | P1 |
| 9 | Extract audit/purge/compliance phases into forked sub-skills under `skills/` | L | P2 |
| 10 | Declare `hooks:` for post-write audit | M | P2 |
| 11 | Add `argument-hint:` + `arguments:` | S | P2 |
| 12 | Narrow `allowed-tools` Bash scopes | M | P2 |
| 13 | Add `compatibility:` claude-code constraint | S | P3 |
| 14 | Document `assets/` vs `templates/` split | S | P3 |
| 15 | Convert "Why/What" prose to imperative + offload rationale | M | P3 |

**Total**: ~4-5 hours to be fully 2026-canonical and marketplace-ready.

---

## Honest take

The skill is high-quality for the **standalone-skill era** (V1 audit closed all those gaps). It is now living in the **plugin era** without a plugin manifest — every other marketplace skill (anthropics/skills, document-skills) ships `.claude-plugin/plugin.json`. Until you do, you cannot publish, you cannot version-pin, you cannot namespace, and `${CLAUDE_SKILL_DIR}` will silently mis-resolve when the skill is invoked from a user repo.

Fix #1, #2, #3, #5 today (one hour combined). Defer #9 (architectural) and #12 (security audit needed) to a 0.4.0 milestone.

Sources:
- [Claude Code Skills docs](https://code.claude.com/docs/en/skills)
- [Claude Code Plugins docs](https://code.claude.com/docs/en/plugins)
- [anthropics/skills repository](https://github.com/anthropics/skills)
- [The Complete Guide to Building Skills for Claude (Anthropic PDF)](https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf)
- [6 Principles from Anthropic's Official Skills Guide — Christian Dussol, Apr 2026](https://medium.com/@christian.dussol/6-principles-from-anthropics-official-skills-guide-applied-to-a-real-skill-d59424e38ff3)
