#Requires -Version 7.0
# =============================================================================
# ${CORP_NAME} - Codex CLI launcher (Windows / PowerShell 7+)
# Powered by ${CORP_POWERED_BY}
#
# Windows-native equivalent of launcher.sh. This wrapper is the only supported
# entry point to Codex CLI on a corporate Windows machine. It sources the
# VPN/proxy/CA modules, injects the gateway env vars, then invokes the upstream
# `codex` binary. Direct invocation of `codex` is not supported by the cyber
# policy.
#
# Flags:
#   --version       print the launcher version and exit
#   --status        print resolved env (no secret) and exit
#   --dry-run       print what would be exec'd and exit 0 (CORP_DRY_RUN=1)
#   --set-key       prompt for a new API token and store it
#   --uninstall     run the uninstaller from the same install dir
#   --help          this help
#   <anything else> forwarded verbatim to codex
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# tpl: ---------------------------------------------------------------------
# tpl: Resolve install dir (where this script + scripts/ + config live)
# tpl: ---------------------------------------------------------------------
$LauncherVersion = '${CORP_LAUNCHER_VERSION}'
$InstallDir      = $PSScriptRoot
$ScriptsDir      = Join-Path $InstallDir 'scripts'

# tpl: ---------------------------------------------------------------------
# tpl: Colors - only when output is a real terminal (not redirected)
# tpl: ---------------------------------------------------------------------
$script:UseColor = ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected)

function Write-Info { param([string]$Msg)
    if ($script:UseColor) { Write-Host "  [OK] $Msg" -ForegroundColor Green }
    else { Write-Host "  [OK] $Msg" }
}
function Write-Warn { param([string]$Msg)
    if ($script:UseColor) { Write-Host "  [!!] $Msg" -ForegroundColor Yellow }
    else { Write-Host "  [!!] $Msg" }
}
function Write-Fail { param([string]$Msg)
    if ($script:UseColor) { Write-Host "  [KO] $Msg" -ForegroundColor Red }
    else { Write-Host "  [KO] $Msg" }
}

# tpl: ---------------------------------------------------------------------
# tpl: Shared module exports needed by the dot-sourced scripts. PowerShell
# tpl: dot-sourcing puts the functions in the caller scope; we set script-
# tpl: scope variables that the modules read.
# tpl: ---------------------------------------------------------------------
$script:CORP_NAME        = '${CORP_NAME}'
$script:CORP_SLUG        = '${CORP_SLUG}'
$script:CORP_SLUG_UPPER  = '${CORP_SLUG_UPPER}'
$script:CORP_POWERED_BY  = '${CORP_POWERED_BY}'
$script:LLM_TOKEN_URL    = '${LLM_TOKEN_URL}'

$script:VPN_REQUIRED     = '${VPN_REQUIRED}'
$script:VPN_PROBE_URL    = '${VPN_PROBE_URL}'

$script:PROXY_HOST       = '${PROXY_HOST}'
$script:PROXY_PORT       = '${PROXY_PORT}'
$script:NO_PROXY_LIST    = '${NO_PROXY_LIST}'

$script:CA_BUNDLE_PATH        = '${CA_BUNDLE_PATH}'
$script:ACCEPT_TLS_INSPECTION = '${ACCEPT_TLS_INSPECTION}'

# tpl: ---------------------------------------------------------------------
# tpl: Dot-source shared modules (PowerShell 7+)
# tpl: ---------------------------------------------------------------------
foreach ($mod in 'vpn-check.ps1','proxy-detect.ps1','secrets-store.ps1') {
    $modPath = Join-Path $ScriptsDir $mod
    if (-not (Test-Path -LiteralPath $modPath -PathType Leaf)) {
        Write-Fail "Missing shared module: $modPath"
        exit 1
    }
    . $modPath
}

# tpl: ---------------------------------------------------------------------
# tpl: Banner
# tpl: ---------------------------------------------------------------------
function Show-Banner {
    if (-not $script:UseColor) { return }
    Write-Host ("{0} v{1} - powered by {2}" -f $script:CORP_NAME, $LauncherVersion, $script:CORP_POWERED_BY) `
        -ForegroundColor Cyan
}

# tpl: ---------------------------------------------------------------------
# tpl: Telemetry kill switches - applied to every child process
# tpl: ---------------------------------------------------------------------
function Disable-Telemetry {
    $env:DO_NOT_TRACK                = '1'
    $env:DISABLE_TELEMETRY           = '1'
    $env:DISABLE_ERROR_REPORTING     = '1'
    $env:OTEL_EXPORTER_OTLP_ENDPOINT = ''
    $env:OTEL_SDK_DISABLED           = 'true'
    $env:SENTRY_DSN                  = ''
    $env:DD_TRACE_ENABLED            = '0'
    $env:STATSIG_DISABLED            = '1'
    $env:OPENCODE_DISABLE_TELEMETRY  = '1'
    # tpl: Codex-specific opt-outs (best effort; pinned via config.toml too)
    $env:CODEX_DISABLE_TELEMETRY     = '1'
    $env:CODEX_DISABLE_ANALYTICS     = '1'
    $env:CODEX_DISABLE_FEEDBACK      = '1'
    $env:CODEX_DISABLE_UPDATE_CHECK  = '1'
}

# tpl: ---------------------------------------------------------------------
# tpl: Gateway env - primary auth + base URL
# tpl: ---------------------------------------------------------------------
function Set-GatewayEnv {
    if ([string]::IsNullOrEmpty($script:CORP_API_KEY)) {
        Write-Fail 'CORP_API_KEY is unset - cannot configure gateway.'
        return $false
    }

    # tpl: Provider-specific env var (e.g. AZURE_OPENAI_API_KEY) + the generic
    # tpl: OPENAI_API_KEY so MCP servers that expect the latter also work.
    [Environment]::SetEnvironmentVariable('${CX_AUTH_ENV_KEY}', $script:CORP_API_KEY, 'Process')
    $env:OPENAI_API_KEY = $script:CORP_API_KEY

    # tpl: Codex also reads OPENAI_BASE_URL when wire_api = "chat".
    $env:OPENAI_BASE_URL = '${CX_PRIMARY_URL}'

    if (-not $env:CODEX_HOME) {
        $env:CODEX_HOME = Join-Path $HOME '.codex'
    }

    # tpl: Session marker - picked up by hooks / logs
    [Environment]::SetEnvironmentVariable("${CORP_SLUG_UPPER}_SESSION",      '1', 'Process')
    [Environment]::SetEnvironmentVariable("${CORP_SLUG_UPPER}_LAUNCHER_PID", "$PID", 'Process')
    return $true
}

# tpl: ---------------------------------------------------------------------
# tpl: HTTPS_PROXY workaround for Codex issue #4242
# tpl: Codex (Rust reqwest) does not yet honor HTTPS_PROXY consistently. If a
# tpl: corporate proxy is required and the gateway is not directly reachable,
# tpl: warn the user and rely on transparent-proxy / split-tunnel routing.
# tpl: ---------------------------------------------------------------------
function Write-ProxyQuirkWarning {
    if ($env:HTTPS_PROXY -and '${CX_PROXY_WARNING}' -eq 'yes') {
        Write-Warn 'Codex CLI does not fully honor HTTPS_PROXY (upstream issue #4242).'
        Write-Warn 'If requests fail, route the gateway hostname outside the proxy'
        Write-Warn '(NO_PROXY) or use a transparent proxy at the network layer.'
    }
}

# tpl: ---------------------------------------------------------------------
# tpl: Status / dry-run output (no secrets)
# tpl: ---------------------------------------------------------------------
function Show-Status {
    Show-Banner
    Write-Host ("  install_dir   : {0}" -f $InstallDir)
    Write-Host ("  codex_home    : {0}" -f ($env:CODEX_HOME ?? (Join-Path $HOME '.codex')))
    Write-Host ("  provider_id   : {0}" -f '${CX_PROVIDER_ID}')
    Write-Host ("  primary_url   : {0}" -f '${CX_PRIMARY_URL}')
    Write-Host ("  primary_model : {0}" -f '${CX_PRIMARY_MODEL}')
    Write-Host ("  wire_api      : {0}" -f '${CX_WIRE_API}')
    Write-Host ("  auth_env_key  : {0}" -f '${CX_AUTH_ENV_KEY}')
    $caDisplay = if ([string]::IsNullOrEmpty($script:CA_BUNDLE_PATH)) { '<system>' } else { $script:CA_BUNDLE_PATH }
    Write-Host ("  ca_bundle     : {0}" -f $caDisplay)
    Write-Host ("  http_proxy    : {0}" -f ($env:HTTP_PROXY ?? '<none>'))
    Write-Host ("  no_proxy      : {0}" -f ($env:NO_PROXY   ?? '<none>'))
    Write-Host ("  vpn_required  : {0}" -f $script:VPN_REQUIRED)

    if (-not [string]::IsNullOrEmpty($script:CORP_API_KEY)) {
        $k = $script:CORP_API_KEY
        $head = $k.Substring(0, [Math]::Min(4, $k.Length))
        $tail = if ($k.Length -ge 2) { $k.Substring($k.Length - 2, 2) } else { '' }
        Write-Host ("  api_key       : {0}***{1} (length {2})" -f $head, $tail, $k.Length)
    } else {
        Write-Host '  api_key       : <unset>'
    }
}

function Show-Help {
    Show-Banner
    @"

Usage: ${CORP_SLUG} [launcher-flag | codex-arg ...]

Launcher flags:
  --version       print launcher version and exit
  --status        print resolved environment (no secret) and exit
  --dry-run       same as --status, then exit 0 without running codex
  --set-key       prompt for a new API token and store it
  --uninstall     run the uninstaller next to this launcher
  --help          show this help

Any other argument is forwarded to the underlying 'codex' binary.

Examples:
  ${CORP_SLUG}                       # interactive session
  ${CORP_SLUG} exec "fix this bug"   # one-shot exec
  ${CORP_SLUG} --status              # diagnose configuration

Docs   : ${CORP_DOCS_URL}
Support: ${CORP_SUPPORT_CONTACT}
"@ | Write-Host
}

# tpl: ---------------------------------------------------------------------
# tpl: Main
# tpl: ---------------------------------------------------------------------
function Invoke-Launcher {
    param([string[]]$Argv)

    $first = if ($Argv.Count -gt 0) { $Argv[0] } else { '' }

    # tpl: --- parse launcher-only flags first ---
    switch ($first) {
        '--version' {
            Write-Host ("{0} {1}" -f $script:CORP_NAME, $LauncherVersion)
            exit 0
        }
        { $_ -in '--help','-h' } {
            Show-Help
            exit 0
        }
        '--set-key' {
            if (Set-ApiKeyInteractive) { exit 0 } else { exit 1 }
        }
        '--uninstall' {
            $uninstall = Join-Path $InstallDir 'uninstall.ps1'
            if (Test-Path -LiteralPath $uninstall -PathType Leaf) {
                & pwsh -NoProfile -File $uninstall
                exit $LASTEXITCODE
            } else {
                Write-Fail "Uninstaller not found: $uninstall"
                exit 1
            }
        }
    }

    # tpl: --- gates ---
    if (-not (Test-CorpVpn)) { exit 1 }

    # tpl: --- secrets ---
    if (-not (Get-ApiKey)) { exit 1 }
    if ([string]::IsNullOrEmpty($script:CORP_API_KEY)) {
        if (-not (Set-ApiKeyInteractive)) { exit 1 }
    }

    # tpl: --- network ---
    Set-CorpProxy
    Set-CaBundle

    # tpl: --- env ---
    Disable-Telemetry
    if (-not (Set-GatewayEnv)) { exit 1 }
    Write-ProxyQuirkWarning

    # tpl: --- dry run / status ---
    switch ($first) {
        '--status' {
            Show-Status
            exit 0
        }
        '--dry-run' {
            Show-Status
            Write-Host ''
            Write-Host '  DRY RUN - not invoking codex' -ForegroundColor DarkGray
            exit 0
        }
    }
    if ($env:CORP_DRY_RUN -eq '1') {
        Show-Status
        Write-Host ''
        Write-Host '  CORP_DRY_RUN=1 - not invoking codex' -ForegroundColor DarkGray
        exit 0
    }

    # tpl: --- locate codex binary ---
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) {
        Write-Fail 'codex binary not found in PATH.'
        Write-Fail ("Re-run the installer: {0}" -f (Join-Path $InstallDir 'install.ps1'))
        exit 127
    }

    Show-Banner
    # tpl: PowerShell has no exec(); we invoke and forward the exit code.
    # tpl: Splat the args to preserve quoting (no eval, no Invoke-Expression).
    & $codex.Source @Argv
    exit $LASTEXITCODE
}

Invoke-Launcher -Argv $args
