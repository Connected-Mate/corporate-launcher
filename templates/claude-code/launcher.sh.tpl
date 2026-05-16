#!/usr/bin/env bash
# =====================================================================
#  ${CORP_NAME}
#  Powered by ${CORP_POWERED_BY}
#
#  Internal AI coding assistant for ${CORP_ORGANIZATION}.
#  - All traffic routed through the corporate gateway
#  - Telemetry disabled
#  - Identity rebranded
#  - Process-level isolation (no system changes)
#  - VPN required: ${VPN_REQUIRED}
# =====================================================================

set -euo pipefail

${CORP_SLUG_UPPER}_HOME="$\{${CORP_SLUG_UPPER}_HOME:-$(cd "$(dirname "$\{BASH_SOURCE[0]\}")" && pwd)\}"

# tpl: --- load shared modules ---
# shellcheck source=/dev/null
source "$\{${CORP_SLUG_UPPER}_HOME\}/scripts/vpn-check.sh"
# shellcheck source=/dev/null
source "$\{${CORP_SLUG_UPPER}_HOME\}/scripts/proxy-detect.sh"
# shellcheck source=/dev/null
source "$\{${CORP_SLUG_UPPER}_HOME\}/scripts/secrets-store.sh"

# tpl: --- ANSI colors ---
ORANGE="\033[38;5;${BANNER_COLOR_PRIMARY}m"
BOLD="\033[1m"
DIM="\033[2m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

set_terminal_title() {
    printf '\033]0;${TERMINAL_TITLE}\033\\'
}

show_banner() {
    set_terminal_title
    printf '\n'
    printf '$\{ORANGE\}$\{BOLD\}  ╔═══════════════════════════════════════════════╗$\{RESET\}\n'
    printf '$\{ORANGE\}$\{BOLD\}  ║  %-44s ║$\{RESET\}\n' "${CORP_NAME}"
    printf '$\{ORANGE\}$\{BOLD\}  ║  %-44s ║$\{RESET\}\n' "Powered by ${CORP_POWERED_BY}"
    printf '$\{ORANGE\}$\{BOLD\}  ╚═══════════════════════════════════════════════╝$\{RESET\}\n'
    printf '\n'
}

# =====================================================================
#  STRIP PROXY (for Bedrock / LiteLLM SSE artefacts)
# =====================================================================
ensure_strip_proxy() {
    # tpl: only start if this tenant needs it
    if [ "${CC_NEEDS_STRIP_PROXY}" != "yes" ]; then
        return 0
    fi

    local upstream="$1"
    STRIP_PROXY_PORT="$\{STRIP_PROXY_PORT:-9876\}"
    local proxy_script="$\{${CORP_SLUG_UPPER}_HOME\}/scripts/strip-proxy.js"
    local pid_file="/tmp/${CORP_SLUG}-strip-proxy.pid"
    local log_file="/tmp/${CORP_SLUG}-strip-proxy.log"
    local lock_file="/tmp/${CORP_SLUG}-strip-proxy.lock"

    if lsof -iTCP:"$STRIP_PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        return 0
    fi

    if [ ! -f "$proxy_script" ]; then
        printf '$\{YELLOW\}[!] strip-proxy.js missing: %s$\{RESET\}\n' "$proxy_script" >&2
        return 1
    fi
    if ! command -v node >/dev/null 2>&1; then
        printf '$\{YELLOW\}[!] node required for strip-proxy, not found$\{RESET\}\n' >&2
        return 1
    fi

    (
        if command -v flock >/dev/null 2>&1; then
            flock -w 5 9 || exit 1
        fi
        if lsof -iTCP:"$STRIP_PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
            exit 0
        fi
        STRIP_PROXY_PORT="$STRIP_PROXY_PORT" \
        STRIP_PROXY_UPSTREAM="$upstream" \
            nohup node "$proxy_script" >"$log_file" 2>&1 &
        echo $! > "$pid_file"
        disown 2>/dev/null || true
        local i=0
        while [ "$i" -lt 30 ]; do
            if lsof -iTCP:"$STRIP_PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
                exit 0
            fi
            sleep 0.1
            i=$((i + 1))
        done
        exit 1
    ) 9>"$lock_file"
}

# =====================================================================
#  ISOLATION — set every env var, never touch the system
# =====================================================================
setup_isolation() {
    load_api_key
    if [ -z "$\{CORP_API_KEY:-\}" ]; then
        prompt_for_api_key
    fi

    # tpl: backend routing
    local upstream_url="${CC_PRIMARY_URL}"

    # tpl: Claude Code talks to the strip-proxy on localhost which forwards to the gateway
    if [ "${CC_NEEDS_STRIP_PROXY}" = "yes" ]; then
        ensure_strip_proxy "$upstream_url"
        export ANTHROPIC_BASE_URL="http://127.0.0.1:$\{STRIP_PROXY_PORT:-9876\}"
    else
        export ANTHROPIC_BASE_URL="$upstream_url"
    fi

    export ANTHROPIC_AUTH_TOKEN="$CORP_API_KEY"
    export ANTHROPIC_MODEL="$\{${CORP_SLUG_UPPER}_MODEL:-${CC_PRIMARY_MODEL}\}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${CC_HAIKU_MODEL}"

    # tpl: corporate proxy + CA bundle
    setup_proxy
    setup_ca_bundle

    # tpl: telemetry kill switches
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    export CLAUDE_CODE_SKIP_UPDATE_CHECK=1
    export DISABLE_AUTOUPDATER=1
    export DO_NOT_TRACK=1
    export DISABLE_TELEMETRY=1
    export DISABLE_ERROR_REPORTING=1
    export SENTRY_DSN=""
    export DD_TRACE_ENABLED=0
    export OTEL_EXPORTER_OTLP_ENDPOINT=""
    export OTEL_EXPORTER_OTLP_HEADERS=""
    export STATSIG_DISABLED=1
    export GROWTHBOOK_API_HOST=""
    export BUN_ENABLE_CRASH_REPORTING=0
    export DISABLE_BUG_COMMAND=1
    export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
    export CLAUDE_CODE_DISABLE_VOICE=1

    # tpl: session marker
    export ${CORP_SLUG_UPPER}_ACTIVE=1
    export ${CORP_SLUG_UPPER}_SESSION_START=$(date +%s)

    # tpl: user-agent for SOC log correlation
    export ${CORP_SLUG_UPPER}_VERSION="1.0.0"
}

# =====================================================================
#  COMMANDS
# =====================================================================
cmd_help() {
    cat <<EOF
${CORP_NAME} — Powered by ${CORP_POWERED_BY}

Usage:
  ${CORP_SLUG}                Launch the assistant
  ${CORP_SLUG} --help         Show this help
  ${CORP_SLUG} --version      Show version + diagnostics
  ${CORP_SLUG} --status       Check VPN, gateway, isolation
  ${CORP_SLUG} --set-key      Reset / change the API token
  ${CORP_SLUG} --cost         Local cost log (session / today / history)
  ${CORP_SLUG} --uninstall    Run the uninstaller

Environment overrides:
  ${CORP_SLUG_UPPER}_MODEL    override the default model
EOF
}

cmd_status() {
    show_banner
    printf '$\{BOLD\}Diagnostics$\{RESET\}\n'
    if check_vpn 2>/dev/null; then
        printf '  $\{GREEN\}[OK]$\{RESET\} VPN reachable\n'
    else
        printf '  $\{RED\}[KO]$\{RESET\} VPN not detected\n'
    fi
    if [ -n "$\{CORP_API_KEY:-\}" ] || load_api_key 2>/dev/null && [ -n "$\{CORP_API_KEY:-\}" ]; then
        printf '  $\{GREEN\}[OK]$\{RESET\} API token loaded\n'
    else
        printf '  $\{YELLOW\}[!] $\{RESET\} API token missing — run "${CORP_SLUG} --set-key"\n'
    fi
    printf '  Backend     : ${CC_BACKEND}\n'
    printf '  Gateway     : ${CC_PRIMARY_URL}\n'
    printf '  Model       : %s\n' "$\{${CORP_SLUG_UPPER}_MODEL:-${CC_PRIMARY_MODEL}\}"
    printf '  Strip-proxy : ${CC_NEEDS_STRIP_PROXY}\n'
}

cmd_set_key() {
    show_banner
    prompt_for_api_key
    printf '$\{GREEN\}[OK]$\{RESET\} token saved.\n'
}

cmd_cost() {
    python3 "$\{${CORP_SLUG_UPPER}_HOME\}/scripts/cost-tracker.py" "$\{1:-session\}"
}

cmd_uninstall() {
    bash "$\{${CORP_SLUG_UPPER}_HOME\}/uninstall.sh"
}

cmd_version() {
    printf '${CORP_NAME} v1.0.0 — Powered by ${CORP_POWERED_BY}\n'
}

# =====================================================================
#  ENTRY POINT
# =====================================================================
main() {
    case "$\{1:-\}" in
        --help|-h)        cmd_help; exit 0 ;;
        --version)        cmd_version; exit 0 ;;
        --status)         cmd_status; exit 0 ;;
        --set-key)        cmd_set_key; exit 0 ;;
        --cost)           shift; cmd_cost "$@"; exit 0 ;;
        --uninstall)      cmd_uninstall; exit 0 ;;
    esac

    if [ "${VPN_REQUIRED}" = "yes" ]; then
        check_vpn || exit 1
    fi

    setup_isolation
    show_banner

    # tpl: dry-run mode for CI / testing
    if [ "$\{${CORP_SLUG_UPPER}_DRY_RUN:-0\}" = "1" ]; then
        printf 'DRY RUN — environment ready, would exec: claude %s\n' "$*"
        env | grep -E '^(ANTHROPIC_|CLAUDE_CODE_|${CORP_SLUG_UPPER}_)' | sort
        exit 0
    fi

    # tpl: append the BRANDING + cyber rules to the system prompt
    local prompt_file="$\{${CORP_SLUG_UPPER}_HOME\}/BRANDING.md"
    local cyber_file="$\{${CORP_SLUG_UPPER}_HOME\}/cyber-rules.md"
    local args=()
    [ -f "$prompt_file" ] && args+=(--append-system-prompt-file "$prompt_file")
    [ -f "$cyber_file" ]  && args+=(--append-system-prompt-file "$cyber_file")

    exec claude "$\{args[@]\}" "$@"
}

main "$@"
