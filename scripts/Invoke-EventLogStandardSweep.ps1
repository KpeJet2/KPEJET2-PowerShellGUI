# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-29
# SupportsPS7.6TestedDate: 2026-04-29
# FileRole: Pipeline
<#
.SYNOPSIS
    Scan modules and scripts for non-canonical event-log emissions per
    docs/EVENT-LOG-STANDARD.md.

.DESCRIPTION
    Report-only by default. Flags:
      - Write-Host outside permitted UI/banner contexts (SS-003)
      - Add-Content / Out-File without -Encoding (P017/P019)
      - Direct Console.WriteLine
      - SilentlyContinue on Import-Module (P003)
    Outputs JSON+MD report to ~REPORTS/EventLogSweep-<ts>.{json,md} and emits a
    summary event row via the adapter (scope=pipeline).
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reportDir = Join-Path $WorkspacePath '~REPORTS'
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonOut = Join-Path $reportDir "EventLogSweep-$ts.json"
$mdOut   = Join-Path $reportDir "EventLogSweep-$ts.md"

$adapter = Join-Path $WorkspacePath 'modules\PwShGUI-EventLogAdapter.psm1'
$adapterLoaded = $false
if (Test-Path $adapter) { try { Import-Module $adapter -Force -DisableNameChecking; $adapterLoaded = $true } catch { <# Intentional: non-fatal -- adapter optional #> } }

function Emit-Event {
    param([string]$Sev, [string]$Msg)
    if ($adapterLoaded) { try { Write-EventLogNormalized -Scope pipeline -Component 'EventLogSweep' -Message $Msg -Severity $Sev -WorkspacePath $WorkspacePath } catch { <# Intentional: non-fatal -- emit best-effort #> } }
}

$excludePatterns = @('*\~REPORTS\*','*\~DOWNLOADS\*','*\.history\*','*\temp\*','*\checkpoints\*','*\FOLDER-ROOT\*','*\sovereign-kernel\*')
$psFiles = @(Get-ChildItem -Path $WorkspacePath -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
    Where-Object { $f = $_.FullName; -not ($excludePatterns | Where-Object { $f -like $_ }) })

$findings = @()
$rules = @(
    @{ id='SS-003-WriteHost';      regex='\bWrite-Host\b';                                   severity='Warning'; desc='Write-Host should be replaced by Write-AppLog/Write-CronLog (UI exempt)' },
    @{ id='P017-OutFileEncoding';  regex='\bOut-File\b(?!.*-Encoding)';                      severity='Error';   desc='Out-File without -Encoding defaults to UTF-16; use -Encoding UTF8' },
    @{ id='SS-006-AddContentEnc';  regex='\bAdd-Content\b(?!.*-Encoding)(?!.*-Path\s+\$logFile)'; severity='Warning'; desc='Add-Content without -Encoding defaults to ANSI' },
    @{ id='P003-SilentlyImport';   regex='Import-Module[^\n]*-ErrorAction\s+SilentlyContinue'; severity='Error'; desc='Import-Module SilentlyContinue masks failures; use try/catch' },
    @{ id='ConsoleWriteLine';      regex='\[Console\]::WriteLine';                            severity='Warning'; desc='Use Write-AppLog instead of Console.WriteLine' }
)

foreach ($f in $psFiles) {
    $rel = $f.FullName.Substring($WorkspacePath.Length).TrimStart('\','/')
    # Allow Write-Host in UI/launch/banner files.
    $allowWriteHost = ($rel -like 'Launch-*.ps1') -or ($rel -like '*\Show-*.ps1') -or ($rel -like 'Main-GUI.ps1') -or ($rel -like '*\View-*.ps1') -or ($rel -like '*\fix_*.ps1')
    $lines = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]  # SIN-EXEMPT:P027 -- index access, context-verified safe
        if ($line -match '^\s*#') { continue }
        foreach ($rule in $rules) {
            if ($line -match $rule.regex) {
                if ($rule.id -eq 'SS-003-WriteHost' -and $allowWriteHost) { continue }
                $findings += [ordered]@{
                    file     = $rel
                    line     = $i + 1
                    rule     = $rule.id
                    severity = $rule.severity
                    snippet  = $line.Trim()
                    desc     = $rule.desc
                }
            }
        }
    }
}

$byRule = $findings | Group-Object rule | ForEach-Object { [ordered]@{ rule = $_.Name; count = @($_.Group).Count } }
$envelope = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    workspace   = $WorkspacePath
    scannedFiles = @($psFiles).Count
    totalFindings = @($findings).Count
    byRule = @($byRule)
    findings = @($findings)
}
$envelope | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonOut -Encoding UTF8

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# Event Log Standard Sweep')
[void]$sb.AppendLine("Generated: $($envelope.generatedAt)")
[void]$sb.AppendLine("Scanned: $($envelope.scannedFiles) files | Findings: $($envelope.totalFindings)")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## By Rule')
[void]$sb.AppendLine('| Rule | Count |')
[void]$sb.AppendLine('|---|---|')
foreach ($r in $byRule) { [void]$sb.AppendLine("| $($r.rule) | $($r.count) |") }
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Top 50 Findings')
[void]$sb.AppendLine('| File | Line | Rule | Snippet |')
[void]$sb.AppendLine('|---|---|---|---|')
foreach ($x in (@($findings) | Select-Object -First 50)) {
    $sn = ($x.snippet -replace '\|','\\|').Substring(0,[Math]::Min(120,$x.snippet.Length))
    [void]$sb.AppendLine("| $($x.file) | $($x.line) | $($x.rule) | ``$sn`` |")
}
$sb.ToString() | Set-Content -LiteralPath $mdOut -Encoding UTF8

Write-Host "JSON: $jsonOut"
Write-Host "MD:   $mdOut"
Write-Host "Findings: $($envelope.totalFindings) across $($envelope.scannedFiles) files"
Emit-Event 'Info' "Sweep complete: $($envelope.totalFindings) findings across $($envelope.scannedFiles) files"
exit 0

