#Requires -Version 7.0
# =====================================================================
#  ${CORP_NAME}
#  Powered by ${CORP_POWERED_BY}
#
#  Internal AI coding assistant for ${CORP_ORGANIZATION}.
#  - All traffic routed through the corporate gateway
#  - Telemetry disabled
#  - Identity rebranded
#  - Process-level isolation (no system changes)
#  - VPN required: ${VPN_REQUIRED}
# =====================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# tpl: resolve install root (PSScriptRoot is the directory of this script)
if (-not $env:${CORP_SLUG_UPPER}_HOME) {
    $env:${CORP_SLUG_UPPER}_HOME = $PSScriptRoot
}
$Script:InstallRoot = $env:${CORP_SLUG_UPPER}_HOME

# tpl: --- load shared modules (PowerShell equivalents of the bash modules) ---
. (Join-Path $Script:InstallRoot 'scripts/vpn-check.ps1')
. (Join-Path $Script:InstallRoot 'scripts/proxy-detect.ps1')
. (Join-Path $Script:InstallRoot 'scripts/secrets-store.ps1')

# tpl: --- ANSI colors (PSStyle on PS 7.2+, fallback to raw escapes) ---
if ($PSStyle) {
    $Script:CLR_ORANGE = $PSStyle.Foreground.FromRgb(0xFF, 0x8C, 0x00)
    $Script:CLR_BOLD   = $PSStyle.Bold
    $Script:CLR_DIM    = $PSStyle.Dim
    $Script:CLR_RED    = $PSStyle.Foreground.BrightRed
    $Script:CLR_GREEN  = $PSStyle.Foreground.BrightGreen
    $Script:CLR_YELLOW = $PSStyle.Foreground.BrightYellow
    $Script:CLR_RESET  = $PSStyle.Reset
} else {
    $esc = [char]27
    $Script:CLR_ORANGE = "$esc[38;5;${BANNER_COLOR_PRIMARY}m"
    $Script:CLR_BOLD   = "$esc[1m"
    $Script:CLR_DIM    = "$esc[2m"
    $Script:CLR_RED    = "$esc[31m"
    $Script:CLR_GREEN  = "$esc[32m"
    $Script:CLR_YELLOW = "$esc[33m"
    $Script:CLR_RESET  = "$esc[0m"
}

function Set-TerminalTitle {
    $Host.UI.RawUI.WindowTitle = '${TERMINAL_TITLE}'
}

function Show-Banner {
    Set-TerminalTitle
    Write-Host ''
    Write-Host ("{0}{1}  ╔═══════════════════════════════════════════════╗{2}" -f $Script:CLR_ORANGE, $Script:CLR_BOLD, $Script:CLR_RESET)
    Write-Host ("{0}{1}  ║  {2,-44} ║{3}" -f $Script:CLR_ORANGE, $Script:CLR_BOLD, '${CORP_NAME}', $Script:CLR_RESET)
    Write-Host ("{0}{1}  ║  {2,-44} ║{3}" -f $Script:CLR_ORANGE, $Script:CLR_BOLD, 'Powered by ${CORP_POWERED_BY}', $Script:CLR_RESET)
    Write-Host ("{0}{1}  ╚═══════════════════════════════════════════════╝{2}" -f $Script:CLR_ORANGE, $Script:CLR_BOLD, $Script:CLR_RESET)
    Write-Host ''
}

# =====================================================================
#  STRIP PROXY (for Bedrock / LiteLLM SSE artefacts)
# =====================================================================
function Test-PortListening {
    param([int]$Port)
    try {
        $conns = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop
        return [bool]$conns
    } catch {
        # tpl: fallback for hosts where Get-NetTCPConnection is unavailable
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            $listener.Stop()
            return $false
        } catch {
            return $true
        }
    }
}

function Start-StripProxy {
    param([string]$Upstream)

    # tpl: only start if this tenant needs it
    if ('${CC_NEEDS_STRIP_PROXY}' -ne 'yes') {
        return
    }

    $port = if ($env:STRIP_PROXY_PORT) { [int]$env:STRIP_PROXY_PORT } else { 9876 }
    $env:STRIP_PROXY_PORT = "$port"
    $proxyScript = Join-Path $Script:InstallRoot 'scripts/strip-proxy.js'
    $pidFile     = Join-Path $env:TEMP '${CORP_SLUG}-strip-proxy.pid'
    $logFile     = Join-Path $env:TEMP '${CORP_SLUG}-strip-proxy.log'

    if (Test-PortListening -Port $port) {
        return
    }

    if (-not (Test-Path $proxyScript)) {
        Write-Host ("{0}[!] strip-proxy.js missing: {1}{2}" -f $Script:CLR_YELLOW, $proxyScript, $Script:CLR_RESET)
        return
    }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Host ("{0}[!] node required for strip-proxy, not found{1}" -f $Script:CLR_YELLOW, $Script:CLR_RESET)
        return
    }

    $env:STRIP_PROXY_UPSTREAM = $Upstream
    $proc = Start-Process -FilePath 'node' `
        -ArgumentList @($proxyScript) `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError  "$logFile.err" `
        -WindowStyle Hidden -PassThru
    Set-Content -Path $pidFile -Value $proc.Id -Encoding ascii

    # tpl: wait up to 3s for the port to come up
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-PortListening -Port $port) { return }
        Start-Sleep -Milliseconds 100
    }
    Write-Host ("{0}[!] strip-proxy did not bind on port {1}{2}" -f $Script:CLR_YELLOW, $port, $Script:CLR_RESET)
}

# =====================================================================
#  ISOLATION — set every env var, never touch the system
# =====================================================================
function Initialize-Isolation {
    Get-ApiKey
    if (-not $env:CORP_API_KEY) {
        Set-ApiKey
    }

    # tpl: backend routing
    $upstreamUrl = '${CC_PRIMARY_URL}'

    # tpl: Claude Code talks to the strip-proxy on localhost which forwards to the gateway
    if ('${CC_NEEDS_STRIP_PROXY}' -eq 'yes') {
        Start-StripProxy -Upstream $upstreamUrl
        $port = if ($env:STRIP_PROXY_PORT) { $env:STRIP_PROXY_PORT } else { '9876' }
        $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$port"
    } else {
        $env:ANTHROPIC_BASE_URL = $upstreamUrl
    }

    $env:ANTHROPIC_AUTH_TOKEN = $env:CORP_API_KEY
    $modelOverride = [Environment]::GetEnvironmentVariable('${CORP_SLUG_UPPER}_MODEL')
    $env:ANTHROPIC_MODEL = if ($modelOverride) { $modelOverride } else { '${CC_PRIMARY_MODEL}' }
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = '${CC_HAIKU_MODEL}'

    # tpl: corporate proxy + CA bundle
    Set-CorporateProxy
    Set-CaBundle

    # tpl: telemetry kill switches
    $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    $env:CLAUDE_CODE_SKIP_UPDATE_CHECK            = '1'
    $env:DISABLE_AUTOUPDATER                      = '1'
    $env:DO_NOT_TRACK                             = '1'
    $env:DISABLE_TELEMETRY                        = '1'
    $env:DISABLE_ERROR_REPORTING                  = '1'
    $env:SENTRY_DSN                               = ''
    $env:DD_TRACE_ENABLED                         = '0'
    $env:OTEL_EXPORTER_OTLP_ENDPOINT              = ''
    $env:OTEL_EXPORTER_OTLP_HEADERS               = ''
    $env:STATSIG_DISABLED                         = '1'
    $env:GROWTHBOOK_API_HOST                      = ''
    $env:BUN_ENABLE_CRASH_REPORTING               = '0'
    $env:DISABLE_BUG_COMMAND                      = '1'
    $env:CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY      = '1'
    $env:CLAUDE_CODE_DISABLE_VOICE                = '1'

    # tpl: session marker
    [Environment]::SetEnvironmentVariable('${CORP_SLUG_UPPER}_ACTIVE', '1', 'Process')
    [Environment]::SetEnvironmentVariable('${CORP_SLUG_UPPER}_SESSION_START', [int][double]::Parse((Get-Date -UFormat %s)), 'Process')

    # tpl: user-agent for SOC log correlation
    [Environment]::SetEnvironmentVariable('${CORP_SLUG_UPPER}_VERSION', '1.0.0', 'Process')
}

# =====================================================================
#  COMMANDS
# =====================================================================
function Invoke-Help {
    @'
${CORP_NAME} — Powered by ${CORP_POWERED_BY}

Usage:
  ${CORP_SLUG}                Launch the assistant
  ${CORP_SLUG} --help         Show this help
  ${CORP_SLUG} --version      Show version + diagnostics
  ${CORP_SLUG} --status       Check VPN, gateway, isolation
  ${CORP_SLUG} --set-key      Reset / change the API token
  ${CORP_SLUG} --cost         Local cost log (session / today / history)
  ${CORP_SLUG} --uninstall    Run the uninstaller

Environment overrides:
  ${CORP_SLUG_UPPER}_MODEL    override the default model
'@ | Write-Host
}

function Invoke-Status {
    Show-Banner
    Write-Host ("{0}Diagnostics{1}" -f $Script:CLR_BOLD, $Script:CLR_RESET)

    $vpnOk = $false
    try { $vpnOk = Test-Vpn } catch { $vpnOk = $false }
    if ($vpnOk) {
        Write-Host ("  {0}[OK]{1} VPN reachable" -f $Script:CLR_GREEN, $Script:CLR_RESET)
    } else {
        Write-Host ("  {0}[KO]{1} VPN not detected" -f $Script:CLR_RED, $Script:CLR_RESET)
    }

    $hasKey = $false
    try { Get-ApiKey; $hasKey = [bool]$env:CORP_API_KEY } catch { $hasKey = $false }
    if ($hasKey) {
        Write-Host ("  {0}[OK]{1} API token loaded" -f $Script:CLR_GREEN, $Script:CLR_RESET)
    } else {
        Write-Host ("  {0}[!]{1}  API token missing — run `"${CORP_SLUG} --set-key`"" -f $Script:CLR_YELLOW, $Script:CLR_RESET)
    }

    $modelEffective = if ($env:${CORP_SLUG_UPPER}_MODEL) { $env:${CORP_SLUG_UPPER}_MODEL } else { '${CC_PRIMARY_MODEL}' }
    Write-Host '  Backend     : ${CC_BACKEND}'
    Write-Host '  Gateway     : ${CC_PRIMARY_URL}'
    Write-Host ("  Model       : {0}" -f $modelEffective)
    Write-Host '  Strip-proxy : ${CC_NEEDS_STRIP_PROXY}'
}

function Invoke-SetKey {
    Show-Banner
    Set-ApiKey
    Write-Host ("{0}[OK]{1} token saved." -f $Script:CLR_GREEN, $Script:CLR_RESET)
}

function Invoke-Cost {
    param([string]$Scope = 'session')
    $tracker = Join-Path $Script:InstallRoot 'scripts/cost-tracker.py'
    & python $tracker $Scope
}

function Invoke-Uninstall {
    $uninstaller = Join-Path $Script:InstallRoot 'uninstall.ps1'
    & pwsh -NoProfile -File $uninstaller
}

function Invoke-Version {
    Write-Host '${CORP_NAME} v1.0.0 — Powered by ${CORP_POWERED_BY}'
}

# =====================================================================
#  ENTRY POINT
# =====================================================================
function Invoke-Main {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Args)

    if ($null -eq $Args) { $Args = @() }
    $first = if ($Args.Count -gt 0) { $Args[0] } else { '' }

    switch -Regex ($first) {
        '^(--help|-h)$' { Invoke-Help; return }
        '^--version$'   { Invoke-Version; return }
        '^--status$'    { Invoke-Status; return }
        '^--set-key$'   { Invoke-SetKey; return }
        '^--cost$'      {
            $rest = if ($Args.Count -gt 1) { $Args[1] } else { 'session' }
            Invoke-Cost -Scope $rest
            return
        }
        '^--uninstall$' { Invoke-Uninstall; return }
    }

    if ('${VPN_REQUIRED}' -eq 'yes') {
        if (-not (Test-Vpn)) {
            Write-Host ("  {0}[KO]{1} VPN required but not detected." -f $Script:CLR_RED, $Script:CLR_RESET)
            exit 1
        }
    }

    Initialize-Isolation
    Show-Banner

    # tpl: dry-run mode for CI / testing
    $dryRun = [Environment]::GetEnvironmentVariable('${CORP_SLUG_UPPER}_DRY_RUN')
    if ($dryRun -eq '1') {
        Write-Host ("DRY RUN — environment ready, would exec: claude {0}" -f ($Args -join ' '))
        Get-ChildItem env: |
            Where-Object { $_.Name -match '^(ANTHROPIC_|CLAUDE_CODE_|${CORP_SLUG_UPPER}_)' } |
            Sort-Object Name |
            ForEach-Object { Write-Host ("{0}={1}" -f $_.Name, $_.Value) }
        return
    }

    # tpl: append the BRANDING + cyber rules to the system prompt
    $promptFile = Join-Path $Script:InstallRoot 'BRANDING.md'
    $cyberFile  = Join-Path $Script:InstallRoot 'cyber-rules.md'
    $claudeArgs = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $promptFile) {
        $claudeArgs.Add('--append-system-prompt-file'); $claudeArgs.Add($promptFile)
    }
    if (Test-Path $cyberFile) {
        $claudeArgs.Add('--append-system-prompt-file'); $claudeArgs.Add($cyberFile)
    }
    foreach ($a in $Args) { $claudeArgs.Add($a) }

    # tpl: locate the underlying CLI — npm global on Windows ships claude.cmd
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeCmd) {
        Write-Host ("  {0}[KO]{1} 'claude' command not found on PATH." -f $Script:CLR_RED, $Script:CLR_RESET)
        exit 127
    }

    # tpl: PowerShell has no exec(); run and propagate the exit code
    & $claudeCmd.Source @claudeArgs
    exit $LASTEXITCODE
}

Invoke-Main @args
