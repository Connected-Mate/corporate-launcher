#!/usr/bin/env bash
# tpl: ${CORP_NAME} — Corporate installer for the Gemini CLI wrapper
# tpl: Powered by ${CORP_POWERED_BY}
# tpl: Compatible: macOS, Linux, WSL, Git Bash (Windows)

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORP_NAME="${CORP_NAME}"
CORP_SLUG="${CORP_SLUG}"
CORP_SLUG_UPPER="${CORP_SLUG_UPPER}"
GM_BACKEND="${GM_BACKEND}"
GM_AUTH_MODE="${GM_AUTH_MODE}"
GM_PRIMARY_MODEL="${GM_PRIMARY_MODEL}"
GM_VERTEX_PROJECT="${GM_VERTEX_PROJECT}"
GM_VERTEX_LOCATION="${GM_VERTEX_LOCATION}"

# --- Colors -------------------------------------------------------------------
ORANGE="\033[38;5;208m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

info() { printf '  %b[OK]%b %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %b[!!]%b %s\n' "$YELLOW" "$RESET" "$1"; }
fail() { printf '  %b[KO]%b %s\n' "$RED" "$RESET" "$1"; }
step() { printf '\n%b%s%b\n' "$BOLD" "$1" "$RESET"; }
ask_yes() {
    local prompt="$1" answer
    printf '  %b%s [y/N] %b' "$YELLOW" "$prompt" "$RESET"
    read -r answer
    case "$answer" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# --- OS + shell detection -----------------------------------------------------
detect_os() {
    OS_TYPE="unknown"
    case "$(uname -s)" in
        Darwin*) OS_TYPE="macos" ;;
        Linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                OS_TYPE="wsl"
            else
                OS_TYPE="linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*) OS_TYPE="gitbash" ;;
    esac
}

detect_shell_rc() {
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
    [ -f "$SHELL_RC" ] || touch "$SHELL_RC"
}

# --- Banner -------------------------------------------------------------------
printf '\n%b%b%s — Installer%b\n' "$ORANGE" "$BOLD" "$CORP_NAME" "$RESET"
printf '%bPowered by ${CORP_POWERED_BY}%b\n' "$DIM" "$RESET"

# --- Step 1: environment ------------------------------------------------------
step "[1/7] Detecting environment..."
detect_os
if [ "$OS_TYPE" = "unknown" ]; then
    fail "Unsupported OS. Supported: macOS, Linux, WSL, Git Bash."
    exit 1
fi
info "OS: $OS_TYPE"
info "Install dir: $INSTALL_DIR"

# --- Step 2: Node.js ----------------------------------------------------------
step "[2/7] Checking Node.js..."
if ! command -v node >/dev/null 2>&1; then
    fail "Node.js is required (>=20)."
    case "$OS_TYPE" in
        macos)       echo "  brew install node" ;;
        linux|wsl)   echo "  sudo apt install nodejs npm  # or use nvm" ;;
        gitbash)     echo "  Install from https://nodejs.org" ;;
    esac
    exit 1
fi
info "node: $(node --version)"

# --- Step 3: underlying CLI engine -------------------------------------------
step "[3/7] Checking the underlying CLI engine..."
if ! command -v gemini >/dev/null 2>&1; then
    warn "Engine not installed."
    if ask_yes "Install it now via npm?"; then
        if npm install -g @google/gemini-cli; then
            info "Engine installed: $(gemini --version 2>/dev/null || echo unknown)"
        else
            fail "npm install failed. Try: sudo npm install -g @google/gemini-cli"
            exit 1
        fi
    else
        echo "  Manual: npm install -g @google/gemini-cli"
        exit 1
    fi
else
    info "Engine version: $(gemini --version 2>/dev/null || echo unknown)"
fi

# --- Step 4: auth -------------------------------------------------------------
step "[4/7] Configuring authentication..."

case "$GM_BACKEND" in
    vertex)
        if [ "$GM_AUTH_MODE" = "ADC" ]; then
            if ! command -v gcloud >/dev/null 2>&1; then
                fail "gcloud CLI is required for ADC authentication."
                echo "  Install: https://cloud.google.com/sdk/docs/install"
                exit 1
            fi
            info "gcloud: $(gcloud --version 2>/dev/null | head -1)"

            if gcloud auth application-default print-access-token >/dev/null 2>&1; then
                info "Application Default Credentials already configured."
            else
                warn "No ADC session yet — a browser window will open."
                if ask_yes "Run 'gcloud auth application-default login' now?"; then
                    gcloud auth application-default login
                    info "ADC login complete."
                else
                    warn "You will need to run it manually before first launch."
                fi
            fi

            # tpl: pin quota project so billing is unambiguous
            if [ -n "$GM_VERTEX_PROJECT" ]; then
                gcloud auth application-default set-quota-project "$GM_VERTEX_PROJECT" 2>/dev/null \
                    && info "Quota project pinned to $GM_VERTEX_PROJECT" \
                    || warn "Could not pin quota project (non-fatal)."
            fi
        else
            # tpl: service account key file
            warn "Service-account key mode selected."
            echo "  Set GOOGLE_APPLICATION_CREDENTIALS to the path of your .json key,"
            echo "  ideally exported from $SHELL_RC."
        fi
        ;;

    ai-studio)
        # shellcheck source=/dev/null
        . "$INSTALL_DIR/lib/secrets-store.sh"
        export CORP_SLUG CORP_SLUG_UPPER CORP_NAME
        if load_api_key && [ -n "${CORP_API_KEY:-}" ]; then
            info "API key already in secret store."
            if ask_yes "Replace it?"; then prompt_for_api_key; fi
        else
            prompt_for_api_key
        fi
        ;;

    *)
        fail "Unknown backend: $GM_BACKEND"
        exit 1
        ;;
esac

# --- Step 5: generate ~/.gemini/settings.json --------------------------------
step "[5/7] Writing ~/.gemini/settings.json..."

GEMINI_HOME="$HOME/.gemini"
mkdir -p "$GEMINI_HOME"

# tpl: backup any existing user settings before we overwrite
if [ -f "$GEMINI_HOME/settings.json" ] && [ ! -f "$GEMINI_HOME/settings.json.${CORP_SLUG}.bak" ]; then
    cp "$GEMINI_HOME/settings.json" "$GEMINI_HOME/settings.json.${CORP_SLUG}.bak"
    info "Existing settings.json backed up."
fi

cp "$INSTALL_DIR/share/settings.json" "$GEMINI_HOME/settings.json"
chmod 644 "$GEMINI_HOME/settings.json"
info "settings.json deployed."

# --- Step 6: deploy GEMINI.md identity file ----------------------------------
step "[6/7] Deploying identity lock..."

if [ -f "$GEMINI_HOME/GEMINI.md" ] \
   && ! grep -q "${CORP_SLUG}-identity-lock" "$GEMINI_HOME/GEMINI.md" 2>/dev/null \
   && [ ! -f "$GEMINI_HOME/GEMINI.md.${CORP_SLUG}.bak" ]; then
    cp "$GEMINI_HOME/GEMINI.md" "$GEMINI_HOME/GEMINI.md.${CORP_SLUG}.bak"
    info "Existing GEMINI.md backed up."
fi

cp "$INSTALL_DIR/share/GEMINI.md" "$GEMINI_HOME/GEMINI.md"
chmod 644 "$GEMINI_HOME/GEMINI.md"
info "GEMINI.md identity file deployed."

# --- Step 7: shell RC block (idempotent) -------------------------------------
step "[7/7] Wiring up the shell command..."

detect_shell_rc
info "Shell: $SHELL_NAME ($SHELL_RC)"

MARKER_START="# >>> ${CORP_SLUG} >>>"
MARKER_END="# <<< ${CORP_SLUG} <<<"

if grep -qF "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
    warn "Previous install detected — refreshing block."
    cp "$SHELL_RC" "${SHELL_RC}.${CORP_SLUG}-backup"
    if [ "$OS_TYPE" = "macos" ]; then
        sed -i '' "/${MARKER_START}/,/${MARKER_END}/d" "$SHELL_RC"
    else
        sed -i "/${MARKER_START}/,/${MARKER_END}/d" "$SHELL_RC"
    fi
fi

{
    echo ""
    echo "$MARKER_START"
    echo "# ${CORP_NAME} — Corporate AI CLI"
    echo "# Powered by ${CORP_POWERED_BY}"
    echo "# Installed: $(date +%Y-%m-%d)"
    echo "${CORP_SLUG}() {"
    echo "    \"${INSTALL_DIR}/bin/${CORP_SLUG}\" \"\$@\""
    echo "}"
    echo "export ${CORP_SLUG_UPPER}_HOME=\"${INSTALL_DIR}\""
    echo "$MARKER_END"
} >> "$SHELL_RC"

chmod +x "$INSTALL_DIR/bin/${CORP_SLUG}" 2>/dev/null || true
info "Shell block added."

# tpl: --- Optional extras (CA bundle / skills / MCP) -----------------------
if [ "${CA_DETECT_AUTO}" = "yes" ] && [ -f "$INSTALL_DIR/scripts/extract-corp-ca.sh" ]; then
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/scripts/extract-corp-ca.sh" && extract_corp_ca || true
fi
if [ -f "$INSTALL_DIR/scripts/install-skills.sh" ]; then
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/scripts/install-skills.sh" && install_skills || true
fi
if [ -f "$INSTALL_DIR/scripts/install-mcp.sh" ]; then
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/scripts/install-mcp.sh" && install_mcp_servers || true
fi

# --- Done ---------------------------------------------------------------------
printf '\n  %b%b%s installed successfully.%b\n\n' "$ORANGE" "$BOLD" "$CORP_NAME" "$RESET"
printf '  Reload your shell:  %bsource %s%b\n' "$GREEN" "$SHELL_RC" "$RESET"
printf '  Launch:             %b%s%b\n\n' "$GREEN" "$CORP_SLUG" "$RESET"
printf '  Update:             %b%s --update%b\n\n' "$GREEN" "$CORP_SLUG" "$RESET"
