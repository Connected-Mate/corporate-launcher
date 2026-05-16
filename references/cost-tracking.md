# Cost tracking — universal across all launchers

Every generated launcher exposes a `--cost` subcommand. It's enabled by default
(`COST_TRACKING_ENABLED=yes`) and writes to a single per-tenant ledger so finance
and engineering see the same numbers no matter which CLI the developer used.

## Why mandatory by default

Finance asked. The launcher already wraps the gateway, so capturing token usage
costs nothing extra — and a tenant that can't answer *"what did your AI tooling
cost last month"* gets cut off at renewal. We default the flag on; the
interview lets you opt out only if the org refuses any local ledger (rare).

## What gets installed

| File | Role |
|---|---|
| `scripts/cost-tracker.py` | Reads `/tmp/<slug>-usage.jsonl`, aggregates per-session / per-day / per-model, optionally POSTs daily totals to a corporate dashboard. |
| `scripts/cost-tracker.ps1` | Windows PowerShell port (session / today / history). |
| `scripts/pricing.json` | Pricing table: `{ "<model>": {"input_per_1m": X, "output_per_1m": Y} }`. Edit to match your contracted rates. |
| `scripts/strip-proxy.js` | Bedrock/LiteLLM-only SSE intercept that emits one JSONL line per response. |
| `scripts/usage-adapter-cline.sh` | Native Cline log adapter — parses `saoudrizwan.claude-dev/tasks/<task-id>/ui_messages.json` for `api_req_started` events (`tokensIn`/`tokensOut`/`cacheReads`/`cacheWrites`/`cost`). Used when Cline talks to a provider that bypasses the strip-proxy (Bedrock-direct, Anthropic-direct, etc.). |
| `scripts/usage-adapter-codex.sh` | Native Codex log adapter — tails `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` and emits one event per `event_msg` with `payload.type == "token_count"` (using `info.last_token_usage` for per-turn deltas). Used because Codex CLI does not honour `HTTPS_PROXY` reliably (upstream issue #4242). |

## How each CLI feeds the ledger

| CLI | Producer of `<slug>-usage.jsonl` | Notes |
|---|---|---|
| Claude Code | `strip-proxy.js` (Bedrock/LiteLLM) or empty | Strip-proxy active on Bedrock & LiteLLM only. For Anthropic-direct, the ledger stays empty — but that backend is rare in a corporate setting. |
| Codex CLI | Native adapter (`usage-adapter-codex.sh`) + strip-proxy fallback | Codex (Rust/reqwest) doesn't honour `HTTPS_PROXY` reliably (#4242), so the adapter tails `~/.codex/sessions/**/rollout-*.jsonl` and emits one event per `event_msg` / `token_count`. The strip-proxy still catches the rare LiteLLM-direct case. See "Codex native adapter" below. |
| Gemini CLI | `usage-adapter-gemini.sh` (Vertex + AI Studio) | Tails Gemini CLI's local OpenTelemetry file sink and projects `gemini_cli.api_response` events into the shared JSONL ledger. See "Vertex AI" section below. |
| Aider | LiteLLM | Same path as Codex. |
| Cline | Native adapter (`usage-adapter-cline.sh`) + strip-proxy fallback | Parses every `api_req_started` event under `<globalStorage>/saoudrizwan.claude-dev/tasks/<task-id>/ui_messages.json`. Strip-proxy still captures the LiteLLM-via-OpenAI-compatible setup. See "Cline native adapter" below. |
| Continue.dev | Strip-proxy (LiteLLM) | Same. |
| opencode | Strip-proxy | Same. |

## Invoking from the launcher

```bash
<launcher>                 # normal interactive session
<launcher> --cost          # alias for "--cost session"
<launcher> --cost session  # cost for current session only
<launcher> --cost today    # today, broken down by model
<launcher> --cost history  # all days, oldest → newest
<launcher> --cost push     # POST today's total to COST_TENANT_ENDPOINT
```

`--cost session` filters on the `<SLUG>_SESSION_ID` env var the launcher exports
on entry. Without that env var, "session" is equivalent to "all events".

## Alert threshold

`COST_ALERT_THRESHOLD` (numeric string, units = `COST_CURRENCY`) prints a
non-fatal stderr warning when today's spend reaches the threshold. The warning
fires from `--cost session` and `--cost today`. Set to `0` (default) to
disable.

Pick a realistic per-dev daily ceiling. For most teams: `5` to `50` USD/EUR.

## Tenant dashboard push

`COST_TENANT_ENDPOINT` (HTTPS URL) is where `--cost push` POSTs an aggregated
daily payload:

```json
{
  "tenant": "acme-copilot",
  "org": "ACME Group",
  "day": "2026-05-16",
  "currency": "USD",
  "total": 12.4567,
  "requests": 84
}
```

Auth header is `Authorization: Bearer <COST_TENANT_TOKEN>` when the env var is
set. Common targets:

| Target | Endpoint shape |
|---|---|
| FinOps dashboard | `https://finops.<org>.internal/v1/llm-cost/ingest` |
| Prometheus Pushgateway | `https://pushgw.<org>.internal/metrics/job/llm-cost` (custom adapter required) |
| Datadog | `https://api.datadoghq.<region>/api/v1/series` (corporate tenant) |
| Internal Grafana / Postgres | any internal POST endpoint that accepts JSON |

Schedule a daily push via cron or systemd-timer:

```cron
0 23 * * *  <launcher> --cost push
```

## Disabling

Set `COST_TRACKING_ENABLED=no` in the config. The cost-tracker script still
installs (for forensic recovery if the policy is reverted) but the launcher's
`--cost` flag becomes a no-op. Strongly discouraged: tenants without cost data
forfeit the FinOps argument for budget renewal.

## Vertex AI

The shared `strip-proxy.js` only understands Anthropic-style SSE. Vertex AI
exposes a different protocol (`StreamGenerateContent` / Cloud AI Platform
gRPC-JSON) that the proxy cannot decode without a full rewrite. Rather than
fork the proxy, Gemini gets a dedicated adapter:
`templates/shared/usage-adapter-gemini.sh.tpl` is installed at
`<install-dir>/lib/usage-adapter-gemini.sh` and spawned in the background by
the Gemini launcher just before `exec gemini`. The launcher traps
`EXIT INT TERM` so the tailer dies with the session — no leftover process.

**How it captures usage.** Gemini CLI ships with native OpenTelemetry. The
adapter rewrites `~/.gemini/settings.json` on each start to force:

```json
{
  "telemetry": {
    "enabled": true,
    "target": "local",
    "outfile": "~/.gemini/telemetry.log"
  }
}
```

`target=local` + `outfile` keeps OTLP data on the host — no GCP export, no
otlpEndpoint. The adapter then runs `tail -F` on that file, filters for
`gemini_cli.api_response` log records, and projects them into the canonical
ledger schema:

| OTLP attribute | Ledger field |
|---|---|
| `model` (or `gen_ai.request.model`) | `model` |
| `input_token_count` (or `gen_ai.usage.input_tokens`) | `usage.input_tokens` |
| `output_token_count` (or `gen_ai.usage.output_tokens`) | `usage.output_tokens` |
| `session.id` | `session` |

These counts come from Vertex's own `usageMetadata`, surfaced verbatim by
gemini-cli — so this is a **real measurement, not an estimate**. Cost is
computed locally using an inline pricing table that mirrors `pricing.json`
(edit both when your contracted rates change).

**Known limits.**

- Requires gemini-cli ≥ v0.2.x (when the OTLP file sink shipped). Older
  versions silently produce no log lines; the adapter writes nothing and
  `--cost` stays empty.
- Cache-hit and "thinking" tokens are billed at the input rate in the inline
  pricing table. If your Vertex contract bills them separately, extend the
  `PRICING` map in `usage-adapter-gemini.sh.tpl` and update `pricing.json`.
- The adapter parses one record per line. Multi-line pretty-printed OTLP
  exports (rare; not the default) are not handled — keep the default sink
  format.
- AI Studio mode also works: the same `gemini_cli.api_response` event is
  emitted regardless of backend.

## Cline native adapter

Cline (extension id `saoudrizwan.claude-dev`) stores per-task state under
the IDE's globalStorage directory:

| OS | Path |
|---|---|
| macOS | `~/Library/Application Support/{Code,Code - Insiders,Cursor,VSCodium}/User/globalStorage/saoudrizwan.claude-dev/tasks/<task-id>/` |
| Linux | `~/.config/{Code,Code - Insiders,Cursor,VSCodium}/User/globalStorage/saoudrizwan.claude-dev/tasks/<task-id>/` |
| Windows | `%APPDATA%\{Code,Cursor}\User\globalStorage\saoudrizwan.claude-dev\tasks\<task-id>\` |

Each task folder contains `ui_messages.json`. The adapter pulls events
matching `type == "say"` and `say == "api_req_started"` whose `.text` is
a JSON-stringified `ClineApiReqInfo`:

```jsonc
// one entry inside ui_messages.json
{ "type": "say", "say": "api_req_started", "ts": 1714477215321,
  "text": "{\"cost\":0.012,\"tokensIn\":1284,\"tokensOut\":312,
            \"cacheReads\":256,\"cacheWrites\":40,
            \"apiProtocol\":\"anthropic\"}" }
```

Model id comes from `task_metadata.json`. Idempotency is enforced by
`/tmp/<slug>-cline-seen.txt`, keyed on `<task-id>:<ts-ms>`. The launcher
spawns the adapter in background on `<launcher>` invocation and kills it
via an `EXIT INT TERM` trap; for a long IDE session run
`<launcher> --usage-watch` in a spare terminal.

**Known limits.**

- Requires `jq` + `python3` (already required by `cost-tracker.py`).
- If `task_metadata.json` predates the recognised schema, model id is
  recorded as `"unknown"` — usage and cost are still captured, but
  per-model breakdowns lose that row.
- Cost is recomputed from `pricing.json` when a match is found; Cline's
  own embedded `cost` (list price) is the fallback so the ledger is
  never empty.

## Codex native adapter

Codex CLI writes a full session rollout under
`~/.codex/sessions/YYYY/MM/DD/rollout-<iso-ts>-<session-uuid>.jsonl`.
Per-turn token counts arrive as:

```jsonc
{"timestamp": "2026-04-30T11:30:13.473Z",
 "type": "event_msg",
 "payload": {
   "type": "token_count",
   "info": {
     "total_token_usage": { /* cumulative */ },
     "last_token_usage":  { "input_tokens": 17476,
                            "cached_input_tokens": 6528,
                            "output_tokens": 295,
                            "reasoning_output_tokens": 51,
                            "total_tokens": 17771 },
     "model_context_window": 258400
   }
 }}
```

Model id is captured from the preceding `turn_context` event's
`payload.model`. The adapter emits one ledger entry per `token_count`
using `info.last_token_usage` (per-turn delta) so multiple events from
the same session don't double-count. Processed lines are recorded in
`/tmp/<slug>-codex-seen.txt` as `<rollout-basename>:<line-no>`.

The adapter is forked from the Codex launcher just before
`exec codex "$@"`. Because `exec` reuses the same PID, the adapter's
`ADAPTER_PARENT_PID` watchdog self-terminates as soon as codex exits —
no orphan daemons.

**Known limits.**

- Sessions emitted by early-September-2025 CLI builds lacked
  `turn_context.model`; those events are tagged `model: "unknown"`.
- `token_count` events with `info == null` (rate-limit-only pings) are
  intentionally skipped — they carry no usage data.
- The adapter watches `~/.codex/sessions/` with `fswatch` (macOS),
  `inotifywait` (Linux), or a 5-second polling fallback. Conversation
  text, tool calls and code edits are never read — only the `timestamp`,
  `turn_context.model` and `event_msg / token_count` shapes.

## Per-team / per-org rollup

For org-level FinOps that operates several launchers (e.g. one tenant per
business unit), `scripts/cost-rollup.py` aggregates N tenants into a single
daily record and POSTs it to a central endpoint.

Two input modes:

```bash
# Mode A — mount each tenant's local JSONL ledger to a shared dir
scripts/cost-rollup.py --from-dir /mnt/finops/tenants/ \
                      --org "ACME Group" \
                      --post https://finops.acme.internal/v1/llm-cost/org-rollup \
                      --bearer "$FINOPS_TOKEN"

# Mode B — each tenant ran `--cost push`, an HTTP relay archived each payload to disk
scripts/cost-rollup.py --from-http-archive /var/lib/cost-relay/archive/ \
                      --org "ACME Group" \
                      --day 2026-05-16 \
                      --post https://finops.acme.internal/v1/llm-cost/org-rollup
```

Aggregated payload shape:

```json
{
  "org": "ACME Group",
  "day": "2026-05-16",
  "currency": "USD",
  "tenants": [
    {"tenant": "acme-copilot",  "total": 12.45, "requests": 84},
    {"tenant": "globex-helper", "total":  3.21, "requests": 22}
  ],
  "grand_total": 15.66,
  "grand_requests": 106,
  "tenant_count": 2
}
```

Run once a day from a central cron host (not from a developer laptop). If
tenants use mixed currencies, the script logs a warning and totals stay
nominal — convert at the org-side ingest, not here.

## Roadmap

- Vertex AI quota dashboard tie-in (read project-level token quotas)
- OIDC-based auth on `--cost push` (replace static bearer)
- Streaming push (websocket instead of daily POST) for orgs with realtime FinOps
