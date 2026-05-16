#!/usr/bin/env bash
# =====================================================================
#  ${CORP_NAME} — installer
#  Powered by ${CORP_POWERED_BY}
# =====================================================================

set -euo pipefail
umask 077

INSTALL_DIR="$(cd "$(dirname "$\{BASH_SOURCE[0]\}")" && pwd)"

ORANGE="\033[38;5;${BANNER_COLOR_PRIMARY}m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

info()  { printf '  $\{GREEN\}[OK]$\{RESET\} %s\n' "$*"; }
warn()  { printf '  $\{YELLOW\}[!]$\{RESET\}  %s\n' "$*"; }
fail()  { printf '  $\{RED\}[KO]$\{RESET\} %s\n' "$*"; }
step()  { printf '\n$\{BOLD\}%s$\{RESET\}\n' "$*"; }
ask()   { printf '  $\{YELLOW\}%s [y/N] $\{RESET\}' "$*"; read -r ans; case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac; }

# tpl: ---------- detection ----------
detect_os() {
    case "$(uname -s)" in
        Darwin*) OS_TYPE="macos"; OS_LABEL="macOS $(sw_vers -productVersion 2>/dev/null || echo '')" ;;
        Linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                OS_TYPE="wsl"; OS_LABEL="Windows (WSL)"
            else
                OS_TYPE="linux"; OS_LABEL="Linux"
            fi
            ;;
        *) OS_TYPE="unknown"; OS_LABEL="Unknown" ;;
    esac
}

detect_shell_rc() {
    local shell_name
    shell_name=$(basename "$\{SHELL:-/bin/sh\}")
    case "$shell_name" in
        zsh)  SHELL_RC="$HOME/.zshrc" ;;
        bash) [ "$OS_TYPE" = "macos" ] && SHELL_RC="$HOME/.bash_profile" || SHELL_RC="$HOME/.bashrc" ;;
        fish) SHELL_RC="$HOME/.config/fish/conf.d/${CORP_SLUG}.fish" ;;
        *)    SHELL_RC="$HOME/.profile" ;;
    esac
    [ -f "$SHELL_RC" ] || touch "$SHELL_RC"
}

show_banner() {
    printf '\n$\{ORANGE\}$\{BOLD\}'
    printf '  ╔═══════════════════════════════════════════════╗\n'
    printf '  ║  %-44s ║\n' "${CORP_NAME} — installer"
    printf '  ║  %-44s ║\n' "Powered by ${CORP_POWERED_BY}"
    printf '  ╚═══════════════════════════════════════════════╝\n'
    printf '$\{RESET\}\n'
}

# tpl: ---------- begin ----------
show_banner

step "[1/7] Detect environment"
detect_os
info "OS         : $OS_LABEL"
detect_shell_rc
info "Shell RC   : $SHELL_RC"

step "[2/7] Check dependencies"
if command -v node >/dev/null 2>&1; then
    info "node: $(node --version)"
else
    fail "Node.js is required. Install from https://nodejs.org or via your package manager."
    exit 1
fi

if command -v claude >/dev/null 2>&1; then
    info "Underlying CLI present: $(claude --version 2>/dev/null || echo unknown)"
else
    warn "Underlying CLI not found."
    if ask "Install via npm (npm i -g @anthropic-ai/claude-code)?"; then
        npm install -g @anthropic-ai/claude-code
    else
        fail "Cannot proceed without the underlying CLI."
        exit 1
    fi
fi

step "[3/7] Permissions"
chmod +x "$INSTALL_DIR/${CORP_SLUG}"
chmod +x "$INSTALL_DIR/scripts/"*.sh 2>/dev/null || true
# tpl: cyber-guard is locked at 555 so the AI cannot rewrite it
chmod 555 "$INSTALL_DIR/scripts/pre-tool-hook.py" 2>/dev/null || true
info "Executable bits set; cyber-guard locked at 555"

step "[4/7] Install settings.json"
mkdir -p "$HOME/.claude"
cp "$INSTALL_DIR/settings.json" "$HOME/.claude/settings.json"
chmod 600 "$HOME/.claude/settings.json"
info "Wrote ~/.claude/settings.json"

step "[5/7] Wire up the shell"
MARKER_START="# >>> ${CORP_SLUG} >>>"
MARKER_END="# <<< ${CORP_SLUG} <<<"

if grep -qF "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
    cp "$SHELL_RC" "$\{SHELL_RC\}.${CORP_SLUG}.bak"
    if [ "$OS_TYPE" = "macos" ]; then
        sed -i '' "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    else
        sed -i "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    fi
    info "Removed previous block (backup at $\{SHELL_RC\}.${CORP_SLUG}.bak)"
fi

{
    printf '\n%s\n' "$MARKER_START"
    printf '# %s — Powered by %s\n' "${CORP_NAME}" "${CORP_POWERED_BY}"
    printf '# Installed on %s\n' "$(date +%Y-%m-%d)"
    printf 'export ${CORP_SLUG_UPPER}_HOME="%s"\n' "$INSTALL_DIR"
    printf '${CORP_SLUG}() { "$\{${CORP_SLUG_UPPER}_HOME\}/${CORP_SLUG}" "$@"; }\n'
    printf '%s\n' "$MARKER_END"
} >> "$SHELL_RC"

info "Shell block added — restart your shell or 'source $SHELL_RC'"

step "[6/7] Configure API token"
# shellcheck source=/dev/null
source "$INSTALL_DIR/scripts/secrets-store.sh"
load_api_key || true
if [ -n "$\{CORP_API_KEY:-\}" ]; then
    if ask "An API token is already stored. Replace it?"; then
        prompt_for_api_key
    fi
else
    prompt_for_api_key
fi

step "[7/10] Extract corporate CA (if requested)"
if [ "${CA_DETECT_AUTO}" = "yes" ]; then
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/scripts/extract-corp-ca.sh"
    extract_corp_ca || warn "CA auto-extract skipped — run later if SSL inspection breaks requests."
fi

step "[8/10] Install bundled skills"
if [ -f "$INSTALL_DIR/scripts/install-skills.sh" ]; then
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/scripts/install-skills.sh"
    install_skills || warn "Skill bundle install failed — run '${CORP_SLUG} --update-skills' to retry."
fi

step "[9/10] Configure MCP servers"
if [ -f "$INSTALL_DIR/scripts/install-mcp.sh" ]; then
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/scripts/install-mcp.sh"
    install_mcp_servers || warn "MCP server config failed — edit ~/.claude/settings.json manually."
fi

step "[10/10] Done"
printf '\n$\{ORANGE\}$\{BOLD\}  Installation complete.$\{RESET\}\n\n'
printf '  Launch with    : $\{GREEN\}${CORP_SLUG}$\{RESET\}\n'
printf '  Diagnostics    : $\{DIM\}${CORP_SLUG} --status$\{RESET\}\n'
printf '  Update         : $\{DIM\}${CORP_SLUG} --update$\{RESET\}\n'
printf '  Uninstall      : $\{DIM\}${CORP_SLUG} --uninstall$\{RESET\}\n\n'
[ "${VPN_REQUIRED}" = "yes" ] && printf '  $\{YELLOW\}[!]$\{RESET\}  Corporate VPN required before first launch.\n\n'
