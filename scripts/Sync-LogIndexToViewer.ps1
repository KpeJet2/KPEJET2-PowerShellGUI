# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-29)
# SupportsPS7.6: YES(As of: 2026-04-29)
# FileRole: Pipeline
# Schema: ChangelogViewerLogIndex/1.0
# Name Alias: Sync-LogIndexToViewer
# Agent-FirstCreator: GitHub-Copilot
# Agent-LastEditor: GitHub-Copilot
# Show-Objectives: Index pipeline, script-execution, and agent-iteration logs into the changelog viewer's offline cache as optimised JS table arrays for fast dropdown selection and rendering.
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [int]$MaxLinesPerLog = 1500,
    [int]$MaxLogsPerCategory = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-ToJsString {
    param([string]$Text)
    if ($null -eq $Text) { return "''" }
    $sanitized = [regex]::Replace($Text, "[\x00-\x08\x0B\x0C\x0E-\x1F]", '')
    $escaped = $sanitized.Replace('\', '\\').Replace("'", "\'")
    # Defuse XHTML structural sequences that would close the host <script>/CDATA wrapper
    $escaped = $escaped.Replace(']]>', ']]\u003E')
    $escaped = [regex]::Replace($escaped, '(?i)</(script|style)', '<\/$1')
    $escaped = $escaped.Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
    return "'$escaped'"
}

function Get-LogContent {
    param([string]$Path, [int]$MaxLines)
    try {
        $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop -TotalCount $MaxLines)
    } catch {
        return @("[ERROR reading $Path : $($_.Exception.Message)]")
    }
    return $lines
}

function New-LogEntry {
    param(
        [string]$Category,
        [System.IO.FileInfo]$File,
        [int]$MaxLines
    )
    $rel = $File.FullName.Substring($WorkspacePath.Length).TrimStart('\','/')
    $lines = Get-LogContent -Path $File.FullName -MaxLines $MaxLines
    return [ordered]@{
        category = $Category
        path     = $rel
        name     = $File.Name
        sizeKB   = [Math]::Round($File.Length / 1KB, 1)
        modified = $File.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        lineCount = @($lines).Count
        truncated = (@($lines).Count -ge $MaxLines)
        lines    = $lines
    }
}

# ------------------------------------------------------------
# Source discovery
# ------------------------------------------------------------
$logsRoot   = Join-Path $WorkspacePath 'logs'
$reportsRoot = Join-Path $WorkspacePath '~REPORTS'
$agentsRoot  = Join-Path $WorkspacePath 'agents'

$pipelineFiles = @()
$scriptExecFiles = @()
$agentIterFiles = @()
$reportFiles = @()

if (Test-Path $logsRoot) {
    $pipelineFiles = @(Get-ChildItem -LiteralPath $logsRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(cron-|automated-tests-|engine-|module-|self-review|cycle-|improvement-|scan-)' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $MaxLogsPerCategory)
    $scriptExecFiles = @(Get-ChildItem -LiteralPath $logsRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(SCRIPTS|SmokeTest|XPS15-MS|Main-GUI_BATCH)' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $MaxLogsPerCategory)
}

if (Test-Path $reportsRoot) {
    $reportFiles = @(Get-ChildItem -LiteralPath $reportsRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.json','.md','.log' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $MaxLogsPerCategory)
}

if (Test-Path $agentsRoot) {
    $agentIterFiles = @(Get-ChildItem -LiteralPath $agentsRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '(iteration|sov-sys-zero|history|run-)' -and
            $_.Extension -in '.json','.jsonl','.log','.md'
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $MaxLogsPerCategory)
}

# ------------------------------------------------------------
# Build LOG_INDEX entries
# ------------------------------------------------------------
$entries = @()
foreach ($f in $pipelineFiles)   { $entries += New-LogEntry -Category 'Pipeline' -File $f -MaxLines $MaxLinesPerLog }
foreach ($f in $scriptExecFiles) { $entries += New-LogEntry -Category 'ScriptExec' -File $f -MaxLines $MaxLinesPerLog }
foreach ($f in $agentIterFiles)  { $entries += New-LogEntry -Category 'AgentIter' -File $f -MaxLines $MaxLinesPerLog }
foreach ($f in $reportFiles)     { $entries += New-LogEntry -Category 'Report' -File $f -MaxLines $MaxLinesPerLog }

# ------------------------------------------------------------
# Emit JS block
# ------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('var LOG_INDEX = [')
for ($i = 0; $i -lt @($entries).Count; $i++) {
    $e = $entries[$i]
    $linesJs = ($e.lines | ForEach-Object { Convert-ToJsString $_ }) -join ','
    [void]$sb.Append('  { id: ')
    [void]$sb.Append((Convert-ToJsString ("$($e.category)::$($e.name)")))
    [void]$sb.Append(', category: ')
    [void]$sb.Append((Convert-ToJsString $e.category))
    [void]$sb.Append(', path: ')
    [void]$sb.Append((Convert-ToJsString $e.path))
    [void]$sb.Append(', name: ')
    [void]$sb.Append((Convert-ToJsString $e.name))
    [void]$sb.Append(', sizeKB: ')
    [void]$sb.Append($e.sizeKB)
    [void]$sb.Append(', modified: ')
    [void]$sb.Append((Convert-ToJsString $e.modified))
    [void]$sb.Append(', lineCount: ')
    [void]$sb.Append($e.lineCount)
    [void]$sb.Append(', truncated: ')
    [void]$sb.Append(($e.truncated.ToString().ToLower()))
    [void]$sb.Append(', lines: [')
    [void]$sb.Append($linesJs)
    [void]$sb.Append(']')
    if ($i -lt @($entries).Count - 1) { [void]$sb.AppendLine(' },') } else { [void]$sb.AppendLine(' }') }
}
[void]$sb.AppendLine('];')
[void]$sb.AppendLine("var LOG_INDEX_GENERATED = '$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')';")
[void]$sb.AppendLine("var LOG_INDEX_COUNT = $(@($entries).Count);")

$logBlock = $sb.ToString()

# ------------------------------------------------------------
# Inject into viewer between markers
# ------------------------------------------------------------
$viewerPath = Join-Path $WorkspacePath 'XHTML-ChangelogViewer.xhtml'
$content = Get-Content -LiteralPath $viewerPath -Raw -Encoding UTF8

$startMarker = '/* LOG_INDEX_BEGIN */'
$endMarker   = '/* LOG_INDEX_END */'

# Use a single deterministic anchor: the populateLogIndexDropdown function declaration.
$anchor = 'function populateLogIndexDropdown'
if ($content -notmatch [regex]::Escape($startMarker)) {
    # First-time injection: insert immediately BEFORE the populateLogIndexDropdown function
    $idx = $content.IndexOf($anchor)
    if ($idx -lt 0) { throw "Anchor '$anchor' not found in viewer; cannot inject LOG_INDEX." }
    $insertion = "$startMarker`r`n$logBlock$endMarker`r`n"
    $content = $content.Substring(0, $idx) + $insertion + $content.Substring($idx)
} else {
    # Subsequent updates: replace exactly once between markers
    $pattern = '(?s)' + [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
    $replacement = "$startMarker`r`n$logBlock$endMarker"
    $rx = [regex]::new($pattern)
    $content = $rx.Replace($content, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }, 1)
}

[System.IO.File]::WriteAllText($viewerPath, $content, [System.Text.UTF8Encoding]::new($true))
Write-Host "LOG_INDEX synced: $(@($entries).Count) entries across Pipeline/ScriptExec/AgentIter/Report categories." -ForegroundColor Green

