# VersionTag: 2607.B1.V52.1
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-07-23
# SupportsPS7.6TestedDate: 2026-07-23
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Continuous pipeline refinement scan for path drift, duplicate functions, metadata consistency, and README hygiene.
.DESCRIPTION
    Produces machine-readable JSON and a concise Markdown report under reports/pipeline-refine.
    Supports staged-only scanning, policy-driven severities, duplicate allowlists,
    per-profile baselines, trend output, and baseline-drift changelog notes.
.PARAMETER WorkspacePath
    Workspace root path.
.PARAMETER OutputRoot
    Folder for report outputs.
.PARAMETER UpdateReadme
    If set, runs scripts/Sync-ReadmeFeatureIndex.ps1 to refresh README managed section.
.PARAMETER FailOnDrift
    Exit code 1 when blocking drift is detected (or baseline regressions when baseline is applied).
.PARAMETER StagedOnly
    Restrict duplicate/tag/dotfile scans to staged files (plus canonical required paths for path checks).
.PARAMETER BaselineJson
    Optional explicit baseline file path. If omitted, profile-based default is used.
.PARAMETER BaselineProfile
    Baseline profile name: full, staged, nightly.
.PARAMETER UpdateBaseline
    Writes/refreshes baseline counts from current findings.
.PARAMETER CanonicalPathRegistry
    Optional canonical path registry JSON. Defaults to config/pipeline-canonical-paths.json.
.PARAMETER AllowlistJson
    Duplicate-function allowlist JSON.
.PARAMETER SeverityPolicyJson
    Severity policy JSON.
.PARAMETER ChangelogPath
    Changelog file updated when baseline is refreshed.
.PARAMETER SkipChangelogOnBaselineUpdate
    Skip changelog drift-note append when updating baseline.
.PARAMETER TrendJson
    JSONL trend file path.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputRoot = '',
    [switch]$UpdateReadme,
    [switch]$FailOnDrift,
    [switch]$StagedOnly,
    [string]$BaselineJson = '',
    [ValidateSet('full','staged','nightly')]
    [string]$BaselineProfile = 'full',
    [switch]$UpdateBaseline,
    [string]$CanonicalPathRegistry = '',
    [string]$AllowlistJson = '',
    [string]$SeverityPolicyJson = '',
    [string]$ChangelogPath = '',
    [switch]$SkipChangelogOnBaselineUpdate,
    [string]$TrendJson = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CategorySeverityMap = @{}
$script:BlockingSeverities = @('CRITICAL','HIGH')

function Resolve-SeverityForCategory {
    param(
        [string]$Category,
        [string]$DefaultSeverity
    )
    if ($script:CategorySeverityMap.ContainsKey($Category)) {
        return [string]$script:CategorySeverityMap[$Category]
    }
    return $DefaultSeverity
}

function New-Finding {
    param(
        [string]$Category,
        [string]$Severity,
        [string]$Message,
        [string]$Path = ''
    )
    $resolvedSeverity = Resolve-SeverityForCategory -Category $Category -DefaultSeverity $Severity
    [pscustomobject]@{
        category = $Category
        severity = $resolvedSeverity
        message  = $Message
        path     = $Path
    }
}

function Convert-ToWorkspaceRelative {
    param(
        [string]$Root,
        [string]$FullPath
    )
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return '' }
    $rel = $FullPath
    if ($FullPath.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $FullPath.Substring($Root.Length).TrimStart('\\')
    }
    return ($rel -replace '\\', '/')
}

function Get-DefaultBaselinePath {
    param(
        [string]$Root,
        [string]$Profile
    )
    return (Join-Path (Join-Path $Root 'config') ('pipeline-refine-baseline-' + $Profile + '.json'))
}

function Normalize-PathLiteral {
    param(
        [string]$Value
    )
    $v = [string]$Value
    if ([string]::IsNullOrWhiteSpace($v)) { return '' }
    $v = $v.Trim()
    $v = $v -replace '\\', '/'
    $v = $v -replace '^\.\/', ''
    $v = $v -replace '^\$\{workspaceFolder\}/?', ''
    $v = $v -replace '/+', '/'
    return $v.ToLowerInvariant()
}

function Get-DeprecatedLiteralVariants {
    param(
        [string]$Literal
    )
    $seed = Normalize-PathLiteral -Value $Literal
    if ([string]::IsNullOrWhiteSpace($seed)) { return @() }

    $variants = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $null = $variants.Add($seed)
    $null = $variants.Add('./' + $seed)
    $null = $variants.Add($seed.TrimStart('/'))

    return @($variants)
}

$root = (Resolve-Path -LiteralPath $WorkspacePath).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path (Join-Path $root 'reports') 'pipeline-refine'
}
if (-not (Test-Path -LiteralPath $OutputRoot)) {
    $null = New-Item -ItemType Directory -Path $OutputRoot -Force
}

if ([string]::IsNullOrWhiteSpace($BaselineJson)) {
    $BaselineJson = Get-DefaultBaselinePath -Root $root -Profile $BaselineProfile
}
if ([string]::IsNullOrWhiteSpace($CanonicalPathRegistry)) {
    $CanonicalPathRegistry = Join-Path (Join-Path $root 'config') 'pipeline-canonical-paths.json'
}
if ([string]::IsNullOrWhiteSpace($AllowlistJson)) {
    $AllowlistJson = Join-Path (Join-Path $root 'config') 'pipeline-refine-allowlist.json'
}
if ([string]::IsNullOrWhiteSpace($SeverityPolicyJson)) {
    $SeverityPolicyJson = Join-Path (Join-Path $root 'config') 'pipeline-refine-severity-policy.json'
}
if ([string]::IsNullOrWhiteSpace($ChangelogPath)) {
    $ChangelogPath = Join-Path $root 'CHANGELOG.md'
}
if ([string]::IsNullOrWhiteSpace($TrendJson)) {
    $TrendJson = Join-Path $OutputRoot 'pipeline-refine-trend.jsonl'
}

$findings = New-Object System.Collections.Generic.List[object]
$scanAt = Get-Date

# Policy load
if (Test-Path -LiteralPath $SeverityPolicyJson) {
    try {
        $policyObj = Get-Content -LiteralPath $SeverityPolicyJson -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($policyObj -and $policyObj.PSObject.Properties.Name -contains 'categorySeverity' -and $null -ne $policyObj.categorySeverity) {
            foreach ($p in $policyObj.categorySeverity.PSObject.Properties) {
                $script:CategorySeverityMap[$p.Name] = [string]$p.Value
            }
        }
        if ($policyObj -and $policyObj.PSObject.Properties.Name -contains 'blockingSeveritiesByProfile' -and $null -ne $policyObj.blockingSeveritiesByProfile) {
            if ($policyObj.blockingSeveritiesByProfile.PSObject.Properties.Name -contains $BaselineProfile) {
                $vals = @($policyObj.blockingSeveritiesByProfile.$BaselineProfile)
                if (@($vals).Count -gt 0) {
                    $script:BlockingSeverities = @($vals | ForEach-Object { [string]$_ })
                }
            }
        }
    } catch {
        $findings.Add((New-Finding -Category 'baseline' -Severity 'HIGH' -Message ('Severity policy unreadable: ' + $_.Exception.Message) -Path (Convert-ToWorkspaceRelative -Root $root -FullPath $SeverityPolicyJson)))
    }
} else {
    $findings.Add((New-Finding -Category 'baseline' -Severity 'HIGH' -Message 'Severity policy file missing.' -Path (Convert-ToWorkspaceRelative -Root $root -FullPath $SeverityPolicyJson)))
}

# Allowlist load
$duplicateFunctionAllowlist = @()
$duplicateFunctionAllowlistMeta = @()
if (Test-Path -LiteralPath $AllowlistJson) {
    try {
        $allowObj = Get-Content -LiteralPath $AllowlistJson -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($allowObj -and $allowObj.PSObject.Properties.Name -contains 'duplicateFunctionAllowlist') {
            foreach ($entry in @($allowObj.duplicateFunctionAllowlist)) {
                if ($entry -is [string]) {
                    $name = [string]$entry
                    if (-not [string]::IsNullOrWhiteSpace($name)) {
                        $duplicateFunctionAllowlist += $name
                        $duplicateFunctionAllowlistMeta += [pscustomobject]@{
                            name = $name
                            owner = ''
                            expiresOn = ''
                            reason = ''
                        }
                    }
                    continue
                }

                $name = ''
                $owner = ''
                $expiresOn = ''
                $reason = ''
                if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains 'name') {
                    $name = [string]$entry.name
                }
                if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains 'owner') {
                    $owner = [string]$entry.owner
                }
                if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains 'expiresOn') {
                    $expiresOn = [string]$entry.expiresOn
                }
                if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains 'reason') {
                    $reason = [string]$entry.reason
                }

                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $duplicateFunctionAllowlist += $name
                    $duplicateFunctionAllowlistMeta += [pscustomobject]@{
                        name = $name
                        owner = $owner
                        expiresOn = $expiresOn
                        reason = $reason
                    }
                }
            }
        }
    } catch {
        $findings.Add((New-Finding -Category 'duplicate-function' -Severity 'LOW' -Message ('Allowlist unreadable: ' + $_.Exception.Message) -Path (Convert-ToWorkspaceRelative -Root $root -FullPath $AllowlistJson)))
    }
}

# Expired or incomplete allowlist entries are actionable governance drift.
$todayDate = (Get-Date).Date
foreach ($meta in @($duplicateFunctionAllowlistMeta)) {
    if ($null -eq $meta) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$meta.owner)) {
        $findings.Add((New-Finding -Category 'allowlist-metadata' -Severity 'MEDIUM' -Message ('Allowlist entry missing owner: ' + [string]$meta.name) -Path (Convert-ToWorkspaceRelative -Root $root -FullPath $AllowlistJson)))
    }

    $exp = [string]$meta.expiresOn
    if ([string]::IsNullOrWhiteSpace($exp)) {
        $findings.Add((New-Finding -Category 'allowlist-metadata' -Severity 'MEDIUM' -Message ('Allowlist entry missing expiresOn: ' + [string]$meta.name) -Path (Convert-ToWorkspaceRelative -Root $root -FullPath $AllowlistJson)))
        continue
    }

    $parsedDate = [datetime]::MinValue
    if ([datetime]::TryParse($exp, [ref]$parsedDate)) {
        if ($parsedDate.Date -lt $todayDate) {
            $findings.Add((New-Finding -Category 'allowlist-expired' -Severity 'HIGH' -Message ('Allowlist entry expired: ' + [string]$meta.name + ' (owner=' + [string]$meta.owner + ', expiresOn=' + $exp + ')') -Path (Convert-ToWorkspaceRelative -Root $root -FullPath $AllowlistJson)))
        }
    } else {
        $findings.Add((New-Finding -Category 'allowlist-metadata' -Severity 'MEDIUM' -Message ('Allowlist expiresOn not parseable: ' + [string]$meta.name + ' (' + $exp + ')') -Path (Convert-ToWorkspaceRelative -Root $root -FullPath $AllowlistJson)))
    }
}

$stagedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
if ($StagedOnly) {
    try {
        $staged = @(git -C $root diff --cached --name-only --diff-filter=ACMR 2>$null)
        foreach ($s in $staged) {
            $normalized = (($s -replace '\\', '/').Trim())
            if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                $null = $stagedSet.Add($normalized)
            }
        }
    } catch {
        $findings.Add((New-Finding -Category 'staged-scan' -Severity 'LOW' -Message 'Unable to read staged file list; falling back to workspace-wide scan.'))
        $StagedOnly = $false
    }
}

# 1) Canonical path reconciliation checks.
$requiredPaths = @(
    'tests/Invoke-SINPatternScanner.ps1',
    'tests/Convert-SinScanToJUnit.ps1',
    'tests/Invoke-PreCommitValidation.ps1',
    'scripts/Invoke-ReferenceIntegrityCheck.ps1',
    'scripts/Invoke-PipelineContinuousRefine.ps1',
    'scripts/Sync-ReadmeFeatureIndex.ps1',
    'scripts/Invoke-ValidateCanonicalPaths.ps1',
    '.github/workflows/sin-scan.yml',
    '.vscode/tasks.json',
    'README.md'
)
$deprecatedRefs = @()

$registryLoaded = $false
$registryMissingCount = 0
if (Test-Path -LiteralPath $CanonicalPathRegistry) {
    try {
        $registryObj = Get-Content -LiteralPath $CanonicalPathRegistry -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($registryObj -and $registryObj.PSObject.Properties.Name -contains 'requiredPaths') {
            $requiredPaths = @($registryObj.requiredPaths)
            $registryLoaded = $true
        }
        if ($registryObj -and $registryObj.PSObject.Properties.Name -contains 'deprecatedPathLiterals') {
            $deprecatedRefs = @($registryObj.deprecatedPathLiterals | ForEach-Object { [string]$_ })
        }
    } catch {
        $findings.Add((New-Finding -Category 'path-registry' -Severity 'HIGH' -Message ('Canonical path registry is unreadable: ' + $_.Exception.Message) -Path 'config/pipeline-canonical-paths.json'))
    }
} else {
    $findings.Add((New-Finding -Category 'path-registry' -Severity 'HIGH' -Message 'Canonical path registry is missing.' -Path 'config/pipeline-canonical-paths.json'))
}

foreach ($rel in $requiredPaths) {
    $relPath = [string]$rel
    if ([string]::IsNullOrWhiteSpace($relPath)) { continue }
    $abs = Join-Path $root ($relPath -replace '/', '\\')
    if (-not (Test-Path -LiteralPath $abs)) {
        $registryMissingCount++
        $findings.Add((New-Finding -Category 'path-reconcile' -Severity 'HIGH' -Message 'Required pipeline path missing.' -Path $relPath))
    }
}

# 1b) Deprecated canonical path reference scan.
$deprecatedHits = New-Object System.Collections.Generic.List[object]
if (@($deprecatedRefs).Count -gt 0) {
    $refScanFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1,*.psm1,*.bat,*.cmd,*.md,*.json,*.yml,*.yaml,*.xhtml,*.html -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(?i)\\(\.git|\.history|~ARCHIVED|~DOWNLOADS|node_modules|\.venv|checkpoints|logs|reports|~REPORTS|temp)\\' })

    foreach ($rf in $refScanFiles) {
        $content = Get-Content -LiteralPath $rf.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content) { continue }
        $normalizedContent = Normalize-PathLiteral -Value $content
        foreach ($dref in $deprecatedRefs) {
            if ([string]::IsNullOrWhiteSpace($dref)) { continue }
            $matchedDeprecated = $false
            foreach ($variant in @(Get-DeprecatedLiteralVariants -Literal $dref)) {
                if ([string]::IsNullOrWhiteSpace($variant)) { continue }
                if ($normalizedContent.Contains($variant)) {
                    $matchedDeprecated = $true
                    break
                }
            }
            if ($matchedDeprecated) {
                $relRf = Convert-ToWorkspaceRelative -Root $root -FullPath $rf.FullName
                $deprecatedHits.Add([pscustomobject]@{ path = $relRf; deprecated = $dref })
                $findings.Add((New-Finding -Category 'deprecated-reference' -Severity 'MEDIUM' -Message ('Deprecated path literal referenced: ' + $dref) -Path $relRf))
            }
        }
    }
}

# 2) Duplicate function names across scripts/modules.
$excludePathRegex = '(?i)\\(\.git|\.history|~ARCHIVED|~DOWNLOADS|node_modules|\.venv|checkpoints|logs|reports|~REPORTS|sin_registry|temp)\\|\\scripts\\QUICK-APP\\~BACKUPS\\'
$psFilesAll = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excludePathRegex })

$psFiles = @()
if ($StagedOnly) {
    foreach ($f in $psFilesAll) {
        $rel = Convert-ToWorkspaceRelative -Root $root -FullPath $f.FullName
        if ($stagedSet.Contains($rel)) {
            $psFiles += $f
        }
    }
} else {
    $psFiles = $psFilesAll
}

$fnMap = @{}
foreach ($f in $psFiles) {
    $lines = Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt @($lines).Count; $i++) {
        if ($lines[$i] -match '^\s*function\s+([A-Za-z0-9_-]+)') {
            $name = $Matches[1]
            if (-not $fnMap.ContainsKey($name)) {
                $fnMap[$name] = New-Object System.Collections.Generic.List[string]
            }
            $relFile = Convert-ToWorkspaceRelative -Root $root -FullPath $f.FullName
            $fnMap[$name].Add($relFile + ':L' + ($i + 1))
        }
    }
}

$duplicateFunctions = @()
foreach ($k in $fnMap.Keys) {
    $locations = @($fnMap[$k])
    $uniqueFiles = @($locations | ForEach-Object { ($_ -split ':L')[0] } | Select-Object -Unique)
    if (@($uniqueFiles).Count -gt 1) {
        $duplicateFunctions += [pscustomobject]@{
            functionName = $k
            filesCount   = @($uniqueFiles).Count
            locations    = $locations
        }
    }
}
$duplicateFunctions = @($duplicateFunctions | Sort-Object filesCount -Descending)

if (@($duplicateFunctions).Count -gt 0) {
    $topDup = @($duplicateFunctions | Select-Object -First 25)
    foreach ($dup in $topDup) {
        $isAllowed = $false
        if (@($duplicateFunctionAllowlist).Count -gt 0) {
            if ($duplicateFunctionAllowlist -contains $dup.functionName) {
                $isAllowed = $true
            }
        }
        if (-not $isAllowed) {
            $findings.Add((New-Finding -Category 'duplicate-function' -Severity 'MEDIUM' -Message ('Function appears across multiple files: ' + $dup.functionName) -Path (($dup.locations | Select-Object -First 1))))
        }
    }
}

# 3) VersionTag normalization checks.
$textFilesAll = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1,*.psm1,*.md,*.xhtml,*.yml,*.yaml,*.json -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excludePathRegex })
$textFiles = @()
if ($StagedOnly) {
    foreach ($f in $textFilesAll) {
        $rel = Convert-ToWorkspaceRelative -Root $root -FullPath $f.FullName
        if ($stagedSet.Contains($rel)) {
            $textFiles += $f
        }
    }
} else {
    $textFiles = $textFilesAll
}

$versionTagRegex = 'VersionTag:\s*(\S+)'
$canonicalRegex = '^\d{4}\.B\d+\.V\d+\.\d+$'
$tagIssues = 0

foreach ($f in $textFiles) {
    $head = Get-Content -LiteralPath $f.FullName -TotalCount 25 -ErrorAction SilentlyContinue
    foreach ($line in @($head)) {
        if ($line -match $versionTagRegex) {
            $tag = $Matches[1]
            if ($tag -notmatch $canonicalRegex) {
                $tagIssues++
                $rel = Convert-ToWorkspaceRelative -Root $root -FullPath $f.FullName
                $findings.Add((New-Finding -Category 'versiontag' -Severity 'LOW' -Message ('Non-canonical VersionTag format: ' + $tag) -Path $rel))
            }
            break
        }
    }
}

# 4) Dotfile placement checks.
$dotFilesAll = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include .todo,.outline,.problems -ErrorAction SilentlyContinue)
$dotFiles = @()
if ($StagedOnly) {
    foreach ($d in $dotFilesAll) {
        $relDot = Convert-ToWorkspaceRelative -Root $root -FullPath $d.FullName
        if ($stagedSet.Contains($relDot)) {
            $dotFiles += $d
        }
    }
} else {
    $dotFiles = $dotFilesAll
}

$dotIssues = 0
foreach ($d in $dotFiles) {
    $rel = Convert-ToWorkspaceRelative -Root $root -FullPath $d.FullName
    if ($rel -like '.todo' -or $rel -like '.outline' -or $rel -like '.problems') {
        $dotIssues++
        $findings.Add((New-Finding -Category 'dotfile-placement' -Severity 'MEDIUM' -Message 'Root-level dotfile should be moved to domain folder.' -Path $rel))
    }
}

# 5) README managed-section checks.
$readmePath = Join-Path $root 'README.md'
$readmeManaged = $false
if (Test-Path -LiteralPath $readmePath) {
    $r = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
    if ($r -match '<!-- AUTO-GENERATED:FEATURE-INDEX:START -->' -and $r -match '<!-- AUTO-GENERATED:FEATURE-INDEX:END -->') {
        $readmeManaged = $true
    } else {
        $findings.Add((New-Finding -Category 'readme-sync' -Severity 'MEDIUM' -Message 'README managed index markers are missing.' -Path 'README.md'))
    }
}

if ($UpdateReadme) {
    $syncScript = Join-Path $root 'scripts/Sync-ReadmeFeatureIndex.ps1'
    if (Test-Path -LiteralPath $syncScript) {
        & $syncScript -WorkspacePath $root
    } else {
        $findings.Add((New-Finding -Category 'readme-sync' -Severity 'HIGH' -Message 'README sync script is missing.' -Path 'scripts/Sync-ReadmeFeatureIndex.ps1'))
    }
}

$countsBySeverity = [ordered]@{ CRITICAL = 0; HIGH = 0; MEDIUM = 0; LOW = 0 }
$countsByKey = [ordered]@{}
foreach ($fnd in $findings) {
    $sev = ''
    if ($null -ne $fnd -and $null -ne $fnd.severity) {
        $sev = [string]$fnd.severity
    }
    if ($countsBySeverity.Keys -contains $sev) {
        $countsBySeverity[$sev] = [int]$countsBySeverity[$sev] + 1
    }

    $cat = ''
    if ($null -ne $fnd -and $null -ne $fnd.category) {
        $cat = [string]$fnd.category
    }
    $key = $sev + ':' + $cat
    if (-not $countsByKey.Contains($key)) {
        $countsByKey[$key] = 0
    }
    $countsByKey[$key] = [int]$countsByKey[$key] + 1
}

$baselineApplied = $false
$baselineCounts = [ordered]@{}
$regressions = @()
$improvements = @()
$baselineBefore = [ordered]@{}

if (Test-Path -LiteralPath $BaselineJson) {
    try {
        $bl = Get-Content -LiteralPath $BaselineJson -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($bl -and $bl.PSObject.Properties.Name -contains 'counts' -and $null -ne $bl.counts) {
            foreach ($p in $bl.counts.PSObject.Properties) {
                $baselineCounts[$p.Name] = [int]$p.Value
                $baselineBefore[$p.Name] = [int]$p.Value
            }
            $baselineApplied = $true
        }
    } catch {
        $findings.Add((New-Finding -Category 'baseline' -Severity 'HIGH' -Message ('Baseline file unreadable: ' + $_.Exception.Message) -Path (Convert-ToWorkspaceRelative -Root $root -FullPath $BaselineJson)))
    }
}

foreach ($k in $countsByKey.Keys) {
    $current = [int]$countsByKey[$k]
    $base = 0
    if ($baselineCounts.Contains($k)) {
        $base = [int]$baselineCounts[$k]
    }
    if ($current -gt $base) {
        $regressions += [pscustomobject]@{ key = $k; baseline = $base; current = $current; delta = ($current - $base) }
    } elseif ($current -lt $base) {
        $improvements += [pscustomobject]@{ key = $k; baseline = $base; current = $current; delta = ($base - $current) }
    }
}

foreach ($k in $baselineCounts.Keys) {
    if (-not $countsByKey.Contains($k)) {
        $improvements += [pscustomobject]@{ key = $k; baseline = [int]$baselineCounts[$k]; current = 0; delta = [int]$baselineCounts[$k] }
    }
}

$baselineChangeLines = @()
if ($UpdateBaseline) {
    $baselineOut = [ordered]@{
        VersionTag = '2607.B1.V52.1'
        generatedAt = (Get-Date).ToString('o')
        source = 'scripts/Invoke-PipelineContinuousRefine.ps1'
        profile = $BaselineProfile
        counts = $countsByKey
    }
    $blDir = Split-Path -Parent $BaselineJson
    if (-not (Test-Path -LiteralPath $blDir)) {
        $null = New-Item -ItemType Directory -Path $blDir -Force
    }
    $baselineOut | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BaselineJson -Encoding UTF8

    $allKeys = @($baselineBefore.Keys + $countsByKey.Keys | Select-Object -Unique)
    foreach ($k in $allKeys) {
        $before = 0
        $after = 0
        if ($baselineBefore.Contains($k)) { $before = [int]$baselineBefore[$k] }
        if ($countsByKey.Contains($k)) { $after = [int]$countsByKey[$k] }
        if ($before -ne $after) {
            $baselineChangeLines += ($k + ': ' + $before + ' -> ' + $after)
        }
    }

    if ((-not $SkipChangelogOnBaselineUpdate) -and (Test-Path -LiteralPath $ChangelogPath)) {
        try {
            $chg = Get-Content -LiteralPath $ChangelogPath -Raw -Encoding UTF8
            $baselineRelPath = Convert-ToWorkspaceRelative -Root $root -FullPath $BaselineJson
            $todayKey = Get-Date -Format 'yyyy-MM-dd'
            $dailyPattern = '(?m)^- \*\*' + [regex]::Escape($todayKey) + ' [0-9]{2}:[0-9]{2}:[0-9]{2}\*\* Baseline refresh \(`' + [regex]::Escape($baselineRelPath) + '`, profile=' + [regex]::Escape($BaselineProfile) + '\):'

            if ($chg -notmatch $dailyPattern) {
                $note = '- **' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '** Baseline refresh (`' + $baselineRelPath + '`, profile=' + $BaselineProfile + '): '
                if (@($baselineChangeLines).Count -gt 0) {
                    $note += (@($baselineChangeLines | Select-Object -First 8) -join '; ')
                } else {
                    $note += 'no count changes.'
                }
                if ($chg -match '## Recent Changes') {
                    $chg = $chg -replace '## Recent Changes', ('## Recent Changes' + "`r`n`r`n" + $note)
                } else {
                    $chg = $chg.TrimEnd() + "`r`n`r`n## Recent Changes`r`n`r`n" + $note + "`r`n"
                }
                Set-Content -LiteralPath $ChangelogPath -Value $chg -Encoding UTF8
            }
        } catch {
            $findings.Add((New-Finding -Category 'baseline' -Severity 'LOW' -Message ('Unable to append baseline note to changelog: ' + $_.Exception.Message) -Path (Convert-ToWorkspaceRelative -Root $root -FullPath $ChangelogPath)))
        }
    }
}

$requiredPathChecksCount = @($requiredPaths).Count
$duplicateFunctionGroupsCount = @($duplicateFunctions).Count
$totalFindingsCount = $findings.Count
$scanIdentifier = 'PIPE-REFINE-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$duplicateFunctionsTop = @($duplicateFunctions | Select-Object -First 200)
$allowedDuplicates = @($duplicateFunctions | Where-Object { $duplicateFunctionAllowlist -contains $_.functionName })

$summary = [ordered]@{}
$summary.scanId = $scanIdentifier
$summary.workspace = $root
$summary.timestamp = $scanAt.ToString('o')
$summary.requiredPathChecks = $requiredPathChecksCount
$summary.pathRegistryLoaded = $registryLoaded
$summary.pathRegistry = (Convert-ToWorkspaceRelative -Root $root -FullPath $CanonicalPathRegistry)
$summary.pathRegistryMissing = $registryMissingCount
$summary.deprecatedReferenceHits = $deprecatedHits.Count
$summary.stagedOnly = [bool]$StagedOnly
$summary.stagedFileCount = $stagedSet.Count
$summary.baselineProfile = $BaselineProfile
$summary.duplicateFunctionGroups = $duplicateFunctionGroupsCount
$summary.duplicateFunctionAllowlisted = $allowedDuplicates.Count
$summary.versionTagIssues = $tagIssues
$summary.dotfilePlacementIssues = $dotIssues
$summary.readmeManagedMarkers = $readmeManaged
$summary.findingsBySeverity = $countsBySeverity
$summary.countsByKey = $countsByKey
$summary.baselinePath = (Convert-ToWorkspaceRelative -Root $root -FullPath $BaselineJson)
$summary.baselineApplied = $baselineApplied
$summary.regressions = @($regressions)
$summary.improvements = @($improvements)
$summary.blockingSeverities = @($script:BlockingSeverities)
$summary.totalFindings = $totalFindingsCount

$result = [ordered]@{}
$result.summary = $summary
$result.findings = @($findings.ToArray())
$result.duplicateFunctions = $duplicateFunctionsTop
$result.duplicateFunctionsAllowlisted = @($allowedDuplicates)
$result.deprecatedReferenceHits = @($deprecatedHits.ToArray())

$jsonPath = Join-Path $OutputRoot 'pipeline-refine-latest.json'
$mdPath   = Join-Path $OutputRoot 'pipeline-refine-latest.md'

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

# Trend append + report
$trendEntry = [ordered]@{
    timestamp = $summary.timestamp
    scanId = $summary.scanId
    profile = $BaselineProfile
    stagedOnly = $summary.stagedOnly
    findingsTotal = $summary.totalFindings
    findingsBySeverity = $countsBySeverity
    regressions = @($regressions).Count
    improvements = @($improvements).Count
    duplicateGroups = $summary.duplicateFunctionGroups
    deprecatedReferenceHits = $summary.deprecatedReferenceHits
}
$trendDir = Split-Path -Parent $TrendJson
if (-not (Test-Path -LiteralPath $trendDir)) {
    $null = New-Item -ItemType Directory -Path $trendDir -Force
}
Add-Content -LiteralPath $TrendJson -Value (($trendEntry | ConvertTo-Json -Depth 6 -Compress)) -Encoding UTF8

$trendEntries = @()
try {
    $trendLines = @(Get-Content -LiteralPath $TrendJson -Encoding UTF8)
    foreach ($line in $trendLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $trendEntries += ($line | ConvertFrom-Json) } catch { }
    }
} catch { }
$trendLatest = @($trendEntries | Select-Object -Last 20)
$trendMdPath = Join-Path $OutputRoot 'pipeline-refine-trend-latest.md'
$trendMd = @()
$trendMd += '# Pipeline Refine Trend'
$trendMd += ''
$trendMd += ('Source: ' + (Convert-ToWorkspaceRelative -Root $root -FullPath $TrendJson))
$trendMd += ('Entries: ' + @($trendEntries).Count)
$trendMd += ''
$trendMd += '| Timestamp | Profile | Staged | Findings | Regressions | Improvements | DuplicateGroups | DeprecatedRefs |'
$trendMd += '|---|---|---:|---:|---:|---:|---:|---:|'
foreach ($e in $trendLatest) {
    $trendMd += ('| ' + [string]$e.timestamp + ' | ' + [string]$e.profile + ' | ' + [string]$e.stagedOnly + ' | ' + [string]$e.findingsTotal + ' | ' + [string]$e.regressions + ' | ' + [string]$e.improvements + ' | ' + [string]$e.duplicateGroups + ' | ' + [string]$e.deprecatedReferenceHits + ' |')
}
$trendMd -join "`r`n" | Set-Content -LiteralPath $trendMdPath -Encoding UTF8

$weeklyRollupPath = Join-Path $OutputRoot 'pipeline-refine-weekly-rollup.md'
$cutoffDate = (Get-Date).AddDays(-7)
$recentTrendEntries = @()
foreach ($entry in @($trendEntries)) {
    try {
        $entryTs = [datetime]$entry.timestamp
        if ($entryTs -ge $cutoffDate) {
            $recentTrendEntries += $entry
        }
    } catch {
        continue
    }
}

$weeklyMd = @()
$weeklyMd += '# Pipeline Refine Weekly Rollup'
$weeklyMd += ''
$weeklyMd += ('WindowStart: ' + $cutoffDate.ToString('yyyy-MM-dd'))
$weeklyMd += ('WindowEnd: ' + (Get-Date).ToString('yyyy-MM-dd'))
$weeklyMd += ('EntriesInWindow: ' + @($recentTrendEntries).Count)
$weeklyMd += ''
$weeklyMd += '| Profile | Runs | FirstFindings | LatestFindings | Delta7d | AvgFindings | Regressions | Improvements |'
$weeklyMd += '|---|---:|---:|---:|---:|---:|---:|---:|'

$profileGroups = @($recentTrendEntries | Group-Object -Property profile)
foreach ($pg in $profileGroups) {
    $profileRuns = @($pg.Group | Sort-Object { [datetime]$_.timestamp })
    if (@($profileRuns).Count -eq 0) { continue }

    $firstFindings = [double]$profileRuns[0].findingsTotal
    $latestFindings = [double]$profileRuns[@($profileRuns).Count - 1].findingsTotal
    $delta7d = $latestFindings - $firstFindings
    $avgFindings = [math]::Round((@($profileRuns | Measure-Object -Property findingsTotal -Average).Average), 2)
    $regTotal = [int](@($profileRuns | Measure-Object -Property regressions -Sum).Sum)
    $impTotal = [int](@($profileRuns | Measure-Object -Property improvements -Sum).Sum)

    $weeklyMd += ('| ' + [string]$pg.Name + ' | ' + @($profileRuns).Count + ' | ' + [int]$firstFindings + ' | ' + [int]$latestFindings + ' | ' + [int]$delta7d + ' | ' + $avgFindings + ' | ' + $regTotal + ' | ' + $impTotal + ' |')
}

$weeklyMd -join "`r`n" | Set-Content -LiteralPath $weeklyRollupPath -Encoding UTF8

$md = @()
$md += '# Pipeline Continuous Refine Report'
$md += ''
$md += ('Scan: ' + $summary.scanId)
$md += ('Timestamp: ' + $summary.timestamp)
$md += ('Profile: ' + $summary.baselineProfile)
$md += ('StagedOnly: ' + $summary.stagedOnly)
$md += ('Staged File Count: ' + $summary.stagedFileCount)
$md += ('Total Findings: ' + $summary.totalFindings)
$md += ('Severity Counts: CRITICAL=' + $countsBySeverity.CRITICAL + ', HIGH=' + $countsBySeverity.HIGH + ', MEDIUM=' + $countsBySeverity.MEDIUM + ', LOW=' + $countsBySeverity.LOW)
$md += ('Duplicate Function Groups: ' + $summary.duplicateFunctionGroups)
$md += ('Allowlisted Duplicate Groups: ' + $summary.duplicateFunctionAllowlisted)
$md += ('Deprecated Reference Hits: ' + $summary.deprecatedReferenceHits)
$md += ('VersionTag Issues: ' + $summary.versionTagIssues)
$md += ('Dotfile Placement Issues: ' + $summary.dotfilePlacementIssues)
$md += ('README Markers Present: ' + $summary.readmeManagedMarkers)
$md += ('Registry Loaded: ' + $summary.pathRegistryLoaded)
$md += ('Registry Missing Paths: ' + $summary.pathRegistryMissing)
$md += ('Baseline Applied: ' + $summary.baselineApplied)
$md += ('Regression Count: ' + @($regressions).Count)
$md += ('Improvement Count: ' + @($improvements).Count)
$md += ''
$md += '## Top Findings'
if ($findings.Count -eq 0) {
    $md += '- No findings.'
} else {
    foreach ($fnd in ($findings | Select-Object -First 60)) {
        $pathText = ''
        if (-not [string]::IsNullOrWhiteSpace($fnd.path)) {
            $pathText = ' | ' + $fnd.path
        }
        $md += ('- [' + $fnd.severity + '] ' + $fnd.category + ': ' + $fnd.message + $pathText)
    }
}

if (@($regressions).Count -gt 0) {
    $md += ''
    $md += '## Regressions'
    foreach ($r in $regressions) {
        $md += ('- ' + $r.key + ' baseline=' + $r.baseline + ' current=' + $r.current + ' delta=' + $r.delta)
    }
}

if (@($baselineChangeLines).Count -gt 0) {
    $md += ''
    $md += '## Baseline Changes'
    foreach ($line in $baselineChangeLines) {
        $md += ('- ' + $line)
    }
}

$md -join "`r`n" | Set-Content -LiteralPath $mdPath -Encoding UTF8

Write-Host ('[PipelineRefine] JSON: ' + $jsonPath) -ForegroundColor Green
Write-Host ('[PipelineRefine] MD  : ' + $mdPath) -ForegroundColor Green
Write-Host ('[PipelineRefine] Trend JSONL: ' + $TrendJson) -ForegroundColor Green
Write-Host ('[PipelineRefine] Trend MD  : ' + $trendMdPath) -ForegroundColor Green
Write-Host ('[PipelineRefine] Weekly Rollup MD: ' + $weeklyRollupPath) -ForegroundColor Green

$blocking = @($findings.ToArray() | Where-Object { $script:BlockingSeverities -contains $_.severity }).Count
if ($FailOnDrift) {
    if ($baselineApplied) {
        if (@($regressions).Count -gt 0) {
            Write-Error ('Baseline regressions detected: ' + @($regressions).Count)
            exit 1
        }
    } elseif ($blocking -gt 0) {
        Write-Error ('Blocking drift findings detected: ' + $blocking)
        exit 1
    }
}

exit 0
