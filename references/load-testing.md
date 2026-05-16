# Load Testing the Gateway

Reference for `scripts/load-test.py`. Run this before scaling a corporate
launcher to a wider audience.

## Purpose

Before scaling a corporate launcher to N developers, verify that the AI
gateway holds up under realistic concurrent load. The load tester sends
controlled traffic to your OpenAI/Anthropic/LiteLLM/Azure/Vertex/Bedrock
endpoint and reports latency percentiles, error breakdown, and throughput.
It is intentionally stdlib-only (no `requests`, no `aiohttp`) so it runs on
any corporate workstation without extra installs.

## Default scenario

50 minimal completions at concurrency 5 against the configured model.
Each request asks the model to reply `OK` (16-token cap), so it is the
cheapest meaningful round-trip you can make through the gateway.

```
total        = 50
concurrency  = 5
prompt       = 'Say "OK" only.'
max_tokens   = 16
timeout      = 30s
```

## Metrics

The tool prints a JSON report:

- `latency_ms.p50` / `p95` / `p99` / `max` — wall-clock per request
- `errors` and `error_codes` — count by HTTP status (`401`, `429`, `5xx`,
  `network` for connection failures)
- `completed` — number of 2xx responses
- `req_per_sec` — throughput over the wall window
- `tokens_per_sec` — sum of `usage.total_tokens` (Anthropic: input+output)
  divided by wall time
- `wall_seconds` — total elapsed

## Usage

Default ramp:

```bash
python3 scripts/load-test.py \
  --url "$GATEWAY" --token "$TOK" \
  --total 50 --concurrency 5 \
  --model gpt-5-codex
```

Burst mode (fire N requests instantly, one worker per request) to find the
rate limit:

```bash
python3 scripts/load-test.py --url "$GATEWAY" --token "$TOK" --burst 20
```

Above 100 requests the tool refuses to run unless you pass `--yes` (the
"I know what I am doing" flag):

```bash
python3 scripts/load-test.py --url "$GATEWAY" --token "$TOK" \
  --total 500 --concurrency 20 --yes
```

Backend is auto-detected from the URL host. Override with
`--backend anthropic|openai|azure|litellm|bedrock-proxy|vertex` if your
gateway lives behind a generic hostname.

Proxy and custom CA are honoured via the standard env vars:
`HTTPS_PROXY`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`.

## Cost

Each request costs LLM tokens. For the default scenario:

- 50 requests × ~10 input tokens + ~3 output tokens ≈ 650 tokens total
- On gpt-4o-mini: well under one US cent
- On gpt-5 / Claude Opus / Sonnet class models: a few US cents
- Burst of 20 or `--total 100`: still pennies

A full saturation run (`--total 500 --yes`) on a premium model can reach
~$0.20–$1. Stay on a cheap model for capacity probes; only rerun on the
production model to validate p95 on the real path.

## When to run

- **Initial deployment** — before announcing the launcher to a team
- **After a gateway upgrade** — LiteLLM bump, proxy change, new region
- **After raising the user count** — every time the audience doubles
- **Periodic SLO check** — weekly or monthly cron (see CI section)
- **Incident triage** — quick probe to confirm or rule out gateway issues

## Interpretation

- **p95 > 2 s** — gateway congested or model overloaded. Raise capacity,
  pin a smaller/faster model, or move the heavy traffic to a dedicated
  deployment. Recheck after change.
- **p99 >> p95** — tail latency, usually queueing. Lower concurrency or
  ask the platform team to add workers.
- **`429` errors** — hitting rate limit. Ask the platform team to raise
  quota, or lower `--concurrency`. Confirm by running `--burst N` with
  increasing N until 429s appear.
- **`5xx` errors** — gateway bug. Capture the full JSON report, the
  request URL, and a timestamp; file a ticket with the platform team.
- **`network` / status `0`** — TLS, proxy, or DNS failure. Check
  `HTTPS_PROXY`, `REQUESTS_CA_BUNDLE`, and that the host resolves from the
  workstation.
- **`401` / `403`** — token wrong or expired. Exit code 2.
- **`completed = 0`** — exit code 2 (auth) or 3 (network), never 0.

## CI integration

Run weekly via GitHub Actions to track SLO drift:

```yaml
name: gateway-loadtest
on:
  schedule:
    - cron: "0 6 * * 1"   # Monday 06:00 UTC
  workflow_dispatch:
jobs:
  probe:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          python3 scripts/load-test.py \
            --url "${{ secrets.GATEWAY_URL }}" \
            --token "${{ secrets.GATEWAY_TOKEN }}" \
            --total 50 --concurrency 5 \
            --model gpt-4o-mini \
            > report.json
      - uses: actions/upload-artifact@v4
        with:
          name: loadtest-report
          path: report.json
```

Archive the JSON reports; a simple jq pipeline can chart p95 over time and
alert on regression.

## Privacy

The prompt is fixed: `Say "OK" only.` No business data, no source code, no
user input is sent. The tool never reads files. The only outbound bytes
are the auth header, the fixed prompt, and the 16-token reply cap. Safe to
run from any workstation, including against production gateways, without a
data-protection review.
