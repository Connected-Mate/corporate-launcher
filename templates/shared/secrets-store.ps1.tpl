# tpl: shared module — Windows secret storage (PowerShell 7+)
# Loads/saves the API key via Windows Credential Manager, with a
# chmod-equivalent ACL'd file fallback at $env:USERPROFILE\.${CORP_SLUG}.conf.

Set-StrictMode -Version Latest

# tpl: Win32 P/Invoke for Credential Manager — used when the optional
# CredentialManager PowerShell module is not installed.
$script:CredManTypeLoaded = $false
function Initialize-CredManType {
    if ($script:CredManTypeLoaded) { return }
    if ('CorpCredMan' -as [type]) { $script:CredManTypeLoaded = $true; return }

    Add-Type -Namespace 'Corp' -Name 'CredMan' -MemberDefinition @"
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
        public struct CREDENTIAL {
            public uint   Flags;
            public uint   Type;
            public IntPtr TargetName;
            public IntPtr Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint   CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint   Persist;
            public uint   AttributeCount;
            public IntPtr Attributes;
            public IntPtr TargetAlias;
            public IntPtr UserName;
        }

        [DllImport("Advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);

        [DllImport("Advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern bool CredWriteW([In] ref CREDENTIAL credential, uint flags);

        [DllImport("Advapi32.dll", SetLastError=true)]
        public static extern bool CredDeleteW(string target, uint type, uint flags);

        [DllImport("Advapi32.dll", SetLastError=true)]
        public static extern void CredFree(IntPtr cred);
"@
    $script:CredManTypeLoaded = $true
}

function Get-CorpApiKey {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $target = '${CORP_SLUG}'
    $conf   = Join-Path $env:USERPROFILE ".${CORP_SLUG}.conf"

    # tpl: 1. CredentialManager module (cleanest if installed)
    if (Get-Module -ListAvailable -Name CredentialManager -ErrorAction SilentlyContinue) {
        try {
            Import-Module CredentialManager -ErrorAction Stop
            $cred = Get-StoredCredential -Target $target -ErrorAction SilentlyContinue
            if ($null -ne $cred -and $cred.Password) {
                $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
                try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
                finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
                if ($key) { return (Test-ApiKeyFormat $key) }
            }
        } catch { }
    }

    # tpl: 2. Win32 P/Invoke fallback
    if ($IsWindows) {
        try {
            Initialize-CredManType
            $ptr = [IntPtr]::Zero
            if ([Corp.CredMan]::CredReadW($target, 1, 0, [ref]$ptr)) {
                try {
                    $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type]'Corp.CredMan+CREDENTIAL')
                    if ($cred.CredentialBlobSize -gt 0) {
                        $key = [Runtime.InteropServices.Marshal]::PtrToStringUni($cred.CredentialBlob, $cred.CredentialBlobSize / 2)
                        if ($key) { return (Test-ApiKeyFormat $key) }
                    }
                } finally {
                    [Corp.CredMan]::CredFree($ptr) | Out-Null
                }
            }
        } catch { }
    }

    # tpl: 3. ACL'd conf file (fallback)
    if (Test-Path -LiteralPath $conf -PathType Leaf) {
        $varUpper = '${CORP_SLUG_UPPER}_API_KEY'
        $line = Select-String -LiteralPath $conf -Pattern "^$varUpper=" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $line) {
            $line = Select-String -LiteralPath $conf -Pattern '^CORP_API_KEY=' -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($line) {
            $raw = ($line.Line -replace '^[^=]+=','').Trim('"')
            if ($raw) { return (Test-ApiKeyFormat $raw) }
        }
    }

    return ''
}

function Test-ApiKeyFormat {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Key)

    if ([string]::IsNullOrEmpty($Key)) { return '' }
    if ($Key -notmatch '^[a-zA-Z0-9_.\-]+$') {
        $esc = [char]27
        [Console]::Error.WriteLine("${esc}[0;31mERROR: API key contains invalid characters.${esc}[0m")
        [Console]::Error.WriteLine('  Allowed: a-z A-Z 0-9 _ . -')
        return ''
    }
    return $Key
}

function Save-CorpApiKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key
    )

    $target = '${CORP_SLUG}'
    $conf   = Join-Path $env:USERPROFILE ".${CORP_SLUG}.conf"

    # tpl: 1. CredentialManager module
    if (Get-Module -ListAvailable -Name CredentialManager -ErrorAction SilentlyContinue) {
        try {
            Import-Module CredentialManager -ErrorAction Stop
            $sec = ConvertTo-SecureString -String $Key -AsPlainText -Force
            New-StoredCredential -Target $target -UserName $env:USERNAME -SecurePassword $sec -Persist LocalMachine -ErrorAction Stop | Out-Null
            return
        } catch { }
    }

    # tpl: 2. Win32 P/Invoke fallback
    if ($IsWindows) {
        try {
            Initialize-CredManType
            $bytes = [Text.Encoding]::Unicode.GetBytes($Key)
            $blob  = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
            try {
                [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $blob, $bytes.Length)
                $cred = New-Object Corp.CredMan+CREDENTIAL
                $cred.Type               = 1   # GENERIC
                $cred.TargetName         = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($target)
                $cred.UserName           = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($env:USERNAME)
                $cred.CredentialBlob     = $blob
                $cred.CredentialBlobSize = [uint32]$bytes.Length
                $cred.Persist            = 2   # LOCAL_MACHINE
                if ([Corp.CredMan]::CredWriteW([ref]$cred, 0)) {
                    [Runtime.InteropServices.Marshal]::FreeHGlobal($cred.TargetName)
                    [Runtime.InteropServices.Marshal]::FreeHGlobal($cred.UserName)
                    return
                }
                [Runtime.InteropServices.Marshal]::FreeHGlobal($cred.TargetName)
                [Runtime.InteropServices.Marshal]::FreeHGlobal($cred.UserName)
            } finally {
                [Runtime.InteropServices.Marshal]::FreeHGlobal($blob)
            }
        } catch { }

        # tpl: 3. cmdkey shell-out as a last-resort keychain attempt
        try {
            & cmdkey.exe /generic:$target /user:$env:USERNAME /pass:$Key | Out-Null
            if ($LASTEXITCODE -eq 0) { return }
        } catch { }
    }

    # tpl: 4. ACL'd conf file (fallback) — owner-only, inheritance off
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $content = @"
# ${CORP_NAME} — Configuration
# Generated $stamp
# Do not share

${CORP_SLUG_UPPER}_API_KEY=$Key
"@
    Set-Content -LiteralPath $conf -Value $content -Encoding utf8 -Force

    try {
        $acl = Get-Acl -LiteralPath $conf
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
        $owner = [Security.Principal.NTAccount]"$env:USERDOMAIN\$env:USERNAME"
        $rule  = New-Object Security.AccessControl.FileSystemAccessRule(
            $owner, 'FullControl', 'Allow'
        )
        $acl.SetOwner($owner)
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $conf -AclObject $acl
    } catch {
        Write-Warning "Could not tighten ACL on $conf — please review permissions manually."
    }
}

function Prompt-ForApiKey {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $esc = [char]27
    Write-Host ""
    Write-Host "${esc}[1;38;5;208m${CORP_NAME} — first launch${esc}[0m"
    Write-Host ""
    $tokenUrl = '${LLM_TOKEN_URL}'
    if ([string]::IsNullOrWhiteSpace($tokenUrl)) { $tokenUrl = 'the gateway portal' }
    Write-Host "Get a token from: $tokenUrl"
    Write-Host ""

    # tpl: -AsSecureString → never echoes, never logged
    $sec = Read-Host -Prompt 'Token' -AsSecureString
    if ($null -eq $sec) {
        [Console]::Error.WriteLine("${esc}[0;31mERROR: empty token.${esc}[0m")
        return ''
    }

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }

    if ([string]::IsNullOrEmpty($apiKey)) {
        [Console]::Error.WriteLine("${esc}[0;31mERROR: empty token.${esc}[0m")
        return ''
    }
    if ($apiKey -notmatch '^[a-zA-Z0-9_.\-]+$') {
        [Console]::Error.WriteLine("${esc}[0;31mERROR: token contains invalid characters.${esc}[0m")
        return ''
    }

    Save-CorpApiKey -Key $apiKey
    return $apiKey
}

function Remove-CorpApiKey {
    [CmdletBinding()]
    param()

    $target = '${CORP_SLUG}'
    $conf   = Join-Path $env:USERPROFILE ".${CORP_SLUG}.conf"

    # tpl: 1. CredentialManager module
    if (Get-Module -ListAvailable -Name CredentialManager -ErrorAction SilentlyContinue) {
        try {
            Import-Module CredentialManager -ErrorAction Stop
            Remove-StoredCredential -Target $target -ErrorAction SilentlyContinue
        } catch { }
    }

    # tpl: 2. Win32 P/Invoke fallback
    if ($IsWindows) {
        try {
            Initialize-CredManType
            [Corp.CredMan]::CredDeleteW($target, 1, 0) | Out-Null
        } catch { }

        # tpl: 3. cmdkey shell-out
        try { & cmdkey.exe /delete:$target | Out-Null } catch { }
    }

    # tpl: 4. conf file
    if (Test-Path -LiteralPath $conf -PathType Leaf) {
        Remove-Item -LiteralPath $conf -Force -ErrorAction SilentlyContinue
    }
}
