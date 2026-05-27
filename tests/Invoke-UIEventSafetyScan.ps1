# VersionTag: 2605.B5.V46.0
#Requires -Version 5.1
<#
.SYNOPSIS
    Static safety scan for tray-related WinForms event hardening.
.DESCRIPTION
    Enforces presence of the centralized safe WinForms event wrapper and
    critical tray bindings that protect against PipelineStoppedException
    during callback reentrancy/shutdown races.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetFile = Join-Path $WorkspacePath 'Main-GUI.ps1'
if (-not (Test-Path -LiteralPath $targetFile)) {
    Write-Error "Target file not found: $targetFile"
    exit 1
}

$content = Get-Content -LiteralPath $targetFile -Raw -Encoding UTF8

$requiredPatterns = @(
    @{ Name = 'Safe wrapper function exists'; Pattern = '(?m)^\s*function\s+New-SafeWinFormsHandler\b' },
    @{ Name = 'Wrapper catches PipelineStoppedException'; Pattern = 'catch\s+\[System\.Management\.Automation\.PipelineStoppedException\]' },
    @{ Name = 'Tray restore reentrancy guard exists'; Pattern = 'if\s*\(\$script:_RestoreInFlight\)\s*\{\s*return\s*\}' },
    @{ Name = 'NotifyIcon double-click uses safe wrapper'; Pattern = '\$script:_TrayIcon\.Add_DoubleClick\(\(New-SafeWinFormsHandler\s+-Handler\s+\$script:_RestoreFromTray\b' },
    @{ Name = 'Tray restore menu uses safe wrapper'; Pattern = '\$trayRestore\.Add_Click\(\(New-SafeWinFormsHandler\s+-Handler\s+\$script:_RestoreFromTray\b' },
    @{ Name = 'Tray exit menu uses safe wrapper'; Pattern = '\$trayExitFinal\.Add_Click\(\(New-SafeWinFormsHandler\s+-Handler\s+\$script:_ForceExit\b' }
)

$missing = @()
foreach ($rule in $requiredPatterns) {
    if (-not [regex]::IsMatch($content, $rule.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $missing += $rule.Name
    }
}

if (@($missing).Count -gt 0) {
    Write-Host '[UI-EVENT-SAFETY] FAILED' -ForegroundColor Red
    foreach ($name in $missing) {
        Write-Host ("  - Missing: {0}" -f $name) -ForegroundColor Yellow
    }
    exit 1
}

Write-Host '[UI-EVENT-SAFETY] PASS - tray callback resilience guards detected.' -ForegroundColor Green
exit 0
