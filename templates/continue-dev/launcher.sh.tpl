#!/usr/bin/env bash
# =====================================================================
#  ${CORP_NAME} — Continue.dev launcher
#  Powered by ${CORP_POWERED_BY}
#
#  Continue.dev is a VS Code / JetBrains extension, not a CLI.
#  This launcher prepares the corporate environment (CA bundle, proxy,
#  API token) and renders ~/.continue/config.yaml so the extension
#  talks to the corporate LLM gateway. It does not spawn the IDE
#  itself — opening VS Code is the user's job.
#
#  - All traffic routed through the corporate gateway
#  - Telemetry / analytics disabled at config level
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
# tpl: Load shared modules (sit next to this launcher)
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
#  IDE / EXTENSION DETECTION
# =====================================================================
detect_continue_extension() {
    # tpl: VS Code (and forks: VSCodium, Cursor) all expose a `code`-style CLI
    # tpl: with --list-extensions. We try them in order.
    local cli
    for cli in code code-insiders codium cursor; do
        if command -v "$cli" >/dev/null 2>&1; then
            if "$cli" --list-extensions 2>/dev/null | grep -qi '^Continue\.continue$'; then
                CONTINUE_IDE="$cli"
                return 0
            fi
        fi
    done

    # tpl: JetBrains — plugin lives under the per-IDE plugins directory.
    # tpl: We check a few common product roots under $HOME/Library (macOS)
    # tpl: and $HOME/.local/share (Linux). Match any "*continue*" folder.
    local jb_root
    for jb_root in \
        "$HOME/Library/Application Support/JetBrains" \
        "$HOME/.local/share/JetBrains" \
        "$HOME/.config/JetBrains"; do
        if [ -d "$jb_root" ]; then
            if find "$jb_root" -maxdepth 3 -type d -iname '*continue*' 2>/dev/null | grep -q .; then
                CONTINUE_IDE="jetbrains"
                return 0
            fi
        fi
    done

    return 1
}

# =====================================================================
#  TELEMETRY KILL SWITCHES (process-level)
# =====================================================================
disable_telemetry() {
    # tpl: Continue.dev exposes `allowAnonymousTelemetry` in config.yaml.
    # tpl: We also set process-wide kill switches for any transitive lib.
    export DO_NOT_TRACK=1
    export DISABLE_TELEMETRY=1
    export DISABLE_ERROR_REPORTING=1
    export SENTRY_DSN=""
    export OTEL_EXPORTER_OTLP_ENDPOINT=""
    export OTEL_SDK_DISABLED=true
    export STATSIG_DISABLED=1
    export CONTINUE_GLOBAL_DIR="$\{CONTINUE_GLOBAL_DIR:-$HOME/.continue\}"
}

# =====================================================================
#  GATEWAY ENV — OpenAI-compatible
# =====================================================================
setup_gateway_env() {
    # tpl: Continue.dev reads keys from its own config.yaml, but several
    # tpl: tools it shells out to (linters, formatters, custom MCP servers)
    # tpl: read OPENAI_API_BASE / OPENAI_API_KEY. Mirror them.
    export OPENAI_API_BASE="${LLM_OPENAI_BASE_URL}"
    export OPENAI_BASE_URL="${LLM_OPENAI_BASE_URL}"
    export OPENAI_API_KEY="$CORP_API_KEY"

    # tpl: Session markers
    export ${CORP_SLUG_UPPER}_ACTIVE=1
    export ${CORP_SLUG_UPPER}_SESSION_START=$(date +%s)
    export ${CORP_SLUG_UPPER}_VERSION="$LAUNCHER_VERSION"
}

# =====================================================================
#  CONFIG.YAML RENDERING
# =====================================================================
render_continue_config() {
    local cfg_dir="$HOME/.continue"
    local cfg_file="$cfg_dir/config.yaml"
    local renderer="$SCRIPTS_DIR/render-continue-config.py"

    mkdir -p "$cfg_dir"

    # tpl: Back up any existing user config once
    if [ -f "$cfg_file" ] && [ ! -f "$cfg_file.${CORP_SLUG}.bak" ]; then
        cp "$cfg_file" "$cfg_file.${CORP_SLUG}.bak"
    fi

    # tpl: Prefer the Python renderer if available (richer templating,
    # tpl: preserves user-defined customCommands, slashCommands, etc.).
    if [ -x "$renderer" ] && command -v python3 >/dev/null 2>&1; then
        CORP_NAME="${CORP_NAME}" \
        CORP_SLUG="${CORP_SLUG}" \
        LLM_OPENAI_BASE_URL="${LLM_OPENAI_BASE_URL}" \
        LLM_PRIMARY_MODEL="${LLM_PRIMARY_MODEL}" \
        CORP_API_KEY="$CORP_API_KEY" \
        CA_BUNDLE_PATH="${CA_BUNDLE_PATH}" \
            python3 "$renderer" --output "$cfg_file"
        return 0
    fi

    # tpl: Inline fallback. Schema follows Continue config.yaml v1
    # tpl: (https://docs.continue.dev/reference). API key is referenced
    # tpl: by literal value here; the file is chmod 600 to protect it.
    (
        umask 077
        cat > "$cfg_file" <<EOF_CFG
# Managed by ${CORP_NAME} — do not edit by hand.
# Regenerate with: ${CORP_SLUG} --status (rewrites this file).
name: ${CORP_NAME}
version: 1.0.0
schema: v1
allowAnonymousTelemetry: false

models:
  - name: ${CORP_NAME} (primary)
    provider: openai
    model: ${LLM_PRIMARY_MODEL}
    apiBase: ${LLM_OPENAI_BASE_URL}
    apiKey: ${CORP_API_KEY}
    roles:
      - chat
      - edit
      - apply
      - summarize

  - name: ${CORP_NAME} (autocomplete)
    provider: openai
    model: ${LLM_PRIMARY_MODEL}
    apiBase: ${LLM_OPENAI_BASE_URL}
    apiKey: ${CORP_API_KEY}
    roles:
      - autocomplete

context:
  - provider: code
  - provider: diff
  - provider: terminal
  - provider: open
EOF_CFG
    )
    chmod 600 "$cfg_file"
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
    disable_telemetry
    setup_gateway_env
}

# =====================================================================
#  COMMANDS
# =====================================================================
cmd_help() {
    cat <<EOF_HELP
${CORP_NAME} — Continue.dev — Powered by ${CORP_POWERED_BY}

Continue.dev is an IDE extension, not a CLI. This command configures
your VS Code / JetBrains extension to use the corporate LLM gateway.

Usage:
  ${CORP_SLUG}                Configure Continue.dev and print next steps
  ${CORP_SLUG} --help         Show this help
  ${CORP_SLUG} --version      Show version
  ${CORP_SLUG} --status       Check VPN, gateway, IDE extension, config
  ${CORP_SLUG} --set-key      Reset / change the API token
  ${CORP_SLUG} --cost         Local cost log (session / today / history)
  ${CORP_SLUG} --uninstall    Run the uninstaller

The launcher writes \$\{HOME\}/.continue/config.yaml. Any existing
config is backed up to config.yaml.${CORP_SLUG}.bak on first run.
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
    if detect_continue_extension; then
        printf '  $\{GREEN\}[OK]$\{RESET\} Continue.dev extension detected (%s)\n' "$CONTINUE_IDE"
    else
        printf '  $\{YELLOW\}[!] $\{RESET\} Continue.dev extension NOT detected\n'
        printf '              Install: https://continue.dev/docs/getting-started/install\n'
    fi
    if [ -f "$HOME/.continue/config.yaml" ]; then
        printf '  $\{GREEN\}[OK]$\{RESET\} ~/.continue/config.yaml present\n'
    else
        printf '  $\{YELLOW\}[!] $\{RESET\} ~/.continue/config.yaml missing — run "${CORP_SLUG}"\n'
    fi
    printf '  Gateway     : ${LLM_OPENAI_BASE_URL}\n'
    printf '  Model       : ${LLM_PRIMARY_MODEL}\n'
    printf '  CA bundle   : %s\n' "$\{CA_BUNDLE_PATH:-<system>\}"
    printf '  HTTP proxy  : %s\n' "$\{HTTPS_PROXY:-<none>\}"
}

cmd_set_key() {
    show_banner
    prompt_for_api_key
    printf '$\{GREEN\}[OK]$\{RESET\} token saved.\n'
    # tpl: re-render the config so the new key takes effect immediately
    setup_gateway_env
    render_continue_config
    info "~/.continue/config.yaml refreshed."
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
        --status)         setup_isolation >/dev/null 2>&1 || true; cmd_status; exit 0 ;;
        --set-key)        setup_isolation >/dev/null 2>&1 || true; cmd_set_key; exit 0 ;;
        --cost)           shift; cmd_cost "$@"; exit 0 ;;
        --uninstall)      cmd_uninstall; exit 0 ;;
    esac

    if [ "${VPN_REQUIRED}" = "yes" ]; then
        check_vpn || exit 1
    fi

    setup_isolation
    show_banner

    if ! detect_continue_extension; then
        warn "Continue.dev extension not detected in VS Code or JetBrains."
        warn "Install it from https://continue.dev/docs/getting-started/install"
        warn "then re-run: ${CORP_SLUG}"
        # tpl: still write the config so it's ready when the extension lands
    fi

    render_continue_config
    info "Wrote $HOME/.continue/config.yaml"

    printf '\n'
    printf 'Continue.dev configured for ${CORP_NAME}. Open VS Code to start coding.\n'
}

main "$@"
