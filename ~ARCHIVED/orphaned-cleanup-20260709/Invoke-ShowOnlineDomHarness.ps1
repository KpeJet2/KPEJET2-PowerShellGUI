# VersionTag: 2606.B5.V51.4
# SupportPS5.1: true
# SupportsPS7.6: true

[CmdletBinding()]
param(
    [Parameter()]
    [string]$PagePath = '',

    [Parameter()]
    [switch]$EmitJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PagePath)) {
    $scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    } else {
        $PSScriptRoot
    }
    $pageDir = Join-Path $scriptRoot '..\\~README.md'
    $PagePath = Join-Path $pageDir 'PwShGUI-Checklists-ShowOnline.xhtml'
}

$script:Checks = @()

function Add-CheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Pass,

        [Parameter()]
        [string]$Detail = ''
    )

    $entry = [pscustomobject]@{
        Name   = $Name
        Pass   = $Pass
        Detail = $Detail
    }
    $script:Checks += $entry

    if ($Pass) {
        Write-Host ("[PASS] {0}" -f $Name) -ForegroundColor Green
    } else {
        $suffix = if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { ': ' + $Detail }
        Write-Host ("[FAIL] {0}{1}" -f $Name, $suffix) -ForegroundColor Red
    }
}

function Get-FunctionBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$FunctionName
    )

    $pattern = 'function\s+' + [regex]::Escape($FunctionName) + '\s*\([^\)]*\)\s*\{'
    $match = [regex]::Match($Source, $pattern)
    if (-not $match.Success) { return $null }

    $depth = 1
    $index = $match.Index + $match.Length
    while ($index -lt $Source.Length -and $depth -gt 0) {
        $char = $Source[$index]
        if ($char -eq '{') {
            $depth++
        } elseif ($char -eq '}') {
            $depth--
        }
        $index++
    }

    if ($depth -ne 0) { return $null }
    return $Source.Substring($match.Index, $index - $match.Index)
}

function Test-FunctionFragments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$FunctionName,

        [Parameter(Mandatory)]
        [string[]]$RequiredFragments
    )

    $body = Get-FunctionBody -Source $Source -FunctionName $FunctionName
    Add-CheckResult -Name ("Function exists: {0}" -f $FunctionName) -Pass ($null -ne $body) -Detail ("Missing function: {0}" -f $FunctionName)
    if ($null -eq $body) { return }

    foreach ($fragment in @($RequiredFragments)) {
        $present = $body.IndexOf($fragment, [System.StringComparison]::Ordinal) -ge 0
        Add-CheckResult -Name ("{0} contains fragment: {1}" -f $FunctionName, $fragment) -Pass $present -Detail 'Expected transition logic was not found.'
    }
}

if (-not (Test-Path -LiteralPath $PagePath -PathType Leaf)) {
    throw "ShowOnline page was not found: $PagePath"
}

$resolvedPagePath = (Resolve-Path -LiteralPath $PagePath).Path
$content = Get-Content -LiteralPath $resolvedPagePath -Raw -Encoding UTF8

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.XmlResolver = $null
$xmlLoaded = $false
try {
    $xmlDoc.LoadXml($content)
    $xmlLoaded = $true
    Add-CheckResult -Name 'XHTML parse' -Pass $true
} catch {
    Add-CheckResult -Name 'XHTML parse' -Pass $false -Detail $_.Exception.Message
}

if (-not $xmlLoaded) {
    $failedEarly = @($script:Checks | Where-Object { -not $_.Pass })
    if ($EmitJson) {
        [pscustomobject]@{
            harness     = 'Invoke-ShowOnlineDomHarness'
            versionTag  = '2605.B5.V50.1'
            engine      = $PSVersionTable.PSVersion.ToString()
            pagePath    = $resolvedPagePath
            checkCount  = @($script:Checks).Count
            failedCount = @($failedEarly).Count
            passed      = $false
            checks      = $script:Checks
        } | ConvertTo-Json -Depth 7
    }
    exit 1
}

$requiredIds = @(
    'so-hover-tooltip',
    'dd-blade-btn',
    'dd-blade',
    'dd-blade-health',
    'dd-health-overview',
    'dd-health-tree',
    'dd-health-remedies',
    'ftModeSummary',
    'ftLiveSummary',
    'ftLiveWebCluster8099',
    'ftLiveTrayMonitor'
)

foreach ($id in $requiredIds) {
    $node = $xmlDoc.SelectSingleNode("//*[@id='$id']")
    Add-CheckResult -Name ("DOM id exists: {0}" -f $id) -Pass ($null -ne $node) -Detail ("Missing element id '{0}'" -f $id)
}

$baselineSet = $xmlDoc.SelectSingleNode("//*[local-name()='button' and @onclick='setMetricBaseline()']")
$baselineClear = $xmlDoc.SelectSingleNode("//*[local-name()='button' and @onclick='clearMetricBaseline()']")
Add-CheckResult -Name 'Baseline button exists' -Pass ($null -ne $baselineSet) -Detail 'Missing setMetricBaseline() control.'
Add-CheckResult -Name 'Clear baseline button exists' -Pass ($null -ne $baselineClear) -Detail 'Missing clearMetricBaseline() control.'

$firstInlineScriptIndex = $content.IndexOf('<script type="text/javascript">')
if ($firstInlineScriptIndex -gt 0) {
    $markupOnly = $content.Substring(0, $firstInlineScriptIndex)
    $inlineStyleCount = [regex]::Matches($markupOnly, 'style="').Count
    Add-CheckResult -Name 'Static markup inline-style count' -Pass ($inlineStyleCount -eq 0) -Detail ("Found {0} inline style attribute(s) before script block." -f $inlineStyleCount)
}

Test-FunctionFragments -Source $content -FunctionName 'setupTabHoverTooltips' -RequiredFragments @(
    "querySelectorAll('.tabs button')",
    "setAttribute('data-tab-id'",
    "addEventListener('mouseenter'",
    "addEventListener('mouseleave'",
    "addEventListener('focus'",
    "addEventListener('blur'"
)

Test-FunctionFragments -Source $content -FunctionName '_so_getValidationPolicy' -RequiredFragments @(
    'ignoreLiveChecks',
    'preferCachedState',
    'suppressTransientErrors',
    'OFFLINE_CACHED',
    'STATIC',
    'TESTING'
)

Test-FunctionFragments -Source $content -FunctionName '_so_refreshFooterRefTooltips' -RequiredFragments @(
    'Ctrl+Alt+Click: open folder/location',
    'ignoreLiveChecks',
    "querySelectorAll('footer .ft-state')",
    "setAttribute('title'"
)

Test-FunctionFragments -Source $content -FunctionName '_so_probeWebCluster8099' -RequiredFragments @(
    'http://127.0.0.1:8099/health',
    'ftLiveWebCluster8099',
    '_so_setServiceState('
)

Test-FunctionFragments -Source $content -FunctionName 'refreshAllShowOnline' -RequiredFragments @(
    'ftLiveSummary',
    'ftLiveTrayMonitor',
    '_so_probeWebCluster8099(',
    '_so_updateDataSourceMode('
)

Test-FunctionFragments -Source $content -FunctionName '_so_showTooltipForTab' -RequiredFragments @(
    "_so_buildTooltipHtml(",
    "classList.remove('hidden')",
    "_so_placeTooltip("
)

Test-FunctionFragments -Source $content -FunctionName '_so_hideTooltip' -RequiredFragments @(
    "classList.add('hidden')"
)

Test-FunctionFragments -Source $content -FunctionName '_so_renderHealthPanel' -RequiredFragments @(
    "dd-health-overview",
    "dd-health-tree",
    "dd-health-remedies",
    "Recommended Remediation Commands"
)

Test-FunctionFragments -Source $content -FunctionName '_so_refreshFooterLegendMetrics' -RequiredFragments @(
    '_so_getValidationPolicy()',
    'policy.ignoreLiveChecks',
    'rows[r].isLiveOnly',
    'live ignored'
)

Test-FunctionFragments -Source $content -FunctionName '_wsManifestEntries' -RequiredFragments @(
    'arr[i].file || arr[i].path || arr[i].name',
    'arr[i].versionTag || arr[i].VersionTag || arr[i].version || arr[i].Version'
)

Test-FunctionFragments -Source $content -FunctionName 'loadScriptVersions' -RequiredFragments @(
    'e.file || e.path || e.name',
    'e.versionTag || e.VersionTag || e.version || e.Version',
    "_wsStaticRowsHtml = ''"
)

Test-FunctionFragments -Source $content -FunctionName 'showTab' -RequiredFragments @(
    "id === 'workspace-scripts'",
    'loadScriptVersions()'
)

Test-FunctionFragments -Source $content -FunctionName '_metricSaveBaseline' -RequiredFragments @(
    "localStorage.setItem("
)

Test-FunctionFragments -Source $content -FunctionName '_metricBuildChecks' -RequiredFragments @(
    "label: 'Pipeline'",
    "label: 'Scripts'",
    "label: 'Agents'",
    "label: 'Scan Tools'",
    "label: 'Items2Do'",
    "label: 'Bugs2FIX'",
    "label: 'Feature2ADD'"
)

Test-FunctionFragments -Source $content -FunctionName 'setMetricBaseline' -RequiredFragments @(
    '_metricBuildChecks(',
    "_metricSaveBaseline(",
    "renderDataDashboard("
)

Test-FunctionFragments -Source $content -FunctionName 'clearMetricBaseline' -RequiredFragments @(
    "localStorage.removeItem(",
    "renderDataDashboard("
)

Test-FunctionFragments -Source $content -FunctionName '_renderMetricIntegrity' -RequiredFragments @(
    '_metricBuildChecks(',
    'title="',
    'Integrity Totals',
    'Baseline'
)

Test-FunctionFragments -Source $content -FunctionName 'toggleDDBlade' -RequiredFragments @(
    "classList.contains('hidden')",
    "classList.remove('hidden')",
    "classList.add('hidden')"
)

Test-FunctionFragments -Source $content -FunctionName 'showBladeTab' -RequiredFragments @(
    "dd-blade-panel",
    "dd-blade-tab",
    "active"
)

$failed = @($script:Checks | Where-Object { -not $_.Pass })
$summary = [pscustomobject]@{
    harness      = 'Invoke-ShowOnlineDomHarness'
    versionTag   = '2605.B5.V50.1'
    timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    engine       = $PSVersionTable.PSVersion.ToString()
    pagePath     = $resolvedPagePath
    checkCount   = @($script:Checks).Count
    failedCount  = @($failed).Count
    passed       = (@($failed).Count -eq 0)
    checks       = $script:Checks
}

if ($EmitJson) {
    $summary | ConvertTo-Json -Depth 7
} else {
    $resultText = if ($summary.passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('--- ShowOnline DOM Harness Summary ---') -ForegroundColor Cyan
    Write-Host ("Engine: {0}" -f $summary.engine)
    Write-Host ("Checks: {0}" -f $summary.checkCount)
    Write-Host ("Failed: {0}" -f $summary.failedCount)
    Write-Host ("Result: {0}" -f $resultText)
}

if (-not $summary.passed) {
    exit 1
}


