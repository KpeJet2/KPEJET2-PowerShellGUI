# VersionTag: 2602.a.12
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $scriptRootPath = Split-Path -Parent $MyInvocation.MyCommand.Path
    $WorkspacePath = Split-Path -Parent $scriptRootPath
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $WorkspacePath '~REPORTS'
}

if (-not (Test-Path $ReportPath)) {
    New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
}

$configPath = Join-Path $WorkspacePath 'config\system-variables.xml'
$exclusions = @()

if (Test-Path $configPath) {
    try {
        [xml]$configXml = Get-Content -Path $configPath -Raw
        $exclusions = @($configXml.Settings.VersionTagging.'Do-Not-VersionTag-FoldersFiles'.Item)
    } catch {
        Write-Warning "Failed to parse exclusions from $configPath : $_"
    }
}

if ($exclusions.Count -eq 0) {
    $exclusions = @('config', 'logs', '.git')
}

$candidates = New-Object 'System.Collections.Generic.List[object]'

foreach ($exclude in $exclusions) {
    if ([string]::IsNullOrWhiteSpace($exclude)) { continue }
    if ($exclude -ieq 'logs') { continue }

    $folderPath = Join-Path $WorkspacePath $exclude
    if (-not (Test-Path $folderPath)) { continue }

    $manifests = @(Get-ChildItem -Path $folderPath -Filter *.txt -File -ErrorAction SilentlyContinue)
    foreach ($manifest in $manifests) {
        $listed = @{}
        foreach ($line in (Get-Content -Path $manifest.FullName -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^(Path,\s*\t|Version:|Generated:)') { continue }

            $relativePath = $null
            if ($line -match '^(?<path>[^,\t]+),\s*\t') {
                $relativePath = $Matches['path']
            } elseif ($line -match '^(?<path>[^\t]+)\t') {
                $relativePath = $Matches['path']
            }

            if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
                $listed[$relativePath] = $true
                $listed[(Split-Path $relativePath -Leaf)] = $true
            }
        }

        Get-ChildItem -Path $folderPath -File -ErrorAction SilentlyContinue | ForEach-Object {
            $fileName = $_.Name
            if ($fileName -like 'pwshGUI-v-*versionbuild*') { return }
            if ($manifest.FullName -eq $_.FullName) { return }

            $relativePath = Join-Path $exclude $fileName
            $relativePath = $relativePath -replace '/', '\\'

            if ($listed.ContainsKey($fileName) -or $listed.ContainsKey($relativePath)) {
                return
            }

            $candidates.Add([ordered]@{
                folder = $exclude
                fileName = $fileName
                relativePath = $relativePath
                fullPath = $_.FullName
                issue = 'not in manifest'
                sourceManifest = $manifest.FullName
                detectedAt = (Get-Date).ToString('o')
            }) | Out-Null
        }
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $ReportPath "orphan-audit-$timestamp.json"
$mdPath = Join-Path $ReportPath "orphan-audit-core-$timestamp.md"

$summary = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    workspace = $WorkspacePath
    detectionModel = 'inventory-drift'
    note = 'Potential orphan candidates are files under excluded folders that are not listed in their local manifest text files.'
    candidateCount = $candidates.Count
}

$payload = [ordered]@{
    summary = $summary
    candidates = @($candidates)
}

$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    '# Core Orphan Audit',
    '',
    "Generated: $($summary.generatedAt)",
    "Workspace: $($summary.workspace)",
    "Detection model: $($summary.detectionModel)",
    "Scope note: $($summary.note)",
    "Zero-reference candidate count: $($summary.candidateCount)",
    '',
    '## Candidates',
    ''
)

if ($candidates.Count -eq 0) {
    $lines += '| RelativePath | Issue | SourceManifest |'
    $lines += '|---|---|---|'
    $lines += '| (none) | none | n/a |'
} else {
    $lines += '| RelativePath | Issue | SourceManifest |'
    $lines += '|---|---|---|'
    foreach ($candidate in $candidates) {
        $lines += "| $($candidate.relativePath) | $($candidate.issue) | $($candidate.sourceManifest) |"
    }
}

Set-Content -Path $mdPath -Value $lines -Encoding UTF8

Write-Output "Orphan audit JSON: $jsonPath"
Write-Output "Orphan audit Markdown: $mdPath"
Write-Output "Orphan candidate count: $($candidates.Count)"
