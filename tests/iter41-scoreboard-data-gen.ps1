# VersionTag: 2605.B5.V46.0
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
    [string]$OutDir       = (Join-Path $PSScriptRoot '..\~REPORTS\scoreboard-data'),
    [string]$TodoPath     = (Join-Path $PSScriptRoot '..\todo'),
    [string]$RegistryConfig = (Join-Path $PSScriptRoot '..\config\cron-aiathon-pipeline.json'),
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent)
)

# VersionTag constant kept in sync with file header (P047 enforces).
$script:ScoreboardSchemaVersion = '2605.B5.V46.1'

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
$parseErrors = New-Object System.Collections.Generic.List[object]
foreach ($f in Get-ChildItem -Path $RegistryPath -Filter '*.json' -File) {
    # G4: Skip REINDEX-MAP and other non-SIN audit files.
    if ($f.Name -like 'REINDEX-*' -or $f.Name -eq 'package.json') { continue }
    try {
        $obj = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $names = $obj.PSObject.Properties.Name
        # G7: support both legacy `sin_id` and newer `id` fields.
        $idVal = if ($names -contains 'sin_id') { [string]$obj.sin_id } elseif ($names -contains 'id') { [string]$obj.id } else { $f.BaseName }
        # G3: read agent_id/reported_by fallback in addition to firstAgent/agent.
        $agentVal = if ($names -contains 'firstAgent') { [string]$obj.firstAgent } `
                    elseif ($names -contains 'agent_id')  { [string]$obj.agent_id } `
                    elseif ($names -contains 'agent')     { [string]$obj.agent } `
                    elseif ($names -contains 'reported_by'){ [string]$obj.reported_by } else { '' }
        # Status: synthesise from is_resolved when no explicit status field.
        $statVal = if ($names -contains 'status') { [string]$obj.status } `
                   elseif ($names -contains 'is_resolved') { if ([bool]$obj.is_resolved) { 'RESOLVED' } else { 'OPEN' } } else { '' }
        $rec = [pscustomobject]@{
            file     = $f.Name
            id       = $idVal
            title    = if ($names -contains 'title')      { [string]$obj.title }      else { '' }
            severity = if ($names -contains 'severity')   { [string]$obj.severity }   else { '' }
            status   = $statVal
            agent    = $agentVal
            category = if ($names -contains 'category')   { [string]$obj.category }   else { '' }
            scannable = ($names -contains 'scan_regex' -and -not [string]::IsNullOrWhiteSpace([string]$obj.scan_regex))
            kind     = if ($f.Name -like 'SIN-PATTERN-*') { 'PATTERN' } elseif ($f.Name -like 'SEMI-SIN-*') { 'SEMI' } else { 'INSTANCE' }
        }
        $all.Add($rec) | Out-Null
    } catch {
        # G2: surface drops instead of silently dropping.
        $parseErrors.Add([pscustomobject]@{ file = $f.Name; error = $_.Exception.Message }) | Out-Null
    }
}

# G5: enumerate candidate + fix queues so they reach the scoreboard.
$candidates = @()
$candDir = Join-Path $RegistryPath 'candidates'
if (Test-Path $candDir) {
    $candidates = @(Get-ChildItem -Path $candDir -Filter 'SIN-CANDIDATE-*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $c = Get-Content -Path $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            [pscustomobject]@{
                file        = $_.Name
                id          = if ($c.PSObject.Properties.Name -contains 'id') { [string]$c.id } else { $_.BaseName }
                title       = if ($c.PSObject.Properties.Name -contains 'title') { [string]$c.title } else { '' }
                occurrences = if ($c.PSObject.Properties.Name -contains 'occurrences') { [int]$c.occurrences } else { 0 }
                severity    = if ($c.PSObject.Properties.Name -contains 'severity') { [string]$c.severity } else { 'Advisory' }
                category    = if ($c.PSObject.Properties.Name -contains 'category') { [string]$c.category } else { '' }
                date_added  = if ($c.PSObject.Properties.Name -contains 'date_added') { [string]$c.date_added } else { '' }
            }
        } catch { $null }
    } | Where-Object { $_ })
}
$fixes = @()
$fixesDir = Join-Path $RegistryPath 'fixes'
if (Test-Path $fixesDir) {
    $fixes = @(Get-ChildItem -Path $fixesDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $fx = Get-Content -Path $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            [pscustomobject]@{
                file           = $_.Name
                fix_id         = if ($fx.PSObject.Properties.Name -contains 'fix_id') { [string]$fx.fix_id } else { $_.BaseName }
                parent_pattern = if ($fx.PSObject.Properties.Name -contains 'parent_pattern') { [string]$fx.parent_pattern } else { '' }
                method         = if ($fx.PSObject.Properties.Name -contains 'method') { [string]$fx.method } else { '' }
                verified       = if ($fx.PSObject.Properties.Name -contains 'verified') { [bool]$fx.verified } else { $false }
                reuse_count    = if ($fx.PSObject.Properties.Name -contains 'reuse_count') { [int]$fx.reuse_count } else { 0 }
            }
        } catch { $null }
    } | Where-Object { $_ })
}

# G6: enumerate todo bug stream + open registry items so scoreboard reflects live state.
$bugsOpen = @()
$bugs2fixOpen = @()
if (Test-Path $TodoPath) {
    foreach ($glob in @('Bug-*.json','BUG-*.json','Bugs2FIX-*.json')) {
        foreach ($bf in Get-ChildItem -Path $TodoPath -Filter $glob -File -ErrorAction SilentlyContinue) {
            try {
                $bj = Get-Content -Path $bf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $bs = if ($bj.PSObject.Properties.Name -contains 'status') { [string]$bj.status } else { '' }
                if ($bs -ne 'OPEN' -and $bs -ne 'IN-PROGRESS' -and $bs -ne 'IN_PROGRESS' -and $bs -ne 'PLANNED') { continue }
                $rec = [pscustomobject]@{
                    file       = $bf.Name
                    id         = if ($bj.PSObject.Properties.Name -contains 'id') { [string]$bj.id } else { $bf.BaseName }
                    title      = if ($bj.PSObject.Properties.Name -contains 'title') { [string]$bj.title } else { '' }
                    status     = $bs
                    priority   = if ($bj.PSObject.Properties.Name -contains 'priority') { [string]$bj.priority } else { '' }
                    sinId      = if ($bj.PSObject.Properties.Name -contains 'sinId') { [string]$bj.sinId } else { '' }
                    sinPattern = if ($bj.PSObject.Properties.Name -contains 'sinPattern') { [string]$bj.sinPattern } else { '' }
                    category   = if ($bj.PSObject.Properties.Name -contains 'category') { [string]$bj.category } else { '' }
                }
                if ($glob -like 'Bug*-*' -or $glob -like 'BUG*-*') { if ($glob -like 'Bugs2FIX*') { $bugs2fixOpen += $rec } else { $bugsOpen += $rec } }
                else { $bugs2fixOpen += $rec }
            } catch { <# Intentional: non-fatal -- malformed record silently skipped during glob parse #> }
        }
    }
}

$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

# --- Write per-metric manifests ---------------------------------------------
# P037 mitigation: precompute @().Count into local vars before using inside literal.
$resolved   = @($all | Where-Object { $_.status -match '^(RESOLVED|FIXED|CLOSED|DONE)$' })
$unresolved = @($all | Where-Object { $_.status -notmatch '^(RESOLVED|FIXED|CLOSED|DONE)$' })
# G8: severity vocab now includes Blocking + critical aliases.
$critical   = @($all | Where-Object { $_.severity -match '^(CRITICAL|CRIT|BLOCKING)$' })
$patterns   = @($all | Where-Object { $_.kind -eq 'PATTERN' })
$semisins   = @($all | Where-Object { $_.kind -eq 'SEMI' })
# G10 surfacing: which patterns actually have a working scan_regex.
$patternsScannable    = @($patterns | Where-Object { $_.scannable })
$patternsManualOnly   = @($patterns | Where-Object { -not $_.scannable })

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
Save-Json 'patterns.json'   ([pscustomobject]@{ generated = $generated; count = $patternsCount;   items = $patterns; scannableCount = $patternsScannable.Count; manualOnlyCount = $patternsManualOnly.Count; manualOnlyIds = @($patternsManualOnly | ForEach-Object { $_.id }) })
Save-Json 'semi-sins.json'  ([pscustomobject]@{ generated = $generated; count = $semiCount;       items = $semisins   })
# G5/G6 new manifests:
Save-Json 'candidates.json'  ([pscustomobject]@{ generated = $generated; count = $candidates.Count;   items = $candidates  })
Save-Json 'fixes.json'       ([pscustomobject]@{ generated = $generated; count = $fixes.Count;        items = $fixes;     verifiedCount = @($fixes | Where-Object { $_.verified }).Count;     orphanCount = @($fixes | Where-Object { $_.parent_pattern -eq 'unknown' -or [string]::IsNullOrWhiteSpace($_.parent_pattern) }).Count })
Save-Json 'bugs-open.json'   ([pscustomobject]@{ generated = $generated; count = $bugsOpen.Count;     items = $bugsOpen     })
Save-Json 'bugs2fix-open.json' ([pscustomobject]@{ generated = $generated; count = $bugs2fixOpen.Count; items = $bugs2fixOpen })
# G2: parse-error visibility (zero rows when healthy).
Save-Json 'parse-errors.json' ([pscustomobject]@{ generated = $generated; count = $parseErrors.Count; items = $parseErrors })

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
    version = $script:ScoreboardSchemaVersion
    files = @(
        @{ key='total-sins';     file='total-sins.json';     label='Total Sins';      count = $totalCount }
        @{ key='resolved';       file='resolved.json';       label='Resolved';        count = $resolvedCount }
        @{ key='unresolved';     file='unresolved.json';     label='Unresolved';      count = $unresolvedCount }
        @{ key='critical';       file='critical.json';       label='Critical';        count = $criticalCount }
        @{ key='patterns';       file='patterns.json';       label='SIN Patterns';    count = $patternsCount }
        @{ key='semi-sins';      file='semi-sins.json';      label='Semi-SINs';       count = $semiCount }
        @{ key='tools';          file='tools.json';          label='Tools';           count = $toolsCount }
        @{ key='candidates';     file='candidates.json';     label='Candidates';      count = $candidates.Count }
        @{ key='fixes';          file='fixes.json';          label='Fixes';           count = $fixes.Count }
        @{ key='bugs-open';      file='bugs-open.json';      label='Open Bugs';       count = $bugsOpen.Count }
        @{ key='bugs2fix-open';  file='bugs2fix-open.json';  label='Open Bugs2FIX';   count = $bugs2fixOpen.Count }
        @{ key='parse-errors';   file='parse-errors.json';   label='Parse Errors';    count = $parseErrors.Count }
    )
    health = [pscustomobject]@{
        patternsScannable    = $patternsScannable.Count
        patternsManualOnly   = $patternsManualOnly.Count
        manualOnlyIds        = @($patternsManualOnly | ForEach-Object { $_.id })
        parseErrorCount      = $parseErrors.Count
        candidatePromotionPending = $candidates.Count
        orphanFixCount       = @($fixes | Where-Object { $_.parent_pattern -eq 'unknown' -or [string]::IsNullOrWhiteSpace($_.parent_pattern) }).Count
    }
}
Save-Json 'index.json' $index

# Best-effort SIN-scope event emission (G15 partial closure: scoreboard regen is now an audit event).
try {
    $adapter = Join-Path $WorkspacePath 'modules\PwShGUI-EventLogAdapter.psm1'
    if (Test-Path $adapter) {
        Import-Module $adapter -Force -DisableNameChecking -ErrorAction Stop
        $eventId = [int64]('{0}{1:D3}' -f (Get-Date -Format 'yyMMddHHmmss'), 1)
        Write-EventLogNormalized -Scope sin -Component 'iter41-scoreboard-data-gen' `
            -Message ("Scoreboard manifests regenerated (sins={0}, patterns={1}, candidates={2}, parseErrors={3})" -f $totalCount, $patternsCount, $candidates.Count, $parseErrors.Count) `
            -Severity Info -WorkspacePath $WorkspacePath -EventId $eventId -ItemType 'Scoreboard' -ActionId 'iter41-regen' -AgentId 'Scoreboard-DataGen' -Editor ([string]$env:USERNAME)
    }
} catch { <# Intentional: non-fatal -- event emission is best-effort #> }

"Wrote scoreboard-data manifests to: $OutDir"
"  total-sins:    $totalCount"
"  resolved:      $resolvedCount"
"  unresolved:    $unresolvedCount"
"  critical:      $criticalCount"
"  patterns:      $patternsCount  (scannable=$($patternsScannable.Count) manualOnly=$($patternsManualOnly.Count))"
"  semi-sins:     $semiCount"
"  tools:         $toolsCount (built: $builtCount)"
"  candidates:    $($candidates.Count)"
"  fixes:         $($fixes.Count)"
"  bugs-open:     $($bugsOpen.Count)"
"  bugs2fix-open: $($bugs2fixOpen.Count)"
"  parseErrors:   $($parseErrors.Count)"

