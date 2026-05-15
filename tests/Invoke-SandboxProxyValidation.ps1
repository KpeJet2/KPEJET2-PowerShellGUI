# VersionTag: 2605.B5.V46.0
<#
.SYNOPSIS
  Local sandbox-proxy validation: parser + import + smoke battery without spawning Windows Sandbox.
.DESCRIPTION
  Walks critical scripts/modules and asserts:
    - All target files parse with 0 errors
    - Critical modules import cleanly (in a child process to isolate side-effects)
    - Backlog pipeline smoke passes
    - Main-GUI.ps1 + Invoke-TodoBacklogPlanner.ps1 + Invoke-BacklogReconcile.ps1 are clean
  Designed to run under both PS 5.1 and PS 7.6.
.NOTES
  Exit 0 on pass, 1 on failure.
#>
[CmdletBinding()]
param([string]$WorkspacePath = 'C:\PowerShellGUI')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True { param($cond,[string]$msg) if (-not $cond) { $failures.Add($msg) | Out-Null; Write-Host "[FAIL] $msg" -ForegroundColor Red } else { Write-Host "[PASS] $msg" -ForegroundColor Green } }

# 1. Parser sweep across critical surface
$critical = @(
    'Main-GUI.ps1',
    'scripts\Invoke-TodoBacklogPlanner.ps1',
    'scripts\Invoke-BacklogReconcile.ps1',
    'scripts\Invoke-CronProcessor.ps1',
    'scripts\Register-WorkspaceRepository.ps1',
    'modules\PwShGUI-TrayHost.psm1',
    'modules\PwShGUI-SessionMetrics.psm1',
    'modules\PwShGUI-PSVersionStandards.psm1',
    'modules\CronAiAthon-EventLog.psm1',
    'modules\CronAiAthon-Scheduler.psm1',
    'modules\CronAiAthon-Pipeline.psm1',
    'modules\AssistedSASC.psm1',
    'modules\PwShGUI-IntegrityCore.psm1',
    'modules\PwSh-HelpFilesUpdateSource-ReR.psm1',
    'tests\Invoke-BacklogPipelineSmoke.ps1'
)

foreach ($rel in $critical) {
    $p = Join-Path $WorkspacePath $rel
    if (-not (Test-Path $p)) {
        Assert-True $false "Missing critical file: $rel"
        continue
    }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)
    Assert-True (@($errs).Count -eq 0) "Parser-clean: $rel"
}

# 2. Import-isolated module smoke: each module loaded in a child PowerShell to avoid pollution
$moduleSmoke = @(
    'PwShGUI-SessionMetrics',
    'PwShGUI-PSVersionStandards',
    'CronAiAthon-EventLog'
)
foreach ($m in $moduleSmoke) {
    $modPath = Join-Path $WorkspacePath ("modules\{0}.psm1" -f $m)
    if (-not (Test-Path $modPath)) { Assert-True $false "Module missing: $m"; continue }
    $cmd = "Set-StrictMode -Version Latest; try { Import-Module -Name '$modPath' -Force -ErrorAction Stop; 'OK' } catch { 'FAIL: ' + `$_.Exception.Message; exit 2 }"
    $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $out = & $exe -NoProfile -NonInteractive -Command $cmd 2>&1
    $okay = ($LASTEXITCODE -eq 0) -and ($out -match 'OK')
    Assert-True $okay ("Import-isolated: {0} ({1})" -f $m, ($out | Select-Object -First 1))
}

# 3. Backlog pipeline smoke
$pipelineSmoke = Join-Path $WorkspacePath 'tests\Invoke-BacklogPipelineSmoke.ps1'
if (Test-Path $pipelineSmoke) {
    & $pipelineSmoke -WorkspacePath $WorkspacePath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "Backlog pipeline smoke: exit code $LASTEXITCODE"
} else {
    Assert-True $false "Backlog pipeline smoke missing"
}

# 4. Pointer integrity
$pointer = Join-Path $WorkspacePath '~REPORTS\TodoPlanning\todo-planning-pointer.json'
if (Test-Path $pointer) {
    $ptr = Get-Content $pointer -Raw | ConvertFrom-Json
    Assert-True (Test-Path $ptr.latestJson) "Latest planner JSON exists"
    Assert-True (Test-Path $ptr.latestMarkdown) "Latest planner MD exists"
}

if ($failures.Count -gt 0) {
    Write-Host "`nSANDBOX-PROXY FAIL: $($failures.Count)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host "`nAll sandbox-proxy validation checks passed." -ForegroundColor Green
    exit 0
}

