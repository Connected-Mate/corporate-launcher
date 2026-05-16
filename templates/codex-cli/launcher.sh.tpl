#!/usr/bin/env bash
# =============================================================================
# ${CORP_NAME} — Codex CLI launcher
# Powered by ${CORP_POWERED_BY}
#
# This wrapper is the only supported entry point to Codex CLI on a corporate
# machine. It loads VPN/proxy/CA modules, injects the gateway env vars, then
# execs the upstream `codex` binary. Direct invocation of `codex` is not
# supported by the cyber policy.
#
# Flags:
#   --version       print the launcher version and exit
#   --status        print resolved env (no secret) and exit
#   --dry-run       print what would be exec'd and exit 0 (CORP_DRY_RUN=1)
#   --set-key       prompt for a new API token and store it
#   --help          this help
#   <anything else> forwarded verbatim to codex
# =============================================================================

set -euo pipefail

# tpl: ---------------------------------------------------------------------
# tpl: Resolve install dir (where this script + scripts/ + config live)
# tpl: ---------------------------------------------------------------------
LAUNCHER_VERSION="${CORP_LAUNCHER_VERSION}"
LAUNCHER_SELF="$\{BASH_SOURCE[0]\}"
INSTALL_DIR="$(cd "$(dirname "$LAUNCHER_SELF")" && pwd)"
SCRIPTS_DIR="$INSTALL_DIR/scripts"

# tpl: ---------------------------------------------------------------------
# tpl: Colors — TTY only
# tpl: ---------------------------------------------------------------------
if [ -t 1 ]; then
    C_BRAND="\033[1;38;5;${CORP_BRAND_ANSI}m"
    C_GREEN="\033[0;32m"
    C_RED="\033[0;31m"
    C_YELLOW="\033[0;33m"
    C_DIM="\033[2m"
    C_RESET="\033[0m"
else
    C_BRAND=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_RESET=""
fi

info() { printf "  $\{C_GREEN\}[OK]$\{C_RESET\} %s\n" "$1"; }
warn() { printf "  $\{C_YELLOW\}[!!]$\{C_RESET\} %s\n" "$1" >&2; }
fail() { printf "  $\{C_RED\}[KO]$\{C_RESET\} %s\n" "$1" >&2; }

# tpl: ---------------------------------------------------------------------
# tpl: Shared module exports needed by sourced scripts
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
# tpl: Source shared modules
# tpl: ---------------------------------------------------------------------
for mod in vpn-check.sh proxy-detect.sh secrets-store.sh; do
    if [ ! -r "$SCRIPTS_DIR/$mod" ]; then
        fail "Missing shared module: $SCRIPTS_DIR/$mod"
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$SCRIPTS_DIR/$mod"
done

# tpl: ---------------------------------------------------------------------
# tpl: Banner
# tpl: ---------------------------------------------------------------------
show_banner() {
    [ -t 1 ] || return 0
    printf "$\{C_BRAND\}%s$\{C_RESET\} $\{C_DIM\}v%s — powered by %s$\{C_RESET\}\n" \
        "${CORP_NAME}" "$LAUNCHER_VERSION" "${CORP_POWERED_BY}"
    printf "\n  $\{C_DIM\}Proudly made from France with $\{C_RESET\}$\{C_RED\}❤️$\{C_RESET\}\n"
}

# tpl: ---------------------------------------------------------------------
# tpl: Telemetry kill switches — applied to every child process
# tpl: ---------------------------------------------------------------------
disable_telemetry() {
    export DO_NOT_TRACK=1
    export DISABLE_TELEMETRY=1
    export DISABLE_ERROR_REPORTING=1
    export OTEL_EXPORTER_OTLP_ENDPOINT=""
    export OTEL_SDK_DISABLED=true
    export SENTRY_DSN=""
    export DD_TRACE_ENABLED=0
    export STATSIG_DISABLED=1
    # tpl: Codex-specific opt-outs (best effort; pinned via config.toml too)
    export CODEX_DISABLE_TELEMETRY=1
    export CODEX_DISABLE_ANALYTICS=1
    export CODEX_DISABLE_FEEDBACK=1
    export CODEX_DISABLE_UPDATE_CHECK=1
}

# tpl: ---------------------------------------------------------------------
# tpl: Gateway env — primary auth + base URL
# tpl: ---------------------------------------------------------------------
setup_gateway_env() {
    # tpl: The auth env var name is provider-specific (e.g. AZURE_OPENAI_API_KEY,
    # tpl: OPENAI_API_KEY for OpenAI-compatible gateways). Set both the explicit
    # tpl: provider variable and the generic OPENAI_API_KEY so MCP servers that
    # tpl: expect the latter also work.
    export ${CX_AUTH_ENV_KEY}="$CORP_API_KEY"
    export OPENAI_API_KEY="$CORP_API_KEY"

    # tpl: Codex also reads OPENAI_BASE_URL when wire_api = "chat".
    # tpl: For Azure/responses, the URL comes from config.toml — we still
    # tpl: export it for tooling that piggybacks.
    export OPENAI_BASE_URL="${CX_PRIMARY_URL}"

    export CODEX_HOME="$\{CODEX_HOME:-$HOME/.codex\}"

    # tpl: Session marker — picked up by hooks / logs
    export ${CORP_SLUG_UPPER}_SESSION=1
    export ${CORP_SLUG_UPPER}_LAUNCHER_PID=$$
}

# tpl: ---------------------------------------------------------------------
# tpl: HTTPS_PROXY workaround for Codex issue #4242
# tpl: Codex (Rust reqwest) does not yet honor HTTPS_PROXY consistently. If a
# tpl: corporate proxy is required and the gateway is not directly reachable,
# tpl: warn the user and rely on transparent-proxy / split-tunnel routing.
# tpl: ---------------------------------------------------------------------
warn_proxy_quirk() {
    if [ -n "$\{HTTPS_PROXY:-\}" ] && [ "${CX_PROXY_WARNING}" = "yes" ]; then
        warn "Codex CLI does not fully honor HTTPS_PROXY (upstream issue #4242)."
        warn "If requests fail, route the gateway hostname outside the proxy"
        warn "(NO_PROXY) or use a transparent proxy at the network layer."
    fi
}

# tpl: ---------------------------------------------------------------------
# tpl: Status / dry-run output (no secrets)
# tpl: ---------------------------------------------------------------------
print_status() {
    show_banner
    printf "  install_dir   : %s\n" "$INSTALL_DIR"
    printf "  codex_home    : %s\n" "$CODEX_HOME"
    printf "  provider_id   : %s\n" "${CX_PROVIDER_ID}"
    printf "  primary_url   : %s\n" "${CX_PRIMARY_URL}"
    printf "  primary_model : %s\n" "${CX_PRIMARY_MODEL}"
    printf "  wire_api      : %s\n" "${CX_WIRE_API}"
    printf "  auth_env_key  : %s\n" "${CX_AUTH_ENV_KEY}"
    printf "  ca_bundle     : %s\n" "$\{CA_BUNDLE_PATH:-<system>\}"
    printf "  http_proxy    : %s\n" "$\{HTTP_PROXY:-<none>\}"
    printf "  no_proxy      : %s\n" "$\{NO_PROXY:-<none>\}"
    printf "  vpn_required  : %s\n" "${VPN_REQUIRED}"
    if [ -n "$\{CORP_API_KEY:-\}" ]; then
        printf "  api_key       : %s***%s (length %d)\n" \
            "$\{CORP_API_KEY:0:4\}" "$\{CORP_API_KEY: -2\}" "$\{#CORP_API_KEY\}"
    else
        printf "  api_key       : <unset>\n"
    fi
}

print_help() {
    show_banner
    cat <<EOF_HELP

Usage: ${CORP_SLUG} [launcher-flag | codex-arg ...]

Launcher flags:
  --version       print launcher version and exit
  --status        print resolved environment (no secret) and exit
  --dry-run       same as --status, then exit 0 without running codex
  --set-key       prompt for a new API token and store it
  --cost          local cost log (session / today / history)
  --usage-watch   continuously scan ~/.codex/sessions/ into the ledger
  --help          show this help

Any other argument is forwarded to the underlying \`codex\` binary.

Examples:
  ${CORP_SLUG}                       # interactive session
  ${CORP_SLUG} exec "fix this bug"   # one-shot exec
  ${CORP_SLUG} --status              # diagnose configuration

Docs   : ${CORP_DOCS_URL}
Support: ${CORP_SUPPORT_CONTACT}
EOF_HELP
}

# tpl: ---------------------------------------------------------------------
# tpl: Main
# tpl: ---------------------------------------------------------------------
main() {
    # tpl: --- parse launcher-only flags first ---
    case "$\{1:-\}" in
        --version)
            printf "%s %s\n" "${CORP_NAME}" "$LAUNCHER_VERSION"
            exit 0 ;;
        --help|-h)
            print_help
            exit 0 ;;
        --set-key)
            prompt_for_api_key
            exit $?
            ;;
        --cost)
            shift
            python3 "$INSTALL_DIR/scripts/cost-tracker.py" "$\{1:-session\}"
            exit $?
            ;;
        --usage-watch)
            # tpl: foreground watcher for standalone capture
            adapter="$SCRIPTS_DIR/usage-adapter-codex.sh"
            if [ ! -r "$adapter" ]; then
                fail "usage adapter not installed: $adapter"
                exit 1
            fi
            export CODEX_ADAPTER_VERBOSE=1
            exec bash "$adapter"
            ;;
    esac

    # tpl: --- gates ---
    check_vpn || exit 1

    # tpl: --- secrets ---
    load_api_key || exit 1
    if [ -z "$\{CORP_API_KEY:-\}" ]; then
        prompt_for_api_key || exit 1
    fi

    # tpl: --- network ---
    setup_proxy
    setup_ca_bundle

    # tpl: --- env ---
    disable_telemetry
    setup_gateway_env
    warn_proxy_quirk

    # tpl: --- dry run / status ---
    case "$\{1:-\}" in
        --status)
            print_status
            exit 0 ;;
        --dry-run)
            print_status
            printf "\n  $\{C_DIM\}DRY RUN — not exec'ing codex$\{C_RESET\}\n"
            exit 0 ;;
    esac
    if [ "$\{CORP_DRY_RUN:-0\}" = "1" ]; then
        print_status
        printf "\n  $\{C_DIM\}CORP_DRY_RUN=1 — not exec'ing codex$\{C_RESET\}\n"
        exit 0
    fi

    # tpl: --- locate codex binary ---
    if ! command -v codex >/dev/null 2>&1; then
        fail "codex binary not found in PATH."
        fail "Re-run the installer: $INSTALL_DIR/install.sh"
        exit 127
    fi

    # tpl: --- native usage adapter (Codex bypasses strip-proxy) ---
    # tpl: Codex CLI does not honour HTTPS_PROXY consistently (#4242), so
    # tpl: the strip-proxy is often off the wire. We spawn an adapter that
    # tpl: tails ~/.codex/sessions/*/rollout-*.jsonl and emits canonical
    # tpl: usage events into /tmp/${CORP_SLUG}-usage.jsonl.
    # tpl: ADAPTER_PARENT_PID = $$ — after `exec codex`, $$ stays the same
    # tpl: PID (it's the same process), so the adapter's watchdog kills it
    # tpl: when codex exits. No orphan daemon.
    local adapter="$SCRIPTS_DIR/usage-adapter-codex.sh"
    if [ -r "$adapter" ]; then
        ADAPTER_PARENT_PID=$$ \
        ${CORP_SLUG_UPPER}_USAGE_LOG="$\{${CORP_SLUG_UPPER}_USAGE_LOG:-/tmp/${CORP_SLUG}-usage.jsonl\}" \
        ${CORP_SLUG_UPPER}_SESSION_ID="$\{${CORP_SLUG_UPPER}_SESSION_ID:-\}" \
        CODEX_HOME="$CODEX_HOME" \
            nohup bash "$adapter" >/dev/null 2>&1 &
        disown $! 2>/dev/null || true
    fi

    show_banner
    # tpl: We exec — the launcher process is replaced. No 'eval', no 'curl|sh'.
    exec codex "$@"
}

main "$@"
