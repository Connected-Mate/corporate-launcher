#!/usr/bin/env bash
# tpl: ${CORP_NAME} — Corporate uninstaller for the Gemini CLI wrapper
# tpl: Powered by ${CORP_POWERED_BY}
# tpl: Idempotent: safe to run multiple times.

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORP_NAME="${CORP_NAME}"
CORP_SLUG="${CORP_SLUG}"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
DIM="\033[2m"
RESET="\033[0m"

info() { printf '  %b[OK]%b %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %b[!!]%b %s\n' "$YELLOW" "$RESET" "$1"; }
skip() { printf '  %b[--]%b %s\n' "$DIM" "$RESET" "$1"; }

printf '\n  Uninstalling %s...\n\n' "$CORP_NAME"

OS_TYPE="linux"
case "$(uname -s)" in
    Darwin*) OS_TYPE="macos" ;;
    MINGW*|MSYS*|CYGWIN*) OS_TYPE="gitbash" ;;
esac

# --- 1. Remove the shell RC block --------------------------------------------
SHELL_NAME="$(basename "${SHELL:-/bin/sh}")"
case "$SHELL_NAME" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash)
        if [ "$OS_TYPE" = "macos" ] && [ -f "$HOME/.bash_profile" ]; then
            SHELL_RC="$HOME/.bash_profile"
        else
            SHELL_RC="$HOME/.bashrc"
        fi
        ;;
    *) SHELL_RC="$HOME/.profile" ;;
esac

MARKER_START="# >>> ${CORP_SLUG} >>>"
MARKER_END="# <<< ${CORP_SLUG} <<<"

if [ -f "$SHELL_RC" ] && grep -qF "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
    cp "$SHELL_RC" "${SHELL_RC}.${CORP_SLUG}-uninstall-backup"
    if [ "$OS_TYPE" = "macos" ]; then
        sed -i '' "/${MARKER_START}/,/${MARKER_END}/d" "$SHELL_RC"
    else
        sed -i "/${MARKER_START}/,/${MARKER_END}/d" "$SHELL_RC"
    fi
    info "Shell block removed from $SHELL_RC (backup at ${SHELL_RC}.${CORP_SLUG}-uninstall-backup)."
else
    skip "No shell block found in $SHELL_RC."
fi

# --- 2. Restore or remove ~/.gemini/settings.json ----------------------------
GEMINI_HOME="$HOME/.gemini"
if [ -f "$GEMINI_HOME/settings.json.${CORP_SLUG}.bak" ]; then
    mv "$GEMINI_HOME/settings.json.${CORP_SLUG}.bak" "$GEMINI_HOME/settings.json"
    info "Restored previous ~/.gemini/settings.json from backup."
elif [ -f "$GEMINI_HOME/settings.json" ]; then
    if grep -qF "${CORP_NAME}" "$GEMINI_HOME/settings.json" 2>/dev/null; then
        rm -f "$GEMINI_HOME/settings.json"
        info "Removed corporate ~/.gemini/settings.json (no backup to restore)."
    else
        skip "~/.gemini/settings.json is not corporate-managed — left in place."
    fi
fi

# --- 3. Restore or remove ~/.gemini/GEMINI.md --------------------------------
if [ -f "$GEMINI_HOME/GEMINI.md.${CORP_SLUG}.bak" ]; then
    mv "$GEMINI_HOME/GEMINI.md.${CORP_SLUG}.bak" "$GEMINI_HOME/GEMINI.md"
    info "Restored previous ~/.gemini/GEMINI.md from backup."
elif [ -f "$GEMINI_HOME/GEMINI.md" ] \
     && grep -qF "${CORP_SLUG}-identity-lock" "$GEMINI_HOME/GEMINI.md" 2>/dev/null; then
    rm -f "$GEMINI_HOME/GEMINI.md"
    info "Removed corporate ~/.gemini/GEMINI.md."
else
    skip "~/.gemini/GEMINI.md is not corporate-managed — left in place."
fi

# --- 4. Remove API key from secret store (ai-studio mode) --------------------
if command -v security >/dev/null 2>&1; then
    security delete-generic-password -s "${CORP_SLUG}" -a "$USER" >/dev/null 2>&1 \
        && info "API key removed from macOS Keychain." \
        || skip "No API key found in macOS Keychain."
fi
if command -v secret-tool >/dev/null 2>&1; then
    secret-tool clear service "${CORP_SLUG}" username "$USER" 2>/dev/null \
        && info "API key removed from libsecret." \
        || skip "No API key found in libsecret."
fi
if [ -f "$HOME/.${CORP_SLUG}.conf" ]; then
    rm -f "$HOME/.${CORP_SLUG}.conf"
    info "Removed $HOME/.${CORP_SLUG}.conf."
fi

# --- 5. Remove the install directory -----------------------------------------
# tpl: Defensive guard — refuse to delete obviously wrong paths.
if [ -z "$INSTALL_DIR" ] || [ "$INSTALL_DIR" = "/" ] || [ "$INSTALL_DIR" = "$HOME" ]; then
    warn "Refusing to delete suspicious INSTALL_DIR: '$INSTALL_DIR'"
elif [ -d "$INSTALL_DIR" ]; then
    # tpl: We're being run from inside the dir we're about to delete — handle it.
    PARENT_DIR="$(dirname "$INSTALL_DIR")"
    cd "$PARENT_DIR"
    rm -rf "$INSTALL_DIR"
    info "Removed install directory: $INSTALL_DIR"
fi

printf '\n  %b%s uninstalled.%b Reload your shell: %bsource %s%b\n\n' \
    "$GREEN" "$CORP_NAME" "$RESET" "$YELLOW" "$SHELL_RC" "$RESET"
