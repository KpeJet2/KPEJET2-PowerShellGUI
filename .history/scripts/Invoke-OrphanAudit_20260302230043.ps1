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
        $exclusions = @($configXml.SystemVariables.'Do-Not-VersionTag-FoldersFiles'.Folder)
    } catch {
        Write-Warning "Failed to parse exclusions from $configPath : $_"
    }
}

if ($exclusions.Count -eq 0) {
    $exclusions = @('config', 'logs', '.git')
}

$candidates = New-Object 'System.Collections.Generic.List[object]'

function Get-ReferenceCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [string]$ReportPath,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string]$CandidateFullPath
    )

    $patterns = @()
    $patterns += [regex]::Escape($RelativePath)
    $patterns += [regex]::Escape(($RelativePath -replace '\\','/'))
    $patterns += [regex]::Escape($FileName)
    $query = ($patterns | Select-Object -Unique) -join '|'

    $textExtensions = @(
        '.ps1','.psm1','.psd1','.md','.txt','.json','.xml','.yml','.yaml',
        '.bat','.cmd','.csv','.xhtml','.html','.htm','.config','.ini'
    )

    $matchCount = 0
    $files = Get-ChildItem -Path $WorkspacePath -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $ext = $_.Extension.ToLowerInvariant()
        if ($textExtensions -notcontains $ext) { return $false }
        if ($_.FullName -like "$ReportPath\\*") { return $false }
        if ($_.FullName -like "$WorkspacePath\\.git\\*") { return $false }
        if ($_.FullName -like "$WorkspacePath\\.history\\*") { return $false }
        if ($_.FullName -like "$WorkspacePath\\scripts\\QUICK-APP\\*") { return $false }
        if ($CandidateFullPath -and $_.FullName -ieq $CandidateFullPath) { return $false }
        return $true
    }

    foreach ($file in $files) {
        try {
            $hits = Select-String -Path $file.FullName -Pattern $query -CaseSensitive:$false -AllMatches -ErrorAction SilentlyContinue
            foreach ($hit in $hits) {
                $matchCount += @($hit.Matches).Count
            }
        } catch {}
    }

    return $matchCount
}

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

$enrichedCandidates = @($candidates | ForEach-Object {
    $referenceCount = Get-ReferenceCount -WorkspacePath $WorkspacePath -ReportPath $ReportPath -RelativePath $_.relativePath -FileName $_.fileName -CandidateFullPath $_.fullPath
    [pscustomobject]@{
        folder = $_.folder
        fileName = $_.fileName
        relativePath = $_.relativePath
        fullPath = $_.fullPath
        issue = $_.issue
        sourceManifest = $_.sourceManifest
        detectedAt = $_.detectedAt
        referenceCount = $referenceCount
        zeroReferenceCandidate = ($referenceCount -eq 0)
    }
})

$zeroReferenceCount = @($enrichedCandidates | Where-Object { $_.zeroReferenceCandidate }).Count

$summary = [pscustomobject]@{
    generatedAt = (Get-Date).ToString('o')
    workspace = $WorkspacePath
    detectionModel = 'inventory-drift+reference-scan'
    note = 'Potential orphan candidates are files under excluded folders not listed in local manifest text files; referenceCount is measured across workspace text files excluding report outputs.'
    candidateCount = $candidates.Count
    zeroReferenceCandidateCount = $zeroReferenceCount
}

$payload = [pscustomobject]@{
    summary = $summary
    candidates = $enrichedCandidates
}

$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    '# Core Orphan Audit',
    '',
    "Generated: $($summary.generatedAt)",
    "Workspace: $($summary.workspace)",
    "Detection model: $($summary.detectionModel)",
    "Scope note: $($summary.note)",
    "Candidate count: $($summary.candidateCount)",
    "Zero-reference candidate count: $($summary.zeroReferenceCandidateCount)",
    '',
    '## Candidates',
    ''
)

if ($enrichedCandidates.Count -eq 0) {
    $lines += '| RelativePath | Issue | SourceManifest | ReferenceCount | ZeroReference |'
    $lines += '|---|---|---|---:|---|'
    $lines += '| (none) | none | n/a | 0 | true |'
} else {
    $lines += '| RelativePath | Issue | SourceManifest | ReferenceCount | ZeroReference |'
    $lines += '|---|---|---|---:|---|'
    foreach ($candidate in $enrichedCandidates) {
        $lines += "| $($candidate.relativePath) | $($candidate.issue) | $($candidate.sourceManifest) | $($candidate.referenceCount) | $($candidate.zeroReferenceCandidate) |"
    }
}

Set-Content -Path $mdPath -Value $lines -Encoding UTF8

Write-Output "Orphan audit JSON: $jsonPath"
Write-Output "Orphan audit Markdown: $mdPath"
Write-Output "Orphan candidate count: $($candidates.Count)"
