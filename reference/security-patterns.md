# Security Patterns

Concrete patterns for the templates. Each subsection answers: "how do I express X correctly in shell / PowerShell / Python / Node?"

---

## 1. VPN gate

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

The middleware fixes SSE artefacts before they reach the CLI parser. Known issues:

- **Phantom empty text block** (Bedrock): inserts `content_block_start` with `text=""` then immediately `content_block_stop`. Filter both.
- **Post-`message_stop` events** (Bedrock): events emitted after the stream should end. Drop them.
- **`anthropic-beta` header strip** (LiteLLM): some betas are not supported by Bedrock. Strip from outgoing request.
- **`context_management` body field strip** (LiteLLM / Bedrock): rejected as "Extra inputs not permitted". Strip from outgoing body.

See `templates/shared/strip-proxy.js.tpl` for the implementation. Port: 9876 by default, override with `STRIP_PROXY_PORT`.

---

## 8. Telemetry kill switches

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

- Send a recognizable `User-Agent`: `${CORP_NAME}/${VERSION} (corporate-cli; +${INTRANET_URL})`. SOC teams can allowlist that.
- Avoid Base64 of large payloads in tool calls — looks like exfil to most DLPs.
- Don't tunnel through unusual ports — stay on 443.
- Don't use ESNI / ECH on hosts whose traffic must be inspected (Zscaler will block).
- Include `X-Request-ID` (UUID per request) for SOC log correlation.
