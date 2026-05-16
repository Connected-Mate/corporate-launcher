# API Probe

Pre-flight check for a corporate AI gateway. Run **before** generating a launcher so the skill fails fast on bad URL, expired token, missing model, or broken TLS.

Implementation: `scripts/api-probe.py` (stdlib only, no third-party deps).

## Why probe

Generating a launcher against an unreachable or misconfigured gateway produces a broken artifact the user only discovers at first run. The probe catches, in <10s:

- Typos in the base URL (wrong scheme, wrong host, missing `/v1`)
- Expired or wrong-type tokens (`x-api-key` vs `Bearer`)
- Backend mismatch (user picked `anthropic` but URL is LiteLLM)
- Self-signed TLS without `REQUESTS_CA_BUNDLE` exported
- Corporate proxy not honored (`HTTPS_PROXY` missing)
- Requested model not present in the gateway's catalog

A successful probe is the only deterministic evidence the launcher will actually start.

## What gets checked

| Check               | Source                                                       |
|---------------------|--------------------------------------------------------------|
| URL well-formed     | `urllib.parse.urlparse` — scheme in {http,https}, netloc set |
| TLS handshake       | `ssl.SSLContext.wrap_socket` on `(host, 443)`                |
| Certificate         | issuer CN, subject CN, `notAfter` ISO                        |
| Reachability + auth | GET `<base>/<probe_path>` with backend-specific headers      |
| Latency             | `time.monotonic()` around the GET, reported in ms            |
| Models catalog      | Parsed from `data` / `models` / `value` array in response    |
| Model availability  | If `--model X` passed: warn if X not in catalog              |
| Fallback completion | If models endpoint non-200 and `--model` given: POST a 4-token ping |

## Per-backend probes

Auto-detection via `BACKEND_HINTS` on the hostname; override with `--backend`.

| Backend         | Probe path                              | Auth header           |
|-----------------|-----------------------------------------|-----------------------|
| `anthropic`     | `/v1/models`                            | `x-api-key: $TOKEN` + `anthropic-version: 2023-06-01` |
| `openai`        | `/v1/models`                            | `Authorization: Bearer $TOKEN` |
| `litellm`       | `/v1/models`                            | `Authorization: Bearer $TOKEN` |
| `bedrock-proxy` | `/v1/models`                            | `Authorization: Bearer $TOKEN` |
| `azure`         | `/openai/models?api-version=2024-02-01` | `api-key: $TOKEN`     |
| `vertex`        | `/v1/models`                            | `Authorization: Bearer $TOKEN` |

Fallback completion (when `/v1/models` is disabled by the gateway) POSTs to `/v1/messages` (Anthropic) or `/v1/chat/completions` (others) with `max_tokens=4`.

## Usage

### Manual

```bash
python3 scripts/api-probe.py \
  --url    "$GATEWAY_URL" \
  --token  "$GATEWAY_TOKEN" \
  --backend litellm \
  --model   gpt-5 \
  --timeout 10
```

`--backend auto` (default) detects from hostname. `--model` is optional but recommended — without it the probe cannot verify the model exists.

### Inside skill flow

Called automatically after **Section 3 — Backend** of the interview (see `references/interview-flow.md`). If the probe returns non-zero, the interview pauses and offers: retry, edit URL/token, or skip-with-warning.

### Inside install.sh

Optional, gated by `API_PROBE_ENABLED=1` in the generated installer. Air-gapped sites typically set it to `0` and rely on a manual probe from a jump host.

## Output format

Always JSON on stdout (success or failure), example success:

```json
{
  "ok": true,
  "backend": "litellm",
  "url": "https://ai-gateway.corp.example/v1",
  "auth": "bearer-token",
  "token_preview": "sk-a...9f2c",
  "latency_ms": 142.3,
  "http_status": 200,
  "models_available": ["gpt-5", "claude-sonnet-4-6", "llama-3.3-70b"],
  "tls": {
    "cert_issuer": "Corp Internal CA",
    "subject_cn": "ai-gateway.corp.example",
    "expires": "2027-03-14T00:00:00+00:00"
  },
  "warnings": [],
  "proxy": true,
  "ca_bundle": "/etc/ssl/corp-ca-bundle.pem"
}
```

## Exit codes

| Code | Meaning                              | Caller action                                |
|------|--------------------------------------|----------------------------------------------|
| 0    | All checks passed                    | Continue to generation                       |
| 2    | Auth failed (HTTP 401/403)           | Re-prompt for token, do **not** retry blindly |
| 3    | Network unreachable / DNS / timeout  | Surface proxy + DNS hints                    |
| 4    | TLS certificate error                | Suggest `REQUESTS_CA_BUNDLE=...`             |
| 5    | Malformed URL or CLI args            | Fix invocation, no network attempt made      |

Exit code `1` is intentionally not used (reserved for unexpected Python errors).

## Failure remediation

- **Code 2 (auth)** — check token type matches backend (`x-api-key` for Anthropic-native, `Bearer` elsewhere, `api-key` for Azure). Verify token not expired in the gateway admin UI.
- **Code 3 (network)** — confirm `HTTPS_PROXY` is set, DNS resolves the host, firewall allows egress. If on VPN, check split-tunnel rules.
- **Code 4 (TLS)** — export `REQUESTS_CA_BUNDLE=/path/to/corp-ca.pem` (the probe honors it). For Zscaler/Netskope MITM, install the corporate root in the bundle.
- **Code 5 (URL)** — typo in scheme (must be `http://` or `https://`) or missing host.
- **Warning `model not found`** — gateway is reachable but the chosen model id is not in the catalog. Use one from `models_available`.
- **Warning `models endpoint returned no entries`** — gateway disables `/v1/models`; pass `--model` to use the fallback completion probe.

## Privacy

- **No payload is sent** during the catalog probe (HTTP GET, empty body). Fallback completion sends only the literal string `"ping"` with `max_tokens=4`.
- **Token is always masked** in JSON output (`token_preview: "sk-a...9f2c"`) and never written to logs by the probe. The skill's interview also redacts tokens before writing to `audit.log`.
- **No telemetry**, no outbound calls beyond the configured gateway.

## When to skip

- **Air-gapped install** where the operator runs the generator on a workstation with no route to the gateway (gateway only reachable from production). Generate with `--skip-probe`, then run the probe manually on a jump host using the same `scripts/api-probe.py` (the file is shipped inside the installer bundle).
- **Gateway not yet provisioned** — early-phase rollouts where the launcher is being prepared before the gateway is live. Document the expected URL/token and re-probe before distribution.
- **Probe-incompatible gateway** — extremely locked-down deployments that only expose a single completion route. Use `--model` + fallback completion, or skip entirely.

Skipping is logged as a `warning` in the generated `audit.log` so downstream reviewers can spot un-validated launchers.
