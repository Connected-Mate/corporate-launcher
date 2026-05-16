# tpl: shared module — VPN gate
# Sourced from the launcher to verify the user is on the corporate network.
# Exit 1 with a helpful message if not.

check_vpn() {
    # tpl: Skip VPN check entirely if not required for this tenant
    if [ "${VPN_REQUIRED}" != "yes" ]; then
        return 0
    fi

    local probe_url="${VPN_PROBE_URL}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 -m 5 "$probe_url" 2>/dev/null)

    if [[ -n "$code" && "$code" != "000" ]]; then
        return 0
    fi

    printf '\033[0;31m[%s] Corporate VPN not detected.\033[0m\n' "${CORP_NAME}" >&2
    printf '  Please connect to the corporate VPN before launching.\n' >&2
    printf '  Probe URL: %s  (HTTP code: %s)\n' "$probe_url" "${code:-000}" >&2
    return 1
}
