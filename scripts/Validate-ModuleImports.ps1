# VersionTag: 2605.B2.V31.7
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-28
# SupportsPS7.6TestedDate: 2026-04-28
# FileRole: Validator
# Scans all scripts for forbidden import patterns (external/global modules)
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceRoot = $WorkspacePath
if (-not (Test-Path $workspaceRoot)) {
    throw "Workspace path does not exist: $workspaceRoot"
}

$allowedModulePath = Join-Path $workspaceRoot 'modules'
$files = @(Get-ChildItem -Path $workspaceRoot -Recurse -Include *.ps1,*.psm1 -File)
$findings = @()

foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file.FullName)) {
        continue
    }

    try {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
    } catch {
        Write-Warning "Skipping unreadable file: $($file.FullName)"
        continue
    }

    if ($content -match 'Import-Module\s+[''\"]?([a-zA-Z]:|\\\\)') {
        $findings += "External module import found in $($file.FullName)"
    }

    if ($content -match 'Import-Module\s+[^''\"\.\\]') {
        $findings += "Potential global module import found in $($file.FullName)"
    }
}

if (@($findings).Count -eq 0) {
    Write-Output "[OK] No forbidden Import-Module patterns detected."
} else {
    foreach ($finding in $findings) {
        Write-Warning $finding
    }
    Write-Output "[WARN] Findings: $(@($findings).Count)"
}

<# Outline:
    Recursively scans the workspace for .ps1/.psm1 files and emits warnings when an
    Import-Module statement targets either an absolute/UNC path (external module) or a
    bareword that is not a relative path (potential global module). Used by the pipeline
    to keep the project self-contained and reproducible.
#>

<# Problems:
    Heuristic regexes only; an obfuscated Import-Module call (variable-built path) will not
    be flagged. The module-import audit invoked from Setup-ModuleEnvironment is the source of
    truth for repo health.
#>

<# ToDo:
    Emit machine-readable JSON output (-OutputJson <path>) for pipeline ingestion.
#>



