# tpl: corporate-launcher / templates/banner/banner.sh.tpl
# tpl: Sourced bash module rendering the startup banner.
# tpl: Variables substituted at install time: ${CORP_NAME}, ${CORP_POWERED_BY},
# tpl: ${CORP_TAGLINE}, ${BANNER_STYLE}, ${BANNER_COLOR_PRIMARY}, ${INSTALL_DIR}.
# tpl: Runtime-only shell vars are escaped (\${HOME}, \${COLUMNS}, \${cols}, ...).
# tpl: Sourced by the launcher's show_banner() — do NOT execute directly.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Configuration injected by the installer
# ---------------------------------------------------------------------------
: "${CORP_NAME:=${CORP_NAME}}"
: "${CORP_POWERED_BY:=${CORP_POWERED_BY}}"
: "${CORP_TAGLINE:=${CORP_TAGLINE}}"
: "${BANNER_STYLE:=${BANNER_STYLE}}"
: "${BANNER_COLOR_PRIMARY:=${BANNER_COLOR_PRIMARY}}"
: "${INSTALL_DIR:=${INSTALL_DIR}}"

# ---------------------------------------------------------------------------
# ANSI helpers (only emit color if stdout is a TTY)
# ---------------------------------------------------------------------------
__corp_banner_supports_color() {
    [ -t 1 ] && [ "\${TERM:-}" != "dumb" ]
}

__corp_banner_color() {
    # $1 = hex like "#RRGGBB" or named (red/green/blue/cyan/magenta/yellow/white)
    # Emits an ANSI 24-bit truecolor escape, or a graceful 8-color fallback.
    local c="\${1:-}"
    __corp_banner_supports_color || return 0
    case "\$c" in
        '#'??????)
            local r=\$((16#\${c:1:2}))
            local g=\$((16#\${c:3:2}))
            local b=\$((16#\${c:5:2}))
            printf '\033[38;2;%d;%d;%dm' "\$r" "\$g" "\$b"
            ;;
        red)     printf '\033[31m' ;;
        green)   printf '\033[32m' ;;
        yellow)  printf '\033[33m' ;;
        blue)    printf '\033[34m' ;;
        magenta) printf '\033[35m' ;;
        cyan)    printf '\033[36m' ;;
        white)   printf '\033[37m' ;;
        *)       : ;;
    esac
}

__corp_banner_reset() {
    __corp_banner_supports_color || return 0
    printf '\033[0m'
}

__corp_banner_dim() {
    __corp_banner_supports_color || return 0
    printf '\033[2m'
}

__corp_banner_bold() {
    __corp_banner_supports_color || return 0
    printf '\033[1m'
}

# ---------------------------------------------------------------------------
# Terminal width detection
# ---------------------------------------------------------------------------
__corp_banner_cols() {
    local cols=""
    if command -v tput >/dev/null 2>&1; then
        cols="\$(tput cols 2>/dev/null || true)"
    fi
    if [ -z "\$cols" ] && [ -n "\${COLUMNS:-}" ]; then
        cols="\$COLUMNS"
    fi
    # sensible default
    [ -z "\$cols" ] && cols=80
    printf '%s' "\$cols"
}

# ---------------------------------------------------------------------------
# Resolve effective style (auto -> block | slant | mini based on width)
# ---------------------------------------------------------------------------
__corp_banner_resolve_style() {
    local style="\${BANNER_STYLE:-auto}"
    if [ "\$style" = "auto" ]; then
        local cols
        cols="\$(__corp_banner_cols)"
        if [ "\$cols" -gt 100 ]; then
            style="block"
        elif [ "\$cols" -ge 60 ]; then
            style="slant"
        else
            style="mini"
        fi
    fi
    printf '%s' "\$style"
}

# ---------------------------------------------------------------------------
# Fallback ASCII frames (used when python3 / pixel-art-logo.py absent)
# ---------------------------------------------------------------------------
__corp_banner_fallback_block() {
    local name="\$1"
    local width=\$(( \${#name} + 8 ))
    local bar
    bar="\$(printf '%*s' "\$width" '' | tr ' ' '=')"
    printf '  %s\n' "\$bar"
    printf '  ||  %s  ||\n' "\$name"
    printf '  %s\n' "\$bar"
}

__corp_banner_fallback_slant() {
    local name="\$1"
    printf '  /// %s ///\n' "\$name"
    printf '  \\\\\\ %s \\\\\\\n' "\$(printf '%*s' "\${#name}" '' | tr ' ' '_')"
}

__corp_banner_fallback_mini() {
    local name="\$1"
    printf '  [ %s ]\n' "\$name"
}

__corp_banner_fallback_pixel() {
    local name="\$1"
    printf '  +%s+\n' "\$(printf '%*s' "\$((\${#name}+2))" '' | tr ' ' '-')"
    printf '  | %s |\n' "\$name"
    printf '  +%s+\n' "\$(printf '%*s' "\$((\${#name}+2))" '' | tr ' ' '-')"
}

__corp_banner_fallback_vintage() {
    local name="\$1"
    printf '  .~*~. %s .~*~.\n' "\$name"
}

__corp_banner_fallback_tech() {
    local name="\$1"
    printf '  >_ %s\n' "\$name"
}

__corp_banner_fallback() {
    local style="\$1" name="\$2"
    case "\$style" in
        block)   __corp_banner_fallback_block   "\$name" ;;
        slant)   __corp_banner_fallback_slant   "\$name" ;;
        mini)    __corp_banner_fallback_mini    "\$name" ;;
        pixel)   __corp_banner_fallback_pixel   "\$name" ;;
        vintage) __corp_banner_fallback_vintage "\$name" ;;
        tech)    __corp_banner_fallback_tech    "\$name" ;;
        *)       __corp_banner_fallback_block   "\$name" ;;
    esac
}

# ---------------------------------------------------------------------------
# Try the python pixel-art renderer, fall back to ASCII frame on any error
# ---------------------------------------------------------------------------
__corp_banner_render() {
    local style="\$1"
    local script="\${INSTALL_DIR}/scripts/pixel-art-logo.py"
    if command -v python3 >/dev/null 2>&1 && [ -f "\$script" ]; then
        if python3 "\$script" \
                --text  "\${CORP_NAME}" \
                --style "\$style" \
                --color "\${BANNER_COLOR_PRIMARY}" 2>/dev/null; then
            return 0
        fi
    fi
    __corp_banner_fallback "\$style" "\${CORP_NAME}"
}

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------
show_corp_banner() {
    local style
    style="\$(__corp_banner_resolve_style)"

    # Top spacing
    printf '\n'

    # Banner art (colored)
    __corp_banner_color "\${BANNER_COLOR_PRIMARY}"
    __corp_banner_render "\$style"
    __corp_banner_reset
    printf '\n'

    # Identity block
    __corp_banner_bold
    printf '  %s\n' "\${CORP_NAME}"
    __corp_banner_reset
    __corp_banner_dim
    printf '  Powered by %s\n' "\${CORP_POWERED_BY}"
    __corp_banner_reset
    printf '  %s\n' "\${CORP_TAGLINE}"

    # Heart footer (V11 template)
    printf '\n'
    __corp_banner_dim
    printf '  Proudly made from France with '
    __corp_banner_reset
    __corp_banner_color "red"
    printf '❤'
    __corp_banner_reset
    printf '\n\n'
}

# Allow callers to discover the resolved style (handy for tests / debugging)
corp_banner_style() {
    __corp_banner_resolve_style
}
