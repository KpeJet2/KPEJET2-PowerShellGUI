# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    Validates canonical docs/XHTML/link integrity for PowerShellGUI.

.DESCRIPTION
    Performs a focused integrity pass over canonical documentation and XHTML
    assets:
      - PowerShell parse checks for key orchestration scripts
      - Strict XML checks for key XHTML pages
      - Local link existence checks for help/index pages
      - Canonical file-location checks for dependency visualisation

.PARAMETER RootPath
    Workspace root path. Defaults to C:\PowerShellGUI.

.PARAMETER Strict
    If set, exits with code 1 when any FAIL result is found.

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 05 Mar 2026
    Modified : 05 Mar 2026
#>

[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Result {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param(
        [ValidateSet('PASS','FAIL','WARN','INFO')]
        [string]$Status,
        [string]$Check,
        [string]$Target,
        [string]$Detail
    )
    $results.Add([pscustomobject]@{
        Time   = Get-Date
        Status = $Status
        Check  = $Check
        Target = $Target
        Detail = $Detail
    }) | Out-Null
}

function Test-Parse {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Add-Result -Status 'FAIL' -Check 'Parse' -Target $Path -Detail 'File missing'
        return
    }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        # Main-GUI can parse differently between Windows PowerShell 5.1 and pwsh
        # due newer syntax/features used in current workspace runtime.
        if ((Split-Path $Path -Leaf) -ieq 'Main-GUI.ps1') {
            $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
            if ($pwsh) {
                $checkCmd = "`$t=`$null;`$e=`$null;[void][System.Management.Automation.Language.Parser]::ParseFile('$Path',[ref]`$t,[ref]`$e); if(`$e -and `$e.Count -gt 0){exit 1}else{exit 0}"
                & $pwsh.Path -NoProfile -Command $checkCmd
                if ($LASTEXITCODE -eq 0) {
                    Add-Result -Status 'WARN' -Check 'Parse' -Target $Path -Detail ('Host parse mismatch: {0}; pwsh parse OK' -f $errors[0].Message)
                    return
                }
            }
        }
        Add-Result -Status 'FAIL' -Check 'Parse' -Target $Path -Detail $errors[0].Message  # SIN-EXEMPT: P027 - $errors[0] only accessed inside parse-fail condition block
    } else {
        Add-Result -Status 'PASS' -Check 'Parse' -Target $Path -Detail 'No parse errors'
    }
}

function Test-XhtmlXml {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Add-Result -Status 'FAIL' -Check 'XhtmlXml' -Target $Path -Detail 'File missing'
        return
    }
    try {
        [xml](Get-Content -Path $Path -Raw -ErrorAction Stop) | Out-Null
        Add-Result -Status 'PASS' -Check 'XhtmlXml' -Target $Path -Detail 'Strict XML parse OK'
    } catch {
        Add-Result -Status 'FAIL' -Check 'XhtmlXml' -Target $Path -Detail $_.Exception.Message
    }
}

function Test-LocalHrefLinks {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Add-Result -Status 'FAIL' -Check 'Links' -Target $Path -Detail 'File missing'
        return
    }
    $base = Split-Path -Parent $Path
    $raw = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw) {
        Add-Result -Status 'FAIL' -Check 'Links' -Target $Path -Detail 'Could not read file'
        return
    }

    $hrefs = [regex]::Matches($raw, 'href\s*=\s*"([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object {
            $_ -notmatch '^(https?:|#|javascript:)' -and
            $_ -notmatch "[\{\}\+\$]" -and
            $_ -notmatch "'\s*\+"
        }

    if (-not $hrefs -or $hrefs.Count -eq 0) {
        Add-Result -Status 'WARN' -Check 'Links' -Target $Path -Detail 'No local href links found'
        return
    }

    foreach ($href in $hrefs) {
        $resolved = [System.IO.Path]::GetFullPath((Join-Path $base $href))
        if (Test-Path $resolved) {
            Add-Result -Status 'PASS' -Check 'Links' -Target $Path -Detail "OK: $href"
        } else {
            Add-Result -Status 'FAIL' -Check 'Links' -Target $Path -Detail "Missing target: $href"
        }
    }
}

$mainGui = Join-Path $RootPath 'Main-GUI.ps1'
$depScript = Join-Path $RootPath 'scripts\Invoke-ScriptDependencyMatrix.ps1'
$helpIndex = Join-Path $RootPath '~README.md\PwShGUI-Help-Index.html'
$depCanonical = Join-Path $RootPath '~README.md\Dependency-Visualisation.html'
$featureXhtml = Join-Path $RootPath 'scripts\XHTML-Checker\XHTML-FeatureRequests.xhtml'
$analysisXhtml = Join-Path $RootPath 'scripts\XHTML-Checker\XHTML-code-analysis.xhtml'
$legacyDep = Join-Path $RootPath 'scripts\XHTML-Checker\Dependency-Visualisation.xhtml'

# Script parse checks
Test-Parse -Path $mainGui
Test-Parse -Path $depScript

# Canonical file-location checks
if (Test-Path $depCanonical) {
    Add-Result -Status 'PASS' -Check 'CanonicalPath' -Target $depCanonical -Detail 'Canonical dependency visualisation exists'
} else {
    Add-Result -Status 'FAIL' -Check 'CanonicalPath' -Target $depCanonical -Detail 'Missing canonical dependency visualisation'
}

if (Test-Path $legacyDep) {
    Add-Result -Status 'WARN' -Check 'LegacyPath' -Target $legacyDep -Detail 'Legacy dependency visualisation still present'
} else {
    Add-Result -Status 'PASS' -Check 'LegacyPath' -Target $legacyDep -Detail 'Legacy dependency visualisation absent'
}

# XHTML strict XML checks
Test-XhtmlXml -Path $analysisXhtml
Test-XhtmlXml -Path $featureXhtml

# Link integrity checks
Test-LocalHrefLinks -Path $helpIndex
Test-LocalHrefLinks -Path $featureXhtml

# Check all active XHTML files for XML validity
Get-ChildItem -Path $RootPath -Recurse -File -Filter *.xhtml -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notlike '*\.history\*' -and
        $_.FullName -notlike '*\.venv\*' -and
        $_.FullName -notlike '*\logs\*' -and
        $_.FullName -notlike '*\temp\*' -and
        $_.FullName -notlike '*\~REPORTS\*' -and
        $_.FullName -notlike '*\archive\*' -and
        $_.FullName -notlike '*\~DOWNLOADS\*'
    } |
    ForEach-Object {
        Test-XhtmlXml -Path $_.FullName
    }

$pass = @($results | Where-Object Status -eq 'PASS').Count
$fail = @($results | Where-Object Status -eq 'FAIL').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
$info = @($results | Where-Object Status -eq 'INFO').Count

$results |
    Sort-Object Time, Check, Target |
    Format-Table -AutoSize Status, Check, Target, Detail

Write-Host ''
Write-Host ('Summary: PASS={0} FAIL={1} WARN={2} INFO={3}' -f $pass, $fail, $warn, $info) -ForegroundColor Cyan

if ($Strict -and $fail -gt 0) {
    exit 1
}






<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





