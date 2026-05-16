#Requires -Version 7.0
<#
.SYNOPSIS
    ${CORP_NAME} - cost tracker (PowerShell port).

.DESCRIPTION
    Reads SSE events from the usage log and aggregates per-session, per-day,
    per-model costs in ${COST_CURRENCY}.

    The strip-proxy writes one JSON line per response containing:
        {"ts": "...", "model": "...", "usage": {...}, "cost": 0.0042}

    Pricing table is loaded from pricing.json next to this script - edit there
    to match your gateway's contracted rates.

.PARAMETER Command
    Subcommand: session | today | history

.PARAMETER SessionId
    Override session filter (also honours $env:${CORP_SLUG_UPPER}_SESSION_ID).

.PARAMETER Since
    ISO-8601 date (YYYY-MM-DD). Filters events with ts >= Since.

.EXAMPLE
    pwsh -File cost-tracker.ps1 session
    pwsh -File cost-tracker.ps1 today
    pwsh -File cost-tracker.ps1 history --since 2026-01-01
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('session', 'today', 'history')]
    [string] $Command,

    [string] $SessionId,
    [string] $Since
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# tpl: ------------------------------------------------------------------
$CURRENCY = '${COST_CURRENCY}'

function Get-UsageLogPath {
    # tpl: Honour env override, else pick a sensible temp dir per OS
    $envName = '${CORP_SLUG_UPPER}_USAGE_LOG'
    $override = [Environment]::GetEnvironmentVariable($envName)
    if ($override) { return $override }

    $tempDir = if ($IsWindows) {
        if ($env:TEMP) { $env:TEMP } else { 'C:\Windows\Temp' }
    } else {
        '/tmp'
    }
    return (Join-Path $tempDir '${CORP_SLUG}-usage.jsonl')
}

$USAGE_LOG = Get-UsageLogPath

function Format-Amount {
    param([Parameter(Mandatory)] [double] $Amount)
    $n = '{0:N4}' -f $Amount
    switch ($CURRENCY) {
        'EUR' { return "$n EUR" }
        'USD' { return "$ $n" }
        default { return "$n $CURRENCY" }
    }
}

function Read-Events {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }

    $events = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        try {
            $events.Add(($trimmed | ConvertFrom-Json -Depth 20 -ErrorAction Stop))
        } catch {
            # tpl: Skip malformed JSON line
            continue
        }
    }
    return $events.ToArray()
}

function Get-EventProp {
    # tpl: PSObject-safe property accessor with default
    param(
        [Parameter(Mandatory)] $Event,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )
    if ($null -eq $Event) { return $Default }
    if ($Event.PSObject.Properties.Name -contains $Name) {
        $v = $Event.$Name
        if ($null -eq $v) { return $Default }
        return $v
    }
    return $Default
}

function Where-Filter {
    param(
        [Parameter(Mandatory)] [object[]] $Events,
        [string] $Session,
        [string] $SinceDate
    )
    $out = $Events
    if ($Session) {
        $out = $out | Where-Object { (Get-EventProp -Event $_ -Name 'session') -eq $Session }
    }
    if ($SinceDate) {
        $out = $out | Where-Object {
            $ts = [string](Get-EventProp -Event $_ -Name 'ts' -Default '')
            $ts.Length -ge 10 -and ($ts.Substring(0, 10) -ge $SinceDate)
        }
    }
    return @($out)
}

function Invoke-Session {
    $events = Read-Events -Path $USAGE_LOG
    $session = $SessionId
    if (-not $session) {
        $session = [Environment]::GetEnvironmentVariable('${CORP_SLUG_UPPER}_SESSION_ID')
    }
    $events = Where-Filter -Events $events -Session $session -SinceDate $Since

    $total = 0.0
    foreach ($e in $events) { $total += [double](Get-EventProp -Event $e -Name 'cost' -Default 0.0) }
    "${CORP_NAME} - current session: $(Format-Amount $total)  ($($events.Count) requests)"
    return 0
}

function Invoke-Today {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $events = Read-Events -Path $USAGE_LOG
    $events = Where-Filter -Events $events -Session $SessionId -SinceDate $Since
    $events = @($events | Where-Object {
        $ts = [string](Get-EventProp -Event $_ -Name 'ts' -Default '')
        $ts.Length -ge 10 -and $ts.Substring(0, 10) -eq $today
    })

    $total = 0.0
    $byModel = @{}
    foreach ($e in $events) {
        $cost = [double](Get-EventProp -Event $e -Name 'cost' -Default 0.0)
        $total += $cost
        $model = [string](Get-EventProp -Event $e -Name 'model' -Default '?')
        if (-not $byModel.ContainsKey($model)) { $byModel[$model] = 0.0 }
        $byModel[$model] += $cost
    }

    "${CORP_NAME} - today ($today): $(Format-Amount $total)  ($($events.Count) requests)"
    foreach ($kv in ($byModel.GetEnumerator() | Sort-Object -Property Value -Descending)) {
        '  {0,-30} {1}' -f $kv.Key, (Format-Amount $kv.Value)
    }
    return 0
}

function Invoke-History {
    $events = Read-Events -Path $USAGE_LOG
    $events = Where-Filter -Events $events -Session $SessionId -SinceDate $Since

    $byDay = @{}
    foreach ($e in $events) {
        $ts = [string](Get-EventProp -Event $e -Name 'ts' -Default '')
        $day = if ($ts.Length -ge 10) { $ts.Substring(0, 10) } else { '?' }
        $cost = [double](Get-EventProp -Event $e -Name 'cost' -Default 0.0)
        if (-not $byDay.ContainsKey($day)) { $byDay[$day] = 0.0 }
        $byDay[$day] += $cost
    }

    "${CORP_NAME} - history:"
    foreach ($kv in ($byDay.GetEnumerator() | Sort-Object -Property Name)) {
        '  {0}  {1}' -f $kv.Key, (Format-Amount $kv.Value)
    }
    return 0
}

# tpl: --- dispatch ------------------------------------------------------
if (-not $Command) {
    Write-Error 'Usage: cost-tracker.ps1 <session|today|history> [-SessionId <id>] [-Since YYYY-MM-DD]'
    exit 2
}

switch ($Command) {
    'session' { exit (Invoke-Session) }
    'today'   { exit (Invoke-Today) }
    'history' { exit (Invoke-History) }
}
