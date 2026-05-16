# Dev rules — examples

Three example `dev-rules.md` files for different industries. Use them as starting points; adapt to your own codebase. The AI assistant loads this file (or your equivalent) into context and applies the rules when generating, refactoring, or reviewing code.

---

## Example 1 — Investment bank backend platform

Audience: Java + Python data pipeline team, regulated by ACPR + EBA. Touches trade lifecycle, post-trade reporting (MiFID II, EMIR), and risk computation.

```markdown
# CIB Markets — Development Rules

## Stack & frameworks
- Java 21 LTS (Temurin), Maven 3.9+. Gradle is not approved on this perimeter.
- Spring Boot 3.3+, Spring Modulith for new services. Spring Cloud only where the platform team has blessed it.
- Python 3.12 for data pipelines, `uv` for env management, no `poetry` for new repos.
- Forbidden: Lombok in the domain layer (hides equality and serialization bugs); `record` types are the answer.
- Forbidden: Kotlin on the JVM side without a written exception from the architecture board.

## Code style
- Strict nullability: `Optional` on return types, `@NonNull` / `@Nullable` on parameters, checked by SpotBugs in CI.
- No `var` for public APIs or fields — only inside short method bodies where the type is obvious from the right-hand side.
- Sealed types for state machines (trade lifecycle, settlement status). Exhaustive `switch` expressions only.
- Logging: SLF4J + Logback, structured JSON, parameterized messages (`log.info("trade {} settled", id)`). `System.out` and `System.err` are CI errors.

## Persistence
- JPA / Hibernate over raw JDBC for transactional services; jOOQ for analytical reads.
- Every entity has a surrogate `id` (UUIDv7), an `audit_created_at` and `audit_updated_at` (UTC, `timestamptz`), and a `version` column for optimistic locking.
- Flyway migrations only, forward-only, no `clean` in any non-local profile.
- N+1 queries are review blockers; use `@EntityGraph` or explicit fetch joins.

## Testing
- JUnit 5, AssertJ, Testcontainers (Postgres, Kafka, IBM MQ). Mocks for I/O are banned in service tests.
- Coverage minimum on new code: **95% line, 90% branch** — regulatory perimeter, not optional.
- Property-based tests (jqwik) for pricing and risk math; golden-master tests for any change to a regulatory report.
- Every bug fix lands with the test that would have caught it.

## Money and time
- Money is `BigDecimal` with explicit scale + `RoundingMode`, never `double` or `float`. Wrapped in a `Money(amount, currency)` value object.
- Time is `Instant` for storage and wire format; `ZonedDateTime` only at presentation boundaries. The trading floor is in `Europe/Paris`, but the code is not.
- Business dates use `LocalDate` and a holiday calendar service — never `Instant.toLocalDate()`.

## Regulatory & audit
- Any change touching `regulatory/`, `reporting/`, or `audit/` packages requires 2 reviewers, one from the regulatory tech lead pool.
- No log redaction tricks: PII fields are typed (`Lei`, `Bic`, `ClientId`) and the logger knows how to mask them. Stringly-typed PII is rejected.
- All outbound regulatory reports are reproducible from the audit log alone — no hidden state.
```

---

## Example 2 — Telco product team

Audience: Go + TypeScript microservices on Kubernetes, ~40M customers, mobile-first product. SRE-adjacent culture: error budgets matter more than feature velocity.

```markdown
# Mobility Platform — Development Rules

## Stack & frameworks
- Go 1.23+, modules only (no `GOPATH` projects). `golangci-lint` config is checked in and pinned.
- TypeScript 5.5+ with `strict: true`, `noUncheckedIndexedAccess: true`, `exactOptionalPropertyTypes: true`. No exceptions.
- React 18 + Vite for the customer web app; Next.js only for SSR-required pages (SEO landing).
- Tailwind v4 with the `@theme` directive; no `tailwind.config.js` in new projects. Component lib: shadcn/ui, copy-pasted, never npm-installed.
- Forbidden: `lodash` (use stdlib + small helpers), `moment` (use `Temporal` polyfill or `date-fns`), `axios` (use `fetch` + a typed wrapper).

## Go conventions
- `context.Context` is the first argument of every function that does I/O, full stop. Background contexts only at `main` and test setup.
- Concurrency: `errgroup` over hand-rolled channels for fan-out; `singleflight` for cache stampede; no naked `go func()` outside `main`.
- Errors are values: wrap with `fmt.Errorf("doing X: %w", err)`, check with `errors.Is` / `errors.As`. `panic` is reserved for programmer errors, never business logic.
- One package, one purpose. `util`, `common`, `helpers` are banned package names.
- Generated code (protobuf, mocks, OpenAPI) lives under `gen/` and is regenerated, never hand-edited.

## TypeScript & React
- Server state: TanStack Query. `useState` + `useEffect` for fetching is a review blocker.
- Client state: `zustand` for cross-component state, plain `useState` for local. Redux is legacy, not extended.
- Forms: `react-hook-form` + `zod` schema; the same schema validates the API request.
- Components are small and dumb; logic lives in custom hooks or services. Files over 200 lines get a second look.
- No `any`, no `as unknown as Foo` casts without a `// reason:` comment.

## API contracts
- OpenAPI-first: spec is the source of truth, server and client are generated from it (`oapi-codegen` for Go, `openapi-typescript` for TS).
- Breaking changes require a versioned endpoint (`/v2/...`) and a 90-day deprecation window communicated to client teams.
- Pagination: cursor-based for any list that can exceed 1000 items. Offset pagination is rejected in review.

## Reliability
- Every service has an SLO documented in the repo (`docs/slo.md`); error budget burn alerts route to the on-call.
- Retries: exponential backoff + jitter + circuit breaker (`gobreaker`). Infinite retries are a bug.
- Timeouts everywhere: every outbound HTTP call has an explicit timeout < the caller's deadline.
- Idempotency keys on every mutating endpoint that costs money or sends a notification.

## Observability
- OpenTelemetry for traces, logs, metrics. No vendor SDKs in business code.
- Trace IDs propagated end-to-end, including through Kafka headers and cron jobs.
- Dashboards live in the repo as Grafana JSON; provisioned via GitOps.
```

---

## Example 3 — Manufacturing PLM SaaS

Audience: .NET + Angular team shipping product lifecycle management software to industrial customers. Slow release cadence (quarterly), customers on premises and air-gapped, long-lived branches per major version.

```markdown
# PLM Suite — Development Rules

## Stack & frameworks
- C# 12, .NET 9 LTS. Preview SDKs are blocked in CI until the next LTS lands.
- ASP.NET Core minimal APIs for new endpoints; controllers retained only in modules predating v8.
- EF Core 9 with **compiled queries** for any query in a hot path; raw SQL via Dapper for reporting workloads.
- Angular 18+ with **standalone components only**. NgModules are legacy; new code does not introduce them.
- ECharts for visualization, never D3 — D3 imperative code does not survive customer support handoffs.
- Forbidden: AutoMapper for new modules (hides bugs at refactor time); write explicit mapping methods.

## Dependency injection
- Constructor injection only; no property injection, no service locator (`IServiceProvider.GetService` outside composition root is rejected).
- Scoped lifetime is the default. Singletons require justification in the PR (thread-safety review).
- `IOptions<T>` with validation attributes for configuration; `IOptionsSnapshot` for hot-reloadable settings.

## Async & threading
- `async` all the way down — no `.Result`, no `.Wait()`, no `.GetAwaiter().GetResult()` outside `Main`.
- `ConfigureAwait(false)` on every library `await`; not required in ASP.NET Core handler code.
- `CancellationToken` is a parameter on every async public method, propagated through.
- Background work uses `IHostedService` or Hangfire (already deployed), never raw `Task.Run` in production paths.

## Angular conventions
- Signal-based state (`signal`, `computed`, `effect`) for new components; RxJS only where streams are genuinely needed (HTTP, WebSocket, debounced inputs).
- Change detection: `OnPush` everywhere; default change detection in a new component is a review blocker.
- Lazy-loaded routes for every feature area > 50KB gzipped.
- Forms: typed reactive forms (`FormGroup<T>`); template-driven forms are not extended.
- Styles: component-scoped SCSS, no global `!important`. Design tokens come from the shared `@plm/design-tokens` package.

## Backwards compatibility
- Public API surface (REST + SDK) is frozen within a major version. Additive changes only — new fields, new endpoints. Removing or renaming is a major-version task.
- Database migrations are forward-only and never rename columns in place; introduce, dual-write, deprecate, drop across three releases.
- Customer-facing config keys are append-only; rename via alias + warning, drop after two LTS cycles.

## Tests
- xUnit + FluentAssertions + Testcontainers for SQL Server and RabbitMQ.
- Integration tests boot the real `WebApplicationFactory` with an ephemeral DB — in-memory provider is forbidden, it lies about query semantics.
- Snapshot tests (Verify) for any generated artifact (BOM exports, PDF reports, SDK output).
- Smoke test suite runs against a freshly restored customer-shaped dataset on every nightly build.
```

---

## How to adapt

1. **Copy the closest example** into a new `dev-rules.md` somewhere on your machine (or in the repo if the team shares it).
2. **Replace the specifics** with your own stack (language versions, frameworks, linters, package managers). Keep the structure — section headings are what makes the file scannable for both humans and the assistant.
3. **Add domain-specific sections** where your industry has non-obvious rules. Examples:
   - Trading: "Every limit order code path validates IRBN before submission."
   - Health: "PHI fields are typed (`Mrn`, `Ssn`) and logged through the redaction logger only."
   - Public sector: "All UI text is bilingual (FR/EN), `lang` attribute mandatory."
4. **Save the file**, then point the launcher at it during the interview by setting `DEV_RULES_LOCAL_PATH` to its absolute path. The launcher copies it into the assistant's context directory at install time.
5. **Iterate**. The best dev-rules files are accretions: every time you see the assistant generate code that doesn't match house style, add one line. Don't try to write the perfect file on day one — write the file your team will actually read.
6. **Keep it short.** A 300-line file the team ignores is worse than a 60-line file the team enforces. Prune rules that haven't been cited in a review for six months.
