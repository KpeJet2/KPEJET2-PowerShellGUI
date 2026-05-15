<#
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-30)
# SupportsPS7.6: YES(As of: 2026-04-30)
.SYNOPSIS
    PwShGUI-CoverageReport - Pester code-coverage HTML/JSON exporter.
.NOTES
    Pester 5.x required. Outputs per-file coverage % and command counts.
.DESCRIPTION
  Detailed behaviour: Export test coverage.
#>
#Requires -Version 5.1

$script:ModuleVersion = '2604.B3.V28.0'

function Export-TestCoverage {
    <#
    .SYNOPSIS  Run Pester with code-coverage and emit HTML + JSON report.
    .PARAMETER  TestPath        Test root (default: <ws>\tests)
    .PARAMETER  CoverageTarget  Files to measure (default: modules/*.psm1)
    .PARAMETER  OutputDir       Defaults to <ws>\~REPORTS
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$WorkspacePath = (Get-Location).Path,
        [string]$TestPath,
        [string[]]$CoverageTarget,
        [string]$OutputDir
    )

    if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [Version]'5.0.0' })) {
        throw 'Pester 5.x not installed. Run: Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck'
    }
    Import-Module Pester -MinimumVersion 5.0 -Force

    if (-not $TestPath)       { $TestPath = Join-Path $WorkspacePath 'tests' }
    if (-not $OutputDir)      { $OutputDir = Join-Path $WorkspacePath '~REPORTS' }
    if (-not $CoverageTarget) {
        $modDir = Join-Path $WorkspacePath 'modules'
        $CoverageTarget = @(Get-ChildItem -Path $modDir -Filter *.psm1 -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }
    if (-not (Test-Path $OutputDir)) {
        if ($PSCmdlet.ShouldProcess($OutputDir, 'Create')) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
    }

    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $TestPath
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Minimal'
    $cfg.CodeCoverage.Enabled = $true
    $cfg.CodeCoverage.Path = $CoverageTarget
    $cfg.CodeCoverage.OutputFormat = 'JaCoCo'
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
    $covXml = Join-Path $OutputDir ("coverage-{0}.xml" -f $stamp)
    $cfg.CodeCoverage.OutputPath = $covXml

    $result = Invoke-Pester -Configuration $cfg

    $cov = $result.CodeCoverage
    $totalA   = if ($cov.CommandsAnalyzedCount) { [int]$cov.CommandsAnalyzedCount } else { 0 }
    $totalE   = if ($cov.CommandsExecutedCount) { [int]$cov.CommandsExecutedCount } else { 0 }
    $pct      = if ($totalA -gt 0) { [math]::Round(($totalE / $totalA) * 100, 2) } else { 0 }

    # Per-file aggregation
    $perFile = @{}
    foreach ($cmd in @($cov.CommandsAnalyzed)) {
        $f = $cmd.File
        if (-not $perFile.ContainsKey($f)) {
            $perFile[$f] = @{ analyzed = 0; executed = 0 }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        }
        $perFile[$f].analyzed++  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    foreach ($cmd in @($cov.CommandsExecuted)) {
        $f = $cmd.File
        if ($perFile.ContainsKey($f)) { $perFile[$f].executed++ }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }

    $rows = ''
    foreach ($k in ($perFile.Keys | Sort-Object)) {
        $a = $perFile[$k].analyzed  # SIN-EXEMPT:P027 -- index access, context-verified safe
        $e = $perFile[$k].executed  # SIN-EXEMPT:P027 -- index access, context-verified safe
        $p = if ($a -gt 0) { [math]::Round(($e / $a) * 100, 1) } else { 0 }
        $cls = if ($p -ge 80) { 'good' } elseif ($p -ge 50) { 'mid' } else { 'low' }
        $shortName = [System.IO.Path]::GetFileName($k)
        $rows += "      <tr class='$cls'><td>$([System.Security.SecurityElement]::Escape($shortName))</td><td>$a</td><td>$e</td><td>$p%</td></tr>`n"
    }

    $htmlPath = Join-Path $OutputDir ("coverage-{0}.html" -f $stamp)
    $jsonPath = Join-Path $OutputDir ("coverage-{0}.json" -f $stamp)

    $html = @"
<!DOCTYPE html>
<html><head><meta charset="UTF-8"/><title>PwShGUI Coverage $stamp</title>
<style>body{background:#0f172a;color:#e2e8f0;font-family:Segoe UI,monospace;padding:20px}
h1{color:#38bdf8}table{border-collapse:collapse;width:100%}
th{background:#253348;color:#38bdf8;padding:8px;text-align:left;border-bottom:2px solid #334155}
td{padding:6px 10px;border-bottom:1px solid #334155}
.good td{color:#22c55e}.mid td{color:#f59e0b}.low td{color:#ef4444}
.summary{background:#1e293b;padding:14px;border-radius:8px;margin-bottom:16px}</style></head>
<body><h1>Code Coverage Report</h1>
<div class="summary"><b>Generated:</b> $stamp &middot;
<b>Files:</b> $(@($perFile.Keys).Count) &middot;
<b>Commands analysed:</b> $totalA &middot;
<b>Executed:</b> $totalE &middot;
<b>Coverage:</b> $pct%</div>
<table><thead><tr><th>File</th><th>Analysed</th><th>Executed</th><th>%</th></tr></thead>
<tbody>
$rows
</tbody></table></body></html>
"@

    if ($PSCmdlet.ShouldProcess($htmlPath, 'Write HTML')) {
        Set-Content -Path $htmlPath -Value $html -Encoding UTF8
    }
    if ($PSCmdlet.ShouldProcess($jsonPath, 'Write JSON')) {
        @{
            generated = (Get-Date).ToUniversalTime().ToString('o')
            totalAnalysed = $totalA
            totalExecuted = $totalE
            percentage = $pct
            perFile = $perFile
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
    }

    [PSCustomObject]@{
        HtmlPath = $htmlPath
        JsonPath = $jsonPath
        XmlPath  = $covXml
        Coverage = $pct
        Files    = @($perFile.Keys).Count
    }
}

Export-ModuleMember -Function Export-TestCoverage

