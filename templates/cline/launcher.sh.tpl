#!/usr/bin/env bash
# =====================================================================
#  ${CORP_NAME} — Cline launcher
#  Powered by ${CORP_POWERED_BY}
#
#  Cline is a VS Code / Cursor / VSCodium extension (marketplace id:
#  saoudrizwan.claude-dev). It is NOT a CLI — there is no headless
#  process to spawn. This "launcher" is a configurator + IDE opener:
#
#    1. Prepares the corporate process environment
#       (HTTPS_PROXY, NODE_EXTRA_CA_CERTS, telemetry kill switches)
#    2. Merges the cline.* keys into the user's VS Code settings.json
#       so the extension talks to the corporate gateway on first run
#    3. Writes the corporate .clinerules so identity / cyber rules
#       are injected into the system prompt of every Cline task
#    4. Optionally opens VS Code (or Cursor / VSCodium) on the
#       requested workspace
#
#  Cline reads its provider config from VS Code settings (UI-driven,
#  persisted to the user settings.json). It honours the standard Node
#  env vars (HTTPS_PROXY, NODE_EXTRA_CA_CERTS) since it runs inside
#  the VS Code extension host (Node).
#
#  - All traffic routed through the corporate gateway
#  - Telemetry / error reporting disabled at settings level
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
    printf '\n'
}

# =====================================================================
#  IDE DETECTION — Cline lives inside a VS Code-family editor.
#  Cursor and VSCodium are VS Code forks: same extension API,
#  same settings.json layout, same `--install-extension` flag.
# =====================================================================
detect_vscode_family() {
    # tpl: probe each `code`-style CLI in priority order.
    # tpl: Cline marketplace id is `saoudrizwan.claude-dev` on the
    # tpl: VS Code Marketplace AND on Open VSX (used by VSCodium and
    # tpl: most Cursor builds).
    IDE_CLI=""
    IDE_LABEL=""
    IDE_SETTINGS_DIR=""
    local cli
    for cli in code cursor codium code-insiders; do
        if command -v "$cli" >/dev/null 2>&1; then
            IDE_CLI="$cli"
            case "$cli" in
                code)           IDE_LABEL="VS Code";          IDE_SETTINGS_DIR="$HOME/Library/Application Support/Code/User" ;;
                code-insiders)  IDE_LABEL="VS Code Insiders"; IDE_SETTINGS_DIR="$HOME/Library/Application Support/Code - Insiders/User" ;;
                cursor)         IDE_LABEL="Cursor";           IDE_SETTINGS_DIR="$HOME/Library/Application Support/Cursor/User" ;;
                codium)         IDE_LABEL="VSCodium";         IDE_SETTINGS_DIR="$HOME/Library/Application Support/VSCodium/User" ;;
            esac
            # tpl: Linux paths differ — override if we are not on macOS.
            if [ "$(uname -s)" = "Linux" ]; then
                case "$cli" in
                    code)           IDE_SETTINGS_DIR="$HOME/.config/Code/User" ;;
                    code-insiders)  IDE_SETTINGS_DIR="$HOME/.config/Code - Insiders/User" ;;
                    cursor)         IDE_SETTINGS_DIR="$HOME/.config/Cursor/User" ;;
                    codium)         IDE_SETTINGS_DIR="$HOME/.config/VSCodium/User" ;;
                esac
            fi
            return 0
        fi
    done
    return 1
}

detect_cline_extension() {
    [ -n "$IDE_CLI" ] || return 1
    "$IDE_CLI" --list-extensions 2>/dev/null | grep -qi '^saoudrizwan\.claude-dev$'
}

# =====================================================================
#  TELEMETRY / KILL SWITCHES (process-level)
#  Cline runs inside the VS Code extension host (Node). Setting these
#  in the launcher process leaks into the extension when it is started
#  from the same shell session (`code .`, `cursor .`).
# =====================================================================
disable_telemetry() {
    export DO_NOT_TRACK=1
    export DISABLE_TELEMETRY=1
    export DISABLE_ERROR_REPORTING=1
    export SENTRY_DSN=""
    export OTEL_EXPORTER_OTLP_ENDPOINT=""
    export OTEL_SDK_DISABLED=true
    export STATSIG_DISABLED=1
}

# =====================================================================
#  GATEWAY ENV — OpenAI-compatible
#  Cline's openai-compatible provider stores its config in
#  settings.json (cline.apiProvider/baseUrl/apiKey/modelId). Mirroring
#  OPENAI_* into the env helps when shells out to subprocess tools
#  (linters, MCP servers, custom scripts) that obey those vars.
# =====================================================================
setup_gateway_env() {
    export OPENAI_API_BASE="${LLM_OPENAI_BASE_URL}"
    export OPENAI_BASE_URL="${LLM_OPENAI_BASE_URL}"
    export OPENAI_API_KEY="$CORP_API_KEY"

    # tpl: Node TLS: feed the corporate root CA to every Node process
    # tpl: launched from this shell, including the VS Code extension
    # tpl: host that loads Cline. Honours NODE_EXTRA_CA_CERTS as Cline
    # tpl: does not bundle its own CA store.
    if [ -n "$\{CA_BUNDLE_PATH:-\}" ] && [ -r "$CA_BUNDLE_PATH" ]; then
        export NODE_EXTRA_CA_CERTS="$CA_BUNDLE_PATH"
    fi

    # tpl: Session markers
    export ${CORP_SLUG_UPPER}_ACTIVE=1
    export ${CORP_SLUG_UPPER}_SESSION_START=$(date +%s)
    export ${CORP_SLUG_UPPER}_VERSION="$LAUNCHER_VERSION"
}

# =====================================================================
#  SETTINGS.JSON MERGE
#  Cline reads its provider config from the VS Code user settings.json.
#  We merge our managed cline.* block in via jq, preserving any other
#  user-defined keys (themes, editor prefs, other extensions).
#  An unmanaged settings.json is backed up once before the first write.
# =====================================================================
merge_cline_settings() {
    [ -n "$IDE_CLI" ] || { warn "No VS Code-family CLI detected — skipping settings merge."; return 1; }

    local settings_file="$IDE_SETTINGS_DIR/settings.json"
    local snippet_file="$INSTALL_DIR/settings-cline.json"

    mkdir -p "$IDE_SETTINGS_DIR"

    if [ ! -r "$snippet_file" ]; then
        fail "Missing managed snippet: $snippet_file"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found — falling back to plain copy (no merge)."
        # tpl: jq is the contract for safe merge. Without it, only
        # tpl: write the snippet when settings.json does not already exist.
        if [ ! -f "$settings_file" ]; then
            install -m 0600 "$snippet_file" "$settings_file"
            info "Wrote $settings_file (jq absent, no merge possible)"
        else
            warn "$settings_file exists and jq missing — refusing to overwrite."
            warn "Install jq, or merge the cline.* keys from:"
            warn "  $snippet_file"
        fi
        return 0
    fi

    # tpl: Back up any existing settings once, before our first merge.
    if [ -f "$settings_file" ] && [ ! -f "$\{settings_file\}.${CORP_SLUG}.bak" ]; then
        cp "$settings_file" "$\{settings_file\}.${CORP_SLUG}.bak"
    elif [ ! -f "$settings_file" ]; then
        printf '{}\n' > "$settings_file"
    fi

    # tpl: Substitute the API key into a temp snippet so the on-disk
    # tpl: settings file contains the value Cline will use. The file is
    # tpl: chmod 600 — same posture as ~/.continue/config.yaml.
    local tmp_snippet
    tmp_snippet="$(mktemp -t ${CORP_SLUG}-cline.XXXXXX)"
    CORP_API_KEY="$CORP_API_KEY" \
    LLM_OPENAI_BASE_URL="${LLM_OPENAI_BASE_URL}" \
    LLM_PRIMARY_MODEL="${LLM_PRIMARY_MODEL}" \
    CORP_NAME="${CORP_NAME}" \
    CORP_SLUG="${CORP_SLUG}" \
    INSTALL_DIR="$INSTALL_DIR" \
        envsubst < "$snippet_file" > "$tmp_snippet"

    local merged
    merged="$(mktemp -t ${CORP_SLUG}-merged.XXXXXX)"
    # tpl: deep merge: snippet wins on keys we manage, user wins on others.
    jq -s '.[0] * .[1]' "$settings_file" "$tmp_snippet" > "$merged"

    install -m 0600 "$merged" "$settings_file"
    rm -f "$tmp_snippet" "$merged"

    info "Merged cline.* keys into $settings_file"
}

# =====================================================================
#  .clinerules / global rules
#  Cline reads workspace rules from `.clinerules/` at the workspace
#  root, and global rules from $HOME/Documents/Cline/Rules. We install
#  the corporate identity + cyber rules into the GLOBAL store so the
#  rebrand applies on every workspace the user opens.
# =====================================================================
install_global_rules() {
    local rules_dir
    case "$(uname -s)" in
        Darwin*) rules_dir="$HOME/Documents/Cline/Rules" ;;
        Linux*)
            if [ -d "$HOME/Documents" ]; then
                rules_dir="$HOME/Documents/Cline/Rules"
            else
                rules_dir="$HOME/Cline/Rules"
            fi
            ;;
        *) rules_dir="$HOME/Documents/Cline/Rules" ;;
    esac

    mkdir -p "$rules_dir"
    local target="$rules_dir/00-${CORP_SLUG}-identity.md"

    if [ -r "$INSTALL_DIR/BRANDING.md" ]; then
        install -m 0644 "$INSTALL_DIR/BRANDING.md" "$target"
        info "Installed global rule: $target"
    fi

    if [ -r "$INSTALL_DIR/cyber-rules.md" ]; then
        install -m 0644 "$INSTALL_DIR/cyber-rules.md" "$rules_dir/10-${CORP_SLUG}-cyber.md"
        info "Installed global rule: $rules_dir/10-${CORP_SLUG}-cyber.md"
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
    disable_telemetry
    setup_gateway_env
}

# =====================================================================
#  COMMANDS
# =====================================================================
cmd_help() {
    cat <<EOF_HELP
${CORP_NAME} — Cline — Powered by ${CORP_POWERED_BY}

Cline is a VS Code / Cursor / VSCodium extension, not a CLI. This
command configures your editor so Cline talks to the corporate
gateway and respects ${CORP_ORGANIZATION}'s cyber rules.

Usage:
  ${CORP_SLUG}                 Configure Cline and (optionally) open the IDE
  ${CORP_SLUG} <path>          Configure, then open <path> in the IDE
  ${CORP_SLUG} --help          Show this help
  ${CORP_SLUG} --version       Show version
  ${CORP_SLUG} --status        Check VPN, gateway, IDE, extension, settings
  ${CORP_SLUG} --set-key       Reset / change the API token
  ${CORP_SLUG} --cost          Local cost log (session / today / history)
  ${CORP_SLUG} --refresh       Re-merge cline.* keys into the IDE settings
  ${CORP_SLUG} --uninstall     Run the uninstaller

Cline keeps its provider config in the IDE's user settings.json. This
launcher merges only the keys it owns (cline.*) — your other VS Code
settings are preserved and backed up on first run.
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
    if detect_vscode_family; then
        printf '  $\{GREEN\}[OK]$\{RESET\} IDE detected: %s (%s)\n' "$IDE_LABEL" "$IDE_CLI"
        if detect_cline_extension; then
            printf '  $\{GREEN\}[OK]$\{RESET\} Cline extension installed (saoudrizwan.claude-dev)\n'
        else
            printf '  $\{YELLOW\}[!] $\{RESET\} Cline extension NOT installed — run the installer to add it.\n'
        fi
        local settings_file="$IDE_SETTINGS_DIR/settings.json"
        if [ -f "$settings_file" ] && grep -qF '"cline.apiProvider"' "$settings_file" 2>/dev/null; then
            printf '  $\{GREEN\}[OK]$\{RESET\} cline.* keys present in %s\n' "$settings_file"
        else
            printf '  $\{YELLOW\}[!] $\{RESET\} cline.* keys missing — run "${CORP_SLUG} --refresh"\n'
        fi
    else
        printf '  $\{YELLOW\}[!] $\{RESET\} No VS Code-family IDE found in PATH (code / cursor / codium)\n'
    fi
    printf '  Gateway     : ${LLM_OPENAI_BASE_URL}\n'
    printf '  Model       : ${LLM_PRIMARY_MODEL}\n'
    printf '  CA bundle   : %s\n' "$\{NODE_EXTRA_CA_CERTS:-<system>\}"
    printf '  HTTP proxy  : %s\n' "$\{HTTPS_PROXY:-<none>\}"
}

cmd_set_key() {
    show_banner
    prompt_for_api_key
    printf '$\{GREEN\}[OK]$\{RESET\} token saved.\n'
    setup_gateway_env
    detect_vscode_family && merge_cline_settings || true
    info "Settings refreshed."
}

cmd_refresh() {
    setup_isolation >/dev/null 2>&1 || true
    detect_vscode_family || { fail "No VS Code-family IDE found in PATH."; exit 1; }
    merge_cline_settings
    install_global_rules
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
        --status)         setup_isolation >/dev/null 2>&1 || true; detect_vscode_family || true; cmd_status; exit 0 ;;
        --set-key)        setup_isolation >/dev/null 2>&1 || true; detect_vscode_family || true; cmd_set_key; exit 0 ;;
        --refresh)        cmd_refresh; exit 0 ;;
        --cost)           shift; cmd_cost "$@"; exit 0 ;;
        --uninstall)      cmd_uninstall; exit 0 ;;
    esac

    if [ "${VPN_REQUIRED}" = "yes" ]; then
        check_vpn || exit 1
    fi

    setup_isolation
    show_banner

    if ! detect_vscode_family; then
        warn "No VS Code-family CLI found (code / cursor / codium)."
        warn "Install VS Code or Cursor, then re-run: ${CORP_SLUG}"
        exit 0
    fi
    info "IDE detected: $IDE_LABEL ($IDE_CLI)"

    if ! detect_cline_extension; then
        warn "Cline (saoudrizwan.claude-dev) not installed in $IDE_LABEL."
        warn "Run the installer once to add it: $INSTALL_DIR/install.sh"
    fi

    merge_cline_settings
    install_global_rules

    # tpl: Optional positional arg = workspace path to open. We pass it
    # tpl: through the IDE CLI rather than spawning the extension
    # tpl: directly (no headless mode in Cline).
    local workspace="$\{1:-\}"
    if [ -n "$workspace" ]; then
        if [ -d "$workspace" ] || [ -f "$workspace" ]; then
            info "Opening $workspace in $IDE_LABEL"
            "$IDE_CLI" "$workspace"
        else
            warn "Workspace path not found: $workspace"
        fi
    else
        printf '\nCline configured. Launch your IDE and open the Cline panel.\n'
        printf '  %s .\n' "$IDE_CLI"
    fi
}

main "$@"
