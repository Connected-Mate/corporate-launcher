#Requires -Version 7.0
<#
.SYNOPSIS
    ${CORP_NAME} - cyber-guard hook (PowerShell port).

.DESCRIPTION
    Reads the PreToolUse event JSON from stdin and decides whether to allow
    or deny the tool call.

    Wired into settings.json:
        {
          "hooks": {
            "PreToolUse": [{
              "matcher": "Bash|Edit|Write|MultiEdit",
              "hooks": [{
                "type": "command",
                "command": "pwsh -NoProfile -File C:\\path\\to\\pre-tool-hook.ps1"
              }]
            }]
          }
        }

    The hook is locked read-only so the AI cannot rewrite it:
        Set-ItemProperty -Path .\pre-tool-hook.ps1 -Name IsReadOnly -Value $true
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# tpl: -------------------------------------------------------------------
# tpl: Secret / PII / forbidden patterns. Block these unconditionally.
# tpl: -------------------------------------------------------------------
$SECRET_PATTERNS = @(
    @{ Pattern = 'sk-ant-[a-zA-Z0-9_-]{20,}';                              Label = 'Anthropic API key' }
    @{ Pattern = 'sk-[a-zA-Z0-9]{40,}';                                    Label = 'OpenAI-style API key' }
    @{ Pattern = 'AKIA[0-9A-Z]{16}';                                       Label = 'AWS access key id' }
    @{ Pattern = 'AIza[0-9A-Za-z_-]{35}';                                  Label = 'Google API key' }
    @{ Pattern = 'ghp_[A-Za-z0-9]{36,}';                                   Label = 'GitHub PAT' }
    @{ Pattern = '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----';   Label = 'Private key' }
    @{ Pattern = '\b[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}\b';    Label = 'Card number (16 digits)' }
)

# tpl: -------------------------------------------------------------------
# tpl: Destructive shell commands. Even bypassPermissions cannot override.
# tpl: -------------------------------------------------------------------
$DESTRUCTIVE_PATTERNS = @(
    @{ Pattern = '\brm\s+-rf\s+/(?:\s|$)';                       Label = 'rm -rf /' }
    @{ Pattern = '\brm\s+-rf\s+\$HOME(?:\s|/|$)';                Label = 'rm -rf $HOME' }
    @{ Pattern = '\bdd\s+if=.*\s+of=/dev/(sd|nvme|hd)';          Label = 'dd to raw device' }
    @{ Pattern = '\bmkfs\.[a-z0-9]+\s+/dev/(sd|nvme|hd)';        Label = 'filesystem format' }
    @{ Pattern = ':\(\)\s*\{[^}]*:\|:&[^}]*\}\s*;?\s*:';         Label = 'fork bomb' }
    @{ Pattern = '\bchmod\s+-R\s+777\s+/(?:\s|$)';               Label = 'chmod -R 777 /' }
    @{ Pattern = '\bgit\s+push\s+--force.*\b(main|master|prod)'; Label = 'force push to main' }
    @{ Pattern = '\bcurl\s+[^|]+\|\s*(?:sudo\s+)?(?:bash|sh)\b'; Label = 'curl | bash' }
    # tpl: PowerShell-specific destructive analogues
    @{ Pattern = '\bRemove-Item\s+.*-Recurse.*-Force.*[A-Z]:\\(?:\s|$)';    Label = 'Remove-Item -Recurse -Force on drive root' }
    @{ Pattern = '\bFormat-Volume\b';                                       Label = 'Format-Volume' }
    @{ Pattern = '\bInvoke-WebRequest\s+[^|]+\|\s*Invoke-Expression\b';     Label = 'iwr | iex' }
    @{ Pattern = '\biex\s*\(\s*(?:iwr|Invoke-WebRequest)\b';                Label = 'iex(iwr ...)' }
)

# tpl: -------------------------------------------------------------------

function Test-Patterns {
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [array]  $Patterns
    )
    foreach ($entry in $Patterns) {
        if ([regex]::IsMatch($Text, $entry.Pattern)) {
            return $entry
        }
    }
    return $null
}

function Write-Decision {
    param(
        [Parameter(Mandatory)] [string] $Decision,
        [string] $Reason
    )
    $obj = [ordered]@{ permissionDecision = $Decision }
    if ($PSBoundParameters.ContainsKey('Reason') -and $Reason) {
        $obj.reason = $Reason
    }
    # tpl: -Compress keeps the JSON on a single line, mirroring json.dumps default
    [pscustomobject]$obj | ConvertTo-Json -Compress -Depth 10
}

# tpl: --- main ----------------------------------------------------------
try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Decision -Decision 'allow'
        exit 0
    }
    try {
        $event = $raw | ConvertFrom-Json -Depth 50 -ErrorAction Stop
    } catch {
        # tpl: Malformed input - let the call through; logging it is a TODO
        Write-Decision -Decision 'allow'
        exit 0
    }

    $toolInput = $null
    if ($event.PSObject.Properties.Name -contains 'tool_input') {
        $toolInput = $event.tool_input
    }
    if ($null -eq $toolInput) { $toolInput = @{} }

    $payload = $toolInput | ConvertTo-Json -Depth 50 -Compress

    # tpl: Secrets - deny + explain
    $hit = Test-Patterns -Text $payload -Patterns $SECRET_PATTERNS
    if ($hit) {
        $reason = "${CORP_NAME} cyber-guard: detected $($hit.Label). Use the corporate secret manager instead."
        Write-Decision -Decision 'deny' -Reason $reason
        exit 0
    }

    # tpl: Destructive - deny + explain
    $hit = Test-Patterns -Text $payload -Patterns $DESTRUCTIVE_PATTERNS
    if ($hit) {
        $reason = "${CORP_NAME} cyber-guard: refused destructive command: $($hit.Label)."
        Write-Decision -Decision 'deny' -Reason $reason
        exit 0
    }

    Write-Decision -Decision 'allow'
    exit 0
} catch {
    # tpl: Last-resort safety net - never crash the hook (would block all tools)
    Write-Decision -Decision 'allow'
    exit 0
}
