# VersionTag: 2605.B5.V46.0
<#
.SYNOPSIS
    Scan files for committed private key material and known secret markers.
.DESCRIPTION
    Reads supplied files (typically staged git files) and fails when PEM private
    key headers are detected. Intended for pre-commit and CI defensive gating.
.PARAMETER IncludeFiles
    Relative file paths to scan.
.PARAMETER RepoRoot
    Repository root path used to resolve relative file paths.
.PARAMETER FailOnFindings
    Return exit code 1 when any finding is detected.
#>
[CmdletBinding()]
param(
    [string[]]$IncludeFiles = @(),
    [string]$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path,
    [switch]$FailOnFindings
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$privateKeyPattern = '(?im)^-----BEGIN\s+(?:RSA\s+PRIVATE\s+KEY|EC\s+PRIVATE\s+KEY|PRIVATE\s+KEY)-----\s*$'
$blockedExtPattern = '(?i)\.key$'
$allowedFixturePattern = '(?i)^(tests[\\/].*fixtures[\\/]|tests[\\/].*samples[\\/])'

$findings = New-Object System.Collections.ArrayList

foreach ($rel in @($IncludeFiles)) {
    if ([string]::IsNullOrWhiteSpace($rel)) { continue }

    $normRel = $rel.Replace('/', '\')
    $full = Join-Path $RepoRoot $normRel
    $resolvedFull = try { [System.IO.Path]::GetFullPath($full) } catch { $null }
    if ($null -eq $resolvedFull) { continue }

    $resolvedRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    if (-not $resolvedFull.StartsWith($resolvedRoot)) { continue }
    if (-not (Test-Path -LiteralPath $resolvedFull -PathType Leaf)) { continue }

    $relPosix = $normRel.Replace('\', '/')
    if ($relPosix -match $allowedFixturePattern) { continue }

    $content = ''
    try {
        $content = Get-Content -LiteralPath $resolvedFull -Raw -Encoding UTF8
    } catch {
        continue
    }

    $hasPemPrivateKey = $content -match $privateKeyPattern
    $isBlockedKeyFile = $relPosix -match $blockedExtPattern

    if ($hasPemPrivateKey -or $isBlockedKeyFile) {
        $reason = if ($hasPemPrivateKey) { 'PEM private key header detected' } else { '.key file committed' }
        $null = $findings.Add([pscustomobject]@{
            path = $relPosix
            reason = $reason
        })
    }
}

if (@($findings).Count -gt 0) {
    Write-Host ('[secret-scan] findings=' + @($findings).Count) -ForegroundColor Red
    foreach ($item in $findings) {
        Write-Host ('  - ' + $item.path + ' :: ' + $item.reason) -ForegroundColor Yellow
    }
    if ($FailOnFindings) {
        exit 1
    }
}

Write-Host '[secret-scan] no blocked private key material detected' -ForegroundColor Green
exit 0
