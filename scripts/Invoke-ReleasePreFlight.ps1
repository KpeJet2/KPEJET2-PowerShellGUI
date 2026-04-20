# VersionTag: 2604.B2.V31.0
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-release validation script for PowerShellGUI.
.DESCRIPTION
    Checks parse health, version consistency, manifest completeness,
    and common quality gates before a release tag is applied.
.NOTES
    Author  : The Establishment
    Version : 2604.B2.V31.0
    Created : 24th March 2026
#>
[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0; $warn = 0

function Write-Check {
    param([string]$Name, [ValidateSet('PASS','FAIL','WARN')][string]$Result, [string]$Detail)
    switch ($Result) {
        'PASS' { $script:pass++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
        'FAIL' { $script:fail++; Write-Host "  [FAIL] $Name -- $Detail" -ForegroundColor Red }
        'WARN' { $script:warn++; Write-Host "  [WARN] $Name -- $Detail" -ForegroundColor Yellow }
    }
}

Write-Host "`n========== PowerShellGUI Release Pre-Flight ==========`n" -ForegroundColor Cyan

# ------------------------------------------------------------------ 1. Parse all PS1/PSM1
Write-Host "--- 1. Parse Health ---" -ForegroundColor White
$scripts = Get-ChildItem -Path $RootPath -Include '*.ps1','*.psm1' -Recurse -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.history[\\/]' }
$parseErrors = 0
foreach ($f in $scripts) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        $parseErrors++
        Write-Check -Name $f.Name -Result 'FAIL' -Detail "$(@($errors).Count) parse error(s)"
    }
}
if ($parseErrors -eq 0) {
    Write-Check -Name "All $(@($scripts).Count) scripts parse clean" -Result 'PASS'
} else {
    Write-Check -Name "$parseErrors file(s) with parse errors" -Result 'FAIL'
}

# ------------------------------------------------------------------ 2. VersionTag consistency
Write-Host "`n--- 2. VersionTag Consistency ---" -ForegroundColor White
$configPath = Join-Path $RootPath 'config\pwsh-app-config-BASE.json'
$expectedTag = $null
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    $expectedTag = $cfg.metadata.versionTag
    Write-Host "  Expected tag: $expectedTag"
}
$tagFiles = Get-ChildItem -Path $RootPath -Include '*.ps1','*.psm1','*.bat','*.xhtml' -Recurse -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.history[\\/]' }
$stale = @()
foreach ($f in $tagFiles) {
    $head = Get-Content $f.FullName -TotalCount 5 -ErrorAction SilentlyContinue
    foreach ($line in $head) {
        if ($line -match '(?:#|REM)\s*VersionTag:\s*(\S+)') {
            $tag = $Matches[1]
            if ($expectedTag -and $tag -ne $expectedTag) {
                $stale += "$($f.Name) ($tag)"
            }
            break
        }
    }
}
if (@($stale).Count -eq 0) {
    Write-Check -Name 'All VersionTags match config' -Result 'PASS'
} else {
    Write-Check -Name "$(@($stale).Count) stale VersionTag(s)" -Result 'WARN' -Detail ($stale -join ', ')
}

# ------------------------------------------------------------------ 3. Duplicate VersionTags in .gitignore
Write-Host "`n--- 3. .gitignore Cleanliness ---" -ForegroundColor White
$gitignores = Get-ChildItem -Path $RootPath -Filter '.gitignore' -Recurse -File
foreach ($gi in $gitignores) {
    $lines = Get-Content $gi.FullName
    $tagLines = @($lines | Where-Object { $_ -match '^#\s*VersionTag:' })
    if (@($tagLines).Count -gt 1) {
        Write-Check -Name $gi.FullName -Result 'WARN' -Detail "$(@($tagLines).Count) duplicate VersionTag lines"
    } else {
        Write-Check -Name $gi.Name -Result 'PASS'
    }
}

# ------------------------------------------------------------------ 4. Module manifests
Write-Host "`n--- 4. Module Manifests ---" -ForegroundColor White
$modules = Get-ChildItem -Path (Join-Path $RootPath 'modules') -Filter '*.psm1' -File -ErrorAction SilentlyContinue
foreach ($m in $modules) {
    $psd1 = $m.FullName -replace '\.psm1$', '.psd1'
    if (Test-Path $psd1) {
        Write-Check -Name "$($m.BaseName).psd1" -Result 'PASS'
    } else {
        Write-Check -Name "$($m.BaseName).psd1" -Result 'WARN' -Detail 'Missing .psd1 manifest'
    }
}

# ------------------------------------------------------------------ 5. XHTML DOCTYPE consistency
Write-Host "`n--- 5. XHTML DOCTYPE ---" -ForegroundColor White
$xhtmlFiles = Get-ChildItem -Path $RootPath -Filter '*.xhtml' -Recurse -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.history[\\/]' }
foreach ($x in $xhtmlFiles) {
    $content = Get-Content $x.FullName -TotalCount 10 -ErrorAction SilentlyContinue
    $doctype = ($content | Where-Object { $_ -match 'DOCTYPE' }) -join ''
    if ($doctype -match 'XHTML 1\.0 Strict') {
        Write-Check -Name $x.Name -Result 'PASS'
    } elseif ($doctype) {
        Write-Check -Name $x.Name -Result 'WARN' -Detail "Non-standard: $doctype"
    } else {
        Write-Check -Name $x.Name -Result 'FAIL' -Detail 'No DOCTYPE found'
    }
}

# ------------------------------------------------------------------ Summary
Write-Host "`n========== Summary ==========" -ForegroundColor Cyan
Write-Host "  PASS: $pass  |  WARN: $warn  |  FAIL: $fail" -ForegroundColor $(if ($fail -gt 0) {'Red'} elseif ($warn -gt 0) {'Yellow'} else {'Green'})
if ($fail -gt 0) {
    Write-Host "  Release BLOCKED -- fix FAIL items above.`n" -ForegroundColor Red
    exit 1
}
Write-Host "  Release gate: CLEAR`n" -ForegroundColor Green
exit 0

