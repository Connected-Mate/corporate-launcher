# Security Patterns

Concrete patterns for the templates. Each subsection answers: "how do I express X correctly in shell / PowerShell / Python / Node?"

## Table of contents
- [1. VPN gate](#1-vpn-gate)
- [2. Proxy detection](#2-proxy-detection)
- [3. CA bundle handling](#3-ca-bundle-handling)
- [4. Secret storage](#4-secret-storage)
- [5. Shell RC block (idempotent)](#5-shell-rc-block-idempotent)
- [6. Prompt filter (cyber-guard)](#6-prompt-filter-cyber-guard)
- [7. Strip-proxy (Bedrock / LiteLLM only)](#7-strip-proxy-bedrock--litellm-only)
- [8. Telemetry kill switches](#8-telemetry-kill-switches)
- [9. Permission lockdown](#9-permission-lockdown)
- [10. DLP-friendly defaults](#10-dlp-friendly-defaults)
- [11. Token rotation](#11-token-rotation)
- [12. Audit trail](#12-audit-trail)

---

## 1. VPN gate

**Why:** corporate LLM gateways are unreachable outside the perimeter; fail fast with a clear message instead of an obscure TLS/DNS error that leaks infrastructure details to whatever public network the user is on.

Probe an internal-only URL with a short timeout. HTTP code `000` = no route → VPN off.

```bash
check_vpn() {
    local probe="${VPN_PROBE_URL}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 -m 5 "$probe" 2>/dev/null)
    if [[ -n "$code" && "$code" != "000" ]]; then
        return 0
    fi
    echo "VPN check failed — please connect to corporate VPN before launching." >&2
    return 1
}
```

PowerShell equivalent:

```powershell
function Test-CorpVpn {
    try {
        $r = Invoke-WebRequest -Uri $env:VPN_PROBE_URL -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}
```

Captive-portal trap: if your probe ever returns `200 OK` with HTML, swap it for `http://clients3.google.com/generate_204` which must return `204 No Content`. Any other code = captive portal.

---

## 2. Proxy detection

**Why:** blindly exporting proxy variables breaks off-network users and can route their traffic into a dead black-hole, while *omitting* the proxy on-corp routes their requests around inspection — both states are security incidents.

Set `HTTP_PROXY` / `HTTPS_PROXY` only if the proxy actually answers. Never blindly export — that breaks users who are off-corp-network.

```bash
detect_proxy() {
    local proxy_url="http://${PROXY_HOST}:${PROXY_PORT}"
    if curl -sf --connect-timeout 2 -o /dev/null "$proxy_url" 2>/dev/null; then
        export HTTP_PROXY="$proxy_url"
        export HTTPS_PROXY="$proxy_url"
        export http_proxy="$HTTP_PROXY"
        export https_proxy="$HTTPS_PROXY"
        export NO_PROXY="${NO_PROXY_LIST}"
        export no_proxy="$NO_PROXY"
    else
        unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
    fi
}
```

Always set both upper and lower case — Windows / Java / .NET prefer upper, Unix tools historically lower.

---

## 3. CA bundle handling

**Why:** corporate TLS inspection re-signs every HTTPS connection with an internal root; without that root in the trust store every CLI fails with `UNABLE_TO_GET_ISSUER_CERT`, and the wrong fix (`NODE_TLS_REJECT_UNAUTHORIZED=0`) silently disables certificate validation entirely.

Three layers, by preference:

1. **Node 22.15+**: `NODE_USE_SYSTEM_CA=1` — read the OS trust store directly. No file management needed.
2. **All Node**: `NODE_EXTRA_CA_CERTS=/path/to/corp.pem` — concatenated PEM bundle.
3. **Python**: `REQUESTS_CA_BUNDLE` + `SSL_CERT_FILE` — same PEM.
4. **Codex CLI (Rust)**: `CODEX_CA_CERTIFICATE=/path/to/corp.pem`.

Never `NODE_TLS_REJECT_UNAUTHORIZED=0` unless the user explicitly accepted the risk in Section 4 of the interview (`ACCEPT_TLS_INSPECTION=yes`).

### Auto-extraction at install time

```bash
extract_corp_ca() {
    local out="$1"
    case "$(uname -s)" in
        Darwin)
            security find-certificate -a -p \
                /System/Library/Keychains/SystemRootCertificates.keychain > "$out"
            security find-certificate -a -p /Library/Keychains/System.keychain >> "$out"
            ;;
        Linux)
            cat /etc/ssl/certs/ca-certificates.crt > "$out" 2>/dev/null \
                || cat /etc/pki/tls/certs/ca-bundle.crt > "$out" 2>/dev/null
            ;;
    esac
}
```

PowerShell:

```powershell
function Export-CorpCa {
    param([string]$OutPath)
    Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root |
      ForEach-Object {
        "-----BEGIN CERTIFICATE-----`n" +
        [Convert]::ToBase64String($_.RawData, 'InsertLineBreaks') +
        "`n-----END CERTIFICATE-----"
      } | Set-Content -Path $OutPath
}
```

---

## 4. Secret storage

**Why:** gateway tokens grant access to a paid LLM quota and (often) to internal data; storing them in plain dotfiles or env files puts them one `cat` or one stolen laptop away from corporate credential theft.

In order of preference:

1. **macOS Keychain**:
   ```bash
   security add-generic-password -s "${CORP_SLUG}" -a "$USER" -w "$TOKEN" -U
   TOKEN=$(security find-generic-password -s "${CORP_SLUG}" -a "$USER" -w)
   ```
2. **Windows Credential Manager** (via PowerShell module `CredentialManager` or `cmdkey`):
   ```powershell
   New-StoredCredential -Target "${env:CORP_SLUG}" -Username "$env:USERNAME" -Password $token -Persist LocalMachine
   $cred = Get-StoredCredential -Target "${env:CORP_SLUG}"
   ```
3. **Linux libsecret**:
   ```bash
   secret-tool store --label="${CORP_SLUG}" service "${CORP_SLUG}" username "$USER"
   secret-tool lookup service "${CORP_SLUG}" username "$USER"
   ```
4. **Fallback** (CI, headless): chmod 600 file.
   ```bash
   umask 077
   echo "$TOKEN" > "$HOME/.${CORP_SLUG}.conf"
   chmod 600 "$HOME/.${CORP_SLUG}.conf"
   ```

Never `echo $TOKEN` in any log. Always `read -rs` for prompts. Always `set +x` around secret-handling blocks.

---

## 5. Shell RC block (idempotent)

**Why:** re-running the installer must never duplicate exports or stack stale proxy values; a marker-delimited block keeps `.bashrc` / `.zshrc` clean and makes uninstall a single `sed` away — critical for fleet-wide rollout and rollback.

```bash
MARKER_START="# >>> ${CORP_SLUG} >>>"
MARKER_END="# <<< ${CORP_SLUG} <<<"

# remove existing block
if grep -qF "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
    cp "$SHELL_RC" "${SHELL_RC}.${CORP_SLUG}-backup"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "/${MARKER_START}/,/${MARKER_END}/d" "$SHELL_RC"
    else
        sed -i "/${MARKER_START}/,/${MARKER_END}/d" "$SHELL_RC"
    fi
fi

# append new block
{
    echo ""
    echo "$MARKER_START"
    echo "# ${CORP_NAME} — Powered by ${CORP_POWERED_BY}"
    echo "# Installed on $(date +%Y-%m-%d)"
    echo "${CORP_SLUG}() { \"${INSTALL_DIR}/${CORP_SLUG}\" \"\$@\"; }"
    echo "export ${CORP_SLUG_UPPER}_HOME=\"${INSTALL_DIR}\""
    echo "$MARKER_END"
} >> "$SHELL_RC"
```

PowerShell equivalent uses `$PROFILE.CurrentUserAllHosts` and the same marker pattern with `-replace` regex.

---

## 6. Prompt filter (cyber-guard)

**Why:** developers routinely paste keys, certs, or PANs into prompts; without a pre-tool gate those secrets leave the perimeter inside the model's context window and are effectively unrevocable once logged by the provider.

A hook executed before any tool call. Blocks if the user prompt contains forbidden patterns.

```python
#!/usr/bin/env python3
# Read from stdin, return JSON to control the tool call.
import json, sys, re

FORBIDDEN = [
    r"sk-[a-zA-Z0-9_-]{20,}",                     # API keys
    r"-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----",
    r"AKIA[0-9A-Z]{16}",                          # AWS access key id
    r"\b[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}\b",  # 16-digit cards
]

data = json.load(sys.stdin)
text = json.dumps(data.get("tool_input", {}))

for pat in FORBIDDEN:
    if re.search(pat, text):
        print(json.dumps({
            "permissionDecision": "deny",
            "reason": f"Pattern blocked by corporate cyber-guard: /{pat}/"
        }))
        sys.exit(0)

print(json.dumps({"permissionDecision": "allow"}))
```

Lock it down: `chmod 555` so the AI cannot modify it. Reference it from `settings.json`'s `PreToolUse` hook.

---

## 7. Strip-proxy (Bedrock / LiteLLM only)

**Why:** corporate gateways often sit behind Bedrock or LiteLLM, which emit non-spec SSE frames and reject unknown body fields; without local normalisation the CLI crashes mid-stream, users retry endlessly, and the gateway gets DoS'd by its own clients.

The middleware fixes SSE artefacts before they reach the CLI parser. Known issues:

- **Phantom empty text block** (Bedrock): inserts `content_block_start` with `text=""` then immediately `content_block_stop`. Filter both.
- **Post-`message_stop` events** (Bedrock): events emitted after the stream should end. Drop them.
- **`anthropic-beta` header strip** (LiteLLM): some betas are not supported by Bedrock. Strip from outgoing request.
- **`context_management` body field strip** (LiteLLM / Bedrock): rejected as "Extra inputs not permitted". Strip from outgoing body.

See `templates/shared/strip-proxy.js.tpl` for the implementation. Port: 9876 by default, override with `STRIP_PROXY_PORT`.

---

## 8. Telemetry kill switches

**Why:** every CLI ships with multiple background channels (Sentry, Datadog, Statsig, auto-updater) that exfiltrate stack traces, hostnames, and project paths to third parties — each one is a data-protection violation if left enabled inside the corporate perimeter.

Apply ALL of these in the launcher to prevent any third-party egress:

```bash
# Master kill (Claude Code)
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_SKIP_UPDATE_CHECK=1
export DISABLE_AUTOUPDATER=1

# Generic opt-out
export DO_NOT_TRACK=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1

# Sentry
export SENTRY_DSN=""

# Datadog
export DD_TRACE_ENABLED=0

# OpenTelemetry
export OTEL_EXPORTER_OTLP_ENDPOINT=""
export OTEL_EXPORTER_OTLP_HEADERS=""

# Feature flags
export STATSIG_DISABLED=1
export GROWTHBOOK_API_HOST=""

# Bun crash reports
export BUN_ENABLE_CRASH_REPORTING=0

# Feedback / surveys
export DISABLE_BUG_COMMAND=1
export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1

# Voice (Claude Code reaches *.anthropic.com directly)
export CLAUDE_CODE_DISABLE_VOICE=1
```

For Gemini CLI:
```bash
export GEMINI_TELEMETRY_ENABLED=false
```

For Codex CLI, edit `~/.codex/config.toml`:
```toml
[analytics] enabled = false
[feedback]  enabled = false
[history]   persistence = "none"
```

---

## 9. Permission lockdown

**Why:** an LLM under prompt injection can be coerced into running `rm -rf /` or force-pushing to `main`; a hook-layer denylist is the only guardrail that survives even `--dangerously-skip-permissions` and prevents single-prompt disasters.

Block the most destructive shell commands at the hook layer — even `bypassPermissions` cannot override a `deny` decision.

```python
DESTRUCTIVE = [
    r"\brm\s+-rf\s+/",
    r"\bdd\s+if=.*of=/dev/",
    r"\bmkfs\.",
    r"\b:>(:>?)*\(",            # fork bomb
    r"\bchmod\s+-R\s+777\s+/",
    r"\bgit\s+push\s+--force.*main",
    r"\bgit\s+reset\s+--hard\s+HEAD~",
]
```

Add these to the cyber-guard hook alongside the secret patterns.

---

## 10. DLP-friendly defaults

**Why:** SOC and DLP tools classify unknown clients as suspicious by default; making the launcher *identifiable and predictable* (UA string, port 443, no ESNI, request IDs) keeps it out of automated quarantine and gives incident responders the correlation handles they need.

- Send a recognizable `User-Agent`: `${CORP_NAME}/${VERSION} (corporate-cli; +${INTRANET_URL})`. SOC teams can allowlist that.
- Avoid Base64 of large payloads in tool calls — looks like exfil to most DLPs.
- Don't tunnel through unusual ports — stay on 443.
- Don't use ESNI / ECH on hosts whose traffic must be inspected (Zscaler will block).
- Include `X-Request-ID` (UUID per request) for SOC log correlation.

---

## 11. Token rotation

**Why:** long-lived bearer tokens are the single biggest credential-theft risk for an LLM gateway; short TTLs + automated refresh mean a leaked token expires before an attacker finishes pivoting, and revocation becomes a one-API-call operation instead of a fleet-wide reinstall.

### TTL recommendations

| Token class            | TTL       | Refresh window      | Storage                    |
|------------------------|-----------|---------------------|----------------------------|
| Interactive (CLI user) | 8 h       | refresh at 6 h      | OS keychain (Section 4)    |
| CI / batch             | 24 h      | refresh at 20 h     | secret manager (Vault/ASM) |
| Service-to-service     | 1 h       | refresh at 45 min   | in-memory only, never disk |
| Break-glass / admin    | 15 min    | no auto-refresh     | hardware-backed (YubiKey)  |

Never issue a token with TTL > 24 h. Never store a refresh token next to its access token (defeats the rotation invariant).

### Auto-refresh against the gateway admin API

```bash
refresh_token() {
    local current expires_at now new_token
    current=$(security find-generic-password -s "${CORP_SLUG}" -a "$USER" -w 2>/dev/null) || return 1
    expires_at=$(echo "$current" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r .exp)
    now=$(date +%s)
    # refresh when less than 25% of TTL remains
    if (( expires_at - now > 1800 )); then
        return 0
    fi
    new_token=$(curl -sf -X POST "${GATEWAY_ADMIN_URL}/tokens/refresh" \
        -H "Authorization: Bearer ${current}" \
        -H "X-Request-ID: $(uuidgen)" \
        --max-time 10) || {
            echo "Token refresh failed — re-authenticate via '${CORP_SLUG} login'." >&2
            return 1
        }
    security add-generic-password -s "${CORP_SLUG}" -a "$USER" -w "$new_token" -U
}
```

Call `refresh_token` at the top of the launcher entrypoint, before any LLM request.

PowerShell equivalent uses `Invoke-RestMethod` against the same endpoint and `Set-StoredCredential` to update the Credential Manager entry.

### Leak response runbook

When a token is suspected leaked (committed to git, pasted in chat, found in a log):

1. **Revoke immediately** — `curl -X DELETE ${GATEWAY_ADMIN_URL}/tokens/${TOKEN_ID}` (idempotent, safe to repeat).
2. **Rotate the user** — force a re-auth on next launcher invocation by deleting the keychain entry.
3. **Pull the audit trail** (Section 12) for that token_id and grep for unusual model/cost spikes.
4. **Notify** the corporate security office via the standard SOC ticket — include `token_id`, leak vector, observed scope.
5. **Scrub** the leak source: `git filter-repo`, retro-edit the chat message, purge log file.
6. **Post-mortem** within 5 business days; if the leak was an AI-assisted commit, add the pattern to the cyber-guard regex (Section 6).

Never reuse a revoked token ID — the gateway must refuse to re-issue one to prevent replay confusion in the audit trail.

---

## 12. Audit trail

**Why:** an LLM gateway is a privileged egress channel for code, prompts, and (eventually) personal data; without a tamper-evident audit trail the SOC cannot answer "who asked what to which model when, and what did it cost?" — which is exactly the question that comes up during every incident and every CNIL inspection.

### What the launcher logs (per request)

One JSON object per line, one line per LLM round-trip:

```json
{
  "ts": "2026-05-16T14:32:07.842Z",
  "session_id": "01HXYZ...ULID",
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "user": "0104389S",
  "host": "MBP-0104389S.local",
  "launcher_version": "1.4.2",
  "cli": "corporate-launcher",
  "model": "claude-opus-4-7",
  "route": "gateway.acme.example/v1/messages",
  "input_tokens": 4218,
  "output_tokens": 612,
  "cache_read_tokens": 31402,
  "cache_write_tokens": 0,
  "cost_eur": 0.0427,
  "latency_ms": 3814,
  "status": "ok",
  "token_id": "tok_4f9a..."
}
```

Mandatory fields: `ts`, `session_id`, `request_id`, `user`, `model`, `cost_eur`, `status`, `token_id`. **Never** log the prompt body, the response body, tool inputs, or the bearer token itself — only counts, identifiers, and metadata.

### Where (local sink)

- Path: `/tmp/${CORP_SLUG}-audit-$(date +%Y%m%d).jsonl` (rotates daily by filename).
- Permissions: created with `umask 077`, mode `0600`, owner = invoking user.
- Append-only: open with `O_APPEND`; never truncate, never rewrite, never edit in-place.
- Size cap: 50 MB per file; on overflow, rotate to `.1`, `.2`, … and gzip — never delete locally; the SIEM is the source of truth.

```bash
audit_log() {
    local line="$1"
    local f="/tmp/${CORP_SLUG}-audit-$(date +%Y%m%d).jsonl"
    ( umask 077; printf '%s\n' "$line" >> "$f" )
}
```

### How the SIEM ingests

1. **Filebeat / Vector agent** on each workstation tails `/tmp/${CORP_SLUG}-audit-*.jsonl`, ships over TLS to the corporate SIEM (Splunk / Elastic / Sentinel).
2. **Index policy**: hot for 30 days, warm for 1 year, cold (object storage, WORM) for 7 years per ACME retention policy.
3. **Parser**: declare each field as a typed column; `cost_eur` as float, `*_tokens` as long, `ts` as datetime UTC.
4. **Dashboards**: per-user daily cost, per-model usage mix, p95 latency by route, anomaly detection on `cost_eur` z-score per `token_id`.
5. **Alerts**: `cost_eur > 5` in a single request, `status != "ok"` rate > 5%/5min, any request from a `token_id` listed in the revocation feed (cross-ref Section 11).
6. **Access**: read-only role for FinOps (cost), full role for SOC (incident response), no role for the developer themselves on aggregate views — RGPD principle of least privilege.

The launcher must **fail open** on audit-log write errors (log to stderr, continue) but **fail closed** on token-rotation errors (Section 11) — losing one audit line is acceptable, sending a request with a stale token is not.
