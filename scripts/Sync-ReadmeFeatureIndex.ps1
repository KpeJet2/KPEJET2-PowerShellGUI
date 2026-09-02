# VersionTag: 2607.B1.V52.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-07-23
# SupportsPS7.6TestedDate: 2026-07-23
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Refreshes the managed feature index block in README.md.
.DESCRIPTION
    Maintains a stable, auto-generated README section so docs stay aligned with
    scripts/modules/tests/pages growth and pipeline controls.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $WorkspacePath).Path
$readmePath = Join-Path $root 'README.md'
if (-not (Test-Path -LiteralPath $readmePath)) {
    throw 'README.md not found at workspace root.'
}

function Get-CountSafe {
    param([string]$Path, [string]$Filter)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @((Get-ChildItem -LiteralPath $Path -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue)).Count
}

$scriptsCount = Get-CountSafe -Path (Join-Path $root 'scripts') -Filter '*.ps1'
$modulesCount = Get-CountSafe -Path (Join-Path $root 'modules') -Filter '*.psm1'
$testsCount   = Get-CountSafe -Path (Join-Path $root 'tests') -Filter '*.ps1'
$pagesCount   = @((Get-ChildItem -LiteralPath (Join-Path $root 'pages') -Recurse -File -Include *.xhtml,*.html -ErrorAction SilentlyContinue)).Count

$scanRefs = @(
    'tests/Invoke-SINPatternScanner.ps1',
    'tests/Convert-SinScanToJUnit.ps1',
    'scripts/Invoke-PipelineContinuousRefine.ps1',
    'scripts/Invoke-ValidateCanonicalPaths.ps1',
    'scripts/Sync-ReadmeFeatureIndex.ps1',
    'scripts/Invoke-ReferenceIntegrityCheck.ps1',
    'scripts/Invoke-VersionAlignmentTool.ps1',
    'config/pipeline-canonical-paths.json',
    'config/pipeline-refine-allowlist.json',
    'config/pipeline-refine-severity-policy.json',
    'config/pipeline-refine-baseline-full.json',
    'config/pipeline-refine-baseline-staged.json',
    'config/pipeline-refine-baseline-nightly.json'
)

$cmdLines = @(
    'pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -UpdateReadme -BaselineProfile full -BaselineJson .\config\pipeline-refine-baseline-full.json -FailOnDrift',
    'pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -StagedOnly -BaselineProfile staged -BaselineJson .\config\pipeline-refine-baseline-staged.json -FailOnDrift',
    'pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -BaselineProfile nightly -BaselineJson .\config\pipeline-refine-baseline-nightly.json -FailOnDrift',
    'pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -BaselineProfile full -UpdateBaseline -BaselineJson .\config\pipeline-refine-baseline-full.json',
    'pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -StagedOnly -BaselineProfile staged -UpdateBaseline -BaselineJson .\config\pipeline-refine-baseline-staged.json',
    'pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -BaselineProfile nightly -UpdateBaseline -BaselineJson .\config\pipeline-refine-baseline-nightly.json',
    'pwsh -NoProfile -File .\scripts\Invoke-ValidateCanonicalPaths.ps1 -FailOnMissing -RegistryPath .\config\pipeline-canonical-paths.json',
    'pwsh -NoProfile -File .\tests\Invoke-SINPatternScanner.ps1 -WorkspacePath . -Runtime Both -OutputJson .\reports\sin-scan-permissive.json',
    'pwsh -NoProfile -File .\scripts\Invoke-ReferenceIntegrityCheck.ps1'
)

$generated = @()
$generated += '<!-- AUTO-GENERATED:FEATURE-INDEX:START -->'
$generated += ''
$generated += '## Managed Feature Index'
$generated += ''
$generated += ('Generated: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
$generated += ''
$generated += '### Workspace Metrics'
$generated += ''
$generated += ('- Scripts (.ps1): ' + $scriptsCount)
$generated += ('- Modules (.psm1): ' + $modulesCount)
$generated += ('- Tests (.ps1): ' + $testsCount)
$generated += ('- Pages (.xhtml/.html): ' + $pagesCount)
$generated += ''
$generated += '### Canonical Pipeline Paths'
$generated += ''
foreach ($r in $scanRefs) {
    $generated += ('- ' + $r)
}
$generated += ''
$generated += '### Continuous Refinement Commands'
$generated += ''
$generated += '```powershell'
foreach ($c in $cmdLines) {
    $generated += $c
}
$generated += '```'
$generated += ''
$generated += '<!-- AUTO-GENERATED:FEATURE-INDEX:END -->'

$raw = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
$startMarker = '<!-- AUTO-GENERATED:FEATURE-INDEX:START -->'
$endMarker = '<!-- AUTO-GENERATED:FEATURE-INDEX:END -->'
$newBlock = ($generated -join "`r`n")

if ($raw -match [regex]::Escape($startMarker) -and $raw -match [regex]::Escape($endMarker)) {
    $pattern = [regex]::Escape($startMarker) + '[\s\S]*?' + [regex]::Escape($endMarker)
    $updated = [regex]::Replace($raw, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newBlock }, 1)
} else {
    $updated = $raw.TrimEnd() + "`r`n`r`n" + $newBlock + "`r`n"
}

$updated = $updated.TrimEnd() + "`r`n"

Set-Content -LiteralPath $readmePath -Value $updated -Encoding UTF8
Write-Host ('[Sync-ReadmeFeatureIndex] Updated: ' + $readmePath) -ForegroundColor Green
