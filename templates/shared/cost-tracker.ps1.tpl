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
    Subcommand: session | today | history | push

.PARAMETER SessionId
    Override session filter (also honours $env:${CORP_SLUG_UPPER}_SESSION_ID).

.PARAMETER Since
    ISO-8601 date (YYYY-MM-DD). Filters events with ts >= Since.

.NOTES
    Optional alerting:
      ${CORP_SLUG_UPPER}_COST_ALERT_THRESHOLD (in COST_CURRENCY units, daily).
      When today's spend exceeds it, `session` and `today` emit a non-fatal
      warning. Zero or absent disables the alert.

    Optional tenant push (corporate dashboard):
      ${CORP_SLUG_UPPER}_COST_TENANT_ENDPOINT — HTTPS URL the tracker POSTs
      aggregated daily totals to when invoked with `push`. Auth header comes
      from ${CORP_SLUG_UPPER}_COST_TENANT_TOKEN (Bearer).

.EXAMPLE
    pwsh -File cost-tracker.ps1 session
    pwsh -File cost-tracker.ps1 today
    pwsh -File cost-tracker.ps1 history --since 2026-01-01
    pwsh -File cost-tracker.ps1 push
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('session', 'today', 'history', 'push')]
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

# tpl: Daily alert threshold (in $CURRENCY units). 0 / empty disables.
$ALERT_THRESHOLD = 0.0
$thresholdRaw = [Environment]::GetEnvironmentVariable('${CORP_SLUG_UPPER}_COST_ALERT_THRESHOLD')
if (-not $thresholdRaw) { $thresholdRaw = '${COST_ALERT_THRESHOLD}' }
if ($thresholdRaw) {
    try { $ALERT_THRESHOLD = [double]::Parse($thresholdRaw, [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { $ALERT_THRESHOLD = 0.0 }
}

# tpl: Corporate tenant push endpoint + bearer token. Empty disables.
$TENANT_ENDPOINT = [Environment]::GetEnvironmentVariable('${CORP_SLUG_UPPER}_COST_TENANT_ENDPOINT')
if (-not $TENANT_ENDPOINT) { $TENANT_ENDPOINT = '${COST_TENANT_ENDPOINT}' }
$TENANT_TOKEN = [Environment]::GetEnvironmentVariable('${CORP_SLUG_UPPER}_COST_TENANT_TOKEN')
if (-not $TENANT_TOKEN) { $TENANT_TOKEN = '' }

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

function Get-TodayTotal {
    param([Parameter(Mandatory)] [object[]] $Events)
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $total = 0.0
    foreach ($e in $Events) {
        $ts = [string](Get-EventProp -Event $e -Name 'ts' -Default '')
        if ($ts.Length -ge 10 -and $ts.Substring(0, 10) -eq $today) {
            $total += [double](Get-EventProp -Event $e -Name 'cost' -Default 0.0)
        }
    }
    return $total
}

function Invoke-MaybeAlert {
    param([Parameter(Mandatory)] [object[]] $Events)
    if ($ALERT_THRESHOLD -le 0) { return }
    $totalToday = Get-TodayTotal -Events $Events
    if ($totalToday -ge $ALERT_THRESHOLD) {
        Write-Warning ("daily cost {0} >= alert threshold {1}" -f (Format-Amount $totalToday), (Format-Amount $ALERT_THRESHOLD))
    }
}

function Invoke-Session {
    $allEvents = Read-Events -Path $USAGE_LOG
    $session = $SessionId
    if (-not $session) {
        $session = [Environment]::GetEnvironmentVariable('${CORP_SLUG_UPPER}_SESSION_ID')
    }
    $events = Where-Filter -Events $allEvents -Session $session -SinceDate $Since

    $total = 0.0
    foreach ($e in $events) { $total += [double](Get-EventProp -Event $e -Name 'cost' -Default 0.0) }
    "${CORP_NAME} - current session: $(Format-Amount $total)  ($($events.Count) requests)"
    Invoke-MaybeAlert -Events $allEvents
    return 0
}

function Invoke-Today {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $allEvents = Read-Events -Path $USAGE_LOG
    $events = Where-Filter -Events $allEvents -Session $SessionId -SinceDate $Since
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
    Invoke-MaybeAlert -Events $allEvents
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

function Invoke-Push {
    # tpl: POST today's aggregated total to the corporate tenant dashboard.
    if (-not $TENANT_ENDPOINT) {
        [Console]::Error.WriteLine('push disabled - set ${CORP_SLUG_UPPER}_COST_TENANT_ENDPOINT to enable')
        return 2
    }

    $today = (Get-Date).ToString('yyyy-MM-dd')
    $allEvents = Read-Events -Path $USAGE_LOG
    $todayEvents = @($allEvents | Where-Object {
        $ts = [string](Get-EventProp -Event $_ -Name 'ts' -Default '')
        $ts.Length -ge 10 -and $ts.Substring(0, 10) -eq $today
    })

    $total = 0.0
    foreach ($e in $todayEvents) { $total += [double](Get-EventProp -Event $e -Name 'cost' -Default 0.0) }
    $total = [math]::Round($total, 6)

    $payload = [ordered]@{
        tenant   = '${CORP_SLUG}'
        org      = '${CORP_ORGANIZATION}'
        day      = $today
        currency = $CURRENCY
        total    = $total
        requests = $todayEvents.Count
    }
    $body = $payload | ConvertTo-Json -Compress -Depth 5

    $headers = @{
        'Content-Type' = 'application/json'
        'User-Agent'   = '${CORP_SLUG}-cost-tracker'
    }
    if ($TENANT_TOKEN) { $headers['Authorization'] = "Bearer $TENANT_TOKEN" }

    try {
        $resp = Invoke-WebRequest -Uri $TENANT_ENDPOINT -Method Post -Body $body `
            -Headers $headers -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        "pushed $(Format-Amount $total) for $today -> HTTP $($resp.StatusCode)"
        return 0
    } catch [System.Net.WebException] {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code) {
            [Console]::Error.WriteLine("push failed: HTTP $code")
        } else {
            [Console]::Error.WriteLine("push failed: $($_.Exception.Message)")
        }
        return 1
    } catch {
        [Console]::Error.WriteLine("push failed: $($_.Exception.Message)")
        return 1
    }
}

# tpl: --- dispatch ------------------------------------------------------
if (-not $Command) {
    Write-Error 'Usage: cost-tracker.ps1 <session|today|history|push> [-SessionId <id>] [-Since YYYY-MM-DD]'
    exit 2
}

switch ($Command) {
    'session' { exit (Invoke-Session) }
    'today'   { exit (Invoke-Today) }
    'history' { exit (Invoke-History) }
    'push'    { exit (Invoke-Push) }
}
