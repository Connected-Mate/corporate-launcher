#!/usr/bin/env bash
# =====================================================================
#  ${CORP_NAME} — Cline launcher uninstaller
#  Powered by ${CORP_POWERED_BY}
#
#  Idempotent: safe to run multiple times.
#
#  - Removes the shell RC block (with backup)
#  - Strips the cline.* keys we manage from every IDE's settings.json
#    (jq merge — preserves every other key the user added)
#  - Removes the global Cline rules we installed in
#    ~/Documents/Cline/Rules
#  - Removes the API token from keychain / libsecret / fallback file
#  - Optionally uninstalls the Cline extension itself
#  - Optionally removes the install dir
# =====================================================================

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$\{BASH_SOURCE[0]\}")" && pwd)"
CLINE_EXT_ID="saoudrizwan.claude-dev"

if [ -t 1 ]; then
    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    DIM="\033[2m"
    BOLD="\033[1m"
    RESET="\033[0m"
else
    RED=""; GREEN=""; YELLOW=""; DIM=""; BOLD=""; RESET=""
fi

info() { printf '  $\{GREEN\}[OK]$\{RESET\} %s\n' "$*"; }
warn() { printf '  $\{YELLOW\}[!]$\{RESET\}  %s\n' "$*"; }
skip() { printf '  $\{DIM\}[--]$\{RESET\} %s\n' "$*"; }
fail() { printf '  $\{RED\}[KO]$\{RESET\} %s\n' "$*" >&2; }
ask()  { printf '  $\{YELLOW\}%s [y/N] $\{RESET\}' "$*"; read -r ans; case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac; }

printf '$\{BOLD\}${CORP_NAME} — Cline uninstalling$\{RESET\}\n\n'

OS_TYPE="linux"
case "$(uname -s)" in
    Darwin*) OS_TYPE="macos" ;;
    MINGW*|MSYS*|CYGWIN*) OS_TYPE="gitbash" ;;
esac

# tpl: ---------- 1. detect shell RC ----------
detect_shell_rc() {
    local shell_name
    shell_name=$(basename "$\{SHELL:-/bin/sh\}")
    case "$shell_name" in
        zsh)  SHELL_RC="$HOME/.zshrc" ;;
        bash)
            if [ "$OS_TYPE" = "macos" ] && [ -f "$HOME/.bash_profile" ]; then
                SHELL_RC="$HOME/.bash_profile"
            else
                SHELL_RC="$HOME/.bashrc"
            fi
            ;;
        fish) SHELL_RC="$HOME/.config/fish/conf.d/${CORP_SLUG}.fish" ;;
        *)    SHELL_RC="$HOME/.profile" ;;
    esac
}
detect_shell_rc

# tpl: ---------- helpers ----------
ide_settings_dir_for() {
    local cli="$1"
    case "$(uname -s)" in
        Darwin*)
            case "$cli" in
                code)          printf '%s' "$HOME/Library/Application Support/Code/User" ;;
                code-insiders) printf '%s' "$HOME/Library/Application Support/Code - Insiders/User" ;;
                cursor)        printf '%s' "$HOME/Library/Application Support/Cursor/User" ;;
                codium)        printf '%s' "$HOME/Library/Application Support/VSCodium/User" ;;
            esac
            ;;
        Linux*)
            case "$cli" in
                code)          printf '%s' "$HOME/.config/Code/User" ;;
                code-insiders) printf '%s' "$HOME/.config/Code - Insiders/User" ;;
                cursor)        printf '%s' "$HOME/.config/Cursor/User" ;;
                codium)        printf '%s' "$HOME/.config/VSCodium/User" ;;
            esac
            ;;
    esac
}

# tpl: ---------- 2. remove shell RC block ----------
MARKER_START="# >>> ${CORP_SLUG} >>>"
MARKER_END="# <<< ${CORP_SLUG} <<<"

if [ -f "$SHELL_RC" ] && grep -qF "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
    cp "$SHELL_RC" "$\{SHELL_RC\}.${CORP_SLUG}.uninstall.bak"
    if [ "$OS_TYPE" = "macos" ]; then
        sed -i '' "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    else
        sed -i "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    fi
    info "Removed shell RC block from $SHELL_RC (backup: $\{SHELL_RC\}.${CORP_SLUG}.uninstall.bak)"
else
    skip "No shell block found in $SHELL_RC"
fi

# tpl: ---------- 3. strip cline.* keys from every IDE's settings.json ----------
# tpl: We delete only the keys WE manage. Everything else the user has
# tpl: configured (themes, other extensions, editor prefs) is preserved.
CLINE_KEYS=(
    "cline.apiProvider"
    "cline.openAiBaseUrl"
    "cline.openAiApiKey"
    "cline.openAiModelId"
    "cline.openAiModelInfo"
    "cline.customInstructions"
    "cline.telemetryOptOut"
    "cline.errorReportingOptOut"
    "cline.allowAutoUpdate"
    "cline.autoApprove"
    "cline.mcpMarketplaceEnabled"
    "cline.enableCheckpoints"
)

if command -v jq >/dev/null 2>&1; then
    for cli in code code-insiders cursor codium; do
        sdir="$(ide_settings_dir_for "$cli")"
        [ -z "$sdir" ] && continue
        sfile="$sdir/settings.json"
        [ -f "$sfile" ] || { skip "$cli: no settings.json at $sfile"; continue; }

        cp "$sfile" "$\{sfile\}.${CORP_SLUG}.uninstall.bak"
        del_expr=""
        for k in "$\{CLINE_KEYS[@]\}"; do
            del_expr="$\{del_expr\}$\{del_expr:+ \| \}del(.[\"$k\"])"
        done
        tmp="$(mktemp -t ${CORP_SLUG}-uninstall.XXXXXX)"
        jq "$del_expr" "$sfile" > "$tmp"
        install -m 0600 "$tmp" "$sfile"
        rm -f "$tmp"
        info "$cli: removed cline.* keys from $sfile (backup: $\{sfile\}.${CORP_SLUG}.uninstall.bak)"

        backup="$\{sfile\}.${CORP_SLUG}-backup"
        if [ -f "$backup" ]; then
            if ask "$cli: restore pre-install settings.json from $backup?"; then
                mv "$backup" "$sfile"
                info "$cli: restored $sfile from backup"
            fi
        fi
    done
else
    warn "jq not found — cannot safely strip cline.* keys from settings.json."
    warn "Open each IDE's settings.json and remove keys starting with cline.* manually."
fi

# tpl: ---------- 4. remove global Cline rules we installed ----------
for rules_dir in "$HOME/Documents/Cline/Rules" "$HOME/Cline/Rules"; do
    [ -d "$rules_dir" ] || continue
    for f in "$rules_dir/00-${CORP_SLUG}-identity.md" "$rules_dir/10-${CORP_SLUG}-cyber.md"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            info "Removed global rule: $f"
        fi
    done
done

# tpl: ---------- 5. clear API token from secret stores ----------
if command -v security >/dev/null 2>&1; then
    if security delete-generic-password -s "${CORP_SLUG}" -a "$USER" >/dev/null 2>&1; then
        info "Removed macOS keychain entry for ${CORP_SLUG}"
    else
        skip "No keychain entry to remove"
    fi
fi
if command -v secret-tool >/dev/null 2>&1; then
    if secret-tool clear service "${CORP_SLUG}" username "$USER" 2>/dev/null; then
        info "Removed libsecret entry for ${CORP_SLUG}"
    else
        skip "No libsecret entry to remove"
    fi
fi

# tpl: ---------- 6. remove fallback conf file ----------
if [ -f "$HOME/.${CORP_SLUG}.conf" ]; then
    rm -f "$HOME/.${CORP_SLUG}.conf"
    info "Removed $HOME/.${CORP_SLUG}.conf"
else
    skip "No fallback $HOME/.${CORP_SLUG}.conf to remove"
fi

# tpl: ---------- 7. ask before uninstalling the Cline extension ----------
for cli in code code-insiders cursor codium; do
    command -v "$cli" >/dev/null 2>&1 || continue
    if "$cli" --list-extensions 2>/dev/null | grep -qi "^$\{CLINE_EXT_ID\}$"; then
        if ask "Uninstall Cline ($CLINE_EXT_ID) from $cli too?"; then
            if "$cli" --uninstall-extension "$CLINE_EXT_ID" >/dev/null 2>&1; then
                info "$cli: uninstalled $CLINE_EXT_ID"
            else
                warn "$cli: uninstall failed — remove manually from the Marketplace pane"
            fi
        else
            skip "$cli: kept $CLINE_EXT_ID"
        fi
    fi
done

# tpl: ---------- 8. ask before removing install dir ----------
if [ -z "$INSTALL_DIR" ] || [ "$INSTALL_DIR" = "/" ] || [ "$INSTALL_DIR" = "$HOME" ]; then
    warn "Refusing to delete suspicious INSTALL_DIR: '$INSTALL_DIR'"
elif [ -d "$INSTALL_DIR" ]; then
    printf '  $\{YELLOW\}Remove install directory %s? [y/N]$\{RESET\} ' "$INSTALL_DIR"
    read -r ans
    case "$ans" in
        [yY]*)
            PARENT_DIR="$(dirname "$INSTALL_DIR")"
            cd "$PARENT_DIR"
            rm -rf "$INSTALL_DIR"
            info "Removed $INSTALL_DIR"
            ;;
        *)
            skip "Kept $INSTALL_DIR — remove manually if desired"
            ;;
    esac
fi

printf '\n$\{GREEN\}$\{BOLD\}Uninstall complete.$\{RESET\}\n'
printf '  Reload your shell to drop the ${CORP_SLUG} command:\n'
printf '    $\{DIM\}source %s$\{RESET\}\n\n' "$SHELL_RC"
