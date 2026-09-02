# VersionTag: 2608.B0.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: Pipeline Configuration Generator
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$WorkspacePath,
    [Parameter(Mandatory)] [string]$FindingsPath,
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspaceFull = [System.IO.Path]::GetFullPath($WorkspacePath)
if (-not (Test-Path -LiteralPath $FindingsPath -PathType Leaf)) { throw "Findings report not found: $FindingsPath" }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Join-Path $workspaceFull 'config') 'deanb-solution-map.json'
}

$payload = Get-Content -LiteralPath $FindingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$findings = if ($payload.PSObject.Properties.Name -contains 'findings') { @($payload.findings) } else { @($payload) }
$sha = [System.Security.Cryptography.SHA256]::Create()
$entries = [System.Collections.ArrayList]::new()
$findingIndex = 0

foreach ($finding in $findings) {
    $findingIndex++
    $category = if ($finding.PSObject.Properties.Name -contains 'category') { [string]$finding.category } else { 'UNKNOWN' }
    $subType = if ($finding.PSObject.Properties.Name -contains 'subType') { [string]$finding.subType } else { '' }
    $file = if ($finding.PSObject.Properties.Name -contains 'file') { [string]$finding.file } else { [string]$finding.path }
    $detail = if ($finding.PSObject.Properties.Name -contains 'detail') { [string]$finding.detail } else { '' }
    $functionName = if ($finding.PSObject.Properties.Name -contains 'functionName') { [string]$finding.functionName } else { '' }
    $canonical = ('{0}|{1}|{2}|{3}|{4}|{5}' -f $findingIndex, $category, $subType, $file, $functionName, $detail)
    $fingerprint = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-', '').ToLowerInvariant()

    if ($category -eq 'MANIFEST' -and $subType -eq 'unexported') {
        $route = 'ManifestExportReview'
        $action = "Review public API intent, add '$functionName' to FunctionsToExport when approved, then run parser and manifest export verification."
        $automated = $false
        $escalation = 'manual-review'
    } elseif ($category -eq 'LAUNCHBAT') {
        $route = 'LauncherPathReview'
        $action = 'Resolve the launcher reference relative to the batch file, validate the target exists, then run the launcher smoke test. Do not rewrite user-tuned launchers automatically.'
        $automated = $false
        $escalation = 'launcher-owner-review'
    } else {
        $route = 'DeanBManualTriage'
        $action = 'Normalize the finding, identify a bounded owner route, apply one change, and rerun parse plus the originating gate.'
        $automated = $false
        $escalation = 'manual-triage'
    }

    $null = $entries.Add([ordered]@{
        findingIndex = $findingIndex
        solutionId = ('DEANB-SOLUTION-' + $findingIndex.ToString('000') + '-' + $fingerprint.Substring(0, 12).ToUpperInvariant())
        fingerprint = $fingerprint
        category = $category
        subType = $subType
        severity = if ($finding.PSObject.Properties.Name -contains 'severity') { [string]$finding.severity } else { 'UNKNOWN' }
        file = $file
        functionName = $functionName
        detail = $detail
        route = $route
        action = $action
        automated = $automated
        maxAttempts = 3
        escalation = $escalation
        verification = @('PowerShell parser', 'originating interop gate', 'SIN scan when available')
    })
}

$routeCounts = @($entries | Group-Object { $_['route'] } | ForEach-Object { [ordered]@{ route = $_.Name; count = $_.Count } })
$map = [ordered]@{
    VersionTag = '2608.B0.V53.0'
    schema = 'DeanB-SolutionMap/1.0'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    generatedFrom = [System.IO.Path]::GetFullPath($FindingsPath)
    findingCount = @($entries).Count
    routeCounts = $routeCounts
    entries = @($entries)
}
$map | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output ("Generated {0} DeanB solution entries at {1}." -f $map.findingCount, $OutputPath)