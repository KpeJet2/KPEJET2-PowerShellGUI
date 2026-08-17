# VersionTag: 2608.B1.V54.6
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-08-17
# SupportsPS7.6TestedDate: 2026-08-17
# FileRole: SecurityRemediation
#Requires -Version 5.1
<#!
.SYNOPSIS
    Creates bounded P015 hardcoded-path remediation proposals.
.DESCRIPTION
    Reads SIN scanner output and proposes workspace/user/environment substitutions.
    Default mode is report-only. ApplySafe changes only exact standalone workspace-root
    string literals in files that already expose WorkspacePath or PSScriptRoot.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$ScanJson = '',
    [string]$OutputJson = '',
    [switch]$ApplySafe,
    [string]$BackupRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $WorkspacePath).Path
if ([string]::IsNullOrWhiteSpace($ScanJson)) {
    $ScanJson = Join-Path (Join-Path $root 'temp') 'sin-scan-results.json'
}
if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $OutputJson = Join-Path (Join-Path $root 'reports') 'sin-hardcoded-path-remediation.json'
}
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path (Join-Path $root 'temp') 'sin-p015-backups'
}

if (-not (Test-Path -LiteralPath $ScanJson)) {
    throw ('SIN scan result not found: ' + $ScanJson)
}

$outDir = Split-Path -Parent $OutputJson
if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
if ($ApplySafe -and -not (Test-Path -LiteralPath $BackupRoot)) { $null = New-Item -ItemType Directory -Path $BackupRoot -Force }

$scan = Get-Content -LiteralPath $ScanJson -Raw -Encoding UTF8 | ConvertFrom-Json
$findings = @($scan.findings | Where-Object { [string]$_.sinId -like 'SIN-PATTERN-015*' })
$proposals = New-Object System.Collections.Generic.List[object]
$changedFiles = New-Object System.Collections.Generic.HashSet[string]

foreach ($finding in $findings) {
    $relative = [string]$finding.file
    if ([string]::IsNullOrWhiteSpace($relative)) { continue }
    $relative = $relative -replace 'psm1$', '.psm1'
    $relative = $relative -replace 'ps1$', '.ps1'
    $path = if ([System.IO.Path]::IsPathRooted($relative)) { $relative } else { Join-Path $root ($relative -replace '/', '\') }
    if (-not (Test-Path -LiteralPath $path)) { continue }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $hasWorkspaceContract = $raw -match '\$WorkspacePath|\$PSScriptRoot'
    $rootPattern = [regex]::Escape($root.TrimEnd('\'))
    $singlePattern = "'(?<value>$rootPattern)(?<tail>\\[^']*)?'"
    $doublePattern = '"(?<value>' + $rootPattern + ')(?<tail>\\[^"]*)?"'
    $match = [regex]::Match($raw, $singlePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        $match = [regex]::Match($raw, $doublePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    if (-not $match.Success) { continue }

    $tail = [string]$match.Groups['tail'].Value
    $replacement = if ([string]::IsNullOrWhiteSpace($tail)) { '$WorkspacePath' } else { '(Join-Path $WorkspacePath ' + [string][char]39 + $tail.TrimStart('\') + [string][char]39 + ')' }
    $safe = $hasWorkspaceContract
    $proposals.Add([ordered]@{
            sinId       = [string]$finding.sinId
            file        = $relative
            line        = [int]$finding.line
            old         = $match.Value
            replacement = $replacement
            safeToApply = $safe
            reason      = if ($safe) { 'File already exposes WorkspacePath or PSScriptRoot.' } else { 'Needs manual context review before replacement.' }
        }) | Out-Null

    if ($ApplySafe -and $safe -and $match.Groups['tail'].Length -eq 0) {
        if (-not $changedFiles.Contains($path)) {
            $backupPath = Join-Path $BackupRoot (($relative -replace '[\\/]', '__') + '.bak')
            Copy-Item -LiteralPath $path -Destination $backupPath -Force
            $newRaw = $raw.Replace($match.Value, '$WorkspacePath')
            Set-Content -LiteralPath $path -Value $newRaw -Encoding UTF8
            [void]$changedFiles.Add($path)
        }
    }
}

$result = @{}
$result['generatedAtUtc'] = (Get-Date).ToUniversalTime().ToString('o')
$result['workspacePath'] = $root
$result['scanJson'] = $ScanJson
$result['applySafe'] = [bool]$ApplySafe
$result['backupRoot'] = $BackupRoot
$proposalArray = @($proposals.ToArray())
$changedFileArray = @($changedFiles)
$result['proposalCount'] = $proposalArray.Count
$result['changedFileCount'] = $changedFileArray.Count
$result['proposals'] = @($proposals | ForEach-Object { $_ })
$result['changedFiles'] = @($changedFiles | ForEach-Object { $_ })
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
return [PSCustomObject]$result
