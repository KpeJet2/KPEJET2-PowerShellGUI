# VersionTag: 2605.B5.V46.0
<#
.SYNOPSIS
  Lightweight smoke test for the backlog reconcile + planner pipeline.
.DESCRIPTION
  Verifies:
    - Invoke-BacklogReconcile.ps1 parses, runs in dry-run, produces audit JSON.
    - Invoke-TodoBacklogPlanner.ps1 parses, runs, produces normalized JSON / markdown / pointer.
    - Pointer manifest fields are present and counts are non-negative.
  Designed to be PS5.1-strict-safe and PS7.6-runnable.
.NOTES
  Returns exit code 0 on pass, 1 on failure.
#>
[CmdletBinding()]
param([string]$WorkspacePath = 'C:\PowerShellGUI')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True { param($cond,[string]$msg) if (-not $cond) { $failures.Add($msg) | Out-Null; Write-Host "[FAIL] $msg" -ForegroundColor Red } else { Write-Host "[PASS] $msg" -ForegroundColor Green } }

$reconcile = Join-Path $WorkspacePath 'scripts\Invoke-BacklogReconcile.ps1'
$planner   = Join-Path $WorkspacePath 'scripts\Invoke-TodoBacklogPlanner.ps1'

# 1. Parser gates
foreach ($p in @($reconcile, $planner)) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)
    Assert-True (@($errs).Count -eq 0) ("Parser-clean: " + (Split-Path $p -Leaf))
}

# 2. Reconcile dry-run produces audit
$beforeReports = @(Get-ChildItem (Join-Path $WorkspacePath '~REPORTS\TodoPlanning') -Filter 'reconcile-*.json' -ErrorAction SilentlyContinue).Count
& $reconcile -WorkspacePath $WorkspacePath | Out-Null
$afterReports = @(Get-ChildItem (Join-Path $WorkspacePath '~REPORTS\TodoPlanning') -Filter 'reconcile-*.json').Count
Assert-True ($afterReports -gt $beforeReports) "Reconcile dry-run wrote new audit JSON"

# 3. Planner produces JSON + MD + pointer
& $planner -WorkspacePath $WorkspacePath | Out-Null
$pointerPath = Join-Path $WorkspacePath '~REPORTS\TodoPlanning\todo-planning-pointer.json'
Assert-True (Test-Path $pointerPath) "Pointer manifest exists"

if (Test-Path $pointerPath) {
    $ptr = Get-Content $pointerPath -Raw | ConvertFrom-Json
    Assert-True ($ptr.PSObject.Properties.Name -contains 'totalItems') "Pointer has totalItems"
    Assert-True ($ptr.PSObject.Properties.Name -contains 'actionableItems') "Pointer has actionableItems"
    Assert-True ($ptr.PSObject.Properties.Name -contains 'executionQueueItems') "Pointer has executionQueueItems"
    Assert-True ($ptr.totalItems -ge 0) "totalItems is non-negative"
    Assert-True ((Test-Path $ptr.latestJson) -and (Test-Path $ptr.latestMarkdown)) "Latest JSON+MD exist"
}

# 4. Audit JSON structure
$latestAudit = Get-ChildItem (Join-Path $WorkspacePath '~REPORTS\TodoPlanning') -Filter 'reconcile-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestAudit) {
    $audit = Get-Content $latestAudit.FullName -Raw | ConvertFrom-Json
    Assert-True ($audit.PSObject.Properties.Name -contains 'candidates') "Audit has candidates"
    Assert-True ($audit.PSObject.Properties.Name -contains 'resolved') "Audit has resolved"
    Assert-True ($audit.candidates -ge 0) "Audit candidates non-negative"
}

if ($failures.Count -gt 0) {
    Write-Host "`nFAILURES: $($failures.Count)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host "`nAll backlog pipeline smoke checks passed." -ForegroundColor Green
    exit 0
}

