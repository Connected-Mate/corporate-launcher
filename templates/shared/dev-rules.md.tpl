# ${CORP_NAME} — Development Rules

These are ${CORP_ORGANIZATION}'s internal development conventions. The AI assistant applies them when generating, refactoring, or reviewing code. They complement (do not replace) the cyber-rules.md baseline.

<!-- tpl: This file is a starter. Replace any section with your own conventions, or delete it entirely if your team has a different doc. Variables below all have safe defaults — leave them as `$\{VAR\}` placeholders if you want the team to fill them in later. -->

---

## How to read this file

Cyber rules tell the assistant what it must *never* do (security baseline). Dev rules tell it what it *should* do (style, taste, workflow). When the two conflict, cyber wins — but conflicts are rare in practice because the categories don't overlap.

Each section below is a sharp default, not an absolute. If a rule blocks a legitimate task, explain why and propose an alternative instead of silently breaking the convention.

---

## 1. Stack & frameworks

- Preferred backend: ${DEV_RULES_BACKEND_STACK}
- Preferred frontend: ${DEV_RULES_FRONTEND_STACK}
- Preferred database: PostgreSQL 15+ (avoid MySQL for new services unless there is a strong reason)
- Preferred container runtime: Docker / OCI images, deployed via the corporate platform
- Forbidden by default: jQuery <3.5 (CVE-2020-11023), Bootstrap <5, AngularJS, raw PHP without a framework, Python 2, Node <18

  *Why:* security baseline (known CVEs), end-of-life (no upstream patches), or replaced by better defaults that the team already standardized on.

When in doubt, match the stack already in use in the repository — consistency beats personal preference.

## 2. Naming conventions

- **Python:** `snake_case` for files, functions, variables; `PascalCase` for classes; `UPPER_SNAKE` for constants
- **TypeScript / JavaScript:** `camelCase` for variables and functions; `PascalCase` for types, interfaces, React components; `kebab-case` for file names (except component files which match the component name)
- **SQL:** `snake_case` for tables and columns; plural table names (`users`, not `user`); `id` for primary keys; `<table>_id` for foreign keys
- **Branches:** `feature/<TICKET>-short-desc`, `fix/<TICKET>-short-desc`, `chore/<short-desc>`
- **Environment variables:** `UPPER_SNAKE`, prefixed by service name (`AUTH_DB_URL`, not just `DB_URL`)

## 3. Code style

- Line length: 100 characters max (120 tolerated for unbreakable URLs or long strings)
- Indentation: 4 spaces for Python, 2 spaces for TypeScript / JSON / YAML
- Import order: stdlib → third-party → first-party, separated by blank lines
- Type hints required for all public functions; `Any` is a smell, justify it in a comment
- Docstrings: Google style for Python, TSDoc for TypeScript; document the *why*, not the *what*
- No dead code, no commented-out blocks "for later" — git remembers

Run the project's formatter (`black`, `ruff format`, `prettier`, `biome`) before every commit. The CI will reject unformatted code.

## 4. Testing

- Test framework: `pytest` for Python, `vitest` or `jest` for TypeScript
- Coverage minimum: 80% for new code; existing untested code is a known debt, not a free pass
- Test file naming: `test_<module>.py` next to the source, or under `tests/` mirroring the package structure; `<file>.test.ts` for TypeScript
- Test names describe behavior, not implementation: `test_user_cannot_login_with_expired_password`, not `test_login_function_2`
- No commits to main without passing tests; failing tests are reverted, not skipped
- Integration tests use real dependencies (Postgres, Redis) via Docker, not mocks — mocks lie

## 5. Git workflow

- Conventional commits: `feat(area): description`, `fix(area): ...`, `chore(area): ...`, `docs(area): ...`
- Commit messages in English, present tense, imperative mood (`add user logout`, not `added` or `adds`)
- Pull request descriptions include: ticket link, summary of the change, screenshots or recordings for UI changes, breaking-change callout if any
- Squash merge to main; rebase feature branches onto main before opening the PR (no merge commits in feature branches)
- Forbidden: force push to `main` or `develop`, direct commits to `main`, bypassing CI with `--no-verify`

## 6. Code reviews

- 1 reviewer minimum for any non-trivial change; 2 reviewers for changes touching authentication, payment, PII handling, or infrastructure-as-code
- Reviewer must read the diff *and* run the code locally (or in a preview env) before approving — no "LGTM blind"
- All review comments must be resolved (replied to or fixed) before merge; "won't fix" is a valid resolution if justified
- Disagreements escalate to a third reviewer, not to a louder argument
- Review comments target the code, not the author: "this branch is unreachable" not "you forgot the case"

## 7. Architecture decisions

- New services or significant architectural changes require an **ADR** (Architecture Decision Record) under `docs/adr/NNNN-title.md`, using the [Nygard format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
- Cross-service changes: notify the architecture channel (${DEV_RULES_ARCH_CHANNEL}) before opening the PR
- Breaking API changes: bump the major version, ship a deprecation notice, keep the old version alive for ≥ 3 months
- "Just one more microservice" is the wrong default — prefer extending an existing service unless ownership, scaling, or compliance forces a split

## 8. Performance budgets

- API endpoints: p99 latency < 500ms under normal load; document the SLO in the service README
- Web pages: TTI < 3s on a 4G connection, LCP < 2.5s, CLS < 0.1, INP < 200ms
- DB queries: any query expected to run >100ms must include an `EXPLAIN` plan in the PR description
- Background jobs: idempotent, retry-safe, and observable (logs + metrics) — fire-and-forget is forbidden
- Bundle size for the main web app: hard budget set per project; CI fails if exceeded

## 9. Dependencies

- Adding a new dependency: justify in the PR description (what problem it solves, what alternatives were considered, what it costs in bundle size or runtime)
- Forbidden licenses for production code: GPL, AGPL (incompatible with the proprietary product); MIT, Apache-2.0, BSD are fine
- Renovate / Dependabot bumps: auto-merge if patch or minor and CI is green; major versions require manual review and a changelog read
- Pin direct dependencies to a known version; lockfiles (`poetry.lock`, `pnpm-lock.yaml`, `package-lock.json`) are committed
- Audit regularly: `pip-audit`, `npm audit`, `osv-scanner` — known vulnerabilities are tickets, not warnings to ignore

## 10. Documentation

- Every new module or service: a `README.md` answering *what it does*, *why it exists*, *how to run it locally*, *how to deploy it*
- Public API endpoints: OpenAPI spec checked into the repo, kept in sync with the code
- Internal documentation hub: ${DEV_RULES_DOC_HUB}
- Code comments explain *why*, not *what* — if you need a comment to explain what the code does, the code is the comment that needs fixing
- Architecture diagrams: `mermaid` in markdown when possible (renderable in the doc hub and on GitHub), exported PNG only when mermaid can't express the diagram

## 11. Observability

- Every service exposes: `/health` (liveness), `/ready` (readiness), `/metrics` (Prometheus format)
- Structured logging (JSON), with a correlation ID propagated across services
- Errors are logged with stack trace and context, not swallowed; warning logs are actionable or removed
- No `print()` or `console.log` in production code — use the project's logger

## 12. Secrets and configuration

- Never commit secrets — the cyber rules cover this, but it's worth repeating because git history is forever
- Configuration via environment variables, validated at startup (fail-fast if a required var is missing or malformed)
- Secrets in the corporate vault, fetched at deploy time, never written to disk in plaintext
- `.env.example` committed with placeholder values; real `.env` files in `.gitignore`

---

*${CORP_NAME} — Proudly made from France with ❤️*
