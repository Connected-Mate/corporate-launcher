#!/usr/bin/env bash
# =====================================================================
#  ${CORP_NAME} — Cline launcher installer
#  Powered by ${CORP_POWERED_BY}
#
#  Idempotent. Re-runnable. Backs up files before modifying them.
#
#  - Detects OS + shell RC (zsh / bash / fish)
#  - Detects supported IDEs: VS Code (`code`), Cursor (`cursor`),
#    VSCodium (`codium`), VS Code Insiders (`code-insiders`)
#  - Installs the Cline extension via `<ide> --install-extension
#    saoudrizwan.claude-dev` (works on every VS Code fork that
#    exposes the CLI: VS Code, Cursor, VSCodium)
#  - Merges a managed cline.* block into the IDE's settings.json
#    (preserving every other key) via jq
#  - Installs the corporate identity + cyber rules into Cline's
#    GLOBAL rules directory ($HOME/Documents/Cline/Rules) so the
#    rebrand applies to every workspace the user opens
#  - Wires an idempotent ${CORP_SLUG} function block into the shell RC
#  - Stores the API token via the shared secrets-store.sh
# =====================================================================

set -euo pipefail
umask 077

INSTALL_DIR="$(cd "$(dirname "$\{BASH_SOURCE[0]\}")" && pwd)"
LAUNCHER_VERSION="${CORP_LAUNCHER_VERSION}"

if [ -t 1 ]; then
    ORANGE="\033[38;5;${BANNER_COLOR_PRIMARY}m"
    GREEN="\033[32m"
    RED="\033[31m"
    YELLOW="\033[33m"
    BOLD="\033[1m"
    DIM="\033[2m"
    RESET="\033[0m"
else
    ORANGE=""; GREEN=""; RED=""; YELLOW=""; BOLD=""; DIM=""; RESET=""
fi

info()  { printf '  $\{GREEN\}[OK]$\{RESET\} %s\n' "$*"; }
warn()  { printf '  $\{YELLOW\}[!]$\{RESET\}  %s\n' "$*"; }
fail()  { printf '  $\{RED\}[KO]$\{RESET\} %s\n' "$*" >&2; }
step()  { printf '\n$\{BOLD\}%s$\{RESET\}\n' "$*"; }
ask()   { printf '  $\{YELLOW\}%s [y/N] $\{RESET\}' "$*"; read -r ans; case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac; }

# tpl: ---------- OS / shell detection ----------
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
        MINGW*|MSYS*|CYGWIN*) OS_TYPE="gitbash"; OS_LABEL="Git Bash (Windows)" ;;
        *) OS_TYPE="unknown"; OS_LABEL="Unknown" ;;
    esac
}

detect_shell_rc() {
    local shell_name
    shell_name=$(basename "$\{SHELL:-/bin/sh\}")
    case "$shell_name" in
        zsh)  SHELL_NAME="zsh";  SHELL_RC="$HOME/.zshrc" ;;
        bash) SHELL_NAME="bash"
              if [ "$OS_TYPE" = "macos" ] && [ -f "$HOME/.bash_profile" ]; then
                  SHELL_RC="$HOME/.bash_profile"
              else
                  SHELL_RC="$HOME/.bashrc"
              fi
              ;;
        fish) SHELL_NAME="fish"; SHELL_RC="$HOME/.config/fish/conf.d/${CORP_SLUG}.fish" ;;
        *)    SHELL_NAME="sh";   SHELL_RC="$HOME/.profile" ;;
    esac
    [ -f "$SHELL_RC" ] || { mkdir -p "$(dirname "$SHELL_RC")" && touch "$SHELL_RC"; }
}

# tpl: ---------- IDE detection ----------
# tpl: Sets IDE_LIST (space-separated CLI names) and IDE_PRIMARY (first
# tpl: one found, preferred for the auto-install step).
detect_ides() {
    IDE_LIST=""
    IDE_PRIMARY=""
    local cli
    for cli in code cursor codium code-insiders; do
        if command -v "$cli" >/dev/null 2>&1; then
            IDE_LIST="$\{IDE_LIST\}$\{IDE_LIST:+ \}$cli"
            [ -z "$IDE_PRIMARY" ] && IDE_PRIMARY="$cli"
        fi
    done
}

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
        *)
            case "$cli" in
                code)          printf '%s' "$APPDATA/Code/User" ;;
                code-insiders) printf '%s' "$APPDATA/Code - Insiders/User" ;;
                cursor)        printf '%s' "$APPDATA/Cursor/User" ;;
                codium)        printf '%s' "$APPDATA/VSCodium/User" ;;
            esac
            ;;
    esac
}

show_banner() {
    printf '\n$\{ORANGE\}$\{BOLD\}'
    printf '  ╔═══════════════════════════════════════════════╗\n'
    printf '  ║  %-44s ║\n' "${CORP_NAME} — installer"
    printf '  ║  %-44s ║\n' "Powered by ${CORP_POWERED_BY}"
    printf '  ╚═══════════════════════════════════════════════╝\n'
    printf '$\{RESET\}\n'
}

# tpl: ---------- markers (must stay in sync with uninstall.sh) ----------
MARKER_START="# >>> ${CORP_SLUG} >>>"
MARKER_END="# <<< ${CORP_SLUG} <<<"
GENERATED_MARKER="${CORP_SLUG}-managed: generated by ${CORP_NAME} launcher v${CORP_LAUNCHER_VERSION}"
CLINE_EXT_ID="saoudrizwan.claude-dev"

# =====================================================================
#  Begin
# =====================================================================
show_banner

step "[1/7] Detect environment"
detect_os
if [ "$OS_TYPE" = "unknown" ]; then
    fail "Unsupported OS. Supported: macOS, Linux, WSL, Git Bash."
    exit 1
fi
info "OS         : $OS_LABEL"
detect_shell_rc
info "Shell RC   : $SHELL_RC"
info "Install dir: $INSTALL_DIR"

# tpl: ---------------------------------------------------------------------
# tpl: Step 2 — IDE detection
# tpl: Cline runs as a VS Code extension. Cursor and VSCodium are
# tpl: VS Code forks and accept the same `--install-extension` command.
# tpl: We do NOT hard-fail when none is found — the user may install one
# tpl: later and re-run this script.
# tpl: ---------------------------------------------------------------------
step "[2/7] Detect VS Code-family IDEs"
detect_ides

if [ -n "$IDE_LIST" ]; then
    info "Detected   : $IDE_LIST"
    info "Primary    : $IDE_PRIMARY (will receive the auto-install)"
else
    warn "No 'code' / 'cursor' / 'codium' CLI found in PATH."
    warn "Cline is an IDE extension and needs one of:"
    warn "  - VS Code     https://code.visualstudio.com"
    warn "  - Cursor      https://cursor.com  (VS Code fork, fully Cline-compatible)"
    warn "  - VSCodium    https://vscodium.com  (open-source VS Code build)"
fi

# tpl: ---------------------------------------------------------------------
# tpl: Step 3 — install the Cline extension
# tpl: Marketplace id: saoudrizwan.claude-dev (same id on VS Marketplace
# tpl: and Open VSX, so it resolves correctly in Cursor and VSCodium).
# tpl: We install in EVERY detected IDE so a user with both VS Code and
# tpl: Cursor gets a consistent setup.
# tpl: ---------------------------------------------------------------------
step "[3/7] Install the Cline extension ($CLINE_EXT_ID)"
if [ -n "$IDE_LIST" ]; then
    for cli in $IDE_LIST; do
        if "$cli" --list-extensions 2>/dev/null | grep -qi "^$\{CLINE_EXT_ID\}$"; then
            info "$cli: already installed"
            continue
        fi
        if ask "Install Cline in $cli now?"; then
            if "$cli" --install-extension "$CLINE_EXT_ID" --force >/dev/null 2>&1; then
                info "$cli: installed $CLINE_EXT_ID"
            else
                warn "$cli: install failed — install manually from the Marketplace"
            fi
        else
            warn "$cli: skipped — install later with: $cli --install-extension $CLINE_EXT_ID"
        fi
    done
else
    warn "No IDE detected — skipping extension install."
fi

# tpl: ---------------------------------------------------------------------
# tpl: Step 4 — Permissions
# tpl: ---------------------------------------------------------------------
step "[4/7] Set permissions"
chmod 755 "$INSTALL_DIR/${CORP_SLUG}"
info "launcher executable: $INSTALL_DIR/${CORP_SLUG}"
if [ -d "$INSTALL_DIR/scripts" ]; then
    find "$INSTALL_DIR/scripts" -type f -name "*.sh" -exec chmod 644 {} \;
    info "shared modules: $INSTALL_DIR/scripts/"
fi
chmod 755 "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true
chmod 600 "$INSTALL_DIR/settings-cline.json" 2>/dev/null || true

# tpl: ---------------------------------------------------------------------
# tpl: Step 5 — merge cline.* keys into each detected IDE's settings.json
# tpl: This step is the heart of the Cline integration. We do a deep
# tpl: merge (jq `*`) so any other user-configured key survives. The
# tpl: previous version of settings.json is backed up exactly once.
# tpl: ---------------------------------------------------------------------
step "[5/7] Configure settings.json"
if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found — installing it is recommended for a clean settings merge."
    warn "macOS: brew install jq    Debian/Ubuntu: sudo apt install jq"
fi

if [ -r "$INSTALL_DIR/settings-cline.json" ]; then
    for cli in $IDE_LIST; do
        sdir="$(ide_settings_dir_for "$cli")"
        [ -z "$sdir" ] && continue
        mkdir -p "$sdir"
        sfile="$sdir/settings.json"

        # tpl: substitute the API key + gateway + model from the
        # tpl: launcher environment into the snippet
        tmp_snippet="$(mktemp -t ${CORP_SLUG}-cline.XXXXXX)"
        CORP_API_KEY="$\{CORP_API_KEY:-PLACEHOLDER_RUN_SET_KEY\}" \
        LLM_OPENAI_BASE_URL="${LLM_OPENAI_BASE_URL}" \
        LLM_PRIMARY_MODEL="${LLM_PRIMARY_MODEL}" \
        CORP_NAME="${CORP_NAME}" \
        CORP_SLUG="${CORP_SLUG}" \
        INSTALL_DIR="$INSTALL_DIR" \
            envsubst < "$INSTALL_DIR/settings-cline.json" > "$tmp_snippet"

        if [ -f "$sfile" ]; then
            if grep -qF "$GENERATED_MARKER" "$sfile" 2>/dev/null; then
                info "$cli: refreshing managed block in $sfile"
            else
                cp "$sfile" "$\{sfile\}.${CORP_SLUG}-backup"
                warn "$cli: existing settings.json backed up to $\{sfile\}.${CORP_SLUG}-backup"
            fi
        else
            printf '{}\n' > "$sfile"
        fi

        if command -v jq >/dev/null 2>&1; then
            merged="$(mktemp -t ${CORP_SLUG}-merged.XXXXXX)"
            jq -s '.[0] * .[1]' "$sfile" "$tmp_snippet" > "$merged"
            install -m 0600 "$merged" "$sfile"
            rm -f "$merged"
            info "$cli: merged cline.* keys into $sfile"
        else
            warn "$cli: jq missing — wrote snippet next to settings.json instead"
            install -m 0600 "$tmp_snippet" "$\{sfile\}.${CORP_SLUG}.snippet"
        fi
        rm -f "$tmp_snippet"
    done
else
    fail "missing $INSTALL_DIR/settings-cline.json — installer aborted"
    exit 1
fi

# tpl: ---------------------------------------------------------------------
# tpl: Step 5b — install global Cline rules (identity + cyber)
# tpl: Cline reads rules from $HOME/Documents/Cline/Rules (global) and
# tpl: $WORKSPACE/.clinerules/ (per-project). Installing into the global
# tpl: directory means the rebrand applies to every workspace the user
# tpl: opens, including ones we never see.
# tpl: ---------------------------------------------------------------------
case "$OS_TYPE" in
    macos) CLINE_GLOBAL_RULES="$HOME/Documents/Cline/Rules" ;;
    linux|wsl)
        if [ -d "$HOME/Documents" ]; then
            CLINE_GLOBAL_RULES="$HOME/Documents/Cline/Rules"
        else
            CLINE_GLOBAL_RULES="$HOME/Cline/Rules"
        fi
        ;;
    *) CLINE_GLOBAL_RULES="$HOME/Documents/Cline/Rules" ;;
esac
mkdir -p "$CLINE_GLOBAL_RULES"
if [ -r "$INSTALL_DIR/BRANDING.md" ]; then
    install -m 0644 "$INSTALL_DIR/BRANDING.md" "$CLINE_GLOBAL_RULES/00-${CORP_SLUG}-identity.md"
    info "Installed global rule: $CLINE_GLOBAL_RULES/00-${CORP_SLUG}-identity.md"
fi
if [ -r "$INSTALL_DIR/cyber-rules.md" ]; then
    install -m 0644 "$INSTALL_DIR/cyber-rules.md" "$CLINE_GLOBAL_RULES/10-${CORP_SLUG}-cyber.md"
    info "Installed global rule: $CLINE_GLOBAL_RULES/10-${CORP_SLUG}-cyber.md"
fi

# tpl: ---------------------------------------------------------------------
# tpl: Step 6 — shell RC block (idempotent)
# tpl: ---------------------------------------------------------------------
step "[6/7] Wire up the shell ($SHELL_RC)"

if grep -qF "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
    cp "$SHELL_RC" "$\{SHELL_RC\}.${CORP_SLUG}.bak"
    info "Backup saved at $\{SHELL_RC\}.${CORP_SLUG}.bak"
    if [ "$OS_TYPE" = "macos" ]; then
        sed -i '' "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    else
        sed -i "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    fi
    info "Removed previous block"
fi

{
    printf '\n%s\n' "$MARKER_START"
    printf '# %s — Powered by %s\n' "${CORP_NAME}" "${CORP_POWERED_BY}"
    printf '# Installed on %s\n' "$(date +%Y-%m-%d)"
    printf 'export ${CORP_SLUG_UPPER}_HOME="%s"\n' "$INSTALL_DIR"
    printf '${CORP_SLUG}() { "$\{${CORP_SLUG_UPPER}_HOME\}/${CORP_SLUG}" "$@"; }\n'
    printf '%s\n' "$MARKER_END"
} >> "$SHELL_RC"
info "Shell block added"

# tpl: ---------------------------------------------------------------------
# tpl: Step 7 — API token (shared secrets-store.sh)
# tpl: ---------------------------------------------------------------------
step "[7/7] Configure API token"

export CORP_NAME="${CORP_NAME}"
export CORP_SLUG="${CORP_SLUG}"
export CORP_SLUG_UPPER="${CORP_SLUG_UPPER}"
export LLM_TOKEN_URL="${LLM_TOKEN_URL}"

# shellcheck disable=SC1091
. "$INSTALL_DIR/scripts/secrets-store.sh"

load_api_key || true
if [ -n "$\{CORP_API_KEY:-\}" ]; then
    if ask "An API token is already stored. Replace it?"; then
        prompt_for_api_key
    fi
else
    prompt_for_api_key || warn "token not configured — run '${CORP_SLUG} --set-key' later"
fi

# tpl: ---------------------------------------------------------------------
# tpl: Optional extras (CA bundle / skills / MCP)
# tpl: ---------------------------------------------------------------------
if [ "${CA_DETECT_AUTO}" = "yes" ] && [ -f "$INSTALL_DIR/scripts/extract-corp-ca.sh" ]; then
    source "$INSTALL_DIR/scripts/extract-corp-ca.sh" && extract_corp_ca || true
fi
if [ -f "$INSTALL_DIR/scripts/install-skills.sh" ]; then
    source "$INSTALL_DIR/scripts/install-skills.sh" && install_skills || true
fi
if [ -f "$INSTALL_DIR/scripts/install-mcp.sh" ]; then
    source "$INSTALL_DIR/scripts/install-mcp.sh" && install_mcp_servers || true
fi

# tpl: ---------------------------------------------------------------------
# tpl: Done
# tpl: ---------------------------------------------------------------------
printf '\n$\{ORANGE\}$\{BOLD\}  Installation complete.$\{RESET\}\n\n'
printf '  Reload your shell : $\{GREEN\}source %s$\{RESET\}\n' "$SHELL_RC"
printf '  Open IDE          : $\{GREEN\}%s .$\{RESET\}\n' "$\{IDE_PRIMARY:-code\}"
printf '  Open Cline panel  : $\{DIM\}sidebar → Cline icon$\{RESET\}\n'
printf '  Re-merge settings : $\{DIM\}${CORP_SLUG} --refresh$\{RESET\}\n'
printf '  Diagnostics       : $\{DIM\}${CORP_SLUG} --status$\{RESET\}\n'
printf '  Uninstall         : $\{DIM\}${CORP_SLUG} --uninstall$\{RESET\}\n\n'
[ "${VPN_REQUIRED}" = "yes" ] && printf '  $\{YELLOW\}[!]$\{RESET\}  Corporate VPN required before first launch.\n\n'
