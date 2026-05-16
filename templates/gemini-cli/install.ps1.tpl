# tpl: ${CORP_NAME} - Corporate installer for the Gemini CLI wrapper (PowerShell 7+)
# tpl: Powered by ${CORP_POWERED_BY}
# tpl: Compatible: Windows PowerShell 7+, macOS pwsh, Linux pwsh

#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$InstallDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$CorpName         = '${CORP_NAME}'
$CorpSlug         = '${CORP_SLUG}'
$CorpSlugUpper    = '${CORP_SLUG_UPPER}'
$CorpPoweredBy    = '${CORP_POWERED_BY}'
$GmBackend        = '${GM_BACKEND}'
$GmAuthMode       = '${GM_AUTH_MODE}'
$GmPrimaryModel   = '${GM_PRIMARY_MODEL}'
$GmVertexProject  = '${GM_VERTEX_PROJECT}'
$GmVertexLocation = '${GM_VERTEX_LOCATION}'

# --- Helpers -----------------------------------------------------------------
function Info { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Warn { param([string]$Msg) Write-Host "  [!!] $Msg" -ForegroundColor Yellow }
function Fail { param([string]$Msg) Write-Host "  [KO] $Msg" -ForegroundColor Red }
function Step { param([string]$Msg) Write-Host "`n$Msg" -ForegroundColor White }
function Ask-Yes {
    param([string]$Prompt)
    $a = Read-Host "  $Prompt [y/N]"
    return ($a -match '^[yY]')
}

function Detect-Os {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS)   { return 'macos' }
    if ($IsLinux)   {
        if (Test-Path '/proc/version') {
            $v = Get-Content '/proc/version' -Raw -ErrorAction SilentlyContinue
            if ($v -match 'microsoft') { return 'wsl' }
        }
        return 'linux'
    }
    return 'unknown'
}

# --- Banner ------------------------------------------------------------------
Write-Host "`n$CorpName - Installer" -ForegroundColor DarkYellow
Write-Host "Powered by $CorpPoweredBy" -ForegroundColor DarkGray

# --- Step 1: environment -----------------------------------------------------
Step '[1/7] Detecting environment...'

# tpl: PowerShell 7+ required (cross-platform, modern syntax, $IsWindows etc.)
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Fail "PowerShell 7+ required. Detected: $($PSVersionTable.PSVersion)"
    Write-Host '  Install pwsh: https://aka.ms/powershell'
    exit 1
}
Info "PowerShell: $($PSVersionTable.PSVersion)"

$OsType = Detect-Os
if ($OsType -eq 'unknown') {
    Fail 'Unsupported OS. Supported: Windows, macOS, Linux, WSL.'
    exit 1
}
Info "OS: $OsType"
Info "Install dir: $InstallDir"

# --- Step 2: Node.js ---------------------------------------------------------
Step '[2/7] Checking Node.js...'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Fail 'Node.js is required (>=20).'
    switch ($OsType) {
        'macos'         { Write-Host '  brew install node' }
        { $_ -in 'linux','wsl' } { Write-Host '  sudo apt install nodejs npm  # or use nvm' }
        'windows'       { Write-Host '  winget install OpenJS.NodeJS  # or https://nodejs.org' }
    }
    exit 1
}
$nodeVersion = (& node --version) -join ''
Info "node: $nodeVersion"

# --- Step 3: underlying CLI engine -------------------------------------------
Step '[3/7] Checking the underlying CLI engine...'
if (-not (Get-Command gemini -ErrorAction SilentlyContinue)) {
    Warn 'Engine not installed.'
    if (Ask-Yes 'Install it now via npm?') {
        & npm install -g '@google/gemini-cli'
        if ($LASTEXITCODE -ne 0) {
            Fail 'npm install failed. On Windows, try running pwsh as Administrator.'
            exit 1
        }
        $geminiVersion = (& gemini --version 2>$null) -join ''
        if ([string]::IsNullOrWhiteSpace($geminiVersion)) { $geminiVersion = 'unknown' }
        Info "Engine installed: $geminiVersion"
    } else {
        Write-Host '  Manual: npm install -g @google/gemini-cli'
        exit 1
    }
} else {
    $geminiVersion = (& gemini --version 2>$null) -join ''
    if ([string]::IsNullOrWhiteSpace($geminiVersion)) { $geminiVersion = 'unknown' }
    Info "Engine version: $geminiVersion"
}

# --- Step 4: auth ------------------------------------------------------------
Step '[4/7] Configuring authentication...'

switch ($GmBackend) {
    'vertex' {
        if ($GmAuthMode -eq 'ADC') {
            if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
                Fail 'gcloud CLI is required for ADC authentication.'
                Write-Host '  Install: https://cloud.google.com/sdk/docs/install'
                Write-Host '  After installing, re-run this installer.'
                exit 1
            }
            $gcloudVersion = ((& gcloud --version 2>$null) -split "`n")[0]
            Info "gcloud: $gcloudVersion"

            $null = & gcloud auth application-default print-access-token 2>$null
            if ($LASTEXITCODE -eq 0) {
                Info 'Application Default Credentials already configured.'
            } else {
                Warn 'No ADC session yet - a browser window will open.'
                if (Ask-Yes "Run 'gcloud auth application-default login' now?") {
                    & gcloud auth application-default login
                    if ($LASTEXITCODE -eq 0) { Info 'ADC login complete.' }
                    else { Warn 'Login failed - run it manually before first launch.' }
                } else {
                    Warn 'You will need to run it manually before first launch.'
                }
            }

            # tpl: pin quota project so billing is unambiguous
            if (-not [string]::IsNullOrEmpty($GmVertexProject)) {
                & gcloud auth application-default set-quota-project $GmVertexProject 2>$null
                if ($LASTEXITCODE -eq 0) { Info "Quota project pinned to $GmVertexProject" }
                else { Warn 'Could not pin quota project (non-fatal).' }
            }
        } else {
            Warn 'Service-account key mode selected.'
            Write-Host '  Set GOOGLE_APPLICATION_CREDENTIALS to the path of your .json key.'
            Write-Host '  Add it to your PowerShell profile or as a system env variable.'
        }
    }

    'ai-studio' {
        . (Join-Path $InstallDir 'lib/secrets-store.ps1')
        $env:CORP_SLUG       = $CorpSlug
        $env:CORP_SLUG_UPPER = $CorpSlugUpper
        $env:CORP_NAME       = $CorpName
        $env:LLM_TOKEN_URL   = '${LLM_TOKEN_URL}'
        if ((Load-ApiKey) -and -not [string]::IsNullOrEmpty($script:CorpApiKey)) {
            Info 'API key already in secret store.'
            if (Ask-Yes 'Replace it?') { Prompt-ForApiKey | Out-Null }
        } else {
            Prompt-ForApiKey | Out-Null
        }
    }

    default {
        Fail "Unknown backend: $GmBackend"
        exit 1
    }
}

# --- Step 5: generate ~/.gemini/settings.json --------------------------------
Step '[5/7] Writing ~/.gemini/settings.json...'

$GeminiHome = Join-Path $HOME '.gemini'
if (-not (Test-Path $GeminiHome)) {
    New-Item -ItemType Directory -Path $GeminiHome -Force | Out-Null
}

$SettingsPath = Join-Path $GeminiHome 'settings.json'
$SettingsBak  = Join-Path $GeminiHome "settings.json.$CorpSlug.bak"
if ((Test-Path $SettingsPath) -and -not (Test-Path $SettingsBak)) {
    Copy-Item -Path $SettingsPath -Destination $SettingsBak -Force
    Info 'Existing settings.json backed up.'
}
Copy-Item -Path (Join-Path $InstallDir 'share/settings.json') -Destination $SettingsPath -Force
Info 'settings.json deployed.'

# --- Step 6: deploy GEMINI.md identity file ----------------------------------
Step '[6/7] Deploying identity lock...'

$GeminiMdPath = Join-Path $GeminiHome 'GEMINI.md'
$GeminiMdBak  = Join-Path $GeminiHome "GEMINI.md.$CorpSlug.bak"

if ((Test-Path $GeminiMdPath) -and -not (Test-Path $GeminiMdBak)) {
    $existing = Get-Content $GeminiMdPath -Raw -ErrorAction SilentlyContinue
    if ($existing -and ($existing -notmatch "$CorpSlug-identity-lock")) {
        Copy-Item -Path $GeminiMdPath -Destination $GeminiMdBak -Force
        Info 'Existing GEMINI.md backed up.'
    }
}
Copy-Item -Path (Join-Path $InstallDir 'share/GEMINI.md') -Destination $GeminiMdPath -Force
Info 'GEMINI.md identity file deployed.'

# --- Step 7: PowerShell profile block (idempotent) ---------------------------
Step '[7/7] Wiring up the PowerShell command...'

# tpl: $PROFILE.CurrentUserAllHosts works for both pwsh and Windows PowerShell.
$ProfilePath = $PROFILE.CurrentUserAllHosts
$ProfileDir  = Split-Path -Parent $ProfilePath
if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
}
if (-not (Test-Path $ProfilePath)) {
    New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
}
Info "Profile: $ProfilePath"

$MarkerStart = "# >>> $CorpSlug >>>"
$MarkerEnd   = "# <<< $CorpSlug <<<"
$LauncherPs1 = Join-Path $InstallDir "bin/$CorpSlug.ps1"

$current = Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue
if ($null -eq $current) { $current = '' }

if ($current -match [regex]::Escape($MarkerStart)) {
    Warn 'Previous install detected - refreshing block.'
    Copy-Item -Path $ProfilePath -Destination "$ProfilePath.$CorpSlug-backup" -Force
    # tpl: strip old block between markers (multiline)
    $pattern = "(?ms)" + [regex]::Escape($MarkerStart) + ".*?" + [regex]::Escape($MarkerEnd) + "\r?\n?"
    $current = [regex]::Replace($current, $pattern, '')
}

$today = Get-Date -Format 'yyyy-MM-dd'
$block = @"

$MarkerStart
# $CorpName - Corporate AI CLI
# Powered by $CorpPoweredBy
# Installed: $today
function $CorpSlug {
    & '$LauncherPs1' @args
}
`$env:${CorpSlugUpper}_HOME = '$InstallDir'
$MarkerEnd
"@

Set-Content -Path $ProfilePath -Value ($current.TrimEnd() + "`n" + $block) -NoNewline
Info 'Profile block added.'

# --- Done --------------------------------------------------------------------
Write-Host "`n  $CorpName installed successfully." -ForegroundColor DarkYellow
Write-Host "  Reload your profile:  . `"$ProfilePath`"" -ForegroundColor Green
Write-Host "  Launch:               $CorpSlug`n"             -ForegroundColor Green
