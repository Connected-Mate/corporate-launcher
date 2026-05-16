# tpl: shared module — corporate proxy detection (PowerShell 7+)
# Only sets HTTPS_PROXY if the proxy is reachable.
# Always sets NO_PROXY for localhost + the gateway hostname.

Set-StrictMode -Version Latest

function Setup-Proxy {
    [CmdletBinding()]
    param()

    # tpl: NO_PROXY is always set so the strip-proxy on 127.0.0.1 is reachable
    $env:NO_PROXY  = '${NO_PROXY_LIST}'
    $env:no_proxy  = $env:NO_PROXY

    # tpl: If no proxy is configured for this tenant, exit early
    if ([string]::IsNullOrWhiteSpace('${PROXY_HOST}')) {
        Remove-Item Env:HTTP_PROXY  -ErrorAction SilentlyContinue
        Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
        Remove-Item Env:http_proxy  -ErrorAction SilentlyContinue
        Remove-Item Env:https_proxy -ErrorAction SilentlyContinue
        return
    }

    $proxyUrl = 'http://${PROXY_HOST}:${PROXY_PORT}'

    $reachable = $false
    try {
        # tpl: TCP-level reachability — many corp proxies return 400/407 on GET /
        # so a Test-NetConnection is more reliable than Invoke-WebRequest.
        $test = Test-NetConnection `
            -ComputerName '${PROXY_HOST}' `
            -Port ([int]'${PROXY_PORT}') `
            -InformationLevel Quiet `
            -WarningAction SilentlyContinue `
            -ErrorAction Stop
        $reachable = [bool]$test
    }
    catch {
        $reachable = $false
    }

    if ($reachable) {
        $env:HTTP_PROXY  = $proxyUrl
        $env:HTTPS_PROXY = $proxyUrl
        $env:http_proxy  = $proxyUrl
        $env:https_proxy = $proxyUrl
    }
    else {
        Remove-Item Env:HTTP_PROXY  -ErrorAction SilentlyContinue
        Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
        Remove-Item Env:http_proxy  -ErrorAction SilentlyContinue
        Remove-Item Env:https_proxy -ErrorAction SilentlyContinue
    }
}

function Setup-CaBundle {
    [CmdletBinding()]
    param()

    $bundlePath = '${CA_BUNDLE_PATH}'

    if (-not [string]::IsNullOrWhiteSpace($bundlePath) -and (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
        $env:NODE_EXTRA_CA_CERTS  = $bundlePath
        $env:REQUESTS_CA_BUNDLE   = $bundlePath
        $env:SSL_CERT_FILE        = $bundlePath
        $env:CODEX_CA_CERTIFICATE = $bundlePath
        return
    }

    # tpl: Node 22.15+ can read the OS trust store directly (Windows cert store)
    $env:NODE_USE_SYSTEM_CA = '1'

    # tpl: Fallback only if the tenant explicitly accepted TLS inspection
    if ('${ACCEPT_TLS_INSPECTION}' -eq 'yes') {
        $env:NODE_TLS_REJECT_UNAUTHORIZED = '0'
        $env:PYTHONHTTPSVERIFY            = '0'
    }
}
