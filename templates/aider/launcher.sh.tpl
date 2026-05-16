#!/usr/bin/env bash
# =====================================================================
#  ${CORP_NAME} — Aider launcher
#  Powered by ${CORP_POWERED_BY}
#
#  Internal AI coding assistant for ${CORP_ORGANIZATION}.
#  - All traffic routed through the corporate gateway (LiteLLM-compatible)
#  - Telemetry / analytics / auto-update disabled
#  - Process-level isolation (no system changes)
#  - VPN required: ${VPN_REQUIRED}
# =====================================================================

set -euo pipefail

LAUNCHER_VERSION="${CORP_LAUNCHER_VERSION}"
LAUNCHER_SELF="$\{BASH_SOURCE[0]\}"
INSTALL_DIR="$(cd "$(dirname "$LAUNCHER_SELF")" && pwd)"
SCRIPTS_DIR="$INSTALL_DIR/scripts"

${CORP_SLUG_UPPER}_HOME="$\{${CORP_SLUG_UPPER}_HOME:-$INSTALL_DIR\}"

# tpl: ---------------------------------------------------------------------
# tpl: Colors — TTY only
# tpl: ---------------------------------------------------------------------
if [ -t 1 ]; then
    ORANGE="\033[38;5;${BANNER_COLOR_PRIMARY}m"
    BOLD="\033[1m"
    DIM="\033[2m"
    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    RESET="\033[0m"
else
    ORANGE=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

info() { printf '  $\{GREEN\}[OK]$\{RESET\} %s\n' "$*"; }
warn() { printf '  $\{YELLOW\}[!]$\{RESET\}  %s\n' "$*" >&2; }
fail() { printf '  $\{RED\}[KO]$\{RESET\} %s\n' "$*" >&2; }

# tpl: ---------------------------------------------------------------------
# tpl: Exports needed by the sourced shared modules
# tpl: ---------------------------------------------------------------------
export CORP_NAME="${CORP_NAME}"
export CORP_SLUG="${CORP_SLUG}"
export CORP_SLUG_UPPER="${CORP_SLUG_UPPER}"
export CORP_POWERED_BY="${CORP_POWERED_BY}"
export LLM_TOKEN_URL="${LLM_TOKEN_URL}"

export VPN_REQUIRED="${VPN_REQUIRED}"
export VPN_PROBE_URL="${VPN_PROBE_URL}"

export PROXY_HOST="${PROXY_HOST}"
export PROXY_PORT="${PROXY_PORT}"
export NO_PROXY_LIST="${NO_PROXY_LIST}"

export CA_BUNDLE_PATH="${CA_BUNDLE_PATH}"
export ACCEPT_TLS_INSPECTION="${ACCEPT_TLS_INSPECTION}"

# tpl: ---------------------------------------------------------------------
# tpl: Load shared modules
# tpl: ---------------------------------------------------------------------
for mod in vpn-check.sh proxy-detect.sh secrets-store.sh; do
    if [ ! -r "$SCRIPTS_DIR/$mod" ]; then
        fail "Missing shared module: $SCRIPTS_DIR/$mod"
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$SCRIPTS_DIR/$mod"
done

set_terminal_title() {
    [ -t 1 ] || return 0
    printf '\033]0;${TERMINAL_TITLE}\033\\'
}

show_banner() {
    [ -t 1 ] || return 0
    set_terminal_title
    printf '\n'
    printf '$\{ORANGE\}$\{BOLD\}  ╔═══════════════════════════════════════════════╗$\{RESET\}\n'
    printf '$\{ORANGE\}$\{BOLD\}  ║  %-44s ║$\{RESET\}\n' "${CORP_NAME}"
    printf '$\{ORANGE\}$\{BOLD\}  ║  %-44s ║$\{RESET\}\n' "Powered by ${CORP_POWERED_BY}"
    printf '$\{ORANGE\}$\{BOLD\}  ╚═══════════════════════════════════════════════╝$\{RESET\}\n'
    printf '\n  $\{DIM\}Proudly made from France with $\{RESET\}$\{RED\}❤️$\{RESET\}\n'
}

# =====================================================================
#  TELEMETRY KILL SWITCHES
# =====================================================================
disable_telemetry() {
    # tpl: Aider-specific opt-outs (mirrored in ~/.aider.conf.yml)
    export AIDER_ANALYTICS_DISABLE=1
    export AIDER_CHECK_UPDATE=false
    export AIDER_SHOW_RELEASE_NOTES=false
    export AIDER_VERIFY_SSL="$\{AIDER_VERIFY_SSL:-true\}"

    # tpl: Generic + transitive (LiteLLM, requests, etc.)
    export DO_NOT_TRACK=1
    export DISABLE_TELEMETRY=1
    export DISABLE_ERROR_REPORTING=1
    export SENTRY_DSN=""
    export OTEL_EXPORTER_OTLP_ENDPOINT=""
    export OTEL_SDK_DISABLED=true
    export STATSIG_DISABLED=1
    export LITELLM_LOG=ERROR
    export LITELLM_TELEMETRY=False
}

# =====================================================================
#  GATEWAY ENV — OpenAI-compatible (LiteLLM proxy in front of any backend)
# =====================================================================
setup_gateway_env() {
    # tpl: Aider speaks the OpenAI Chat Completions wire format via LiteLLM,
    # tpl: so the only knobs we need are OPENAI_API_BASE + OPENAI_API_KEY.
    # tpl: The model name is selected via AIDER_MODEL.
    export OPENAI_API_BASE="${LLM_OPENAI_BASE_URL}"
    export OPENAI_API_KEY="$CORP_API_KEY"

    # tpl: Some libs read OPENAI_BASE_URL (without "API"). Mirror it.
    export OPENAI_BASE_URL="${LLM_OPENAI_BASE_URL}"

    # tpl: Primary model — overridable via ${CORP_SLUG_UPPER}_MODEL.
    # tpl: NEVER hard-code a specific model here — always honor the tenant config.
    export AIDER_MODEL="$\{${CORP_SLUG_UPPER}_MODEL:-${LLM_PRIMARY_MODEL}\}"

    # tpl: Weak / cheap model for commit messages, summaries — fall back to primary
    export AIDER_WEAK_MODEL="$\{${CORP_SLUG_UPPER}_WEAK_MODEL:-${LLM_WEAK_MODEL}\}"
    if [ -z "$\{AIDER_WEAK_MODEL:-\}" ]; then
        export AIDER_WEAK_MODEL="$AIDER_MODEL"
    fi

    # tpl: Point aider at the managed config file we wrote at install time
    export AIDER_CONFIG="$\{AIDER_CONFIG:-$HOME/.aider.conf.yml\}"

    # tpl: Session markers
    export ${CORP_SLUG_UPPER}_ACTIVE=1
    export ${CORP_SLUG_UPPER}_SESSION_START=$(date +%s)
    export ${CORP_SLUG_UPPER}_VERSION="$LAUNCHER_VERSION"
}

# =====================================================================
#  TLS / CA bundle for Python (requests / httpx / LiteLLM)
# =====================================================================
setup_python_tls() {
    # tpl: The shared proxy-detect module already exports REQUESTS_CA_BUNDLE,
    # tpl: SSL_CERT_FILE and NODE_EXTRA_CA_CERTS when CA_BUNDLE_PATH is set.
    # tpl: We make doubly sure here for Aider (pure Python via httpx).
    if [ -n "${CA_BUNDLE_PATH}" ] && [ -r "${CA_BUNDLE_PATH}" ]; then
        export REQUESTS_CA_BUNDLE="${CA_BUNDLE_PATH}"
        export SSL_CERT_FILE="${CA_BUNDLE_PATH}"
        export CURL_CA_BUNDLE="${CA_BUNDLE_PATH}"
        # tpl: httpx looks at this one
        export HTTPX_SSL_CERT_FILE="${CA_BUNDLE_PATH}"
        export AIDER_VERIFY_SSL=true
    elif [ "${ACCEPT_TLS_INSPECTION}" = "yes" ]; then
        # tpl: Tenant explicitly accepted TLS-inspection without providing a CA
        # tpl: bundle — disable verification only in this process tree.
        export AIDER_VERIFY_SSL=false
        export PYTHONHTTPSVERIFY=0
        warn "TLS verification disabled (tenant policy: ACCEPT_TLS_INSPECTION=yes)"
    fi
}

# =====================================================================
#  ISOLATION
# =====================================================================
setup_isolation() {
    load_api_key
    if [ -z "$\{CORP_API_KEY:-\}" ]; then
        prompt_for_api_key
    fi

    setup_proxy
    setup_ca_bundle
    setup_python_tls
    disable_telemetry
    setup_gateway_env
}

# =====================================================================
#  COMMANDS
# =====================================================================
cmd_help() {
    cat <<EOF_HELP
${CORP_NAME} — Powered by ${CORP_POWERED_BY}

Usage:
  ${CORP_SLUG}                Launch the assistant (interactive)
  ${CORP_SLUG} --help         Show this help
  ${CORP_SLUG} --version      Show version
  ${CORP_SLUG} --status       Check VPN, gateway, isolation
  ${CORP_SLUG} --set-key      Reset / change the API token
  ${CORP_SLUG} --cost         Local cost log (session / today / history)
  ${CORP_SLUG} --dry-run      Print resolved env and exit (no aider run)
  ${CORP_SLUG} --uninstall    Run the uninstaller

Environment overrides:
  ${CORP_SLUG_UPPER}_MODEL       override the default model
  ${CORP_SLUG_UPPER}_WEAK_MODEL  override the weak / cheap model
  ${CORP_SLUG_UPPER}_DRY_RUN=1   same as --dry-run

Any other argument is forwarded verbatim to \`aider\`.
EOF_HELP
}

cmd_status() {
    show_banner
    printf '$\{BOLD\}Diagnostics$\{RESET\}\n'
    if check_vpn 2>/dev/null; then
        printf '  $\{GREEN\}[OK]$\{RESET\} VPN reachable\n'
    else
        printf '  $\{RED\}[KO]$\{RESET\} VPN not detected\n'
    fi
    if [ -n "$\{CORP_API_KEY:-\}" ] || { load_api_key 2>/dev/null && [ -n "$\{CORP_API_KEY:-\}" ]; }; then
        printf '  $\{GREEN\}[OK]$\{RESET\} API token loaded\n'
    else
        printf '  $\{YELLOW\}[!] $\{RESET\} API token missing — run "${CORP_SLUG} --set-key"\n'
    fi
    printf '  Backend     : ${LLM_BACKEND}\n'
    printf '  Gateway     : ${LLM_OPENAI_BASE_URL}\n'
    printf '  Model       : %s\n' "$\{${CORP_SLUG_UPPER}_MODEL:-${LLM_PRIMARY_MODEL}\}"
    printf '  Weak model  : %s\n' "$\{${CORP_SLUG_UPPER}_WEAK_MODEL:-${LLM_WEAK_MODEL}\}"
    printf '  Config file : %s\n' "$\{AIDER_CONFIG:-$HOME/.aider.conf.yml\}"
    printf '  CA bundle   : %s\n' "$\{CA_BUNDLE_PATH:-<system>\}"
    printf '  HTTP proxy  : %s\n' "$\{HTTP_PROXY:-<none>\}"
}

cmd_set_key() {
    show_banner
    prompt_for_api_key
    printf '$\{GREEN\}[OK]$\{RESET\} token saved.\n'
}

cmd_cost() {
    python3 "$INSTALL_DIR/scripts/cost-tracker.py" "$\{1:-session\}"
}

cmd_uninstall() {
    bash "$INSTALL_DIR/uninstall.sh"
}

cmd_version() {
    printf '${CORP_NAME} v%s — Powered by ${CORP_POWERED_BY}\n' "$LAUNCHER_VERSION"
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

    # tpl: dry-run mode — print the resolved env and exit (CI / debugging)
    if [ "$\{1:-\}" = "--dry-run" ] || [ "$\{${CORP_SLUG_UPPER}_DRY_RUN:-0\}" = "1" ]; then
        show_banner
        printf '$\{BOLD\}DRY RUN$\{RESET\} — environment ready, would exec: aider %s\n\n' "$*"
        env | grep -E '^(OPENAI_|AIDER_|REQUESTS_CA_BUNDLE|SSL_CERT_FILE|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|${CORP_SLUG_UPPER}_)' \
            | grep -v -E '_API_KEY=' \
            | sort
        exit 0
    fi

    show_banner

    if ! command -v aider >/dev/null 2>&1; then
        fail "aider binary not found in PATH."
        fail "Re-run the installer: $INSTALL_DIR/install.sh"
        exit 127
    fi

    # tpl: exec — replace the launcher process; no eval, no curl|sh
    exec aider "$@"
}

main "$@"
