# VersionTag: 2605.B5.V46.1
# SupportPS5.1: YES(As of: 2026-04-28)
# SupportsPS7.6: YES(As of: 2026-04-28)
# SupportPS5.1TestedDate: 2026-04-28
# SupportsPS7.6TestedDate: 2026-04-28
# FileRole: Pipeline
# Schema: ChangelogViewerEmbedSync/1.0
# Name Alias: Sync-ChangelogViewerData
# Agent-FirstCreator: GitHub-Copilot
# Agent-LastEditor: GitHub-Copilot
# Agents-TotaleEditsValue: 1
# Show-Objectives: Maintain safe changelog embedding, prevent XHTML parser breakage, and keep markdown-to-viewer sync deterministic.
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [bool]$RefreshAiActionSummary = $true,
    [switch]$IncludeTestAiActions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Escape-JsLine {
    param(
        [string]$Line
    )

    if ($null -eq $Line) {
        $Line = ''
    }
    # Strip non-printable control bytes that can break XHTML parsing.
    $sanitized = [regex]::Replace($Line, "[\x00-\x08\x0B\x0C\x0E-\x1F]", '')

    # Escape for JS single-quoted strings — STRICTLY ONE PASS:
    #   step 1: backslash    \  -> \\   (PS literal '\' is 1 char; '\\' is 2 chars)
    #   step 2: apostrophe   '  -> \'   (PS literal "\'" is 2 chars: \ + ')
    # Caller MUST pass raw markdown (never re-feed previously-escaped JS lines or
    # double-escaping produces \\' which JS reads as \ + close-quote = SyntaxError.
    $escaped = $sanitized.Replace('\', '\\').Replace("'", "\'")
    $escaped = $escaped.Replace(']]>', ']]\x3E')

    # Keep line/paragraph separators parser-safe across hosts.
    $escaped = $escaped.Replace(([string][char]0x2028), '\u2028').Replace(([string][char]0x2029), '\u2029')
    return "'$escaped'"
}

function Build-JsArrayBlock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VariableName,

        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $buffer = New-Object System.Collections.Generic.List[string]
    $buffer.Add("$VariableName = [") | Out-Null
    foreach ($line in $Lines) {
        $buffer.Add((Escape-JsLine -Line $line) + ',') | Out-Null
    }
    if (@($Lines).Count -gt 0) {
        $last = $buffer[$buffer.Count - 1]
        if ($last.EndsWith(',')) {
            $buffer[$buffer.Count - 1] = $last.Substring(0, $last.Length - 1)
        }
    }
    $buffer.Add("].join('\\n');") | Out-Null
    return ($buffer -join [Environment]::NewLine)
}

function ConvertFrom-VersionTagValue {
    param([string]$Tag)

    if ([string]::IsNullOrWhiteSpace($Tag)) { return $null }
    if ($Tag -notmatch '^(\d{4})\.B(\d+)\.V(\d+)\.(\d+)$') { return $null }
    return [pscustomobject]@{
        YearMonth = [int]$Matches[1]
        Build     = [int]$Matches[2]
        Major     = [int]$Matches[3]
        Minor     = [int]$Matches[4]
    }
}

function Get-ChangelogTopVersion {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '0000.B0.V0.0' }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -TotalCount 120)
    foreach ($line in $lines) {
        if ($line -match '^## \[(\d{4}\.B\d+\.V\d+\.\d+)\]') {
            return [string]$Matches[1]
        }
    }
    return '0000.B0.V0.0'
}

function Compare-VersionTagValue {
    param([string]$Left, [string]$Right)

    $l = ConvertFrom-VersionTagValue -Tag $Left
    $r = ConvertFrom-VersionTagValue -Tag $Right
    if ($null -eq $l -and $null -eq $r) { return 0 }
    if ($null -eq $l) { return -1 }
    if ($null -eq $r) { return 1 }

    foreach ($prop in @('YearMonth','Build','Major','Minor')) {
        if ($l.$prop -gt $r.$prop) { return 1 }
        if ($l.$prop -lt $r.$prop) { return -1 }
    }
    return 0
}

$viewerPath = Join-Path $WorkspacePath 'XHTML-ChangelogViewer.xhtml'
$readmePath = Join-Path $WorkspacePath '~README.md'
$readmeChangelogPath = Join-Path $readmePath 'CHANGELOG.md'
$rootChangelogPath = Join-Path $WorkspacePath 'CHANGELOG.md'
$enhancementsPath = Join-Path $readmePath 'ENHANCEMENTS-LOG.md'

$readmeTopVersion = Get-ChangelogTopVersion -Path $readmeChangelogPath
$rootTopVersion = Get-ChangelogTopVersion -Path $rootChangelogPath
$changelogPath = $readmeChangelogPath
if (Compare-VersionTagValue -Left $rootTopVersion -Right $readmeTopVersion -gt 0) {
    $changelogPath = $rootChangelogPath
}

if (-not (Test-Path -LiteralPath $viewerPath)) {
    throw "Viewer file missing: $viewerPath"
}
if (-not (Test-Path -LiteralPath $changelogPath)) {
    throw "Source changelog missing: $changelogPath"
}
if (-not (Test-Path -LiteralPath $enhancementsPath)) {
    throw "Source enhancements log missing: $enhancementsPath"
}

$viewerContent = Get-Content -LiteralPath $viewerPath -Raw -Encoding UTF8
$changelogLines = @(Get-Content -LiteralPath $changelogPath -Encoding UTF8)
$enhancementLines = @(Get-Content -LiteralPath $enhancementsPath -Encoding UTF8)

if ($RefreshAiActionSummary) {
    $aiReportScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-AiActionLogReport.ps1'
    if (Test-Path -LiteralPath $aiReportScript) {
        $aiParams = @{ WorkspacePath = $WorkspacePath }
        if ($IncludeTestAiActions) { $aiParams['IncludeTest'] = $true }
        try {
            & $aiReportScript @aiParams | Out-Null
        } catch {
            Write-Warning ('AI-action summary refresh failed: ' + $_.Exception.Message)
        }
    }
}

$changelogBlock = Build-JsArrayBlock -VariableName 'CHANGELOG_CONTENT' -Lines $changelogLines
$enhancementBlock = Build-JsArrayBlock -VariableName 'ENHANCEMENTS_CONTENT' -Lines $enhancementLines

# Match either an empty-string assignment ('' or "") OR a previously-synced [...].join('...') form.
$changelogPattern   = '(?s)CHANGELOG_CONTENT\s*=\s*(?:''(?:[^''\\]|\\.)*''|\[.*?\]\.join\(''(?:[^''\\]|\\.)*''\));'
$enhancementPattern = '(?s)ENHANCEMENTS_CONTENT\s*=\s*(?:''(?:[^''\\]|\\.)*''|\[.*?\]\.join\(''(?:[^''\\]|\\.)*''\)|CHANGELOG_CONTENT\s*);'

$changeCount = 0
# Use a MatchEvaluator so the replacement string is treated literally (no $1/$& expansion bugs).
$newContent = [regex]::Replace(
    $viewerContent,
    $changelogPattern,
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $changelogBlock }
)
if ($newContent -ne $viewerContent) { $changeCount++ }

$finalContent = [regex]::Replace(
    $newContent,
    $enhancementPattern,
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $enhancementBlock }
)
if ($finalContent -ne $newContent) { $changeCount++ }

if ($changeCount -eq 0) {
    Write-Output "No viewer data block changes needed"
    return
}

Set-Content -LiteralPath $viewerPath -Value $finalContent -Encoding UTF8
Write-Output ("Changelog viewer embedded data updated from source markdown: " + $changelogPath)

<# Outline:
    Synchronize markdown changelog sources into XHTML JS arrays with parser-safe escaping.
#>

<# Objectives-Review:
    Current objective fit is strong for safety and determinism.
    Next improvement: add optional hash diff reporting to indicate exactly which source file changed.
#>

<# Problems:
    Large embedded payloads can still increase XHTML size; monitor file growth over time.
#>

