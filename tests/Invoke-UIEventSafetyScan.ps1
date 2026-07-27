# VersionTag: 2607.B6.V53.0
# FileRole: Test
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-07-28
# SupportsPS7.6TestedDate: 2026-07-28
#Requires -Version 5.1
<#!
.SYNOPSIS
    Static safety scan for tray-related WinForms event hardening.
.DESCRIPTION
    Enforces presence of the centralized safe WinForms event wrapper and
    critical tray bindings that protect against PipelineStoppedException
    during callback reentrancy/shutdown races.
.PARAMETER WorkspacePath
    Workspace root path.
.PARAMETER AsObject
    Return structured rule results for nested gate evaluation.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path,
    [switch]$AsObject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetFile = Join-Path $WorkspacePath 'Main-GUI.ps1'
if (-not (Test-Path -LiteralPath $targetFile)) {
    $missingTarget = [PSCustomObject]@{
        Name = 'Target file exists'
        Status = 'FAIL'
        Detail = ('Target file not found: ' + $targetFile)
    }

    if ($AsObject) {
        return [PSCustomObject]@{
            Name = 'UIEventSafetyScan'
            Passed = $false
            Checks = @($missingTarget)
            Total = 1
            Failed = 1
        }
    }

    Write-Error ('Target file not found: ' + $targetFile)
    exit 1
}

$content = Get-Content -LiteralPath $targetFile -Raw -Encoding UTF8

$requiredPatterns = @(
    @{ Name = 'Safe wrapper function exists'; Pattern = '(?m)^\s*function\s+New-SafeWinFormsHandler\b' },
    @{ Name = 'Wrapper handles PipelineStoppedException'; Pattern = '(catch\s+\[System\.Management\.Automation\.PipelineStoppedException\])|(\$_\s+-is\s+\[System\.Management\.Automation\.PipelineStoppedException\])' },
    @{ Name = 'Tray restore reentrancy guard exists'; Pattern = 'if\s*\(\$script:_RestoreInFlight\)\s*\{\s*return\s*\}' },
    @{ Name = 'NotifyIcon double-click uses safe wrapper'; Pattern = '\$script:_TrayIcon\.Add_DoubleClick\(\(New-SafeWinFormsHandler\s+-Handler\s+\$script:_RestoreFromTray\b' },
    @{ Name = 'Tray restore menu uses safe wrapper'; Pattern = '\$trayRestore\.Add_Click\(\(New-SafeWinFormsHandler\s+-Handler\s+\$script:_RestoreFromTray\b' },
    @{ Name = 'Tray exit menu uses safe wrapper'; Pattern = '\$trayExitFinal\.Add_Click\(\(New-SafeWinFormsHandler\s+-Handler\s+\$script:_ForceExit\b' }
)

$checks = @()
foreach ($rule in $requiredPatterns) {
    $matched = [regex]::IsMatch($content, $rule.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $checks += [PSCustomObject]@{
        Name = [string]$rule.Name
        Status = if ($matched) { 'PASS' } else { 'FAIL' }
        Detail = if ($matched) { 'Pattern found' } else { 'Pattern missing' }
    }
}

$failed = @($checks | Where-Object { $_.Status -ne 'PASS' })
$passed = (@($failed).Count -eq 0)
$result = [PSCustomObject]@{
    Name = 'UIEventSafetyScan'
    Passed = [bool]$passed
    Checks = @($checks)
    Total = @($checks).Count
    Failed = @($failed).Count
}

if ($AsObject) {
    return $result
}

if (-not $passed) {
    Write-Host '[UI-EVENT-SAFETY] FAILED' -ForegroundColor Red
    foreach ($item in $failed) {
        Write-Host ('  - Missing: {0}' -f $item.Name) -ForegroundColor Yellow
    }
    exit 1
}

Write-Host '[UI-EVENT-SAFETY] PASS - tray callback resilience guards detected.' -ForegroundColor Green
exit 0
