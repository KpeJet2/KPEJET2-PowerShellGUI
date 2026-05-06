# VersionTag: 2605.B2.V31.7
# Phase 2 - Scoreboard data layer generator.
# Emits per-metric JSON manifests under ~REPORTS/scoreboard-data/ for the
# SIN-Scoreboard.xhtml drilldown pane to consume via XHR.
#
# Output files (one per drillable metric):
#   total-sins.json         - all SIN registry entries (id, title, severity, status, agent)
#   resolved.json           - SINs flagged RESOLVED
#   unresolved.json         - SINs not yet RESOLVED
#   critical.json           - SINs with severity=CRITICAL
#   patterns.json           - all P001..PNNN definitions
#   semi-sins.json          - all SS-NNN advisory entries
#   tools.json              - the 18 Section-9 tools (built + status)
#   index.json              - manifest of available drilldown files

[CmdletBinding()]
param(
    [string]$RegistryPath = (Join-Path $PSScriptRoot '..\sin_registry'),
    [string]$ModulesPath  = (Join-Path $PSScriptRoot '..\modules'),
    [string]$OutDir       = (Join-Path $PSScriptRoot '..\~REPORTS\scoreboard-data')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$enc = New-Object System.Text.UTF8Encoding($true)

function Save-Json {
    param([string]$File, $Data)
    $json = $Data | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllBytes(
        (Join-Path $OutDir $File),
        $enc.GetPreamble() + $enc.GetBytes($json)
    )
}

# --- Load SIN registry entries ----------------------------------------------
$all = New-Object System.Collections.Generic.List[object]
foreach ($f in Get-ChildItem -Path $RegistryPath -Filter '*.json' -File) {
    try {
        $obj = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $rec = [pscustomobject]@{
            file     = $f.Name
            id       = if ($obj.PSObject.Properties.Name -contains 'id')         { [string]$obj.id }         else { $f.BaseName }
            title    = if ($obj.PSObject.Properties.Name -contains 'title')      { [string]$obj.title }      else { '' }
            severity = if ($obj.PSObject.Properties.Name -contains 'severity')   { [string]$obj.severity }   else { '' }
            status   = if ($obj.PSObject.Properties.Name -contains 'status')     { [string]$obj.status }     else { '' }
            agent    = if ($obj.PSObject.Properties.Name -contains 'firstAgent') { [string]$obj.firstAgent } elseif ($obj.PSObject.Properties.Name -contains 'agent') { [string]$obj.agent } else { '' }
            category = if ($obj.PSObject.Properties.Name -contains 'category')   { [string]$obj.category }   else { '' }
            kind     = if ($f.Name -like 'SIN-PATTERN-*') { 'PATTERN' } elseif ($f.Name -like 'SEMI-SIN-*') { 'SEMI' } else { 'INSTANCE' }
        }
        $all.Add($rec) | Out-Null
    } catch {
        # Skip non-conforming files
    }
}

$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

# --- Write per-metric manifests ---------------------------------------------
# P037 mitigation: precompute @().Count into local vars before using inside literal.
$resolved   = @($all | Where-Object { $_.status -match '^(RESOLVED|FIXED|CLOSED|DONE)$' })
$unresolved = @($all | Where-Object { $_.status -notmatch '^(RESOLVED|FIXED|CLOSED|DONE)$' })
$critical   = @($all | Where-Object { $_.severity -match '^(CRITICAL|CRIT)$' })
$patterns   = @($all | Where-Object { $_.kind -eq 'PATTERN' })
$semisins   = @($all | Where-Object { $_.kind -eq 'SEMI' })

$totalCount      = $all.Count
$resolvedCount   = $resolved.Count
$unresolvedCount = $unresolved.Count
$criticalCount   = $critical.Count
$patternsCount   = $patterns.Count
$semiCount       = $semisins.Count

Save-Json 'total-sins.json' ([pscustomobject]@{ generated = $generated; count = $totalCount;      items = $all        })
Save-Json 'resolved.json'   ([pscustomobject]@{ generated = $generated; count = $resolvedCount;   items = $resolved   })
Save-Json 'unresolved.json' ([pscustomobject]@{ generated = $generated; count = $unresolvedCount; items = $unresolved })
Save-Json 'critical.json'   ([pscustomobject]@{ generated = $generated; count = $criticalCount;   items = $critical   })
Save-Json 'patterns.json'   ([pscustomobject]@{ generated = $generated; count = $patternsCount;   items = $patterns   })
Save-Json 'semi-sins.json'  ([pscustomobject]@{ generated = $generated; count = $semiCount;       items = $semisins   })

# --- Tools manifest ---------------------------------------------------------
$tools = @(
    @{ name='Invoke-DependencyGraph';        module='PwShGUI-DependencyMap';         status='BUILT'; tier='Originals' }
    @{ name='Export-TestCoverage';           module='PwShGUI-CoverageReport';        status='BUILT'; tier='Originals' }
    @{ name='New-SINFromScan';               module='PwShGUI-SinFromScan';           status='BUILT'; tier='Originals' }
    @{ name='Invoke-AutoRemediate';          module='PwShGUI-AutoRemediate';         status='BUILT'; tier='Originals' }
    @{ name='Invoke-BreakingChangeDetector'; module='PwShGUI-BreakingChange';        status='BUILT'; tier='Originals' }
    @{ name='Invoke-PSScriptAnalyzerScan';   module='PwShGUI-PSScriptAnalyzerScan';  status='BUILT'; tier='Originals' }
    @{ name='Invoke-SinDriftScan';           module='PwShGUI-SinDriftScan';          status='BUILT'; tier='Backlog' }
    @{ name='Get-SinHeatmap';                module='PwShGUI-SinHeatmap';            status='BUILT'; tier='Backlog' }
    @{ name='Test-XhtmlReports';             module='PwShGUI-XhtmlReportTester';     status='BUILT'; tier='Backlog' }
    @{ name='Invoke-SecretScan';             module='PwShGUI-SecretScan';            status='BUILT'; tier='Backlog' }
    @{ name='Convert-LegacyEncoding';        module='PwShGUI-LegacyEncoding';        status='BUILT'; tier='Backlog' }
    @{ name='Invoke-EventLogReplay';         module='PwShGUI-EventLogReplay';        status='BUILT'; tier='Backlog' }
    @{ name='Get-AgentScorecard';            module='PwShGUI-AgentScorecard';        status='BUILT'; tier='Backlog' }
    @{ name='Invoke-PesterParallel';         module='PwShGUI-PesterParallel';        status='BUILT'; tier='Backlog' }
    @{ name='Compare-ModuleManifest';        module='PwShGUI-ManifestDiff';          status='BUILT'; tier='Backlog' }
    @{ name='Invoke-CheckpointPrune';        module='PwShGUI-CheckpointPrune';       status='BUILT'; tier='Backlog' }
    @{ name='Get-LaunchTimingProfile';       module='PwShGUI-LaunchTimingProfile';   status='BUILT'; tier='Backlog' }
    @{ name='New-SinFixBranch';              module='PwShGUI-SinFixBranch';          status='BUILT'; tier='Backlog' }
)

# Verify each tool's module file exists
foreach ($t in $tools) {
    $mp = Join-Path $ModulesPath ($t.module + '.psm1')
    $t['fileExists'] = (Test-Path $mp)
}
$builtCount = @($tools | Where-Object { $_.status -eq 'BUILT' -and $_.fileExists }).Count

Save-Json 'tools.json' ([pscustomobject]@{
    generated = $generated
    builtCount = $builtCount
    items = $tools
})

# --- Index manifest ---------------------------------------------------------
$toolsCount = @($tools).Count
$index = [pscustomobject]@{
    generated = $generated
    version = '2604.B3.V37.0'
    files = @(
        @{ key='total-sins'; file='total-sins.json'; label='Total Sins';   count = $totalCount }
        @{ key='resolved';   file='resolved.json';   label='Resolved';     count = $resolvedCount }
        @{ key='unresolved'; file='unresolved.json'; label='Unresolved';   count = $unresolvedCount }
        @{ key='critical';   file='critical.json';   label='Critical';     count = $criticalCount }
        @{ key='patterns';   file='patterns.json';   label='SIN Patterns'; count = $patternsCount }
        @{ key='semi-sins';  file='semi-sins.json';  label='Semi-SINs';    count = $semiCount }
        @{ key='tools';      file='tools.json';      label='Tools';        count = $toolsCount }
    )
}
Save-Json 'index.json' $index

"Wrote scoreboard-data manifests to: $OutDir"
"  total-sins:  $totalCount"
"  resolved:    $resolvedCount"
"  unresolved:  $unresolvedCount"
"  critical:    $criticalCount"
"  patterns:    $patternsCount"
"  semi-sins:   $semiCount"
"  tools:       $toolsCount (built: $builtCount)"

