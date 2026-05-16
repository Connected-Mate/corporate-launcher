#Requires -Version 5.1
# =====================================================================
#  ${CORP_NAME} — installer (PowerShell)
#  Powered by ${CORP_POWERED_BY}
# =====================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:InstallDir = $PSScriptRoot

# tpl: --- ANSI colors (PSStyle on PS 7.2+, fallback for 5.1) ---
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

function Write-Info { param([string]$Msg) Write-Host ("  {0}[OK]{1} {2}" -f $Script:CLR_GREEN,  $Script:CLR_RESET, $Msg) }
function Write-Warn { param([string]$Msg) Write-Host ("  {0}[!]{1}  {2}" -f $Script:CLR_YELLOW, $Script:CLR_RESET, $Msg) }
function Write-Fail { param([string]$Msg) Write-Host ("  {0}[KO]{1} {2}" -f $Script:CLR_RED,    $Script:CLR_RESET, $Msg) }
function Write-Step { param([string]$Msg) Write-Host ''; Write-Host ("{0}{1}{2}" -f $Script:CLR_BOLD, $Msg, $Script:CLR_RESET) }
function Read-Confirm {
    param([string]$Prompt)
    $ans = Read-Host ("  {0}{1} [y/N]{2}" -f $Script:CLR_YELLOW, $Prompt, $Script:CLR_RESET)
    return ($ans -match '^[yY]')
}

function Show-Banner {
    Write-Host ''
    Write-Host ("{0}{1}  ╔═══════════════════════════════════════════════╗{2}" -f $Script:CLR_ORANGE, $Script:CLR_BOLD, $Script:CLR_RESET)
    Write-Host ("{0}{1}  ║  {2,-44} ║{3}" -f $Script:CLR_ORANGE, $Script:CLR_BOLD, '${CORP_NAME} — installer', $Script:CLR_RESET)
    Write-Host ("{0}{1}  ║  {2,-44} ║{3}" -f $Script:CLR_ORANGE, $Script:CLR_BOLD, 'Powered by ${CORP_POWERED_BY}', $Script:CLR_RESET)
    Write-Host ("{0}{1}  ╚═══════════════════════════════════════════════╝{2}" -f $Script:CLR_ORANGE, $Script:CLR_BOLD, $Script:CLR_RESET)
    Write-Host ''
}

# tpl: ---------- detection ----------
function Get-PsVersionLabel {
    return ("PowerShell {0}" -f $PSVersionTable.PSVersion)
}

Show-Banner

Write-Step '[1/7] Detect environment'
Write-Info ("OS         : Windows ({0})" -f [System.Environment]::OSVersion.Version)
Write-Info ("Shell      : {0}" -f (Get-PsVersionLabel))

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warn 'PowerShell 5.1 detected. The launcher requires PowerShell 7+ at runtime.'
    Write-Warn 'Install from https://aka.ms/powershell, then re-run this installer in pwsh.'
    if (-not (Read-Confirm 'Continue installing anyway?')) {
        exit 1
    }
}

# tpl: pick the right profile path — CurrentUserAllHosts spans pwsh + powershell
$profilePath = $PROFILE.CurrentUserAllHosts
$profileDir  = Split-Path -Parent $profilePath
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath -Force | Out-Null }
Write-Info ("Profile    : {0}" -f $profilePath)

Write-Step '[2/7] Check dependencies'
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) {
    $nodeVersion = (& node --version) 2>$null
    Write-Info ("node: {0}" -f $nodeVersion)
} else {
    Write-Fail 'Node.js is required. Install from https://nodejs.org or via winget install OpenJS.NodeJS.LTS.'
    exit 1
}

# tpl: VS Code detection is informational only
$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if ($codeCmd) {
    Write-Info 'VS Code detected on PATH'
} else {
    Write-Warn 'VS Code not detected on PATH (optional)'
}

$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    $claudeVersion = (& $claudeCmd.Source --version) 2>$null
    if (-not $claudeVersion) { $claudeVersion = 'unknown' }
    Write-Info ("Underlying CLI present: {0}" -f $claudeVersion)
} else {
    Write-Warn 'Underlying CLI not found.'
    if (Read-Confirm 'Install via npm (npm i -g @anthropic-ai/claude-code)?') {
        & npm install -g '@anthropic-ai/claude-code'
        if ($LASTEXITCODE -ne 0) {
            Write-Fail 'npm install failed.'
            exit 1
        }
    } else {
        Write-Fail 'Cannot proceed without the underlying CLI.'
        exit 1
    }
}

Write-Step '[3/7] File permissions / ACLs'
# tpl: Windows does not have chmod; lock the cyber-guard hook via ACL deny-write for the current user
$cyberGuard = Join-Path $Script:InstallDir 'scripts/pre-tool-hook.py'
if (Test-Path $cyberGuard) {
    try {
        $acl  = Get-Acl $cyberGuard
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $user, 'WriteData,AppendData,Delete,ChangePermissions', 'Deny')
        $acl.AddAccessRule($rule)
        Set-Acl -Path $cyberGuard -AclObject $acl
        Write-Info 'Cyber-guard hook locked (deny write for current user)'
    } catch {
        Write-Warn ("Could not lock cyber-guard ACL: {0}" -f $_.Exception.Message)
    }
}

Write-Step '[4/7] Install settings.json'
$claudeConfigDir = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $claudeConfigDir)) {
    New-Item -ItemType Directory -Path $claudeConfigDir -Force | Out-Null
}
$srcSettings = Join-Path $Script:InstallDir 'settings.json'
$dstSettings = Join-Path $claudeConfigDir 'settings.json'
Copy-Item -Path $srcSettings -Destination $dstSettings -Force
# tpl: restrict settings.json ACL to the current user only (equivalent of chmod 600)
try {
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "$env:USERDOMAIN\$env:USERNAME", 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $dstSettings -AclObject $acl
} catch {
    Write-Warn ("Could not harden settings.json ACL: {0}" -f $_.Exception.Message)
}
Write-Info ("Wrote {0}" -f $dstSettings)

Write-Step '[5/7] Wire up the PowerShell profile'
$markerStart = '# >>> ${CORP_SLUG} >>>'
$markerEnd   = '# <<< ${CORP_SLUG} <<<'

# tpl: idempotent — strip any previous block first
$existing = Get-Content -Path $profilePath -Raw -ErrorAction SilentlyContinue
if ($existing -and ($existing -match [regex]::Escape($markerStart))) {
    Copy-Item -Path $profilePath -Destination "$profilePath.${CORP_SLUG}.bak" -Force
    $pattern = [regex]::Escape($markerStart) + '[\s\S]*?' + [regex]::Escape($markerEnd) + '\r?\n?'
    $cleaned = [regex]::Replace($existing, $pattern, '')
    Set-Content -Path $profilePath -Value $cleaned -NoNewline
    Write-Info ("Removed previous block (backup at {0}.${CORP_SLUG}.bak)" -f $profilePath)
}

# tpl: build the block — use single-quoted here-string so PowerShell does not interpolate $env: at install time
$launcherPath = (Join-Path $Script:InstallDir '${CORP_SLUG}.ps1').Replace("'", "''")
$installDir   = $Script:InstallDir.Replace("'", "''")
$today        = (Get-Date -Format 'yyyy-MM-dd')

$block = @"
$markerStart
# ${CORP_NAME} — Powered by ${CORP_POWERED_BY}
# Installed on $today
`$env:${CORP_SLUG_UPPER}_HOME = '$installDir'
function ${CORP_SLUG} { & '$launcherPath' @args }
$markerEnd
"@

Add-Content -Path $profilePath -Value "`r`n$block"
Write-Info 'Profile block added — open a new pwsh session or run: . $PROFILE.CurrentUserAllHosts'

Write-Step '[6/7] Configure API token'
. (Join-Path $Script:InstallDir 'scripts/secrets-store.ps1')

$existingToken = $null
try { Get-ApiKey; $existingToken = $env:CORP_API_KEY } catch { $existingToken = $null }

if ($existingToken) {
    if (Read-Confirm 'An API token is already stored. Replace it?') {
        Set-ApiKey
    } else {
        Write-Info 'Kept existing token'
    }
} else {
    Set-ApiKey
}

Write-Step '[7/7] Done'
Write-Host ''
Write-Host ("  {0}{1}Installation complete.{2}" -f $Script:CLR_ORANGE, $Script:CLR_BOLD, $Script:CLR_RESET)
Write-Host ''
Write-Host ("  Launch with    : {0}${CORP_SLUG}{1}" -f $Script:CLR_GREEN, $Script:CLR_RESET)
Write-Host ("  Diagnostics    : {0}${CORP_SLUG} --status{1}" -f $Script:CLR_DIM, $Script:CLR_RESET)
Write-Host ("  Uninstall      : {0}${CORP_SLUG} --uninstall{1}" -f $Script:CLR_DIM, $Script:CLR_RESET)
Write-Host ''
if ('${VPN_REQUIRED}' -eq 'yes') {
    Write-Host ("  {0}[!]{1}  Corporate VPN required before first launch." -f $Script:CLR_YELLOW, $Script:CLR_RESET)
    Write-Host ''
}
