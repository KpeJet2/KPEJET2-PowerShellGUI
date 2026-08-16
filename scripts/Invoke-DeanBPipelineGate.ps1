# VersionTag: 2608.B0.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: Pipeline Gate
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    [Parameter(Mandatory)]
    [string]$FindingsPath,
    [int]$Iteration = 1,
    [ValidateRange(1, 7)]
    [int]$BatchSize = 7,
    [switch]$NoFix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceFull = [System.IO.Path]::GetFullPath($WorkspacePath)
if (-not (Test-Path -LiteralPath $workspaceFull -PathType Container)) {
    throw "Workspace path does not exist: $WorkspacePath"
}
if (-not (Test-Path -LiteralPath $FindingsPath -PathType Leaf)) {
    throw "Findings path does not exist: $FindingsPath"
}

$pipelineModule = Join-Path (Join-Path $workspaceFull 'modules') 'CronAiAthon-Pipeline.psm1'
$gateScript = Join-Path $workspaceFull 'scripts\Invoke-AutoCorrectGate.ps1'
if (-not (Test-Path -LiteralPath $pipelineModule)) { throw "Pipeline module not found: $pipelineModule" }
if (-not (Test-Path -LiteralPath $gateScript)) { throw "AutoCorrect gate script not found: $gateScript" }

Import-Module $pipelineModule -Force -DisableNameChecking -ErrorAction Stop
$payload = Get-Content -LiteralPath $FindingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$findings = if ($payload.PSObject.Properties.Name -contains 'findings') { @($payload.findings) } else { @($payload) }
$registryPath = Join-Path (Join-Path $workspaceFull 'config') 'cron-aiathon-pipeline.json'
$registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$existing = @($registry.bugs2FIX)
$solutionMapPath = Join-Path (Join-Path $workspaceFull 'config') 'deanb-solution-map.json'
$solutionMap = $null
if (Test-Path -LiteralPath $solutionMapPath -PathType Leaf) {
    $solutionMap = Get-Content -LiteralPath $solutionMapPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
}

$eligible = @($findings | Where-Object {
        $path = if ($_.PSObject.Properties.Name -contains 'file') { [string]$_.file } else { [string]$_.path }
        -not [string]::IsNullOrWhiteSpace($path) -and
        ([System.IO.Path]::GetExtension($path) -in @('.ps1', '.psm1', '.psd1'))
    })
$selected = @($eligible | Select-Object -First $BatchSize)
$created = [System.Collections.ArrayList]::new()
$skipped = [System.Collections.ArrayList]::new()
$gateItems = [System.Collections.ArrayList]::new()
$gateFindings = [System.Collections.ArrayList]::new()

foreach ($finding in $selected) {
    $path = if ($finding.PSObject.Properties.Name -contains 'file') { [string]$finding.file } else { [string]$finding.path }
    $fullPath = if ([System.IO.Path]::IsPathRooted($path)) { [System.IO.Path]::GetFullPath($path) } else { [System.IO.Path]::GetFullPath((Join-Path $workspaceFull $path)) }
    $relativePath = $fullPath.Substring($workspaceFull.Length).TrimStart('\', '/')
    $category = if ($finding.PSObject.Properties.Name -contains 'category') { [string]$finding.category } else { 'DEANB' }
    $detail = if ($finding.PSObject.Properties.Name -contains 'detail') { [string]$finding.detail } else { 'Unresolved pipeline finding' }
    $functionName = if ($finding.PSObject.Properties.Name -contains 'functionName') { [string]$finding.functionName } else { '' }
    $findingSubType = if ($finding.PSObject.Properties.Name -contains 'subType') { [string]$finding.subType } else { '' }
    $solution = $null
    if ($null -ne $solutionMap) {
        $solution = @($solutionMap.entries | Where-Object {
            $_.category -eq $category -and $_.subType -eq $findingSubType -and $_.file -eq $path -and $_.functionName -eq $functionName -and $_.detail -eq $detail
            } | Select-Object -First 1)
        if (@($solution).Count -gt 0) { $solution = $solution[0] }
    }
    $key = ('DEANB:{0}:{1}' -f $category, $relativePath).ToLowerInvariant()
    $duplicate = @($existing | Where-Object {
            $notes = if ($_.PSObject.Properties.Name -contains 'notes') { [string]$_.notes } else { '' }
            $affected = if ($_.PSObject.Properties.Name -contains 'affectedFiles') { @($_.affectedFiles) } else { @() }
            $status = if ($_.PSObject.Properties.Name -contains 'status') { [string]$_.status } else { 'OPEN' }
            ($notes -like "*$key*") -or (($affected -contains $fullPath) -and $status -notin @('DONE', 'CLOSED'))
        }).Count -gt 0
    if ($duplicate) {
        $null = $skipped.Add([pscustomobject]@{ path = $relativePath; reason = 'existing-active-fix-item' })
        continue
    }

    $item = New-PipelineItem -Type 'Bugs2FIX' -Title ("DeanB: {0} - {1}" -f $category, ([System.IO.Path]::GetFileName($fullPath))) -Description $detail -Priority 'HIGH' -Source 'SinRegistry' -Category 'DeanB' -AffectedFiles @($fullPath) -SuggestedBy 'DeanB' -SinPattern $category
    $itemHash = @{}
    foreach ($property in $item.Keys) { $itemHash[$property] = $item[$property] }
    $itemHash['notes'] = $key
    if ($null -ne $solution) {
        $itemHash['solutionId'] = [string]$solution.solutionId
        $itemHash['solutionRoute'] = [string]$solution.route
        $itemHash['solutionAction'] = [string]$solution.action
        $itemHash['solutionMaxAttempts'] = [int]$solution.maxAttempts
    }
    if (-not $NoFix) {
        $null = Add-PipelineItem -WorkspacePath $workspaceFull -Item $itemHash -SkipArtifactRefresh
    }
    $existing += [pscustomobject]$itemHash
    $null = $created.Add([pscustomobject]@{ id = $itemHash.id; path = $relativePath; category = $category; key = $key; solutionId = if ($null -ne $solution) { $solution.solutionId } else { '' }; solutionRoute = if ($null -ne $solution) { $solution.route } else { 'UNMAPPED' }; mode = if ($NoFix) { 'WHATIF' } else { 'CREATED' } })
    $null = $gateItems.Add([pscustomobject]@{ path = $fullPath; gate = $category; severity = if ($finding.PSObject.Properties.Name -contains 'severity') { [string]$finding.severity } else { 'HIGH' }; message = $detail })
    $null = $gateFindings.Add($finding)
}

$gateResult = $null
if (-not $NoFix -and @($gateItems).Count -gt 0) {
    $batchPath = Join-Path (Join-Path $workspaceFull 'temp') ('deanb-gate-batch-iter{0}.json' -f $Iteration)
    [pscustomobject]@{ findings = @($gateFindings) } | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $batchPath -Encoding UTF8 -Force
    $gateResult = & $gateScript -WorkspacePath $workspaceFull -ReportJson $batchPath -Scope 'SpecificFocus' -FocusTargets @($gateItems.path) -MaxAttempts 1 2>&1 | Select-Object -Last 1
}

[pscustomobject][ordered]@{
    stage            = 'Digital Effluence and nauance blender'
    gate             = 'DeanB'
    iteration        = $Iteration
    batchSize        = $BatchSize
    eligibleFindings = @($eligible).Count
    selectedFindings = @($selected).Count
    createdFixItems  = @($created).Count
    skippedExisting  = @($skipped).Count
    gateInvoked      = (-not $NoFix -and @($gateItems).Count -gt 0)
    gateResult       = $gateResult
    created          = @($created)
    skipped          = @($skipped)
    solutionMapPath  = $solutionMapPath
    mappedSelected   = @($created | Where-Object { $_.solutionRoute -ne 'UNMAPPED' }).Count
    unmappedSelected = @($created | Where-Object { $_.solutionRoute -eq 'UNMAPPED' }).Count
    stopReason       = if (@($created).Count -eq 0) { 'NO_NEW_FIX_ITEMS' } else { '' }
}
