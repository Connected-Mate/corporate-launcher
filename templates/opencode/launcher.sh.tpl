#!/usr/bin/env bash
# =====================================================================
#  ${CORP_NAME}
#  Powered by ${CORP_POWERED_BY}
#
#  Internal AI coding TUI for ${CORP_ORGANIZATION}.
#  - All traffic routed through the corporate gateway (OpenAI-compatible)
#  - Telemetry disabled (DO_NOT_TRACK + OPENCODE_DISABLE_TELEMETRY)
#  - Identity rebranded via opencode.json
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
#  ISOLATION — set every env var, never touch the system
# =====================================================================
setup_isolation() {
    load_api_key
    if [ -z "$\{CORP_API_KEY:-\}" ]; then
        prompt_for_api_key
    fi

    # tpl: OpenAI-compatible env vars consumed both by opencode.json {env:...}
    # tpl: substitution AND as a fallback for any tool reading raw env.
    export OPENAI_BASE_URL="${LLM_OPENAI_BASE_URL}"
    export OPENAI_API_KEY="$CORP_API_KEY"

    # tpl: corporate proxy + CA bundle (NODE_EXTRA_CA_CERTS if CA_BUNDLE_PATH set)
    setup_proxy
    setup_ca_bundle

    # tpl: telemetry kill switches — no master switch, use generic + project-specific
    export OPENCODE_DISABLE_TELEMETRY=1
    export DO_NOT_TRACK=1
    export DISABLE_TELEMETRY=1
    export DISABLE_ERROR_REPORTING=1
    export SENTRY_DSN=""
    export OTEL_EXPORTER_OTLP_ENDPOINT=""
    export OTEL_EXPORTER_OTLP_HEADERS=""

    # tpl: pin config path so opencode reads the managed file
    export OPENCODE_CONFIG="$\{OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json\}"

    # tpl: session marker
    export ${CORP_SLUG_UPPER}_ACTIVE=1
    export ${CORP_SLUG_UPPER}_SESSION_START=$(date +%s)
    export ${CORP_SLUG_UPPER}_VERSION="1.0.0"
}

# =====================================================================
#  COMMANDS
# =====================================================================
cmd_help() {
    cat <<EOF
${CORP_NAME} — Powered by ${CORP_POWERED_BY}

Usage:
  ${CORP_SLUG}                Launch the TUI
  ${CORP_SLUG} --help         Show this help
  ${CORP_SLUG} --version      Show version + diagnostics
  ${CORP_SLUG} --status       Check VPN, gateway, isolation
  ${CORP_SLUG} --set-key      Reset / change the API token
  ${CORP_SLUG} --cost         Local cost log (session / today / history)
  ${CORP_SLUG} --uninstall    Run the uninstaller

Environment overrides:
  ${CORP_SLUG_UPPER}_DRY_RUN=1   Print env and exit without launching
  OPENCODE_CONFIG                Override config file path
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
    printf '  Gateway     : ${LLM_OPENAI_BASE_URL}\n'
    printf '  Model       : ${LLM_PRIMARY_MODEL}\n'
    printf '  Config      : %s\n' "$\{OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json\}"
    if [ -f "$\{OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json\}" ]; then
        printf '  $\{GREEN\}[OK]$\{RESET\} opencode.json present\n'
    else
        printf '  $\{YELLOW\}[!] $\{RESET\} opencode.json missing — re-run install.sh\n'
    fi
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
        printf 'DRY RUN — environment ready, would exec: opencode %s\n' "$*"
        env | grep -E '^(OPENAI_|OPENCODE_|${CORP_SLUG_UPPER}_|DO_NOT_TRACK)' | sort
        exit 0
    fi

    if ! command -v opencode >/dev/null 2>&1; then
        printf '$\{RED\}[KO]$\{RESET\} opencode CLI not found. Re-run install.sh.\n' >&2
        exit 1
    fi

    exec opencode "$@"
}

main "$@"
