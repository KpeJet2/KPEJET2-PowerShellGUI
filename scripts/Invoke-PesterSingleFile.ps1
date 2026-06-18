# VersionTag: 2605.B5.V51.1
# FileRole: Script
# SupportPS5.1: true
# SupportsPS7.6: true
#Requires -Version 5.1
<#
.SYNOPSIS
    Runs a single Pester test file and dumps a flat JSON summary for triage.
.DESCRIPTION
    Helper for Invoke-PesterTriage.ps1. Designed to be spawned as a child process so
    a wallclock-timeout supervisor can kill it if it hangs (e.g. AssistedSASC mandatory-
    param prompt trap). Output JSON keys are stable for aggregation.
.PARAMETER TestFile
    Absolute path to a *.Tests.ps1 file.
.PARAMETER OutputJson
    Absolute path to write the per-file result JSON.
#>
param(
    [Parameter(Mandatory=$true)][string]$TestFile,
    [Parameter(Mandatory=$true)][string]$OutputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Scrub PSModulePath of PowerShell 7 paths when running under Windows PowerShell 5.1.
# Inherited PSModulePath from parent shells often contains 'C:\Program Files\PowerShell\7\Modules',
# which causes PS 5.1 to autoload PS 7's Microsoft.PowerShell.Security module. Its
# Security.types.ps1xml conflicts with PS 5.1's built-in TypeData ("member AuditToString
# is already present" etc.), blocking ConvertTo-SecureString/ConvertFrom-SecureString and
# any cert/DPAPI work. This breaks AVPN-Tracker, PKIChainManager, ConvoVault, etc.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $sep = [System.IO.Path]::PathSeparator
    $parts = @(($env:PSModulePath -split [regex]::Escape($sep)) |
        Where-Object { $_ -and ($_ -notmatch '\\PowerShell\\7(?:-preview)?\\Modules') })
    $env:PSModulePath = ($parts -join $sep)
}

$startedAt = Get-Date
$result = [ordered]@{
    file        = $TestFile
    engine      = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    startedAt   = $startedAt.ToUniversalTime().ToString('o')
    completedAt = $null
    elapsedSec  = $null
    status      = 'UNKNOWN'
    total       = 0
    passed      = 0
    failed      = 0
    skipped     = 0
    error       = $null
    failures    = @()
}

try {
    $pester = Get-Module -Name Pester -ListAvailable |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pester) { throw 'Pester not installed' }
    Import-Module Pester -MinimumVersion 5.0 -Force -ErrorAction Stop

    $cfg = New-PesterConfiguration
    $cfg.Run.Path = @($TestFile)
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'None'
    $cfg.Should.ErrorAction = 'Continue'

    $r = Invoke-Pester -Configuration $cfg

    $result.total   = [int]$r.TotalCount
    $result.passed  = [int]$r.PassedCount
    $result.failed  = [int]$r.FailedCount
    $result.skipped = [int]$r.SkippedCount
    $result.status  = if ($result.failed -eq 0) { 'PASSED' } else { 'FAILED' }

    $failArr = @()
    foreach ($t in $r.Tests) {
        if ($t.Result -eq 'Failed') {
            $msg = ''
            $stack = ''
            if ($t.PSObject.Properties.Name -contains 'ErrorRecord' -and $null -ne $t.ErrorRecord) {
                $er = @($t.ErrorRecord)
                if ($er.Count -gt 0) {
                    try { $msg = "$($er[0].Exception.Message)" } catch { <# Intentional: skip if no Exception #> }
                    try { $stack = "$($er[0].ScriptStackTrace)" } catch { <# Intentional: skip if no StackTrace #> }
                }
            }
            $failArr += [ordered]@{
                name      = "$($t.ExpandedPath)"
                block     = "$($t.Block.Path -join ' / ')"
                line      = if ($t.PSObject.Properties.Name -contains 'ScriptBlock' -and $null -ne $t.ScriptBlock) { [int]$t.ScriptBlock.StartPosition.StartLine } else { 0 }
                message   = $msg
                stack     = $stack
                durationMs= if ($t.PSObject.Properties.Name -contains 'Duration') { [int]$t.Duration.TotalMilliseconds } else { 0 }
            }
        }
    }
    $result.failures = $failArr
}
catch {
    $result.status = 'ERROR'
    $result.error  = "$($_.Exception.Message)"
}
finally {
    $endedAt = Get-Date
    $result.completedAt = $endedAt.ToUniversalTime().ToString('o')
    $result.elapsedSec  = [math]::Round(($endedAt - $startedAt).TotalSeconds, 2)

    try {
        $outDir = Split-Path -Parent $OutputJson
        if (-not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        $json = $result | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($OutputJson, $json, (New-Object System.Text.UTF8Encoding $true))
    } catch {
        Write-Warning "Failed to write result JSON: $($_.Exception.Message)"
    }
}

exit ([int]($result.status -ne 'PASSED'))

