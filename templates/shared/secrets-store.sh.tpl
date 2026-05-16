# tpl: shared module — cross-OS secret storage
# Loads the API key into $CORP_API_KEY.
# Tries (in order): OS keychain → ${CORP_SLUG}.conf file (chmod 600).

# tpl: read a key=value line from a shell config file
_corp_read_conf_var() {
    local var="$1" file="$2"
    grep -E "^${var}=" "$file" 2>/dev/null | head -1 | sed "s/^${var}=//; s/^\"//; s/\"\$//"
}

load_api_key() {
    local conf="$HOME/.${CORP_SLUG}.conf"

    # tpl: 1. macOS Keychain
    if command -v security >/dev/null 2>&1; then
        CORP_API_KEY=$(security find-generic-password -s "${CORP_SLUG}" -a "$USER" -w 2>/dev/null) || CORP_API_KEY=""
        if [ -n "$CORP_API_KEY" ]; then
            return 0
        fi
    fi

    # tpl: 2. Linux libsecret
    if command -v secret-tool >/dev/null 2>&1; then
        CORP_API_KEY=$(secret-tool lookup service "${CORP_SLUG}" username "$USER" 2>/dev/null) || CORP_API_KEY=""
        if [ -n "$CORP_API_KEY" ]; then
            return 0
        fi
    fi

    # tpl: 3. chmod 600 conf file (fallback)
    if [ -f "$conf" ]; then
        CORP_API_KEY=$(_corp_read_conf_var "${CORP_SLUG_UPPER}_API_KEY" "$conf")
        if [ -z "$CORP_API_KEY" ]; then
            CORP_API_KEY=$(_corp_read_conf_var CORP_API_KEY "$conf")
        fi
    fi

    if [ -n "$CORP_API_KEY" ] && ! [[ "$CORP_API_KEY" =~ ^[a-zA-Z0-9_.\-]+$ ]]; then
        printf '\033[0;31mERROR: API key contains invalid characters.\033[0m\n' >&2
        printf '  Allowed: a-z A-Z 0-9 _ . -\n' >&2
        return 1
    fi
}

prompt_for_api_key() {
    printf '\n\033[1;38;5;208m%s — first launch\033[0m\n\n' "${CORP_NAME}"
    printf 'Get a token from: %s\n\n' "${LLM_TOKEN_URL:-the gateway portal}"
    printf 'Token: '

    # tpl: -s = silent. Never log the key.
    stty -echo 2>/dev/null
    read -r api_key
    stty echo 2>/dev/null
    echo

    if [ -z "$api_key" ]; then
        printf '\033[0;31mERROR: empty token.\033[0m\n' >&2
        return 1
    fi
    if ! [[ "$api_key" =~ ^[a-zA-Z0-9_.\-]+$ ]]; then
        printf '\033[0;31mERROR: token contains invalid characters.\033[0m\n' >&2
        return 1
    fi

    save_api_key "$api_key"
    CORP_API_KEY="$api_key"
}

save_api_key() {
    local key="$1" conf="$HOME/.${CORP_SLUG}.conf"

    # tpl: macOS keychain
    if command -v security >/dev/null 2>&1; then
        security add-generic-password -s "${CORP_SLUG}" -a "$USER" -w "$key" -U 2>/dev/null && return 0
    fi

    # tpl: Linux libsecret
    if command -v secret-tool >/dev/null 2>&1; then
        printf '%s' "$key" | secret-tool store --label="${CORP_NAME}" service "${CORP_SLUG}" username "$USER"
        return 0
    fi

    # tpl: fallback file
    (
        umask 077
        cat > "$conf" <<EOF_CONF
# ${CORP_NAME} — Configuration
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Do not share

${CORP_SLUG_UPPER}_API_KEY=${key}
EOF_CONF
    )
}
