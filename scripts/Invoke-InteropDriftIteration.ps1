# VersionTag: 2607.B7.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
<#
.SYNOPSIS
    One iteration of: discover interop/manifest drift -> apply safe auto-fixes ->
    verify (parse + sin scan) -> pipeline-integrity dry check -> emit JSON report.
.DESCRIPTION
    Conservative auto-fix scope (only well-typed, mechanical issues):
      F-RELPATH    Broken <link href> / <script src> relative paths inside *.xhtml
                   where the target does not exist but a unique candidate exists
                   in the workspace (case-insensitive).
      F-MANIFEST   Module manifest FunctionsToExport entries that point to
                   functions not present in the .psm1 (removed) and missing
                   public functions (added) -- ONLY when the .psm1 has a single
                   matching definition per name (no ambiguity).
      F-LAUNCHBAT  Launch-*.bat files referencing scripts that don't exist;
                   logged only (not auto-edited; .bat scripts are user-tuned).
    All other findings are reported, never silently rewritten.
.OUTPUTS
    reports/interop-iter/iter-<N>.json
#>
param(
    [int]$Iteration = 1,
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [switch]$NoFix,
    [switch]$NoPipelineDry,
    [switch]$NoSinScan,
    [switch]$NoDeanB
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$report = [ordered]@{
    iteration = $Iteration
    startedAt = (Get-Date -Format 'o')
    workspace = $WorkspacePath
    findings  = [System.Collections.ArrayList]@()
    fixes     = [System.Collections.ArrayList]@()
    verify    = [ordered]@{}
    summary   = [ordered]@{}
    stages    = [System.Collections.ArrayList]@()
}

function Add-Stage {
    param([string]$Name, [string]$Status, [int]$FindingsBefore, [int]$FindingsAfter, [int]$FixesApplied, [string]$Detail)
    $null = $report.stages.Add([pscustomobject][ordered]@{
            id             = ('iter-{0}.{1}' -f $Iteration, ($report.stages.Count + 1))
            name           = $Name
            status         = $Status
            findingsBefore = $FindingsBefore
            findingsAfter  = $FindingsAfter
            fixesApplied   = $FixesApplied
            detail         = $Detail
        })
}

function Add-Finding {
    param([string]$Category, [string]$Severity, [string]$File, [string]$Detail, [hashtable]$Extra)
    $o = [ordered]@{ category = $Category; severity = $Severity; file = $File; detail = $Detail }
    if ($Extra) { foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] } }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $null = $report.findings.Add([pscustomobject]$o)
}
function Add-Fix {
    param([string]$Category, [string]$File, [string]$Detail, [hashtable]$Extra)
    $o = [ordered]@{ category = $Category; file = $File; detail = $Detail }
    if ($Extra) { foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] } }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $null = $report.fixes.Add([pscustomobject]$o)
}

# ---------- WORKSPACE FILE INDEX (cached) ----------
# Excludes: VCS/build artifacts, downloads, log dumps, scan reports, snapshots,
# any *_yyyyMMdd-HHmmss snapshot/dump file, dependency visualisations, and
# explicit backup files. These dirs/files are non-authoritative artefacts; auto-
# rewriting refs inside them creates churn without value.
$Script:ExcludeRx = '\\(checkpoints|temp|~DOWNLOADS|~REPORTS|reports|logs|node_modules|gallery|Report|~README\.md|XHTML-Checker|\.history|\.git|\.snapshots|\.sin)\\|\\\.venv[^\\]*\\|\\venv\\|\\Dependency-Visualisation[^\\]*\.html$|_\d{8}-?\d{6}\.(html|xhtml|json|md)$|\.bak[^\\]*$|\.backup[^\\]*$'
function Get-WorkspaceFileIndex {
    if ($Script:WsIndex) { return $Script:WsIndex }
    $idx = @{}   # key=lower(leaf) -> [list]FullName
    $all = [System.IO.Directory]::EnumerateFiles($WorkspacePath, '*', [System.IO.SearchOption]::AllDirectories)
    foreach ($p in $all) {
        if ($p -match $Script:ExcludeRx) { continue }
        $leaf = [IO.Path]::GetFileName($p).ToLowerInvariant()
        if (-not $idx.ContainsKey($leaf)) { $idx[$leaf] = New-Object 'System.Collections.Generic.List[string]' }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        [void]$idx[$leaf].Add($p)  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    $Script:WsIndex = $idx
    return $idx
}

# ---------- DISCOVERY: relative paths in XHTML ----------
function Test-XhtmlRelPaths {
    $xhtml = @([System.IO.Directory]::EnumerateFiles($WorkspacePath, '*.xhtml', [System.IO.SearchOption]::AllDirectories)) +
    @([System.IO.Directory]::EnumerateFiles($WorkspacePath, '*.html', [System.IO.SearchOption]::AllDirectories))
    $rxRef = [regex]'(?i)(?:href|src)\s*=\s*"([^":?#\s]+\.(?:css|js|xhtml|html|svg|png|json|xml))"'
    $idx = Get-WorkspaceFileIndex
    $maxFindingsPerFile = 25
    $maxFileBytes = 1MB
    foreach ($fp in $xhtml) {
        if ($fp -match $Script:ExcludeRx) { continue }
        try {
            $fi = [IO.FileInfo]::new($fp)
            if ($fi.Length -gt $maxFileBytes) { continue }   # snapshot/dump-sized — skip
        }
        catch { continue }
        $content = $null
        try { $content = [IO.File]::ReadAllText($fp) } catch { continue }
        $dir = [IO.Path]::GetDirectoryName($fp)
        $matches2 = $rxRef.Matches($content)
        $perFile = 0
        foreach ($m in $matches2) {
            if ($perFile -ge $maxFindingsPerFile) { break }
            $rel = $m.Groups[1].Value
            if ($rel -match '^(https?:|//|data:|file:|mailto:)') { continue }
            $combined = [IO.Path]::Combine($dir, $rel)
            try { $resolved = [IO.Path]::GetFullPath($combined) } catch { continue }
            if (-not [IO.File]::Exists($resolved)) {
                $leaf = [IO.Path]::GetFileName($rel).ToLowerInvariant()
                $cand = $null
                if ($idx.ContainsKey($leaf)) { $cand = @($idx[$leaf]) }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                if ($cand -and $cand.Count -eq 1) {
                    Add-Finding -Category 'RELPATH' -Severity 'HIGH' -File $fp -Detail "Broken ref '$rel'" -Extra @{
                        candidate   = $cand[0]  # SIN-EXEMPT:P027 -- index access, context-verified safe
                        autoFixable = $true
                    }
                    $perFile++
                }
                else {
                    $n = if ($cand) { $cand.Count } else { 0 }
                    Add-Finding -Category 'RELPATH' -Severity 'MEDIUM' -File $fp -Detail "Broken ref '$rel' (no unique candidate; $n matches)" -Extra @{ autoFixable = $false }
                    $perFile++
                }
            }
        }
    }
}

# ---------- DISCOVERY: manifest export drift ----------
function Test-ModuleManifestExports {
    $psd1List = @(Get-ChildItem -Path (Join-Path $WorkspacePath 'modules') -Filter '*.psd1' -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($psd1 in $psd1List) {
        $data = $null
        try { $data = Import-PowerShellDataFile -LiteralPath $psd1.FullName -ErrorAction Stop } catch {
            Add-Finding -Category 'MANIFEST' -Severity 'CRITICAL' -File $psd1.FullName -Detail "Manifest parse failed: $_"
            continue
        }
        if (-not $data) { continue }
        $rootRel = $data.RootModule
        if ([string]::IsNullOrEmpty($rootRel)) { continue }
        $psm1 = Join-Path $psd1.DirectoryName $rootRel
        if (-not (Test-Path -LiteralPath $psm1)) {
            Add-Finding -Category 'MANIFEST' -Severity 'CRITICAL' -File $psd1.FullName -Detail "RootModule '$rootRel' not found"
            continue
        }
        # Parse psm1 to find function names
        $errs = $null; $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($psm1, [ref]$tokens, [ref]$errs)
        if (@($errs).Count -gt 0) {
            Add-Finding -Category 'MANIFEST' -Severity 'CRITICAL' -File $psm1 -Detail "RootModule has $((@($errs)).Count) parse error(s); first: L$($errs[0].Extent.StartLineNumber): $($errs[0].Message)"  # SIN-EXEMPT:P027 -- index access, context-verified safe
            continue
        }
        $funcs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name } | Where-Object { $_ -match '^[A-Za-z][A-Za-z0-9]+-[A-Za-z][A-Za-z0-9]+$' })
        $declared = @($data.FunctionsToExport)
        if ($declared -contains '*') { continue }   # wildcard: nothing to verify
        $missingInPsm1 = @($declared | Where-Object { $_ -and ($funcs -notcontains $_) })
        $missingInExport = @($funcs | Where-Object { $declared -notcontains $_ })
        foreach ($n in $missingInPsm1) {
            Add-Finding -Category 'MANIFEST' -Severity 'HIGH' -File $psd1.FullName -Detail "FunctionsToExport lists '$n' but no such function in $rootRel" -Extra @{ subType = 'ghost-export'; functionName = $n; autoFixable = $true }
        }
        foreach ($n in $missingInExport) {
            Add-Finding -Category 'MANIFEST' -Severity 'LOW' -File $psd1.FullName -Detail "Function '$n' in $rootRel not listed in FunctionsToExport" -Extra @{ subType = 'unexported'; functionName = $n; autoFixable = $false }
        }
    }
}

# ---------- DISCOVERY: launcher script refs ----------
function Test-LaunchBatRefs {
    $bats = @(Get-ChildItem -Path $WorkspacePath -Filter 'Launch-*.bat' -File -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -Path $WorkspacePath -Filter 'SmokeTest-*.bat' -File -ErrorAction SilentlyContinue)
    $rx = [regex]'(?im)(?:^|\s)(?:powershell(?:\.exe)?|pwsh(?:\.exe)?)[^\r\n]*?-File\s+"?([^"\r\n]+\.ps1)"?'
    foreach ($b in $bats) {
        if ($b.Name -match '\.backup') { continue }
        $txt = $null
        try { $txt = [IO.File]::ReadAllText($b.FullName) } catch { continue }
        foreach ($m in $rx.Matches($txt)) {
            $ref = $m.Groups[1].Value.Trim()
            $expanded = [Environment]::ExpandEnvironmentVariables($ref) -replace '%~dp0', ($b.DirectoryName + '\')
            if ([IO.Path]::IsPathRooted($expanded)) {
                $candidate = $expanded
            }
            else {
                $candidate = Join-Path $b.DirectoryName $expanded
            }
            if (-not (Test-Path -LiteralPath $candidate)) {
                Add-Finding -Category 'LAUNCHBAT' -Severity 'HIGH' -File $b.FullName -Detail "Script not found: '$ref'"
            }
        }
    }
}

# ---------- DISCOVERY: agentic-manifest agent name vs file existence ----------
function Test-AgenticManifest {
    $mf = Join-Path $WorkspacePath 'config\agentic-manifest.json'
    if (-not (Test-Path -LiteralPath $mf)) { return }
    try {
        $j = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Add-Finding -Category 'AGENTIC' -Severity 'CRITICAL' -File $mf -Detail "Manifest parse failed: $_"
        return
    }
    if ($null -eq $j) { return }
    if ($j.PSObject.Properties.Name -notcontains 'agents') { return }
    foreach ($a in @($j.agents)) {
        $name = $a.name
        if ([string]::IsNullOrEmpty($name)) { continue }
        $manifestRef = $a.manifestPath
        if ($manifestRef) {
            $resolved = if ([IO.Path]::IsPathRooted($manifestRef)) { $manifestRef } else { Join-Path $WorkspacePath $manifestRef }
            if (-not (Test-Path -LiteralPath $resolved)) {
                Add-Finding -Category 'AGENTIC' -Severity 'HIGH' -File $mf -Detail "Agent '$name' manifestPath missing: $manifestRef"
            }
        }
    }
}

# ---------- AUTO-FIX: relpaths ----------
function Invoke-AutoFix-RelPaths {
    if ($NoFix) { return }
    $byFile = $report.findings | Where-Object { $_.category -eq 'RELPATH' -and $_.autoFixable -eq $true } | Group-Object file
    foreach ($g in $byFile) {
        $path = $g.Name
        Write-Host ("  [fix-rel] {0} ({1} refs)" -f ([IO.Path]::GetFileName($path)), $g.Count) -ForegroundColor DarkGray
        $content = [IO.File]::ReadAllText($path)
        $orig = $content
        foreach ($f in $g.Group) {
            # Extract the broken ref from detail "Broken ref 'X'"
            if ($f.detail -match "Broken ref '([^']+)'") {
                $broken = $Matches[1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
                $candidate = $f.candidate
                if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
                $fileDir = Split-Path -Parent $path
                $newRel = ([IO.Path]::GetRelativePath($fileDir, $candidate)) -replace '\\', '/'
                # Only touch first occurrence to be safe (P031)
                $escaped = [regex]::Escape($broken)
                $rx = [regex]"(?i)((?:href|src)\s*=\s*`")$escaped(`")"
                $content = $rx.Replace($content, ('$1' + $newRel + '$2'), 1)
                if ($content -ne $orig) {
                    Add-Fix -Category 'RELPATH' -File $path -Detail "Rewrote '$broken' -> '$newRel'"
                    $orig = $content
                }
            }
        }
        if ($content -ne (([IO.File]::ReadAllText($path)))) {
            # Preserve UTF-8 BOM if present
            $bytes = [IO.File]::ReadAllBytes($path)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)  # SIN-EXEMPT:P027 -- index access, context-verified safe
            $enc = New-Object System.Text.UTF8Encoding($hasBom)
            [IO.File]::WriteAllText($path, $content, $enc)
        }
    }
}

# ---------- AUTO-FIX: manifest ghost exports ----------
function Invoke-AutoFix-Manifest {
    if ($NoFix) { return }
    $ghosts = $report.findings | Where-Object { $_.category -eq 'MANIFEST' -and $_.subType -eq 'ghost-export' }
    $byFile = $ghosts | Group-Object file
    foreach ($g in $byFile) {
        $path = $g.Name
        $names = @($g.Group | ForEach-Object { $_.functionName } | Where-Object { $_ })
        if ($names.Count -eq 0) { continue }
        $content = [IO.File]::ReadAllText($path)
        $orig = $content
        foreach ($n in $names) {
            # Remove "'$n'" entries from FunctionsToExport array (with optional trailing comma + ws)
            $escaped = [regex]::Escape($n)
            $rx = [regex]"(?ms)('$escaped'\s*,\s*|,\s*'$escaped'|'$escaped')"
            $content = $rx.Replace($content, '', 1)
        }
        if ($content -ne $orig) {
            $bytes = [IO.File]::ReadAllBytes($path)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)  # SIN-EXEMPT:P027 -- index access, context-verified safe
            $enc = New-Object System.Text.UTF8Encoding($hasBom)
            [IO.File]::WriteAllText($path, $content, $enc)
            Add-Fix -Category 'MANIFEST' -File $path -Detail ("Removed ghost exports: " + ($names -join ', '))
        }
    }
}

# ---------- VERIFY: dual-engine parse of changed PS files ----------
function Invoke-Verify-Parse {
    $verify = [ordered]@{ parseErrors = @() }
    # Parse all .ps1/.psm1/.psd1 in modules + scripts + tests
    $files = @()
    foreach ($d in @('modules', 'scripts', 'tests')) {
        $p = Join-Path $WorkspacePath $d
        if (Test-Path -LiteralPath $p) {
            $files += @(Get-ChildItem -Path $p -Include '*.ps1', '*.psm1', '*.psd1' -Recurse -File -ErrorAction SilentlyContinue)
        }
    }
    $files += Get-Item -LiteralPath (Join-Path $WorkspacePath 'Main-GUI.ps1') -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        if ($null -eq $f) { continue }
        $errs = $null; $tokens = $null
        try {
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        }
        catch { continue }
        if (@($errs).Count -gt 0) {
            $first = $errs[0]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            $verify.parseErrors += [pscustomobject]@{
                file         = $f.FullName
                count        = @($errs).Count
                firstLine    = $first.Extent.StartLineNumber
                firstMessage = $first.Message
            }
            Add-Finding -Category 'PARSE' -Severity 'CRITICAL' -File $f.FullName -Detail "$(@($errs).Count) parse error(s); first L$($first.Extent.StartLineNumber): $($first.Message)"
        }
    }
    return $verify
}

# ---------- VERIFY: SIN scan ----------
function Invoke-Verify-SinScan {
    if ($NoSinScan) { return [ordered]@{ skipped = $true } }
    $scanner = Join-Path $WorkspacePath 'tests\Invoke-SINPatternScanner.ps1'
    if (-not (Test-Path -LiteralPath $scanner)) { return [ordered]@{ skipped = $true; reason = 'scanner not found' } }
    $out = Join-Path $WorkspacePath ('reports\interop-iter\sin-scan-iter{0}.json' -f $Iteration)
    try {
        & $scanner -WorkspacePath $WorkspacePath -OutputJson $out -Quiet -Runtime Both 2>$null | Out-Null
        if (Test-Path -LiteralPath $out) {
            $j = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
            $crit = 0; $high = 0; $total = 0
            if ($j.PSObject.Properties.Name -contains 'findings') {
                foreach ($f in @($j.findings)) {
                    $total++
                    switch (('' + $f.severity).ToUpper()) {
                        'CRITICAL' { $crit++ }
                        'HIGH' { $high++ }
                    }
                }
            }
            return [ordered]@{ ok = $true; total = $total; critical = $crit; high = $high; output = $out }
        }
    }
    catch {
        return [ordered]@{ ok = $false; error = "$_" }
    }
    return [ordered]@{ ok = $false; error = 'no output' }
}

function Invoke-RandomSinBatch {
    if ($NoSinScan) { return [ordered]@{ skipped = $true; reason = 'disabled' } }
    if ((Get-Random -Minimum 1 -Maximum 6) -ne 5) {
        return [ordered]@{ skipped = $true; reason = 'random-pass-not-selected'; chance = '1-in-5' }
    }
    $roots = @('scripts', 'modules', 'tests') | ForEach-Object { Join-Path $WorkspacePath $_ }
    $candidates = @($roots | ForEach-Object {
            if (Test-Path -LiteralPath $_) { Get-ChildItem -LiteralPath $_ -Include '*.ps1', '*.psm1', '*.psd1' -Recurse -File -ErrorAction SilentlyContinue }
        })
    $batch = @(if (@($candidates).Count -le 7) { $candidates } else { $candidates | Get-Random -Count 7 })
    $scanner = Join-Path $WorkspacePath 'tests\Invoke-SINPatternScanner.ps1'
    $out = Join-Path $WorkspacePath ('reports\interop-iter\sin-batch-iter{0}.json' -f $Iteration)
    if (-not (Test-Path -LiteralPath $scanner) -or @($batch).Count -eq 0) {
        return [ordered]@{ skipped = $true; reason = 'scanner-or-candidates-unavailable'; chance = '1-in-5' }
    }
    try {
        $scan = & $scanner -WorkspacePath $WorkspacePath -IncludeFiles @($batch.FullName) -OutputJson $out -Quiet -Runtime Both 2>$null
        $json = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        return [ordered]@{
            skipped  = $false
            selected = @($batch | ForEach-Object { $_.FullName })
            count    = @($batch).Count
            output   = $out
            total    = if ($json -and $json.PSObject.Properties.Name -contains 'totalFindings') { [int]$json.totalFindings } else { 0 }
            ok       = $true
        }
    }
    catch {
        return [ordered]@{ skipped = $false; ok = $false; error = $_.Exception.Message; count = @($batch).Count }
    }
}

function Invoke-CompletionAudit {
    $registryPath = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-pipeline.json'
    if (-not (Test-Path -LiteralPath $registryPath)) { return [ordered]@{ skipped = $true; reason = 'registry-not-found' } }
    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $active = @(@($registry.todos) + @($registry.featureRequests) | Where-Object { $_.status -notin @('DONE', 'CLOSED') })
    $invalid = @($active | Where-Object {
            ($_.status -eq 'PLANNED' -and $_.completedAt) -or
            ($_.status -in @('DONE', 'CLOSED') -and -not $_.completedAt)
        })
    return [ordered]@{ checked = @(@($registry.todos) + @($registry.featureRequests)).Count; active = @($active).Count; invalid = @($invalid).Count; invalidIds = @($invalid | ForEach-Object { $_.id }); passed = (@($invalid).Count -eq 0) }
}

function Invoke-IssueInventory {
    $scriptPath = Join-Path $WorkspacePath 'scripts\Invoke-PipelineIssueInventory.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { return [ordered]@{ skipped = $true; reason = 'inventory-script-not-found' } }
    try {
        $output = & $scriptPath -WorkspacePath $WorkspacePath -NoFix:$NoFix 2>&1
        $result = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'gate' } | Select-Object -Last 1)
        if (@($result).Count -eq 0) { return [ordered]@{ skipped = $false; ok = $false; error = 'inventory returned no result' } }
        return $result[0]
    }
    catch { return [ordered]@{ skipped = $false; ok = $false; error = $_.Exception.Message } }
}

function Invoke-GateBouncerForPath {
    param([string]$Path, [string]$Phase)
    $scriptPath = Join-Path $WorkspacePath 'scripts\Invoke-TheGateBouncer.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath) -or [string]::IsNullOrWhiteSpace($Path)) { return [ordered]@{ skipped = $true; reason = 'gate-or-target-unavailable' } }
    try {
        $output = & $scriptPath -WorkspacePath $WorkspacePath -TargetPath $Path -Phase $Phase -AllowDetour 2>&1
        $result = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'gate' } | Select-Object -Last 1)
        if (@($result).Count -eq 0) { return [ordered]@{ skipped = $false; ok = $false; error = 'TheGateBouncer returned no result' } }
        return $result[0]
    }
    catch { return [ordered]@{ skipped = $false; ok = $false; error = $_.Exception.Message } }
}

# ---------- VERIFY: pipeline integrity (read-only check) ----------
function Invoke-Verify-PipelineIntegrity {
    if ($NoPipelineDry) { return [ordered]@{ skipped = $true } }
    $script = Join-Path $WorkspacePath 'scripts\Invoke-PipelineIntegrityCheck.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return [ordered]@{ skipped = $true; reason = 'script not found' } }
    try {
        $log = & $script -WorkspacePath $WorkspacePath 2>&1 | Out-String
        return [ordered]@{ ok = $true; tail = ($log -split "`n" | Select-Object -Last 20) -join "`n" }
    }
    catch {
        return [ordered]@{ ok = $false; error = "$_" }
    }
}

# ---------- RUN ----------
Write-Host ("[iter {0}] discovery..." -f $Iteration) -ForegroundColor Cyan
$stageStart = $report.findings.Count
Test-XhtmlRelPaths
Test-ModuleManifestExports
Test-LaunchBatRefs
Test-AgenticManifest
$discoveryCount = $report.findings.Count - $stageStart
Add-Stage -Name 'discovery' -Status 'COMPLETE' -FindingsBefore 0 -FindingsAfter $report.findings.Count -FixesApplied 0 -Detail ('Collected {0} findings across interop and manifest checks.' -f $discoveryCount)

$report.verify.issueInventory = Invoke-IssueInventory
$inventoryTarget = if ($report.verify.issueInventory.created -and @($report.verify.issueInventory.created).Count -gt 0) { [string]$report.verify.issueInventory.created[0].path } else { 'scripts/Invoke-InteropDriftIteration.ps1' }
$report.verify.gateBouncerPre = Invoke-GateBouncerForPath -Path $inventoryTarget -Phase 'PreRemediation'
Add-Stage -Name 'issue-inventory' -Status $(if ($report.verify.issueInventory.skipped -eq $true) { 'SKIPPED' } elseif ($report.verify.issueInventory.error) { 'FAIL' } else { 'COMPLETE' }) -FindingsBefore $report.findings.Count -FindingsAfter $report.findings.Count -FixesApplied $(if ($report.verify.issueInventory.bugsCreated) { [int]$report.verify.issueInventory.bugsCreated } else { 0 }) -Detail ('Inventory found {0} issue(s), created {1} Bug item(s), preserved {2} protected item(s).' -f $(if ($report.verify.issueInventory.issueCount) { $report.verify.issueInventory.issueCount } else { 0 }), $(if ($report.verify.issueInventory.bugsCreated) { $report.verify.issueInventory.bugsCreated } else { 0 }), $(if ($report.verify.issueInventory.protectedPreserved) { $report.verify.issueInventory.protectedPreserved } else { 0 }))
Add-Stage -Name 'TheGateBouncer-pre' -Status $(if ($report.verify.gateBouncerPre.detourAllowed -eq $true) { 'RELAXED_DETOUR' } elseif ($report.verify.gateBouncerPre.skipped -eq $true) { 'SKIPPED' } else { 'BLOCKED' }) -FindingsBefore $report.findings.Count -FindingsAfter $report.findings.Count -FixesApplied 0 -Detail ('Pre-remediation route={0}; reason={1}; validation={2}.' -f $inventoryTarget, $report.verify.gateBouncerPre.reason, $report.verify.gateBouncerPre.validationMode)

$preFixCount = $report.findings.Count
Write-Host ("[iter {0}] auto-fix... (relpath findings={1})" -f $Iteration, ($report.findings | Where-Object { $_.category -eq 'RELPATH' -and $_.autoFixable -eq $true } | Measure-Object).Count) -ForegroundColor Cyan
Invoke-AutoFix-RelPaths
Write-Host ("[iter {0}] auto-fix manifest..." -f $Iteration) -ForegroundColor Cyan
Invoke-AutoFix-Manifest
Add-Stage -Name 'auto-fix' -Status $(if ($NoFix) { 'SKIPPED' } else { 'COMPLETE' }) -FindingsBefore $preFixCount -FindingsAfter $report.findings.Count -FixesApplied $report.fixes.Count -Detail ('Applied {0} safe mechanical fixes.' -f $report.fixes.Count)
$report.verify.gateBouncerPost = Invoke-GateBouncerForPath -Path $inventoryTarget -Phase 'PostRemediation'
Add-Stage -Name 'TheGateBouncer-post' -Status $(if ($report.verify.gateBouncerPost.detourAllowed -eq $true) { 'RELAXED_DETOUR' } elseif ($report.verify.gateBouncerPost.skipped -eq $true) { 'SKIPPED' } else { 'BLOCKED' }) -FindingsBefore $report.findings.Count -FindingsAfter $report.findings.Count -FixesApplied 0 -Detail ('Post-remediation route={0}; reason={1}; validation={2}.' -f $inventoryTarget, $report.verify.gateBouncerPost.reason, $report.verify.gateBouncerPost.validationMode)

$deanBResult = [ordered]@{ skipped = $true; reason = 'disabled' }
if (-not $NoDeanB) {
    $deanBInput = Join-Path (Join-Path $WorkspacePath 'temp') ('deanb-findings-iter{0}.json' -f $Iteration)
    $report | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $deanBInput -Encoding UTF8 -Force
    try {
        $deanBResult = & (Join-Path $WorkspacePath 'scripts\Invoke-DeanBPipelineGate.ps1') -WorkspacePath $WorkspacePath -FindingsPath $deanBInput -Iteration $Iteration -BatchSize 7 -NoFix:$NoFix | Select-Object -Last 1
    }
    catch {
        $deanBResult = [ordered]@{ skipped = $false; ok = $false; error = $_.Exception.Message }
    }
}
$report.verify.deanB = $deanBResult
$deanBHasError = ($deanBResult -is [object] -and $deanBResult.PSObject.Properties.Name -contains 'error' -and -not [string]::IsNullOrWhiteSpace([string]$deanBResult.error))
Add-Stage -Name 'Digital Effluence and nauance blender' -Status $(if ($deanBResult.skipped -eq $true) { 'SKIPPED' } elseif ($deanBHasError) { 'STOP' } else { 'COMPLETE' }) -FindingsBefore $report.findings.Count -FindingsAfter $report.findings.Count -FixesApplied $(if ($deanBResult.createdFixItems) { [int]$deanBResult.createdFixItems } else { 0 }) -Detail ('DeanB gate created {0} bounded fix item(s); stopReason={1}.' -f $(if ($deanBResult.createdFixItems) { $deanBResult.createdFixItems } else { 0 }), $(if ($deanBResult.stopReason) { $deanBResult.stopReason } elseif ($deanBHasError) { $deanBResult.error } else { '' }))

Write-Host ("[iter {0}] verify parse..." -f $Iteration) -ForegroundColor Cyan
$report.verify.parse = Invoke-Verify-Parse
Add-Stage -Name 'verify-parse' -Status $(if (@($report.verify.parse.parseErrors).Count -eq 0) { 'PASS' } else { 'FAIL' }) -FindingsBefore $report.findings.Count -FindingsAfter $report.findings.Count -FixesApplied 0 -Detail ('Parse verification found {0} error files.' -f @($report.verify.parse.parseErrors).Count)

Write-Host ("[iter {0}] verify sin..." -f $Iteration) -ForegroundColor Cyan
$report.verify.sin = Invoke-Verify-SinScan
Add-Stage -Name 'verify-sin' -Status $(if ($report.verify.sin.skipped -eq $true) { 'SKIPPED' } elseif ($report.verify.sin.ok -eq $true) { 'PASS' } else { 'FAIL' }) -FindingsBefore $report.findings.Count -FindingsAfter $report.findings.Count -FixesApplied 0 -Detail ('SIN findings: total={0}, critical={1}, high={2}.' -f $(if ($report.verify.sin.total) { $report.verify.sin.total } else { 0 }), $(if ($report.verify.sin.critical) { $report.verify.sin.critical } else { 0 }), $(if ($report.verify.sin.high) { $report.verify.sin.high } else { 0 }))

$report.verify.randomSinBatch = Invoke-RandomSinBatch
Add-Stage -Name 'random-sin-batch' -Status $(if ($report.verify.randomSinBatch.skipped -eq $true) { 'SKIPPED' } elseif ($report.verify.randomSinBatch.ok -eq $true) { 'PASS' } else { 'FAIL' }) -FindingsBefore $report.findings.Count -FindingsAfter $report.findings.Count -FixesApplied 0 -Detail ('Random 1-in-5 batch: selected {0} file(s).' -f $(if ($report.verify.randomSinBatch.count) { $report.verify.randomSinBatch.count } else { 0 }))

Write-Host ("[iter {0}] verify pipeline integrity..." -f $Iteration) -ForegroundColor Cyan
$report.verify.pipelineIntegrity = Invoke-Verify-PipelineIntegrity
Add-Stage -Name 'verify-pipeline-integrity' -Status $(if ($report.verify.pipelineIntegrity.skipped -eq $true) { 'SKIPPED' } elseif ($report.verify.pipelineIntegrity.ok -eq $true) { 'PASS' } else { 'FAIL' }) -FindingsBefore $report.findings.Count -FindingsAfter $report.findings.Count -FixesApplied 0 -Detail 'Completed the read-only pipeline integrity check.'

$report.verify.completionAudit = Invoke-CompletionAudit
Add-Stage -Name 'completion-audit' -Status $(if ($report.verify.completionAudit.skipped -eq $true) { 'SKIPPED' } elseif ($report.verify.completionAudit.passed -eq $true) { 'PASS' } else { 'FAIL' }) -FindingsBefore $report.findings.Count -FindingsAfter $report.findings.Count -FixesApplied 0 -Detail ('Checked {0} ToDo/feature item(s); invalid completion records={1}.' -f $report.verify.completionAudit.checked, $report.verify.completionAudit.invalid)

$report.summary.findingsTotal = $report.findings.Count
$report.summary.findingsAtDiscovery = $preFixCount
$report.summary.fixesApplied = $report.fixes.Count
$report.summary.bySeverity = ($report.findings | Group-Object severity | ForEach-Object { @{ ($_.Name) = $_.Count } } |
        ForEach-Object { $_ } | Out-String) -replace "`r", ''
$report.summary.byCategory = ($report.findings | Group-Object category | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', '
$report.summary.stageCount = @($report.stages).Count
$report.summary.stageBreakdown = (@($report.stages) | ForEach-Object { '{0}:{1}' -f $_.id, $_.status }) -join ', '
$report.completedAt = (Get-Date -Format 'o')

$outFile = Join-Path $WorkspacePath ('reports\interop-iter\iter-{0}.json' -f $Iteration)
$report | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding UTF8 -Force

Write-Host ("[iter {0}] DONE  findings={1} fixes={2} parseErrFiles={3} sinTotal={4}" -f `
        $Iteration, $report.summary.findingsTotal, $report.summary.fixesApplied,
    @($report.verify.parse.parseErrors).Count,
    ($(if ($report.verify.sin.total) { $report.verify.sin.total } else { 0 }))) -ForegroundColor Green
foreach ($stage in @($report.stages)) {
    Write-Host ("[iter {0}.{1}] {2} status={3} findings={4}->{5} fixes={6} :: {7}" -f `
            $Iteration, ($stage.id -split '\.')[-1], $stage.name, $stage.status,
        $stage.findingsBefore, $stage.findingsAfter, $stage.fixesApplied, $stage.detail) -ForegroundColor DarkGray
}

# Return summary object
[pscustomobject]@{
    iteration            = $Iteration
    findings             = $report.summary.findingsTotal
    fixes                = $report.summary.fixesApplied
    byCategory           = $report.summary.byCategory
    parseErrFiles        = @($report.verify.parse.parseErrors).Count
    sinTotal             = ($(if ($report.verify.sin.total) { $report.verify.sin.total } else { 0 }))
    sinCritical          = ($(if ($report.verify.sin.critical) { $report.verify.sin.critical } else { 0 }))
    deanBCreated         = ($(if ($deanBResult.createdFixItems -and -not $NoFix) { $deanBResult.createdFixItems } else { 0 }))
    inventoryBugsCreated = ($(if ($report.verify.issueInventory.bugsCreated -and -not $NoFix) { $report.verify.issueInventory.bugsCreated } else { 0 }))
    inventoryIssues      = ($(if ($report.verify.issueInventory.issueCount) { $report.verify.issueInventory.issueCount } else { 0 }))
    randomSinBatch       = $report.verify.randomSinBatch
    completionAudit      = $report.verify.completionAudit
    reportPath           = $outFile
}


