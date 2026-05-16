# tpl: shared module — corporate AI gateway probe
# tpl: Sourced from install.sh.tpl when ${API_PROBE_ENABLED}=yes.
# tpl: NOT executed standalone — no shebang, no set -e. Caller controls flow.
#
# Wraps scripts/api-probe.py to verify:
#   - gateway reachability (latency)
#   - models endpoint (count + sample)
#   - authentication (token accepted)
#   - TLS posture (issuer + expiry)
#
# Exit semantics of api-probe.py:
#   0  ok
#   2  auth failure (401/403)
#   3  network unreachable / DNS / timeout
#   4  TLS certificate error
#   5  malformed URL / bad args
#
# Function:
#   probe_gateway       — run the probe, print a summary, save the JSON report

# tpl: Resolve the gateway URL the wrapped CLI actually uses.
# tpl: Each CLI flavour exposes its own variable name; pick the first that resolves.
_probe_resolve_url() {
    if [ -n "${CC_PRIMARY_URL:-}" ]; then
        printf '%s' "$\{CC_PRIMARY_URL\}"
        return 0
    fi
    if [ -n "${CX_PRIMARY_URL:-}" ]; then
        printf '%s' "$\{CX_PRIMARY_URL\}"
        return 0
    fi
    if [ -n "${LLM_OPENAI_BASE_URL:-}" ]; then
        printf '%s' "$\{LLM_OPENAI_BASE_URL\}"
        return 0
    fi
    # tpl: Gemini-CLI doesn't expose a single base URL: derive from backend.
    if [ -n "${GM_BACKEND:-}" ]; then
        case "$GM_BACKEND" in
            vertex)
                local loc="${GM_VERTEX_LOCATION:-global}"
                if [ "$loc" = "global" ]; then
                    printf 'https://aiplatform.googleapis.com'
                else
                    printf 'https://%s-aiplatform.googleapis.com' "$loc"
                fi
                return 0
                ;;
            ai-studio)
                # url-purge: allow — Gemini AI Studio base URL is built into the SDK; only used when GM_BACKEND=ai-studio.
                printf 'https://generativelanguage.googleapis.com'
                return 0
                ;;
        esac
    fi
    return 1
}

# tpl: Pick the probe backend hint that matches the wrapped CLI.
# tpl: Maps to api-probe.py's --backend choices: anthropic|openai|azure|vertex|litellm|bedrock-proxy|auto
_probe_resolve_backend() {
    # tpl: Explicit override wins.
    if [ -n "${CC_BACKEND_KEY:-}" ]; then
        printf '%s' "$\{CC_BACKEND_KEY\}"
        return 0
    fi
    if [ -n "${CX_BACKEND_KEY:-}" ]; then
        printf '%s' "$\{CX_BACKEND_KEY\}"
        return 0
    fi
    if [ -n "${LLM_BACKEND_KEY:-}" ]; then
        printf '%s' "$\{LLM_BACKEND_KEY\}"
        return 0
    fi
    # tpl: Gemini — map backend flag to probe backend name.
    if [ -n "${GM_BACKEND:-}" ]; then
        case "$GM_BACKEND" in
            vertex)    printf 'vertex'; return 0 ;;
            ai-studio) printf 'openai'; return 0 ;;
        esac
    fi
    # tpl: Otherwise let the python probe auto-detect from the host.
    printf 'auto'
    return 0
}

# tpl: Translate a probe exit code into actionable remediation lines.
_probe_remediation() {
    local code="$1"
    local url="$2"
    case "$code" in
        2)
            printf '  Hint: rotate the API token — current credential rejected (401/403).\n' >&2
            printf '        ${CORP_SLUG} --set-token        # store a fresh token\n' >&2
            printf '        ${CORP_SLUG} --revoke-token     # then re-register\n' >&2
            ;;
        3)
            printf '  Hint: network/DNS unreachable.\n' >&2
            printf '        - Connect to corporate VPN (profile: ${VPN_PROFILE_NAME}).\n' >&2
            printf '        - Verify proxy: echo "$HTTPS_PROXY"\n' >&2
            printf '        - DNS probe : curl -v --max-time 5 %s\n' "$url" >&2
            ;;
        4)
            printf '  Hint: TLS handshake failed — corporate inspection CA likely missing.\n' >&2
            printf '        ${CORP_SLUG} --refresh-ca       # re-extract from OS trust store\n' >&2
            printf '        export REQUESTS_CA_BUNDLE=%s/corp-ca-bundle.pem\n' "${INSTALL_DIR}" >&2
            ;;
        5)
            printf '  Hint: malformed URL — fix the gateway URL and re-run install.\n' >&2
            ;;
        127)
            printf '  Hint: python3 not found — install Python 3.8+ and re-run.\n' >&2
            ;;
        *)
            printf '  Hint: probe exited %s. Inspect %s/.api-probe-report.json for details.\n' \
                "$code" "${INSTALL_DIR}" >&2
            ;;
    esac
}

# tpl: Tiny JSON field extractors. Avoids a hard dep on jq.
# tpl: Pulls a string field "key" from a JSON blob in $1. Returns "" on miss.
_probe_json_str() {
    local blob="$1" key="$2"
    python3 - "$key" <<'PY' 2>/dev/null <<<"$blob"
import json, sys
key = sys.argv[1]
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
def walk(d, k):
    if isinstance(d, dict):
        if k in d and not isinstance(d[k], (dict, list)):
            print(d[k] if d[k] is not None else "")
            return True
        for v in d.values():
            if walk(v, k):
                return True
    return False
walk(data, key)
PY
}

probe_gateway() {
    # tpl: Step 0 — opt-out.
    if [ "${API_PROBE_ENABLED}" != "yes" ]; then
        return 0
    fi

    # tpl: Step 1 — locate the python probe. It's authored in parallel; defend
    # tpl: against the case where it hasn't shipped yet.
    local probe_py="${INSTALL_DIR}/scripts/api-probe.py"
    if [ ! -r "$probe_py" ]; then
        printf '\033[0;33m[%s] API probe skipped: %s not found.\033[0m\n' \
            "${CORP_NAME}" "$probe_py" >&2
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf '\033[0;33m[%s] API probe skipped: python3 not installed.\033[0m\n' \
            "${CORP_NAME}" >&2
        return 0
    fi

    # tpl: Step 2 — resolve URL + backend for the active CLI flavour.
    local url backend
    url=$(_probe_resolve_url) || {
        printf '\033[0;33m[%s] API probe skipped: no gateway URL bound for this CLI.\033[0m\n' \
            "${CORP_NAME}" >&2
        return 0
    }
    backend=$(_probe_resolve_backend)

    # tpl: Step 3 — secret material. Loaded by secrets-store.sh at install time.
    if [ -z "${CORP_API_KEY:-}" ]; then
        printf '\033[0;33m[%s] API probe skipped: CORP_API_KEY not loaded.\033[0m\n' \
            "${CORP_NAME}" >&2
        return 0
    fi

    local report_file="${INSTALL_DIR}/.api-probe-report.json"
    local report_tmp
    report_tmp=$(mktemp -t apiprobe.XXXXXX) || return 1

    printf '  Probing %s ...\n' "$url"

    # tpl: Step 4 — invoke the probe. Token is passed as an arg (process-local)
    # tpl: rather than via env so it never leaks into a child env dump.
    # tpl: Stderr from python is forwarded; stdout (JSON) captured to $report_tmp.
    python3 "$probe_py" \
        --url "$url" \
        --token "$CORP_API_KEY" \
        --backend "$backend" \
        --timeout 10 \
        > "$report_tmp" 2>&1
    local rc=$?

    # tpl: Step 5 — persist the report (mode 600 — may carry hostnames + token preview).
    if [ -s "$report_tmp" ]; then
        cp "$report_tmp" "$report_file" 2>/dev/null || true
        chmod 600 "$report_file" 2>/dev/null || true
    fi

    # tpl: Step 6 — read the JSON. If python crashed, $report_tmp may not be JSON;
    # tpl: degrade to a status-line summary in that case.
    local report=""
    if [ -s "$report_tmp" ]; then
        # tpl: cheap sanity check — first non-whitespace char must be '{'
        if head -c 1 "$report_tmp" 2>/dev/null | grep -q '{'; then
            report=$(cat "$report_tmp")
        fi
    fi
    rm -f "$report_tmp"

    # tpl: Step 7 — extract summary fields. Fallback to "?" when missing.
    local ok latency http_status models_count models_preview \
          tls_issuer tls_expires tls_error auth_label

    if [ -n "$report" ]; then
        ok=$(printf '%s' "$report"      | _probe_json_str "$report" ok 2>/dev/null)
        latency=$(printf '%s' "$report" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get("latency_ms")
    print("" if v is None else v)
except Exception:
    pass' 2>/dev/null <<<"$report")
        http_status=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get("http_status")
    print("" if v is None else v)
except Exception:
    pass' 2>/dev/null <<<"$report")
        models_count=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    m = d.get("models_available") or []
    print(len(m) if isinstance(m, list) else 0)
except Exception:
    print(0)' 2>/dev/null <<<"$report")
        models_preview=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    m = d.get("models_available") or []
    if isinstance(m, list):
        print(", ".join(str(x) for x in m[:5]))
except Exception:
    pass' 2>/dev/null <<<"$report")
        tls_issuer=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    t = d.get("tls") or {}
    print(t.get("cert_issuer") or t.get("subject_cn") or "")
except Exception:
    pass' 2>/dev/null <<<"$report")
        tls_expires=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    t = d.get("tls") or {}
    print(t.get("expires") or "")
except Exception:
    pass' 2>/dev/null <<<"$report")
        tls_error=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    t = d.get("tls") or {}
    print(t.get("error") or "")
except Exception:
    pass' 2>/dev/null <<<"$report")
        auth_label=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("auth") or "")
except Exception:
    pass' 2>/dev/null <<<"$report")
    fi

    # tpl: Step 8 — pretty summary. ANSI literal codes for portability;
    # tpl: keep dim/orange consistent with the rest of the launcher.
    local C_GREEN='\033[0;32m' C_RED='\033[0;31m' C_DIM='\033[2m' C_OFF='\033[0m'
    printf '\n  %sAPI gateway probe%s\n' "$C_DIM" "$C_OFF"

    # Reachability
    if [ "$rc" -eq 0 ] || [ -n "$latency" ]; then
        printf '    Gateway reachable : %syes%s  (%s ms, HTTP %s)\n' \
            "$C_GREEN" "$C_OFF" "${latency:-?}" "${http_status:-?}"
    else
        printf '    Gateway reachable : %sno%s\n' "$C_RED" "$C_OFF"
    fi

    # Models
    if [ -n "$models_count" ] && [ "$models_count" -gt 0 ] 2>/dev/null; then
        printf '    Models available  : %s  (%s)\n' "$models_count" "${models_preview:-—}"
    else
        printf '    Models available  : %s0%s\n' "$C_DIM" "$C_OFF"
    fi

    # Auth — true when probe returned 0 AND we got an http 2xx on /models.
    if [ "$rc" -eq 0 ]; then
        printf '    Auth validated    : %syes%s  (%s)\n' \
            "$C_GREEN" "$C_OFF" "${auth_label:-?}"
    elif [ "$rc" -eq 2 ]; then
        printf '    Auth validated    : %sno%s  (%s)\n' \
            "$C_RED" "$C_OFF" "${auth_label:-?}"
    else
        printf '    Auth validated    : %s?%s  (probe failed before auth check)\n' \
            "$C_DIM" "$C_OFF"
    fi

    # TLS
    if [ -n "$tls_error" ]; then
        printf '    TLS cert          : %s%s%s\n' "$C_RED" "$tls_error" "$C_OFF"
    elif [ -n "$tls_issuer" ] || [ -n "$tls_expires" ]; then
        printf '    TLS cert          : issuer=%s, expires=%s\n' \
            "${tls_issuer:-?}" "${tls_expires:-?}"
    else
        printf '    TLS cert          : %s(http or unknown)%s\n' "$C_DIM" "$C_OFF"
    fi

    # Path to full report
    if [ -r "$report_file" ]; then
        printf '    Report            : %s%s%s\n' "$C_DIM" "$report_file" "$C_OFF"
    fi

    # tpl: Step 9 — if the probe failed, surface remediation hints.
    # tpl: We treat ok="True" / rc=0 as the success path; anything else gets hints.
    if [ "$rc" -ne 0 ] || { [ -n "$ok" ] && [ "$ok" != "true" ] && [ "$ok" != "True" ]; }; then
        printf '  %sProbe reported failure (exit %s).%s\n' "$C_RED" "$rc" "$C_OFF" >&2
        _probe_remediation "$rc" "$url"
        # tpl: Non-fatal: install can still complete. Caller decides via return code.
        return "$rc"
    fi

    return 0
}
