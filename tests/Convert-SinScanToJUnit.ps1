# VersionTag: 2605.B2.V31.7
<#
.SYNOPSIS
    Converts a SIN scanner result JSON into a JUnit-format XML for CI consumption.

.DESCRIPTION
    Reads the JSON emitted by tests\Invoke-SINPatternScanner.ps1 and produces a
    JUnit-compatible XML test report:
      - One <testsuite> per SIN pattern
      - One <testcase> per finding (passes when count<=baseline, fails on regression)
      - Adds <testsuite> for ratchet/regression summary
    Compatible with Azure Pipelines, GitHub Actions JUnit reporters and Jenkins.

.PARAMETER ScanJson
    Path to the scanner output JSON (default: reports\sin-scan-bat-xhtml.json).

.PARAMETER OutputXml
    Path to write the JUnit XML (default: reports\sin-scan-junit.xml).

.EXAMPLE
    pwsh -File tests\Convert-SinScanToJUnit.ps1 -ScanJson reports\latest.json -OutputXml reports\sin-junit.xml
#>
[CmdletBinding()]
param(
    [string]$ScanJson  = (Join-Path $PSScriptRoot '..\reports\sin-scan-bat-xhtml.json'),
    [string]$OutputXml = (Join-Path $PSScriptRoot '..\reports\sin-scan-junit.xml'),
    [string]$BaselineJson = (Join-Path $PSScriptRoot '..\config\sin-baseline.json')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScanJson)) {
    throw "Scan JSON not found: $ScanJson"
}

$j = Get-Content -LiteralPath $ScanJson -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-SafeProp {
    param($Obj, [string]$Name, $Default)
    if ($null -eq $Obj) { return $Default }
    if ($Obj.PSObject.Properties.Name -contains $Name) { return $Obj.$Name }
    return $Default
}

function ConvertTo-XmlSafe([string]$s) {
    if ($null -eq $s) { return '' }
    return [System.Security.SecurityElement]::Escape($s)
}

$baselineCounts = @{}
if (Test-Path -LiteralPath $BaselineJson) {
    try {
        $bl = Get-Content -LiteralPath $BaselineJson -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($bl -and $bl.PSObject.Properties.Name -contains 'counts' -and $null -ne $bl.counts) {
            foreach ($p in $bl.counts.PSObject.Properties) { $baselineCounts[$p.Name] = [int]$p.Value }
        }
    } catch {
        Write-Warning "[Convert-SinScanToJUnit] Could not load baseline: $_"
    }
}

$findings = @($j.findings)
$bySin = $findings | Group-Object sinId

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')

$totalFindings = @($findings).Count
$regressions   = @(Get-SafeProp $j 'regressions' @())
$ratchetMode   = Get-SafeProp $j 'ratchetMode' 'unknown'
$timestamp     = Get-SafeProp $j 'timestamp'   ((Get-Date).ToString('o'))

[void]$sb.AppendFormat(
    '<testsuites name="SinScanner" time="{0}" tests="{1}" failures="{2}" timestamp="{3}">' + "`r`n",
    [math]::Round([double](Get-SafeProp $j 'elapsedMs' 0) / 1000.0, 3),
    $totalFindings,
    @($regressions).Count,
    (ConvertTo-XmlSafe $timestamp)
)

# Suite per SIN id
foreach ($g in $bySin) {
    $sinId    = $g.Name
    $count    = $g.Count
    $baseline = if ($baselineCounts.ContainsKey($sinId)) { $baselineCounts[$sinId] } else { 0 }
    $isRegression = $count -gt $baseline

    [void]$sb.AppendFormat(
        '  <testsuite name="{0}" tests="{1}" failures="{2}">' + "`r`n",
        (ConvertTo-XmlSafe $sinId), $count, $(if ($isRegression) { $count - $baseline } else { 0 })
    )

    foreach ($f in $g.Group) {
        $tcName = "$($f.file):$($f.line)"
        [void]$sb.AppendFormat(
            '    <testcase classname="{0}" name="{1}">' + "`r`n",
            (ConvertTo-XmlSafe $sinId), (ConvertTo-XmlSafe $tcName)
        )
        if ($isRegression) {
            $msg = "[$($f.severity)] $($f.title) -- $($f.file):$($f.line)"
            $details = if ($null -ne $f.content) { ConvertTo-XmlSafe ([string]$f.content) } else { '' }
            [void]$sb.AppendFormat(
                '      <failure type="{0}" message="{1}"><![CDATA[{2}]]></failure>' + "`r`n",
                (ConvertTo-XmlSafe $f.severity),
                (ConvertTo-XmlSafe $msg),
                $details
            )
        } else {
            # Within-baseline finding -> system-out only
            $note = "Within baseline tolerance (count=$count <= baseline=$baseline) [$($f.severity)]"
            [void]$sb.AppendFormat('      <system-out><![CDATA[{0}]]></system-out>' + "`r`n", (ConvertTo-XmlSafe $note))
        }
        [void]$sb.AppendLine('    </testcase>')
    }

    [void]$sb.AppendLine('  </testsuite>')
}

# Ratchet-summary suite
$improvements = @(Get-SafeProp $j 'improvements' @())
[void]$sb.AppendFormat(
    '  <testsuite name="RatchetSummary" tests="3" failures="{0}">' + "`r`n",
    $(if (@($regressions).Count -gt 0) { 1 } else { 0 })
)
[void]$sb.AppendFormat('    <testcase classname="RatchetSummary" name="ratchetMode={0}"><system-out>{0}</system-out></testcase>' + "`r`n", (ConvertTo-XmlSafe $ratchetMode))
[void]$sb.AppendFormat('    <testcase classname="RatchetSummary" name="improvements={0}"><system-out>{0}</system-out></testcase>' + "`r`n", @($improvements).Count)

if (@($regressions).Count -gt 0) {
    $regMsg = ($regressions | ForEach-Object { "$($_.sinId): $($_.baseline)->$($_.current)" }) -join '; '
    [void]$sb.AppendFormat(
        '    <testcase classname="RatchetSummary" name="regressions"><failure type="REGRESSION" message="{0}"></failure></testcase>' + "`r`n",
        (ConvertTo-XmlSafe $regMsg)
    )
} else {
    [void]$sb.AppendLine('    <testcase classname="RatchetSummary" name="regressions"><system-out>none</system-out></testcase>')
}
[void]$sb.AppendLine('  </testsuite>')

[void]$sb.AppendLine('</testsuites>')

$outDir = Split-Path -Parent $OutputXml
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($OutputXml, $sb.ToString(), $utf8)

Write-Output ("Wrote JUnit XML: {0} ({1} testcases, {2} failures)" -f $OutputXml, $totalFindings, @($regressions).Count)

