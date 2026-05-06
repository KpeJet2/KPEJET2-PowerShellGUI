# VersionTag: 2605.B2.V31.7
<#
.SYNOPSIS
    PwShGUI-KillSwitch — per-version emergency kill switch governance.

.DESCRIPTION
    Reads/maintains config/kill-switches.csv. Each row maps a VersionTag to a
    keyboard hotkey + secret phrase. Calling Get-VersionKillSwitch for a new
    version clones the seed row (V=x) and appends a real row for that version.

    Register-VersionKillSwitch wires a global hotkey + (optional) TextBox
    secret-phrase monitor into a host WinForms form, so an operator can
    terminate every registered script process / service via Invoke-KillSwitch.

    SIN-aware: PS 5.1 strict-mode safe; UTF-8 BOM; no PS7-only ops; @() arrays;
    explicit -Encoding; no Invoke-Expression; null-guarded.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:KillSwitchCsvPath     = $null
$Script:RegisteredKillTargets = New-Object System.Collections.ArrayList
$Script:RegisteredHotkeys     = New-Object System.Collections.ArrayList

function _Resolve-KillSwitchCsv {
    [CmdletBinding()]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ($Script:KillSwitchCsvPath) { return $Script:KillSwitchCsvPath }
        $candidate = Join-Path $PSScriptRoot '..\config\kill-switches.csv'
        $resolved  = (Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue)
        if ($resolved) { $Script:KillSwitchCsvPath = $resolved.Path; return $resolved.Path }
        $Script:KillSwitchCsvPath = $candidate
        return $candidate
    }
    $Script:KillSwitchCsvPath = $Path
    return $Path
}

# ── DPAPI helpers (W3) ───────────────────────────────────────────────────────
# Wrap/unwrap kill-switch passphrases with current-user DPAPI.
# Wrapped values are stored in CSV as "DPAPI:<base64>". Plaintext values pass through.
$Script:DpapiPrefix = 'DPAPI:'

function _Test-DpapiAvailable {
    try {
        if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
        }
        return $true
    } catch {
        return $false
    }
}

function Protect-KillSwitchPassphrase {
    <#
    .SYNOPSIS
        Wrap a plaintext passphrase with current-user DPAPI; returns "DPAPI:<base64>".
    .PARAMETER PlainText
        The passphrase to protect.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$PlainText)
    if (-not (_Test-DpapiAvailable)) {
        throw "DPAPI not available on this platform"
    }
    if ($PlainText.StartsWith($Script:DpapiPrefix)) {
        return $PlainText  # already wrapped
    }
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $cipher = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return ($Script:DpapiPrefix + [Convert]::ToBase64String($cipher))
}

function Unprotect-KillSwitchPassphrase {
    <#
    .SYNOPSIS
        Unwrap a DPAPI-protected passphrase. Pass-through if not prefixed "DPAPI:".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if (-not $Value.StartsWith($Script:DpapiPrefix)) { return $Value }
    if (-not (_Test-DpapiAvailable)) {
        throw "DPAPI not available on this platform"
    }
    $b64    = $Value.Substring($Script:DpapiPrefix.Length)
    $cipher = [Convert]::FromBase64String($b64)
    $plain  = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $cipher, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function ConvertTo-ProtectedKillSwitchCsv {
    <#
    .SYNOPSIS
        Re-write kill-switches.csv with every Passphrase column DPAPI-wrapped.
        Recomputes Md5/Sha256 against the *plaintext* (so integrity check still works).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$CsvPath)
    $csv = _Resolve-KillSwitchCsv -Path $CsvPath
    if (-not (Test-Path -LiteralPath $csv)) { throw "Kill-switch CSV not found: $csv" }
    $rows = @(Import-Csv -LiteralPath $csv)
    if (@($rows).Count -eq 0) { throw "Kill-switch CSV is empty: $csv" }
    $changed = 0
    foreach ($r in $rows) {
        if (-not ($r.PSObject.Properties.Name -contains 'Passphrase')) { continue }
        $current = [string]$r.Passphrase
        if ($current.StartsWith($Script:DpapiPrefix)) { continue }
        if ($PSCmdlet.ShouldProcess("$($r.Version)", "DPAPI-wrap Passphrase")) {
            $r.Passphrase = Protect-KillSwitchPassphrase -PlainText $current
            $changed++
        }
    }
    if ($changed -gt 0) {
        $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    }
    return [pscustomobject]@{ ProtectedRows = $changed; Total = @($rows).Count }
}
# ── End DPAPI helpers ────────────────────────────────────────────────────────

function Get-VersionKillSwitch {
    <#
    .SYNOPSIS
        Returns the kill-switch row for a given version, cloning the seed row if absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Version,
        [string]$CsvPath
    )
    $csv = _Resolve-KillSwitchCsv -Path $CsvPath
    if (-not (Test-Path -LiteralPath $csv)) {
        throw "Kill-switch CSV not found: $csv"
    }
    $rows = @(Import-Csv -LiteralPath $csv)
    if (@($rows).Count -eq 0) {
        throw "Kill-switch CSV is empty: $csv"
    }
    $match = @($rows | Where-Object { $_.Version -eq $Version })
    if (@($match).Count -gt 0) {
        $row = $match[0]
        if ($row.PSObject.Properties.Name -contains 'Passphrase') {
            $row.Passphrase = Unprotect-KillSwitchPassphrase -Value ([string]$row.Passphrase)
        }
        return $row
    }
    $seed = @($rows | Where-Object { $_.Version -eq 'V=x' })
    if (@($seed).Count -eq 0) {
        $seed = @($rows[0])
    }
    $passphrase = Unprotect-KillSwitchPassphrase -Value ([string]$seed[0].Passphrase)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($passphrase)
    $md5Hash = [BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)).Replace('-','').ToLower()
    $shaHash = [BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-','').ToLower()
    $cipher = if ($seed[0].PSObject.Properties.Name -contains 'Cipher' -and -not [string]::IsNullOrWhiteSpace($seed[0].Cipher)) { [string]$seed[0].Cipher } else { 'AES256' }
    $newRow = [pscustomobject]@{
        Version    = $Version
        KillSwitch = $seed[0].KillSwitch
        Passphrase = $passphrase
        Md5        = $md5Hash
        Sha256     = $shaHash
        Cipher     = $cipher
    }
    $rows += $newRow
    $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    return $newRow
}

function Register-KillTarget {
    <#
    .SYNOPSIS
        Track a process / service to be terminated when the kill switch fires.
    .PARAMETER ProcessId
        OS process id (int). Use $PID for the current PowerShell host.
    .PARAMETER ServiceName
        Windows service name to stop on kill.
    .PARAMETER Description
        Free text label for diagnostics/logging.
    #>
    [CmdletBinding()]
    param(
        [int]$ProcessId,
        [string]$ServiceName,
        [string]$Description
    )
    $entry = [pscustomobject]@{
        ProcessId   = $ProcessId
        ServiceName = $ServiceName
        Description = $Description
        RegisteredAt = (Get-Date)
    }
    [void]$Script:RegisteredKillTargets.Add($entry)
    return $entry
}

function Invoke-KillSwitch {
    <#
    .SYNOPSIS
        Stop every registered process and service. Final fallback: kill self.
    #>
    [CmdletBinding()]
    param([string]$Reason = 'Manual kill switch')

    $stopped = New-Object System.Collections.ArrayList
    foreach ($t in @($Script:RegisteredKillTargets)) {
        try {
            if ($t.ServiceName) {
                $svc = Get-Service -Name $t.ServiceName -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -ne 'Stopped') {
                    Stop-Service -Name $t.ServiceName -Force -ErrorAction SilentlyContinue
                    [void]$stopped.Add("svc:$($t.ServiceName)")
                }
            }
            if ($t.ProcessId -and $t.ProcessId -gt 0 -and $t.ProcessId -ne $PID) {
                $p = Get-Process -Id $t.ProcessId -ErrorAction SilentlyContinue
                if ($p) {
                    Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue
                    [void]$stopped.Add("pid:$($t.ProcessId)")
                }
            }
        } catch {
            # Intentional: best-effort kill, do not let one failure stop the chain
            Write-Warning "KillSwitch target failure: $_"
        }
    }

    Write-Warning "[KILL-SWITCH] Triggered. Reason='$Reason'. Stopped: $($stopped -join ', ')"

    # Last: terminate host process so no UI loop survives. Bypass when test harness sets KILLSWITCH_NO_SELFTERMINATE.
    if ($env:KILLSWITCH_NO_SELFTERMINATE -eq '1') { return }
    try { Stop-Process -Id $PID -Force } catch { exit 1 }
}

function Register-VersionKillSwitch {
    <#
    .SYNOPSIS
        Wire kill-switch hotkey + (optional) secret phrase TextBox to a form.
    .PARAMETER Version
        VersionTag to look up (or auto-create) in kill-switches.csv.
    .PARAMETER Form
        Host System.Windows.Forms.Form to attach KeyDown handler to.
    .PARAMETER SecretTextBox
        Optional TextBox; typing the secret phrase + Enter triggers kill.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Version,
        [Parameter(Mandatory)] $Form,
        $SecretTextBox
    )

    $row = Get-VersionKillSwitch -Version $Version
    if ($null -eq $row) { return $null }

    # Parse kill-switch hotkey "ctrl+shift+q" → modifiers + key
    $tokens   = @(($row.KillSwitch -split '\+') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    $needCtrl  = $tokens -contains 'ctrl'
    $needShift = $tokens -contains 'shift'
    $needAlt   = $tokens -contains 'alt'
    $keyToken  = @($tokens | Where-Object { $_ -notin @('ctrl','shift','alt') })
    $keyName   = if (@($keyToken).Count -gt 0) { $keyToken[0].ToUpper() } else { 'Q' }

    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { <# already loaded #> }

    $Form.KeyPreview = $true
    $handler = {
        param($sender, $e)
        try {
            $okCtrl  = (-not $needCtrl)  -or $e.Control
            $okShift = (-not $needShift) -or $e.Shift
            $okAlt   = (-not $needAlt)   -or $e.Alt
            if ($okCtrl -and $okShift -and $okAlt -and ($e.KeyCode.ToString() -ieq $keyName)) {
                Invoke-KillSwitch -Reason "KillSwitch $($row.KillSwitch) (version $($row.Version))"
            }
        } catch {
            Write-Warning "KillSwitch hotkey handler: $_"
        }
    }.GetNewClosure()
    $Form.add_KeyDown($handler)
$Script:RegisteredHotkeys.Add([pscustomobject]@{ Version=$row.Version; KillSwitch=$row.KillSwitch }) | Out-Null

    if ($null -ne $SecretTextBox) {
        $secret = $row.Passphrase
        $secretHandler = {
            param($sender, $e)
            try {
                if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                    if ($null -ne $sender -and $sender.Text -ceq $secret) {
                        Invoke-KillSwitch -Reason "Passphrase (version $($row.Version))"
                    }
                }
            } catch {
                Write-Warning "KillSwitch secret handler: $_"
            }
        }.GetNewClosure()
        $SecretTextBox.add_KeyDown($secretHandler)
    }

    return $row
}

function Get-RegisteredKillTargets {
    [CmdletBinding()] param()
    return @($Script:RegisteredKillTargets)
}

function Test-KillSwitchIntegrity {
    <#
    .SYNOPSIS
        Verify Md5/Sha256 columns in kill-switches.csv match hashes of the Passphrase column.
    .DESCRIPTION
        Returns an array of drift records (one per mismatched field). Empty array = OK.
        Each record: @{ Version=...; Field='Md5'|'Sha256'; Expected=<computed>; Actual=<stored> }
    #>
    [CmdletBinding()]
    param([string]$CsvPath)
    $csv = _Resolve-KillSwitchCsv -Path $CsvPath
    if (-not (Test-Path -LiteralPath $csv)) {
        throw "Kill-switch CSV not found: $csv"
    }
    $rows = @(Import-Csv -LiteralPath $csv)
    $drift = New-Object System.Collections.ArrayList
    foreach ($r in $rows) {
        $needed = @('Passphrase','Md5','Sha256')
        $hasAll = $true
        foreach ($n in $needed) {
            if ($r.PSObject.Properties.Name -notcontains $n) { $hasAll = $false; break }
        }
        if (-not $hasAll) { continue }
        $plain  = Unprotect-KillSwitchPassphrase -Value ([string]$r.Passphrase)
        $bytes  = [System.Text.Encoding]::UTF8.GetBytes($plain)
        $md5    = [BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)).Replace('-','').ToLower()
        $sha    = [BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-','').ToLower()
        if (([string]$r.Md5).ToLower() -ne $md5) {
            [void]$drift.Add([pscustomobject]@{ Version=$r.Version; Field='Md5'; Expected=$md5; Actual=[string]$r.Md5 })
        }
        if (([string]$r.Sha256).ToLower() -ne $sha) {
            [void]$drift.Add([pscustomobject]@{ Version=$r.Version; Field='Sha256'; Expected=$sha; Actual=[string]$r.Sha256 })
        }
    }
    return @($drift)
}

Export-ModuleMember -Function Get-VersionKillSwitch, Register-VersionKillSwitch, Register-KillTarget, Invoke-KillSwitch, Get-RegisteredKillTargets, Test-KillSwitchIntegrity, Protect-KillSwitchPassphrase, Unprotect-KillSwitchPassphrase, ConvertTo-ProtectedKillSwitchCsv

