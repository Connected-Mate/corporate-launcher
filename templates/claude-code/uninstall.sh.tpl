#!/usr/bin/env bash
# =====================================================================
#  ${CORP_NAME} — uninstaller
# =====================================================================

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$\{BASH_SOURCE[0]\}")" && pwd)"

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BOLD="\033[1m"; RESET="\033[0m"
info() { printf '  $\{GREEN\}[OK]$\{RESET\} %s\n' "$*"; }
warn() { printf '  $\{YELLOW\}[!]$\{RESET\}  %s\n' "$*"; }

printf '$\{BOLD\}${CORP_NAME} — uninstalling$\{RESET\}\n\n'

# tpl: 1. detect shell RC
detect_shell_rc() {
    local shell_name
    shell_name=$(basename "$\{SHELL:-/bin/sh\}")
    case "$shell_name" in
        zsh)  SHELL_RC="$HOME/.zshrc" ;;
        bash) [ "$(uname -s)" = "Darwin" ] && SHELL_RC="$HOME/.bash_profile" || SHELL_RC="$HOME/.bashrc" ;;
        fish) SHELL_RC="$HOME/.config/fish/conf.d/${CORP_SLUG}.fish" ;;
        *)    SHELL_RC="$HOME/.profile" ;;
    esac
}
detect_shell_rc

# tpl: 2. remove shell RC block
MARKER_START="# >>> ${CORP_SLUG} >>>"
MARKER_END="# <<< ${CORP_SLUG} <<<"
if [ -f "$SHELL_RC" ] && grep -qF "$MARKER_START" "$SHELL_RC"; then
    cp "$SHELL_RC" "$\{SHELL_RC\}.${CORP_SLUG}.uninstall.bak"
    if [ "$(uname -s)" = "Darwin" ]; then
        sed -i '' "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    else
        sed -i "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    fi
    info "Removed shell RC block from $SHELL_RC (backup: $\{SHELL_RC\}.${CORP_SLUG}.uninstall.bak)"
fi

# tpl: 3. remove settings.json IF it was ours
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -qF "Managed by ${CORP_NAME} corporate launcher" "$SETTINGS"; then
    rm -f "$SETTINGS"
    info "Removed $SETTINGS"
fi

# tpl: 4. stop strip-proxy if running
PID_FILE="/tmp/${CORP_SLUG}-strip-proxy.pid"
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        info "Stopped strip-proxy (pid $pid)"
    fi
    rm -f "$PID_FILE"
fi
rm -f "/tmp/${CORP_SLUG}-strip-proxy.log" "/tmp/${CORP_SLUG}-strip-proxy.lock"

# tpl: 5. remove API token from keychain / file
if command -v security >/dev/null 2>&1; then
    security delete-generic-password -s "${CORP_SLUG}" -a "$USER" 2>/dev/null && info "Removed keychain entry" || true
fi
if command -v secret-tool >/dev/null 2>&1; then
    secret-tool clear service "${CORP_SLUG}" username "$USER" 2>/dev/null && info "Removed libsecret entry" || true
fi
[ -f "$HOME/.${CORP_SLUG}.conf" ] && rm -f "$HOME/.${CORP_SLUG}.conf" && info "Removed $HOME/.${CORP_SLUG}.conf"

# tpl: 6. remove install dir (last, since we're running from it)
if [ -d "$INSTALL_DIR" ]; then
    warn "Will remove $INSTALL_DIR — re-run from outside if you want a backup."
    printf '  Remove install directory? [y/N] '
    read -r ans
    case "$ans" in
        [yY]*) rm -rf "$INSTALL_DIR"; info "Removed $INSTALL_DIR" ;;
        *)     warn "Kept $INSTALL_DIR — remove manually if desired" ;;
    esac
fi

printf '\n$\{GREEN\}$\{BOLD\}Uninstall complete.$\{RESET\}\n'
printf '  Reload your shell to drop the ${CORP_SLUG} command.\n\n'
