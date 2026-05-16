# Dev Rules

Corporate development conventions injected into the launcher's system prompt alongside `cyber-rules.md`. Separate from the 15 cyber controls because they encode taste and house style, not threat-model defenses.

## Table of contents
- [1. Why dev rules exist](#1-why-dev-rules-exist)
- [2. What gets shipped](#2-what-gets-shipped)
- [3. Four source modes](#3-four-source-modes)
- [4. Suggested structure](#4-suggested-structure)
- [5. What works well](#5-what-works-well)
- [6. Relationship to cyber-rules](#6-relationship-to-cyber-rules)
- [7. Update path](#7-update-path)
- [8. Per-team variants](#8-per-team-variants)
- [9. Confidentiality](#9-confidentiality)
- [10. CI integration](#10-ci-integration)

---

## 1. Why dev rules exist

Every company has its own development conventions — file naming, import ordering, test layout, commit message format, which logging library is blessed, whether `Optional[X]` or `X | None` is preferred in Python, whether services live in `internal/` or `pkg/`. Without these conventions in the prompt, the model defaults to "generic best practice" code drawn from public training data, which does not match any specific codebase.

The visible failure mode is benign: a pull request that works but feels foreign. Variables named `result` instead of the house style `out_payload`. Tests in `tests/` when the repo uses `*_test.go` adjacent to sources. Loggers from `logging` when the standard is `structlog`. The reviewer spends ten minutes on style nits per AI-authored PR — a tax that compounds across the engineering org.

With dev rules in the prompt, the model matches house style from the first generation. The reviewer reviews logic; style is already correct. Across hundreds of PRs per week, this is the difference between AI-assisted development feeling like a senior teammate or an enthusiastic intern.

Dev rules are not a substitute for code review; they are a substitute for the style nits that consume review bandwidth.

---

## 2. What gets shipped

The launcher writes the dev rules to `<install_dir>/dev-rules.md` and references the file from the CLI's system-prompt flag — concretely, `claude --append-system-prompt-file <install_dir>/dev-rules.md` (or the equivalent flag for the chosen CLI). The file is read fresh on every launch, so updates do not require a re-install.

`scripts/dev-rules-installer.py` handles fetching the content at install time, resolving the source mode chosen during the interview (see section 3) and writing the final file. It is also re-invoked by `${CORP_SLUG} --update-dev-rules` to refresh from a git source without re-running the full interview.

The file lives alongside `cyber-rules.md`. Both are appended; neither overrides the other. The launcher does not parse or validate the dev-rules content — it is opaque markdown to the launcher, interpreted only by the model.

---

## 3. Four source modes

The interview asks where the dev rules should come from. Four answers are supported:

**none** — no dev rules are installed. The launcher runs with only `cyber-rules.md`. This is the default for first-time users who don't yet have written conventions and don't want to invent them on the spot. The directory still has a `dev-rules.md` file, but it is a one-line placeholder so the `--append-system-prompt-file` flag does not error.

**inline** — the user pastes the markdown directly into the interview (terminated by a sentinel line such as `EOF`). Useful for solo developers or small teams whose rules fit in a screen and don't yet warrant a git repo. The content is written verbatim to `<install_dir>/dev-rules.md` with no further processing.

**local** — the user points at a file on disk (`/Users/me/work/dev-rules.md` or `C:\code\rules.md`). The installer copies the file to `<install_dir>/dev-rules.md` at install time. Subsequent edits to the source file are not picked up automatically; the user must re-run `--update-dev-rules` or re-install. Suitable when rules live in a personal notes folder or a shared drive.

**git** — recommended for teams. The user provides a git URL, branch, and path-within-repo (e.g. `git@github.corp:platform/standards.git`, branch `main`, path `ai/dev-rules.md`). The installer clones with depth 1, copies the target file, and discards the clone. Credentials are reused from the user's existing SSH agent or git credential helper; the launcher never stores them. `--update-dev-rules` re-clones and overwrites the local copy, so a single push to the standards repo propagates to every developer on their next refresh.

The git mode is the only one that scales beyond a handful of users. Inline and local both create drift the moment a rule changes.

---

## 4. Suggested structure

The template at `templates/shared/dev-rules.md.tpl` ships ten sections. Use it as a skeleton; delete sections that don't apply rather than leaving them empty.

1. **Stack** — languages and versions in use (Python 3.11+, Go 1.22+, Node 20 LTS, TypeScript strict mode). Frees the model from guessing or supporting deprecated runtimes.
2. **Naming** — file naming (snake_case, kebab-case, PascalCase), variable conventions, package layout.
3. **Style** — formatter and linter (`ruff` + `black`, `gofmt`, `prettier` + `eslint`), line length, import ordering.
4. **Testing** — framework (`pytest`, `go test`, `vitest`), file location, naming pattern, coverage expectations, fixtures convention.
5. **Git** — commit message format (Conventional Commits, ticket prefix), branch naming, PR template.
6. **Reviews** — what reviewers check, who approves what, blocking vs. non-blocking comments.
7. **Architecture** — layering rules (handlers → services → repos), allowed cross-module imports, where new features go.
8. **Performance** — N+1 query rules, caching conventions, async vs. sync defaults, memory ceilings.
9. **Dependencies** — approved/forbidden packages, license constraints, who can add a new dep.
10. **Documentation** — docstring style, README expectations, ADR location.

Each section should be short and specific. The model reads the full file on every turn — verbosity is paid for in latency and tokens.

---

## 5. What works well

Concrete examples beat abstract principles. The rule "follow company conventions" is invisible to the model because it carries no signal. The rule "use `snake_case.py` for Python files, `kebab-case.ts` for TypeScript" generates correctly on the first try.

**Good:**
- "Loggers come from `from app.logging import get_logger`; never `import logging`."
- "Tests live in `tests/` mirroring `src/`. Filename is `test_<module>.py`. Class names are `TestX`, methods `test_<behavior>`."
- "Commit messages: `<type>(<scope>): <subject>` where type ∈ {feat, fix, chore, refactor, test, docs}."

**Anti-patterns:**
- "Follow company conventions" — no signal.
- "Write clean code" — every model already tries to.
- "Match the existing style" — without access to the repo the model can't, and even with access it picks the closest file, which may itself be inconsistent.
- 4000-word manifestos — the model truncates attention; the last sections get ignored.

Aim for 100–300 lines total. If your conventions don't fit, the rules are probably tribal knowledge that should be linted, not prompted.

---

## 6. Relationship to cyber-rules

Dev rules complement, never replace, the 15 cyber controls. They live in two files for a reason: cyber rules are non-negotiable (identity lock, TLS minimums, forbidden functions like `eval`); dev rules are taste.

When a dev rule conflicts with a cyber rule, the cyber rule wins. Example: a dev rule that says "use `child_process.exec` for shell commands because the team finds it readable" loses to cyber rule 12 (forbidden functions). The model is instructed in `cyber-rules.md` that those controls are absolute; a contradicting dev rule should be treated as a request the model refuses with the cyber rationale.

In practice this rarely fires — most dev rules concern naming, layout, and tooling, not the primitives cyber rules cover. But the precedence is explicit so a careless dev-rules edit cannot silently lower the security baseline.

---

## 7. Update path

`${CORP_SLUG} --update-dev-rules` re-runs the installer in update mode. Behavior by source mode:

- **none** — no-op.
- **inline** — error; inline rules can only be changed by re-running the full interview, since there is no source to pull from.
- **local** — re-copies from the original path. If the file moved or was deleted, the installer reports the error and leaves the existing copy untouched.
- **git** — shallow-clones the configured repo/branch/path, replaces `<install_dir>/dev-rules.md`, and exits. Exit code is `0` on success, non-zero on clone failure (so it can be cron'd safely).

The source mode and any associated metadata (path, git URL, branch, in-repo path) are persisted to `<install_dir>/dev-rules.json` at install time so the update command knows what to do. That JSON file is also chmod 644.

A weekly cron entry — `0 9 * * 1 ${CORP_SLUG} --update-dev-rules` — keeps every developer aligned with the latest standards without manual coordination.

---

## 8. Per-team variants

When multiple teams within the same organization have meaningfully different conventions (a Java backend team and a TypeScript frontend team, or platform and product), pick one of two patterns:

**One launcher per team** — generate a separate corporate launcher for each team with its own `CORP_SLUG` (`acme-platform`, `acme-product`). Each binary carries its own dev rules. Simplest mental model; uses more disk; clearest blast radius for changes.

**Shared launcher, named rule files** — store team rules in the standards repo as `dev-rules.platform.md`, `dev-rules.frontend.md`, `dev-rules.data.md`. The git source mode points at the right one per developer. The launcher itself is identical across teams; only the cloned path differs.

Avoid concatenating multiple team rule files into a single mega-prompt — the conflicts (frontend says "use `kebab-case.ts`", backend says "use `PascalCase.java`") become noise the model cannot resolve.

---

## 9. Confidentiality

Dev rules can contain internal architectural details — service names, internal package paths, the existence of unreleased systems, the structure of the monorepo. Treat them as confidential at the same level as the source code they describe.

Operational implications:

- The git source URL (`DEV_RULES_GIT_URL`) and any local path (`DEV_RULES_LOCAL_PATH`) are persisted to `<install_dir>/dev-rules.json` on the developer's machine. Do not commit those values into a public corporate-launcher fork.
- The launcher writes the resolved `dev-rules.md` to `<install_dir>/dev-rules.md` with mode `0644` (owner-write, world-read on the local machine — adequate for single-user workstations, not for shared servers).
- The standards repo itself should be private. Public mirrors leak the internal landscape to anyone scraping GitHub for "dev-rules.md".
- Telemetry, if enabled, must not include the rules content. The launcher's audit hook redacts the file path but never the body — see `references/security-patterns.md` section 12.

If the org policy classifies architecture as Restricted, the local cache should be chmod 600 instead of 644; override via the installer's `--mode` flag.

---

## 10. CI integration

A minimal GitHub Actions job validates that the standards repo's `dev-rules.md` is well-formed before it propagates to thousands of developers. The launcher does not parse the file, but malformed markdown (unclosed code fences, broken headings) degrades model attention.

```yaml
# .github/workflows/dev-rules.yml
name: validate-dev-rules
on:
  pull_request:
    paths:
      - 'ai/dev-rules.md'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check size (< 50 KB)
        run: |
          size=$(wc -c < ai/dev-rules.md)
          test "$size" -lt 51200 || { echo "dev-rules.md too large: $size bytes"; exit 1; }
      - name: Lint markdown
        uses: DavidAnson/markdownlint-cli2-action@v16
        with:
          globs: 'ai/dev-rules.md'
      - name: Smoke-test with launcher
        run: |
          pip install -r requirements.txt
          python scripts/dev-rules-installer.py --validate ai/dev-rules.md
```

The `--validate` flag in `dev-rules-installer.py` runs the same parsing/copy path used at install time but writes to a temp directory and exits non-zero on any error (unreadable file, encoding mismatch, write failure). It is the only way to detect a regression before the next `--update-dev-rules` cron fans it out to every developer.
