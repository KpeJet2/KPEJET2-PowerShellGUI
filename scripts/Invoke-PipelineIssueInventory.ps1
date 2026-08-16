# VersionTag: 2608.B0.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: Pipeline Inventory Gate
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$WorkspacePath,
    [int]$StaleInProgressDays = 3,
    [int]$StaleOpenDays = 14,
    [switch]$NoFix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspaceFull = [System.IO.Path]::GetFullPath($WorkspacePath)
$pipelineModule = Join-Path (Join-Path $workspaceFull 'modules') 'CronAiAthon-Pipeline.psm1'
if (-not (Test-Path -LiteralPath $pipelineModule)) { throw "Pipeline module not found: $pipelineModule" }
Import-Module $pipelineModule -Force -DisableNameChecking -ErrorAction Stop
$configPath = Join-Path (Join-Path $workspaceFull 'config') 'the-gate-bouncer.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$protectedPatterns = @($config.protectedPathPatterns)
$registryPath = Join-Path (Join-Path $workspaceFull 'config') 'cron-aiathon-pipeline.json'
$registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$existing = @($registry.bugs)
$findings = [System.Collections.ArrayList]::new()
$protected = [System.Collections.ArrayList]::new()

function Add-Issue {
    param([string]$Kind, [string]$Path, [string]$Detail, [string]$Severity = 'HIGH')
    $relative = if ([System.IO.Path]::IsPathRooted($Path)) { ([System.IO.Path]::GetFullPath($Path)).Substring($workspaceFull.Length).TrimStart('\', '/') } else { $Path }
    $isProtected = @($protectedPatterns | Where-Object { ($relative -replace '\\', '/') -match $_ }).Count -gt 0
    if ($isProtected) {
        $null = $protected.Add([pscustomobject]@{ kind = $Kind; path = $relative; detail = $Detail; reason = 'kernel/cache/protected path preserved' })
        return
    }
    $null = $findings.Add([pscustomobject]@{ kind = $Kind; path = $relative; fullPath = $Path; detail = $Detail; severity = $Severity })
}

$todoRoot = Join-Path $workspaceFull 'todo'
$jsonFiles = if (Test-Path -LiteralPath $todoRoot) { @(Get-ChildItem -LiteralPath $todoRoot -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('_index.json', '_master-aggregated.json') }) } else { @() }
foreach ($file in $jsonFiles) {
    $relative = $file.FullName.Substring($workspaceFull.Length).TrimStart('\', '/')
    $protectedFile = @($protectedPatterns | Where-Object { ($relative -replace '\\', '/') -match $_ }).Count -gt 0
    if ($file.Length -eq 0) { Add-Issue -Kind 'NULL_ON_DISK' -Path $file.FullName -Detail 'Queue JSON is zero bytes.' -Severity 'CRITICAL'; continue }
    try { $null = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { Add-Issue -Kind 'CORRUPT_JSON' -Path $file.FullName -Detail $_.Exception.Message -Severity 'CRITICAL'; continue }
    if (-not $protectedFile) {
        try {
            $stream = New-Object System.IO.FileStream($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $stream.Dispose()
        }
        catch {
            Add-Issue -Kind 'LOCKED_OR_IN_USE' -Path $file.FullName -Detail 'Queue JSON could not be opened exclusively; process ownership must be reviewed before remediation.' -Severity 'HIGH'
        }
    }
    if (($file.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { Add-Issue -Kind 'IMMUTABLE_OR_READONLY' -Path $file.FullName -Detail 'Queue JSON has ReadOnly attribute.' -Severity 'HIGH' }
}

try {
    $integrity = Test-PipelineArtifactIntegrity -WorkspacePath $workspaceFull -IncludeStaleCheck -OpenDays $StaleOpenDays -InProgressDays $StaleInProgressDays
    foreach ($item in @($integrity.interruptions.items)) {
        if ($null -ne $item) { Add-Issue -Kind 'STALE_PIPELINE_ITEM' -Path ('todo/' + [string]$item.id + '.json') -Detail ("$($item.title); status=$($item.status); ageDays=$($item.ageDays); threshold=$($item.threshold)") -Severity 'HIGH' }
    }
}
catch {
    Add-Issue -Kind 'INVENTORY_CHECK_FAILED' -Path 'config/cron-aiathon-pipeline.json' -Detail $_.Exception.Message -Severity 'CRITICAL'
}

$created = [System.Collections.ArrayList]::new()
foreach ($issue in @($findings)) {
    $marker = ('TheGateBouncer:{0}:{1}' -f $issue.kind, $issue.path).ToLowerInvariant()
    $duplicate = @($existing | Where-Object {
            $notes = if ($_.PSObject.Properties.Name -contains 'notes') { [string]$_.notes } else { '' }
            $notes -like "*$marker*" -and $_.status -notin @('DONE', 'CLOSED')
        }).Count -gt 0
    if ($duplicate) { continue }
    $bug = New-PipelineItem -Type 'Bug' -Title ("{0}: {1}" -f $issue.kind, ([System.IO.Path]::GetFileName($issue.path))) -Description $issue.detail -Priority ([string]$issue.severity) -Source 'BugTracker' -Category 'pipeline-integrity' -AffectedFiles @($issue.path) -SuggestedBy 'TheGateBouncer'
    $bugHash = @{}
    foreach ($property in $bug.Keys) { $bugHash[$property] = $bug[$property] }
    $bugHash['notes'] = $marker
    $bugHash['gate'] = 'TheGateBouncer'
    if (-not $NoFix) { $null = Add-PipelineItem -WorkspacePath $workspaceFull -Item $bugHash -SkipArtifactRefresh }
    $existing += [pscustomobject]$bugHash
    $null = $created.Add([pscustomobject]@{ id = $bugHash.id; kind = $issue.kind; path = $issue.path; mode = if ($NoFix) { 'WHATIF' } else { 'CREATED' } })
}

[pscustomobject][ordered]@{
    gate                = 'PipelineIssueInventory'
    staleInProgressDays = $StaleInProgressDays
    staleOpenDays       = $StaleOpenDays
    issueCount          = @($findings).Count
    protectedPreserved  = @($protected).Count
    bugsCreated         = @($created).Count
    noFix               = [bool]$NoFix
    issues              = @($findings)
    protected           = @($protected)
    created             = @($created)
}
