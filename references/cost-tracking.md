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

## How each CLI feeds the ledger

| CLI | Producer of `<slug>-usage.jsonl` | Notes |
|---|---|---|
| Claude Code | `strip-proxy.js` (Bedrock/LiteLLM) or empty | Strip-proxy active on Bedrock & LiteLLM only. For Anthropic-direct, the ledger stays empty — but that backend is rare in a corporate setting. |
| Codex CLI | `strip-proxy.js` (LiteLLM) | LiteLLM is the standard backend; strip-proxy intercepts all responses. |
| Gemini CLI | (none in v0.7) | Vertex AI does not stream usage in a format the proxy parses cleanly. `--cost` works against pre-recorded entries; a Vertex-native adapter is on the v0.8 list. |
| Aider | LiteLLM | Same path as Codex. |
| Cline | Strip-proxy (LiteLLM) | Cline talks to LiteLLM via OpenAI-compatible client. |
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

## v0.8 roadmap

- Vertex AI native adapter (parse `gemini-cli` JSON logs)
- Cline-native usage capture (read `~/.cline/conversations/*.json`)
- Codex session log parser as fallback when strip-proxy is off
- PowerShell parity for `push` + alert threshold
- Per-team rollup endpoint (push N tenants → one aggregated record)
