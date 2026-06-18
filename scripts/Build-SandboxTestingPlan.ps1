# VersionTag: 2605.B5.V51.1
# SupportPS5.1: YES(As of: 2026-05-25)
# SupportsPS7.6: YES(As of: 2026-05-25)
# FileRole: TestPlanBuilder
#Requires -Version 5.1
<#!
.SYNOPSIS
    Builds a Sandbox testing-plan dataset from workspace XHTML pages and function hooks.
.DESCRIPTION
    Scans XHTML files, extracts function definitions and event-hook references, and writes
    a checkbox-ready testing-plan JSON used by pages/Sandbox-TestingPlan.xhtml.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputJsonPath = '',
    [string]$OutputFeedbackPath = '',
    [switch]$IncludeRootXhtml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputJsonPath)) {
    $OutputJsonPath = Join-Path (Join-Path (Join-Path $WorkspacePath '~REPORTS') 'testing-plan') 'sandbox-testing-plan.json'
}
if ([string]::IsNullOrWhiteSpace($OutputFeedbackPath)) {
    $OutputFeedbackPath = Join-Path (Join-Path (Join-Path $WorkspacePath '~REPORTS') 'testing-plan') 'sandbox-testing-feedback-template.json'
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$FullPath
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $resolvedFile = [System.IO.Path]::GetFullPath($FullPath)
    if ($resolvedFile.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $trimChars = [char[]]@('\','/')
        $rel = $resolvedFile.Substring($resolvedRoot.Length).TrimStart($trimChars)
        return ($rel -replace '\\','/')
    }

    return ($FullPath -replace '\\','/')
}

$outDir = Split-Path -Parent $OutputJsonPath
if (-not (Test-Path -LiteralPath $outDir)) {
    $null = New-Item -Path $outDir -ItemType Directory -Force
}

$pageCandidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
$pageDirs = @(
    (Join-Path $WorkspacePath 'pages'),
    (Join-Path (Join-Path $WorkspacePath 'scripts') 'XHTML-Checker')
)
if ($IncludeRootXhtml) {
    $pageDirs += $WorkspacePath
}

foreach ($dir in $pageDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter *.xhtml -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        if ($file.FullName -match '[\\/](\.history|~REPORTS|~DOWNLOADS|logs|temp|archive)[\\/]') { continue }
        $pageCandidates.Add($file) | Out-Null
    }
}

$pages = @($pageCandidates | Sort-Object -Property FullName -Unique)

$planItems = @()
$feedbackItems = @()

$functionRegex = [regex]::new('(?im)^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(')
$eventRegex = [regex]::new('(?im)(?:on[a-z]+\s*=\s*"[^"]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*\(|addEventListener\s*\(\s*["''][^"'']+["'']\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\b)')

foreach ($page in $pages) {
    $raw = Get-Content -LiteralPath $page.FullName -Raw -Encoding UTF8
    $relative = Get-RelativePath -Root $WorkspacePath -FullPath $page.FullName

    $defs = @()
    foreach ($m in $functionRegex.Matches($raw)) {
        if ($m.Groups.Count -lt 2) { continue }
        $name = [string]$m.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($defs -notcontains $name) { $defs += $name }
    }

    $hooks = @()
    foreach ($m in $eventRegex.Matches($raw)) {
        $candidates = @()
        if ($m.Groups.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace([string]$m.Groups[1].Value)) {
            $candidates += [string]$m.Groups[1].Value
        }
        if ($m.Groups.Count -ge 3 -and -not [string]::IsNullOrWhiteSpace([string]$m.Groups[2].Value)) {
            $candidates += [string]$m.Groups[2].Value
        }

        foreach ($candidate in $candidates) {
            if ($hooks -notcontains $candidate) { $hooks += $candidate }
        }
    }

    $allFns = @($defs + $hooks | Sort-Object -Unique)
    if (@($allFns).Count -eq 0) {
        $allFns = @('page-load')
    }

    $checks = @()
    foreach ($fn in $allFns) {
        $checkId = ('{0}-{1}' -f ($relative -replace '[^A-Za-z0-9]+','-').Trim('-').ToLowerInvariant(), $fn.ToLowerInvariant())
        $checks += [ordered]@{
            checkId = $checkId
            functionName = $fn
            status = 'pending'
            validated = $false
            confirmed = $false
            signOff = ''
            comments = ''
            bugRefs = @()
            standards = @('SOV-Sys-zero', 'SIN-governance', 'DualEngine-SmokeGate')
            tags = @('testing-plan', 'sandbox', 'smoke', 'scan', 'feedback')
            memoryRefs = @('/memories/repo/testing-plan-feedback-link.md')
        }

        $feedbackItems += [ordered]@{
            checkId = $checkId
            page = $relative
            functionName = $fn
            status = 'pending'
            comments = ''
            bugRefs = @()
            signOff = ''
            standards = @('SOV-Sys-zero', 'SIN-governance', 'DualEngine-SmokeGate')
            tags = @('testing-plan', 'sandbox', 'smoke', 'scan', 'feedback')
            memoryRefs = @('/memories/repo/testing-plan-feedback-link.md')
        }
    }

    $planItems += [ordered]@{
        page = $relative
        functionDefinitions = @($defs)
        eventHooks = @($hooks)
        checks = @($checks)
    }
}

$plan = [ordered]@{
    schema = 'PwShGUI-SandboxTestingPlan/1.0'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    workspacePath = $WorkspacePath
    pagesCount = @($planItems).Count
    checksCount = @($feedbackItems).Count
    standards = @('SOV-Sys-zero', 'SIN governance rules', 'PS7.6 primary + PS5.1 fallback')
    tags = @('smoke', 'scan', 'sandbox', 'testing-plan', 'feedback', 'diagnostic-dryrun')
    memoryLinks = @('/memories/repo/testing-plan-feedback-link.md')
    pages = @($planItems)
}

$feedbackTemplate = [ordered]@{
    schema = 'PwShGUI-SandboxTestingFeedback/1.0'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    sourcePlan = (Get-RelativePath -Root $WorkspacePath -FullPath $OutputJsonPath)
    status = 'open'
    tags = @('feedback', 'bug-report-ready', 'smoke', 'scan', 'sandbox')
    memoryLinks = @('/memories/repo/testing-plan-feedback-link.md')
    items = @($feedbackItems)
}

$planJson = $plan | ConvertTo-Json -Depth 10
$feedbackJson = $feedbackTemplate | ConvertTo-Json -Depth 10

Set-Content -LiteralPath $OutputJsonPath -Value $planJson -Encoding UTF8
Set-Content -LiteralPath $OutputFeedbackPath -Value $feedbackJson -Encoding UTF8

[pscustomobject]@{
    OutputJsonPath = $OutputJsonPath
    OutputFeedbackPath = $OutputFeedbackPath
    Pages = @($planItems).Count
    Checks = @($feedbackItems).Count
}
