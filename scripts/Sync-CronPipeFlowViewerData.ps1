# VersionTag: 2608.B1.V54.2
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-08-14
# SupportsPS7.6TestedDate: 2026-08-14
# FileRole: Pipeline
#Requires -Version 5.1
<#!
.SYNOPSIS
    Injects pipeline flow graph payload into XHTML-Cron-Pipe-Flow.xhtml.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$GraphPath = '',
    [string]$ViewerPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toJsSafe = {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { $Text = '' }
    $sanitized = [regex]::Replace($Text, "[\x00-\x08\x0B\x0C\x0E-\x1F]", '')
    $escaped = $sanitized.Replace('\\', '\\\\').Replace("'", "\\'")
    $escaped = $escaped.Replace(']]>', ']]\\x3E')
    $escaped = $escaped.Replace('&', '\\u0026')
    $escaped = $escaped.Replace("`r", '\\r').Replace("`n", '\\n')
    $escaped = $escaped.Replace(([string][char]0x2028), '\\u2028').Replace(([string][char]0x2029), '\\u2029')
    return $escaped
}

$root = (Resolve-Path -LiteralPath $WorkspacePath).Path
if ([string]::IsNullOrWhiteSpace($GraphPath)) {
    $GraphPath = Join-Path (Join-Path $root 'config') 'pipeline-flow-graph.json'
}
if ([string]::IsNullOrWhiteSpace($ViewerPath)) {
    $ViewerPath = Join-Path $root 'XHTML-Cron-Pipe-Flow.xhtml'
}

if (-not (Test-Path -LiteralPath $GraphPath)) {
    throw ('Graph artifact missing: ' + $GraphPath)
}
if (-not (Test-Path -LiteralPath $ViewerPath)) {
    throw ('Viewer file missing: ' + $ViewerPath)
}

$graphRaw = Get-Content -LiteralPath $GraphPath -Raw -Encoding UTF8
$graphObj = $graphRaw | ConvertFrom-Json
$graphHash = ''
if ($graphObj -and $graphObj.PSObject.Properties.Name -contains 'graphHash') {
    $graphHash = [string]$graphObj.graphHash
}
if ([string]::IsNullOrWhiteSpace($graphHash)) {
    $graphHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $GraphPath).Hash.ToLowerInvariant()
}

$viewerContent = Get-Content -LiteralPath $ViewerPath -Raw -Encoding UTF8
$escapedPayload = & $toJsSafe -Text $graphRaw
$escapedHash = & $toJsSafe -Text $graphHash

$payloadPattern = '(?s)FLOW_GRAPH_DATA\s*=\s*(?:''(?:[^''\\]|\\.)*''|"(?:[^"\\]|\\.)*"|\[.*?\]);'
$hashPattern = '(?s)FLOW_GRAPH_HASH\s*=\s*(?:''(?:[^''\\]|\\.)*''|"(?:[^"\\]|\\.)*");'

$payloadReplacement = "FLOW_GRAPH_DATA = '$escapedPayload';"
$hashReplacement = "FLOW_GRAPH_HASH = '$escapedHash';"

$newContent = [regex]::Replace(
    $viewerContent,
    $payloadPattern,
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $payloadReplacement }
)

$finalContent = [regex]::Replace(
    $newContent,
    $hashPattern,
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $hashReplacement }
)

$changed = ($finalContent -ne $viewerContent)
if ($changed) {
    Set-Content -LiteralPath $ViewerPath -Value $finalContent -Encoding UTF8
}

[PSCustomObject]@{
    viewerPath = $ViewerPath
    graphPath = $GraphPath
    graphHash = $graphHash
    changed = $changed
}
