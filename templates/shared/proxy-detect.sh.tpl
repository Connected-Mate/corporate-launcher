# tpl: shared module — corporate proxy detection
# Only sets HTTP_PROXY / HTTPS_PROXY if the proxy is reachable.
# Always sets NO_PROXY for localhost + the gateway hostname.

setup_proxy() {
    # tpl: NO_PROXY is always set so the strip-proxy on 127.0.0.1 is reachable
    export NO_PROXY="${NO_PROXY_LIST}"
    export no_proxy="$NO_PROXY"

    # tpl: If no proxy is configured for this tenant, exit early
    if [ -z "${PROXY_HOST}" ]; then
        unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
        return 0
    fi

    local proxy_url="http://${PROXY_HOST}:${PROXY_PORT}"

    if curl -sf --connect-timeout 2 -o /dev/null "$proxy_url" 2>/dev/null; then
        export HTTP_PROXY="$proxy_url"
        export HTTPS_PROXY="$proxy_url"
        export http_proxy="$HTTP_PROXY"
        export https_proxy="$HTTPS_PROXY"
    else
        unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
    fi
}

setup_ca_bundle() {
    if [ -n "${CA_BUNDLE_PATH}" ] && [ -r "${CA_BUNDLE_PATH}" ]; then
        export NODE_EXTRA_CA_CERTS="${CA_BUNDLE_PATH}"
        export REQUESTS_CA_BUNDLE="${CA_BUNDLE_PATH}"
        export SSL_CERT_FILE="${CA_BUNDLE_PATH}"
        export CODEX_CA_CERTIFICATE="${CA_BUNDLE_PATH}"
        return 0
    fi

    # tpl: Node 22.15+ can read the OS trust store directly
    export NODE_USE_SYSTEM_CA=1

    # tpl: Fallback only if the tenant explicitly accepted TLS inspection
    if [ "${ACCEPT_TLS_INSPECTION}" = "yes" ]; then
        export NODE_TLS_REJECT_UNAUTHORIZED=0
        export PYTHONHTTPSVERIFY=0
    fi
}
