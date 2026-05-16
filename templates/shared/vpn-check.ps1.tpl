# tpl: shared module — VPN gate (PowerShell 7+)
# Dot-sourced from the launcher to verify the user is on the corporate network.
# Returns $true if reachable (or VPN not required), $false otherwise.

Set-StrictMode -Version Latest

function Test-CorpVpn {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # tpl: Skip VPN check entirely if not required for this tenant
    if ('${VPN_REQUIRED}' -ne 'yes') {
        return $true
    }

    $probeUrl = '${VPN_PROBE_URL}'

    try {
        # tpl: -UseBasicParsing avoids IE engine dependency on legacy hosts
        $response = Invoke-WebRequest `
            -Uri $probeUrl `
            -TimeoutSec 5 `
            -UseBasicParsing `
            -MaximumRedirection 0 `
            -ErrorAction Stop

        $code = [int]$response.StatusCode

        # tpl: Captive portal trap — HTTP 200 from an unexpected host
        # often means a hotel/airport WiFi portal hijacked the request.
        # We surface a warning but still treat it as "reachable" since
        # the launcher's downstream calls will fail loudly anyway.
        if ($response.BaseResponse.ResponseUri.Host -and
            $response.BaseResponse.ResponseUri.Host -notmatch [regex]::Escape(([Uri]$probeUrl).Host)) {
            Write-Host ("[${CORP_NAME}] Warning: probe redirected to {0} — possible captive portal." -f $response.BaseResponse.ResponseUri.Host) -ForegroundColor Yellow
        }

        if ($code -gt 0 -and $code -lt 600) {
            return $true
        }
    }
    catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
        # tpl: any HTTP response (even 401/403/407) proves the probe is reachable
        if ($_.Exception.Response) {
            return $true
        }
    }
    catch {
        # tpl: timeout / DNS failure / connection refused → not on VPN
    }

    $esc = [char]27
    [Console]::Error.WriteLine("${esc}[0;31m[${CORP_NAME}] Corporate VPN not detected.${esc}[0m")
    [Console]::Error.WriteLine('  Please connect to the corporate VPN before launching.')
    [Console]::Error.WriteLine("  Probe URL: $probeUrl")
    [Console]::Error.WriteLine('  Tip: if you are on a hotel/airport WiFi, sign in to the captive portal first.')
    return $false
}
