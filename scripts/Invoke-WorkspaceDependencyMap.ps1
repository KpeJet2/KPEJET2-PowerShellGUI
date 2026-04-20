# VersionTag: 2604.B2.V31.1
# FileRole: Pipeline
# Author: The Establishment
# Date: 2026-04-03
# FileRole: Scanner
#Requires -Version 5.1
<#
.SYNOPSIS
    Workspace Dependency Map -- scans folders, modules, functions, variables, config keys, URLs and IPs.
.DESCRIPTION
    Walks the workspace tree (honouring an exclusion list) and builds a structured
    vector object map of:
        - Folder tree (depth-first, up to depth 5)
        - Modules  (.psm1/.psd1): name, VersionTag, exported function names, size
        - Scripts  (.ps1): name, VersionTag, defined function names, size
        - Functions: name, parameter names, source file
        - Variables: $script: and $global: declarations with source file
        - JSON configs (config/): top-level key names
        - XML  configs (config/): root-child element names
        - URL references: http/https URLs found in every scanned file
        - IP references:  raw IPv4 addresses found in every scanned file
        - DNS resolution: each unique hostname resolved to IP(s) for hit-rate analysis

    Exclusion list: .git .history .venv .venv-pygame312 archive todo temp

    Outputs:
        ~REPORTS/workspace-dependency-map-{ts}.json
        ~REPORTS/workspace-dependency-map-{ts}.zip  (compressed copy of the JSON)
        ~REPORTS/workspace-dependency-map-pointer.json
        ~README.md/Dependency-Visualisation.html   (XHTML links + dependency view)
.PARAMETER WorkspacePath
    Root of workspace. Defaults to parent of script directory.
.PARAMETER ReportPath
    Report output directory. Defaults to WorkspacePath\~REPORTS.
.PARAMETER SkipHtml
    Skip XHTML generation (JSON only).
.PARAMETER SkipZip
    Skip ZIP compression of the JSON output.
.PARAMETER SkipDns
    Skip DNS resolution of URL hostnames (faster, offline-safe).
.EXAMPLE
    .\scripts\Invoke-WorkspaceDependencyMap.ps1
    .\scripts\Invoke-WorkspaceDependencyMap.ps1 -SkipDns -SkipHtml
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [string]$ReportPath,
    [switch]$SkipHtml,
    [switch]$SkipZip,
    [switch]$SkipDns
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─── Path Setup ──────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $WorkspacePath '~REPORTS'
}
if (-not (Test-Path $ReportPath)) {
    New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Folder names to skip entirely (case-insensitive exact segment match)
$script:ExcludeNames = @('.git', '.history', '.venv', '.venv-pygame312', 'archive', 'todo', 'temp')

Write-Output "Workspace Dependency Map -- Start ($timestamp)"
Write-Output "Workspace : $WorkspacePath"
Write-Output "Excluded  : $($script:ExcludeNames -join ', ')"

# ─── Checkpoint + progress helpers ─────────────────────────────────────────
$script:_CkptPath    = Join-Path (Join-Path $WorkspacePath 'checkpoints') 'dependency-scan-checkpoint.json'
$script:_ProgressPath= Join-Path (Join-Path $WorkspacePath 'logs') 'scan-progress.json'
$script:_ScanStart   = [System.Diagnostics.Stopwatch]::StartNew()

function Save-ScanPhaseCheckpoint {
    [CmdletBinding()]
    param(
        [string]$Phase,          # e.g. 'folders', 'scripts', 'configs'
        [string]$Status = 'ok',  # 'ok' | 'error'
        [int]   $Count  = 0,
        [string]$Error  = '',
        [int]   $ProgressPct = 0
    )
    $now = Get-Date -Format 'o'
    $durationMs = [int]$script:_ScanStart.Elapsed.TotalMilliseconds

    # ── Read existing checkpoint (or start fresh) ──
    $ckpt = @{ phases = @{}; version = '2604.B1.V32.0'; lastFullScan = '' }
    if (Test-Path $script:_CkptPath) {
        try {
            $raw  = [System.IO.File]::ReadAllText($script:_CkptPath, [System.Text.Encoding]::UTF8)
            $obj  = $raw | ConvertFrom-Json
            if ($null -ne $obj -and $null -ne $obj.phases) {
                # Re-hydrate phases hashtable from PSObject
                $phasePso = $obj.phases
                foreach ($pn in $phasePso.PSObject.Properties.Name) {
                    $ckpt.phases[$pn] = @{
                        status      = $phasePso.$pn.status
                        completedAt = $phasePso.$pn.completedAt
                        durationMs  = [int]($phasePso.$pn.durationMs)
                        count       = [int]($phasePso.$pn.count)
                        error       = if ($null -ne $phasePso.$pn.error) { $phasePso.$pn.error } else { '' }
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($obj.lastFullScan)) {
                    $ckpt.lastFullScan = $obj.lastFullScan
                }
            }
        } catch { <# Intentional: stale or malformed checkpoint — will overwrite #> }
    }

    # ── Write updated phase ──
    $ckpt.phases[$Phase] = @{
        status      = $Status
        completedAt = $now
        durationMs  = $durationMs
        count       = $Count
        error       = $Error
    }

    # ── Persist checkpoint ──
    $ckptDir = Split-Path $script:_CkptPath -Parent
    if (-not (Test-Path $ckptDir)) { New-Item -ItemType Directory -Path $ckptDir -Force | Out-Null }
    $ckpt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:_CkptPath -Encoding UTF8

    # ── Write scan-progress.json for LocalWebEngine polling ──
    $progressDir = Split-Path $script:_ProgressPath -Parent
    if (-not (Test-Path $progressDir)) { New-Item -ItemType Directory -Path $progressDir -Force | Out-Null }
    $progress = @{
        type           = 'scanProgress'
        statusMessage  = "Phase $Phase complete ($Count items)"
        progress       = $ProgressPct
        phases         = $ckpt.phases
        updatedAt      = $now
    }
    $progress | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:_ProgressPath -Encoding UTF8

    Write-Output "  [checkpoint] $Phase -> $Status ($Count items, ${durationMs}ms)"
}

# ─── Helper: is this path under an excluded segment? ─────────────────────────
function Test-ExcludedPath {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    [CmdletBinding()]
    param([string]$FullPath)
    $parts = $FullPath.ToLower().Split([System.IO.Path]::DirectorySeparatorChar)
    foreach ($part in $parts) {
        foreach ($ex in $script:ExcludeNames) {
            if ($part -eq $ex.ToLower()) { return $true }
        }
    }
    return $false
}

# ─── Node ID factory ─────────────────────────────────────────────────────────
$script:NodeCounter = 0
function New-NodeId {
    $script:NodeCounter++
    return "n$($script:NodeCounter)"
}

# ─── Phase 1: Collect all workspace files ────────────────────────────────────
Write-Output '[10%] Collecting workspace files...'
$allFiles = @(Get-ChildItem -Path $WorkspacePath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        -not (Test-ExcludedPath $_.FullName) -and
        $_.Extension -notmatch '^\.(tmp|bak|log|lock|pyc|pyo|cache)$' -and
        $_.Name -notmatch '^~' -and
        $_.Name -notmatch '\.tmp$'
    })

$codeFiles   = @($allFiles | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') })
$configFiles = @($allFiles | Where-Object {
    $_.Extension -in @('.json', '.xml') -and
    $_.FullName -notlike '*\.vscode\*' -and
    $_.Directory.FullName -like (Join-Path $WorkspacePath 'config*')
})

Write-Output "  Total: $(@($allFiles).Count)  Code: $(@($codeFiles).Count)  Config: $(@($configFiles).Count)"

# ─── Phase 2: Build folder nodes ─────────────────────────────────────────────
Write-Output '[20%] Building folder tree...'
$folderNodes = [System.Collections.Generic.List[object]]::new()
$folderIdMap = @{}   # fullPath.ToLower() -> nodeId

$allDirs = @(Get-ChildItem -Path $WorkspacePath -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-ExcludedPath $_.FullName) })

# Prepend the root as a pseudo-entry
$rootEntry = [pscustomobject]@{ FullName = $WorkspacePath; Name = '(root)' }
$allDirsWithRoot = @($rootEntry) + $allDirs

foreach ($dir in $allDirsWithRoot) {
    $nid = New-NodeId
    $rel = if ($dir.FullName -eq $WorkspacePath) {
        '.'
    } else {
        $dir.FullName.Substring($WorkspacePath.Length).TrimStart('\')
    }
    $parentRel = if ($rel -eq '.') {
        $null
    } else {
        $pr = Split-Path $rel -Parent
        if ([string]::IsNullOrEmpty($pr)) { '.' } else { $pr }
    }

    $folderIdMap[$dir.FullName.ToLower()] = $nid
    $folderNodes.Add([pscustomobject]@{
        id         = $nid
        type       = 'folder'
        label      = $dir.Name
        path       = $rel
        parentPath = $parentRel
    }) | Out-Null
}

# ── Checkpoint: folders phase complete ──
Save-ScanPhaseCheckpoint -Phase 'folders' -Status 'ok' -Count @($folderNodes).Count -ProgressPct 20

# ─── Regex patterns used during code file parsing ────────────────────────────
$fnRegex  = [regex]'(?m)^[ \t]*function\s+([A-Za-z][\w-]+)\s*[({]'
$fnParamRx= [regex]'(?m)param\s*\(([^)]{0,400})\)'
$varRegex = [regex]'(?m)\$(script|global):([A-Za-z_]\w*)\s*='
$impRegex = [regex]"(?im)Import-Module\s+['""]?([A-Za-z][\w\-\.]+)['""]?"
$reqRegex = [regex]'(?im)#Requires\s+-Modules?\s+([A-Za-z][\w\-\.]+)'
$vtRegex  = [regex]'# VersionTag:\s*(\S+)'
# URL extraction -- matches http(s):// references (strips trailing quotes/parens)
$urlRegex = [regex]'https?://[^\s"''<>()\[\]{},;\\]+'
# Raw IPv4 extraction (e.g. 192.168.1.1 but not inside a larger number like 127.0.0.1:8080 host part)
$ipv4Regex = [regex]'\b((?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?))\b'

# ─── Phase 3: Parse code files ───────────────────────────────────────────────
Write-Output '[40%] Parsing code files...'
$moduleNodes   = [System.Collections.Generic.List[object]]::new()
$scriptNodes   = [System.Collections.Generic.List[object]]::new()
$functionNodes = [System.Collections.Generic.List[object]]::new()
$variableNodes = [System.Collections.Generic.List[object]]::new()
$edges         = [System.Collections.Generic.List[object]]::new()

# URL/IP accumulation: rel-path -> @{urls=@(); ips=@()}
$urlIpMap      = @{}

foreach ($f in $codeFiles) {
    $rel      = $f.FullName.Substring($WorkspacePath.Length).TrimStart('\')
    $dirKey   = $f.Directory.FullName.ToLower()
    $folderId = if ($folderIdMap.ContainsKey($dirKey)) { $folderIdMap[$dirKey] } else { $null }

    try {
        $src = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    } catch {
        Write-Output "  WARN: Cannot read $rel -- $($_.Exception.Message)"
        continue
    }

    # VersionTag
    $vtMatch    = $vtRegex.Match($src)
    $versionTag = if ($vtMatch.Success) { $vtMatch.Groups[1].Value } else { '' }

    # Defined functions
    $funcMatches = $fnRegex.Matches($src)
    $funcDefs = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $funcMatches) {
        $fname = $m.Groups[1].Value
        $paramBlock = $src.Substring([Math]::Min($m.Index, $src.Length - 1), [Math]::Min(300, $src.Length - $m.Index))
        $paramMatch = $fnParamRx.Match($paramBlock)
        $params = @()
        if ($paramMatch.Success) {
            $params = @(([regex]'\$([A-Za-z_]\w*)').Matches($paramMatch.Groups[1].Value) |
                ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        }
        $funcDefs.Add([pscustomobject]@{ name = $fname; params = $params }) | Out-Null
    }
    $funcNames = @($funcDefs | ForEach-Object { $_.name } | Select-Object -Unique)

    # Script-/global-scoped variable declarations
    $varMatches = $varRegex.Matches($src)
    $varNamesList = foreach ($m in $varMatches) {
        "$($m.Groups[1].Value):$($m.Groups[2].Value)"
    }
    $varNames = @($varNamesList | Select-Object -Unique)

    # URL extraction
    $foundUrls = @($urlRegex.Matches($src) | ForEach-Object { $_.Value.TrimEnd('.,:;)>]') } | Select-Object -Unique)

    # IPv4 extraction
    $foundIPs  = @($ipv4Regex.Matches($src) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)

    if (@($foundUrls).Count -gt 0 -or @($foundIPs).Count -gt 0) {
        $urlIpMap[$rel] = @{ urls = $foundUrls; ips = $foundIPs }
    }

    $isModule = $f.Extension -in @('.psm1', '.psd1')
    $nid = New-NodeId

    if ($isModule) {
        $moduleNodes.Add([pscustomobject]@{
            id         = $nid
            type       = 'module'
            label      = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            path       = $rel
            extension  = $f.Extension.ToLower()
            versionTag = $versionTag
            functions  = $funcNames
            urls       = $foundUrls
            ips        = $foundIPs
            sizeBytes  = $f.Length
        }) | Out-Null
    } else {
        $scriptNodes.Add([pscustomobject]@{
            id         = $nid
            type       = 'script'
            label      = $f.Name
            path       = $rel
            versionTag = $versionTag
            functions  = $funcNames
            urls       = $foundUrls
            ips        = $foundIPs
            sizeBytes  = $f.Length
        }) | Out-Null
    }

    if ($folderId) {
        $edges.Add([pscustomobject]@{ source = $folderId; target = $nid; rel = 'contains' }) | Out-Null
    }

    foreach ($fd in $funcDefs) {
        $fnid = New-NodeId
        $functionNodes.Add([pscustomobject]@{
            id     = $fnid
            type   = 'function'
            label  = $fd.name
            params = $fd.params
            source = $rel
        }) | Out-Null
        $edges.Add([pscustomobject]@{ source = $nid; target = $fnid; rel = 'defines' }) | Out-Null
    }

    foreach ($vn in $varNames) {
        $vnid = New-NodeId
        $variableNodes.Add([pscustomobject]@{
            id     = $vnid
            type   = 'variable'
            label  = "`$$vn"
            source = $rel
        }) | Out-Null
        $edges.Add([pscustomobject]@{ source = $nid; target = $vnid; rel = 'declares' }) | Out-Null
    }

    foreach ($m in $impRegex.Matches($src)) {
        $edges.Add([pscustomobject]@{ source = $nid; target = "(module)$($m.Groups[1].Value)"; rel = 'imports' }) | Out-Null
    }
    foreach ($m in $reqRegex.Matches($src)) {
        $edges.Add([pscustomobject]@{ source = $nid; target = "(module)$($m.Groups[1].Value)"; rel = 'requires' }) | Out-Null
    }
}

# ── Checkpoint: modules + scripts + urls_ips phases complete ──
Save-ScanPhaseCheckpoint -Phase 'modules' -Status 'ok' -Count @($moduleNodes).Count -ProgressPct 45
Save-ScanPhaseCheckpoint -Phase 'scripts' -Status 'ok' -Count @($scriptNodes).Count -ProgressPct 50
Save-ScanPhaseCheckpoint -Phase 'urls_ips' -Status 'ok' -Count @($urlIpMap.Keys).Count -ProgressPct 55

# ─── Phase 4: Parse config files ─────────────────────────────────────────────
Write-Output '[55%] Parsing config files and extracting URLs/IPs...'
$configNodes = [System.Collections.Generic.List[object]]::new()

foreach ($cf in $configFiles) {
    $rel       = $cf.FullName.Substring($WorkspacePath.Length).TrimStart('\')
    $dirKey    = $cf.Directory.FullName.ToLower()
    $folderId  = if ($folderIdMap.ContainsKey($dirKey)) { $folderIdMap[$dirKey] } else { $null }
    $topKeys   = @()

    # Also scan config files for URLs and IPs
    try {
        $cfSrc = [System.IO.File]::ReadAllText($cf.FullName, [System.Text.Encoding]::UTF8)
        $cfUrls = @($urlRegex.Matches($cfSrc) | ForEach-Object { $_.Value.TrimEnd('.,:;)>]') } | Select-Object -Unique)
        $cfIPs  = @($ipv4Regex.Matches($cfSrc) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if (@($cfUrls).Count -gt 0 -or @($cfIPs).Count -gt 0) {
            $urlIpMap[$rel] = @{ urls = $cfUrls; ips = $cfIPs }
        }
    } catch { <# Intentional: non-fatal URL scan on config #> }

    try {
        if ($cf.Extension -ieq '.json') {
            $raw    = [System.IO.File]::ReadAllText($cf.FullName, [System.Text.Encoding]::UTF8)
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            $topKeys = @($parsed.PSObject.Properties.Name |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 30)
        } elseif ($cf.Extension -ieq '.xml') {
            [xml]$xdoc = [System.IO.File]::ReadAllText($cf.FullName, [System.Text.Encoding]::UTF8)
            if ($xdoc.DocumentElement) {
                $topKeys = @($xdoc.DocumentElement.ChildNodes |
                    Where-Object { $_.NodeType -eq 'Element' } |
                    Select-Object -ExpandProperty LocalName |
                    Select-Object -Unique -First 30)
            }
        }
    } catch { <# Intentional: non-fatal config parse failure #> }

    $cnid = New-NodeId
    $configNodes.Add([pscustomobject]@{
        id        = $cnid
        type      = 'config'
        label     = $cf.Name
        path      = $rel
        topKeys   = $topKeys
        sizeBytes = $cf.Length
    }) | Out-Null

    if ($folderId) {
        $edges.Add([pscustomobject]@{ source = $folderId; target = $cnid; rel = 'contains' }) | Out-Null
    }
}

# ── Checkpoint: configs phase complete ──
Save-ScanPhaseCheckpoint -Phase 'configs' -Status 'ok' -Count @($configNodes).Count -ProgressPct 62

# ─── Phase 4b: DNS resolution of URL hostnames ───────────────────────────────
Write-Output '[62%] Resolving URL hostnames to IPs...'
$dnsResolution  = @{}   # hostname -> @{ips=@(); error=''}
$hostHitCount   = @{}   # hostname -> count of files referencing it

if (-not $SkipDns) {
    # Collect all unique hostnames across all files
    $allHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $urlIpMap.Values) {
        foreach ($url in $entry.urls) {
            try {
                $uri  = [System.Uri]$url
                $host = $uri.Host
                if (-not [string]::IsNullOrWhiteSpace($host)) {
                    $allHosts.Add($host) | Out-Null
                }
            } catch { <# Intentional: malformed URL #> }
        }
    }

    # Count per-file hit frequency
    foreach ($relPath in $urlIpMap.Keys) {
        $seenHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($url in $urlIpMap[$relPath].urls) {
            try {
                $uri  = [System.Uri]$url
                $host = $uri.Host
                if (-not [string]::IsNullOrWhiteSpace($host)) {
                    $seenHosts.Add($host) | Out-Null
                }
            } catch { <# Intentional: malformed URL #> }
        }
        foreach ($h in $seenHosts) {
            if ($hostHitCount.ContainsKey($h)) { $hostHitCount[$h]++ }
            else { $hostHitCount[$h] = 1 }
        }
    }

    Write-Output "  Resolving $($allHosts.Count) unique hostnames..."
    foreach ($hostName in $allHosts) {
        try {
            $resolved = [System.Net.Dns]::GetHostAddresses($hostName) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                ForEach-Object { $_.ToString() } |
                Select-Object -Unique
            $dnsResolution[$hostName] = @{
                ips   = @($resolved)
                error = ''
                hits  = if ($hostHitCount.ContainsKey($hostName)) { $hostHitCount[$hostName] } else { 0 }
            }
        } catch {
            $dnsResolution[$hostName] = @{
                ips   = @()
                error = $_.Exception.Message
                hits  = if ($hostHitCount.ContainsKey($hostName)) { $hostHitCount[$hostName] } else { 0 }
            }
        }
    }
    Write-Output "  DNS resolved $(@($dnsResolution.Keys).Count) hosts"
    Save-ScanPhaseCheckpoint -Phase 'dns_resolution' -Status 'ok' -Count @($dnsResolution.Keys).Count -ProgressPct 70
} else {
    Write-Output '  DNS resolution skipped (-SkipDns)'
    Save-ScanPhaseCheckpoint -Phase 'dns_resolution' -Status 'ok' -Count 0 -ProgressPct 70
}

# ─── Phase 5: Resolve import edges ───────────────────────────────────────────
Write-Output '[70%] Resolving dependency edges...'

# Build lookup: module label (lowercase) -> nodeId
$moduleIdLookup = @{}
foreach ($mn in $moduleNodes) {
    $moduleIdLookup[$mn.label.ToLower()] = $mn.id
}

$allNodes = [System.Collections.Generic.List[object]]::new()
foreach ($n in $folderNodes)   { $allNodes.Add($n) | Out-Null }
foreach ($n in $moduleNodes)   { $allNodes.Add($n) | Out-Null }
foreach ($n in $scriptNodes)   { $allNodes.Add($n) | Out-Null }
foreach ($n in $functionNodes) { $allNodes.Add($n) | Out-Null }
foreach ($n in $variableNodes) { $allNodes.Add($n) | Out-Null }
foreach ($n in $configNodes)   { $allNodes.Add($n) | Out-Null }

$realNodeIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($n in $allNodes) { $realNodeIds.Add($n.id) | Out-Null }

# Resolve placeholder import targets
$resolvedEdges = [System.Collections.Generic.List[object]]::new()
foreach ($e in $edges) {
    $tgt = $e.target
    if ($tgt.StartsWith('(module)')) {
        $modName = $tgt.Substring(8)
        $resolved = if ($moduleIdLookup.ContainsKey($modName.ToLower())) {
            $moduleIdLookup[$modName.ToLower()]
        } else { $null }

        if ($resolved -and $realNodeIds.Contains($e.source)) {
            $resolvedEdges.Add([pscustomobject]@{
                source = $e.source; target = $resolved; rel = $e.rel
            }) | Out-Null
        }
        # Unresolved external module imports are dropped (not in workspace)
    } elseif ($realNodeIds.Contains($e.source) -and $realNodeIds.Contains($tgt)) {
        $resolvedEdges.Add($e) | Out-Null
    }
}

# ─── Phase 6: Assemble and write JSON ────────────────────────────────────────
Write-Output '[80%] Writing workspace-dependency-map JSON...'

# Build IP hit-rate table: each resolved IP -> list of files that reference it
$ipHitRate = @{}
foreach ($relPath in $urlIpMap.Keys) {
    # Direct IP references in source
    foreach ($ip in $urlIpMap[$relPath].ips) {
        if (-not $ipHitRate.ContainsKey($ip)) { $ipHitRate[$ip] = @() }
        $ipHitRate[$ip] += $relPath
    }
}
# Also add IPs resolved from URLs for each file  
foreach ($relPath in $urlIpMap.Keys) {
    foreach ($url in $urlIpMap[$relPath].urls) {
        try {
            $uri  = [System.Uri]$url
            $host = $uri.Host
            if (-not [string]::IsNullOrWhiteSpace($host) -and $dnsResolution.ContainsKey($host)) {
                foreach ($ip in $dnsResolution[$host].ips) {
                    if (-not $ipHitRate.ContainsKey($ip)) { $ipHitRate[$ip] = @() }
                    if ($ipHitRate[$ip] -notcontains $relPath) {
                        $ipHitRate[$ip] += $relPath
                    }
                }
            }
        } catch { <# Intentional: malformed URL #> }
    }
}

# Convert ipHitRate to sorted list for output
$ipHitRateRaw = foreach ($ip in ($ipHitRate.Keys | Sort-Object)) {
    [pscustomobject]@{
        ip        = $ip
        fileCount = @($ipHitRate[$ip]).Count
        files     = @($ipHitRate[$ip] | Select-Object -Unique)
    }
}
$ipHitRateList = @($ipHitRateRaw | Sort-Object fileCount -Descending)

# Build urlIpMapList for output
$urlIpMapList = @(foreach ($relPath in ($urlIpMap.Keys | Sort-Object)) {
    [pscustomobject]@{
        file = $relPath
        urls = @($urlIpMap[$relPath].urls)
        ips  = @($urlIpMap[$relPath].ips)
    }
})

$mapOutput = [pscustomobject]@{
    schemaVersion   = 'DependencyMap/1.0'
    generated       = (Get-Date -Format 'o')
    workspace       = $WorkspacePath
    excludedFolders = $script:ExcludeNames
    summary         = [pscustomobject]@{
        folderCount   = $folderNodes.Count
        moduleCount   = $moduleNodes.Count
        scriptCount   = $scriptNodes.Count
        functionCount = $functionNodes.Count
        variableCount = $variableNodes.Count
        configCount   = $configNodes.Count
        edgeCount     = $resolvedEdges.Count
        urlFileCount  = @($urlIpMapList).Count
        uniqueHosts   = @($dnsResolution.Keys).Count
        uniqueIPs     = @($ipHitRateList).Count
    }
    nodes         = $allNodes
    edges         = $resolvedEdges
    urlIpByFile   = $urlIpMapList
    dnsResolution = $dnsResolution
    ipHitRate     = $ipHitRateList
}

$outJson = Join-Path $ReportPath "workspace-dependency-map-$timestamp.json"
ConvertTo-Json -InputObject $mapOutput -Depth 8 | Set-Content -Path $outJson -Encoding UTF8
Write-Output "  JSON: $outJson ($([Math]::Round((Get-Item $outJson).Length / 1KB, 1)) KB)"

# ── ZIP the JSON output ───────────────────────────────────────────────────────
if (-not $SkipZip) {
    Write-Output '[82%] Compressing scan data to ZIP...'
    $zipPath = $outJson -replace '\.json$', '.zip'
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            $outJson,
            [System.IO.Path]::GetFileName($outJson),
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
        $zip.Dispose()
        Write-Output "  ZIP:  $zipPath ($([Math]::Round((Get-Item $zipPath).Length / 1KB, 1)) KB)"
    } catch {
        Write-Output "  WARN: ZIP failed -- $($_.Exception.Message)"
    }
}

# Write pointer
$ptr = [pscustomobject]@{
    latest    = "workspace-dependency-map-$timestamp.json"
    zip       = "workspace-dependency-map-$timestamp.zip"
    generated = (Get-Date -Format 'o')
}
$ptrPath = Join-Path $ReportPath 'workspace-dependency-map-pointer.json'
ConvertTo-Json -InputObject $ptr -Depth 2 | Set-Content -Path $ptrPath -Encoding UTF8

# ─── Phase 7: Generate XHTML Dependency Visualisation ────────────────────────
if (-not $SkipHtml) {
    Write-Output '[90%] Generating Dependency-Visualisation XHTML...'

    # For performance: only include folder/module/script/config nodes
    $htmlNodes = @($allNodes | Where-Object { $_.type -in @('folder', 'module', 'script', 'config') })
    $htmlNodeIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($n in $htmlNodes) { $htmlNodeIds.Add($n.id) | Out-Null }
    $htmlEdges = @($resolvedEdges | Where-Object {
        $htmlNodeIds.Contains($_.source) -and $htmlNodeIds.Contains($_.target)
    })

    $graphData = [pscustomobject]@{
        generated     = (Get-Date -Format 'o')
        workspace     = $WorkspacePath
        summary       = $mapOutput.summary
        nodes         = $htmlNodes
        edges         = $htmlEdges
        urlIpByFile   = $urlIpMapList
        dnsResolution = $dnsResolution
        ipHitRate     = $ipHitRateList
    }
    $graphJson = ConvertTo-Json -InputObject $graphData -Depth 6 -Compress

    # Build XHTML (self-contained, valid XHTML 1.1, no external dependencies)
    # Three views: Graph, Links (URL/IP per file), IP Hit Rate (DNS resolved IP frequency table)
    $htmlContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
<meta http-equiv="Content-Type" content="application/xhtml+xml; charset=UTF-8" />
<meta name="viewport" content="width=device-width,initial-scale=1.0" />
<title>Workspace Dependency Visualisation</title>
<style type="text/css">
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#1a1a2e;color:#e0e0e0;display:flex;flex-direction:column;height:100vh;overflow:hidden}
#topbar{background:#0f3460;border-bottom:1px solid #e94560;padding:4px 10px;display:flex;align-items:center;gap:0;flex-shrink:0}
#topbar h2{font-size:13px;color:#e94560;margin-right:16px;white-space:nowrap}
.tab{background:transparent;border:none;border-bottom:3px solid transparent;color:#aaa;cursor:pointer;font-size:12px;padding:5px 14px;font-family:inherit}
.tab.active{color:#fff;border-bottom-color:#e94560}
.tab:hover{color:#e0e0e0}
#views{flex:1;overflow:hidden;display:flex}
.view{display:none;flex:1;overflow:hidden}
.view.active{display:flex}
/* Graph view */
#vGraph{flex-direction:row}
#sidebar{width:260px;background:#16213e;padding:8px;overflow-y:auto;display:flex;flex-direction:column;gap:7px;border-right:1px solid #0f3460;flex-shrink:0}
h3{font-size:10px;color:#e94560;letter-spacing:1px;text-transform:uppercase;margin:3px 0 2px}
#sum{background:#0f3460;border-radius:4px;padding:7px;font-size:11px;line-height:1.9}
#sum b{color:#e94560}
#filters{display:flex;flex-direction:column;gap:3px}
.fb{background:#0f3460;border:1px solid #1a4a7a;border-radius:3px;color:#e0e0e0;cursor:pointer;font-size:11px;padding:3px 7px;text-align:left;display:flex;align-items:center;gap:5px}
.fb.active{border-color:#e94560;background:#1e3a5f}
.dot{width:9px;height:9px;border-radius:50%;display:inline-block;flex-shrink:0}
#nodeInfo{background:#0f3460;border-radius:4px;padding:7px;font-size:11px;line-height:1.7;white-space:pre-wrap;word-break:break-all;min-height:80px;color:#ccc}
.nil{color:#555}
#gMain{flex:1;position:relative;overflow:hidden}
svg{width:100%;height:100%}
.node{cursor:pointer}
.node circle,.node rect,.node polygon{stroke-width:1.5;transition:stroke .15s}
.node:hover circle,.node:hover rect,.node:hover polygon{stroke:#fff!important;stroke-width:2.5}
.node.sel circle,.node.sel rect,.node.sel polygon{stroke:#ffe600!important;stroke-width:3}
.lnk{stroke-opacity:.28}
.nlbl{font-size:9px;fill:#aaa;pointer-events:none;dominant-baseline:middle}
#gctrl{position:absolute;top:7px;right:7px;display:flex;gap:4px}
.cb{background:rgba(15,52,96,.9);border:1px solid #1a4a7a;border-radius:3px;color:#e0e0e0;cursor:pointer;font-size:11px;padding:3px 8px}
.cb:hover{color:#fff;background:#1e3a5f}
#zlbl{position:absolute;bottom:5px;right:7px;font-size:10px;color:#555;background:rgba(15,52,96,.7);padding:2px 5px;border-radius:3px}
#sinfo{position:absolute;bottom:5px;left:5px;font-size:10px;color:#444}
/* Table views */
#vLinks,#vIp{flex-direction:column;overflow:hidden}
.vtop{background:#16213e;border-bottom:1px solid #0f3460;padding:6px 10px;display:flex;align-items:center;gap:10px;flex-shrink:0}
.vtop label{font-size:11px;color:#aaa}
.vtop input{background:#0f3460;border:1px solid #1a4a7a;color:#e0e0e0;border-radius:3px;padding:2px 6px;font-size:11px;width:280px}
.tscroll{flex:1;overflow-y:auto;padding:8px}
table{width:100%;border-collapse:collapse;font-size:11px}
th{background:#0f3460;color:#e94560;text-align:left;padding:5px 8px;position:sticky;top:0;z-index:1;cursor:pointer;user-select:none}
th:hover{background:#1a4a7a}
td{padding:4px 8px;border-bottom:1px solid #0f3460;vertical-align:top;word-break:break-all}
tr:hover td{background:#16213e}
.badge{display:inline-block;background:#e94560;color:#fff;border-radius:9px;padding:0 5px;font-size:10px;min-width:18px;text-align:center}
.urllink{color:#4a9eff;text-decoration:none}
.urllink:hover{text-decoration:underline}
.ipbadge{background:#22d3ee;color:#1a1a2e;border-radius:3px;padding:1px 4px;font-size:10px;font-family:monospace}
.nodata{color:#555;padding:20px;text-align:center}
::-webkit-scrollbar{width:6px;height:6px}
::-webkit-scrollbar-track{background:#1a1a2e}
::-webkit-scrollbar-thumb{background:#0f3460;border-radius:3px}
</style>
</head>
<body>
<div id="topbar">
  <h2>Workspace Dependency Map</h2>
  <button class="tab active" id="tbGraph"  onclick="swTab('Graph')">&#x1F5FA; Graph</button>
  <button class="tab"        id="tbLinks"  onclick="swTab('Links')">&#x1F517; Links &amp; IPs</button>
  <button class="tab"        id="tbIp"     onclick="swTab('Ip')">&#x1F4CD; IP Hit Rate</button>
</div>
<div id="views">

  <!-- ═══ GRAPH VIEW ════════════════════════════════════════════════════════ -->
  <div class="view active" id="vGraph">
    <div id="sidebar">
      <h3>Summary</h3>
      <div id="sum"><i>Loading&#8230;</i></div>
      <h3>Filter</h3>
      <div id="filters"></div>
      <h3>Node Detail</h3>
      <div id="nodeInfo"><span class="nil">Click a node to inspect</span></div>
    </div>
    <div id="gMain">
      <svg id="gsvg"></svg>
      <div id="gctrl">
        <button class="cb" onclick="gReset()">Reset</button>
        <button class="cb" onclick="gLbls()">Labels</button>
        <button class="cb" onclick="gRelax()">Relax</button>
      </div>
      <div id="zlbl">Scroll=zoom  Drag=pan  Click=select</div>
      <div id="sinfo">Simulating&#8230;</div>
    </div>
  </div>

  <!-- ═══ LINKS VIEW ════════════════════════════════════════════════════════ -->
  <div class="view" id="vLinks">
    <div class="vtop">
      <label>Filter:</label>
      <input type="text" id="linksFilter" oninput="filterLinks()" placeholder="file name, URL, or IP&#8230;" />
      <span id="linksCount" style="font-size:11px;color:#aaa;margin-left:8px"></span>
    </div>
    <div class="tscroll">
      <table id="linksTable">
        <thead><tr>
          <th onclick="sortLinks(0)">File</th>
          <th onclick="sortLinks(1)">URLs <span id="urlTot"></span></th>
          <th onclick="sortLinks(2)">Direct IPs <span id="ipTot"></span></th>
        </tr></thead>
        <tbody id="linksBody"></tbody>
      </table>
      <div id="linksNone" class="nodata" style="display:none">No URL or IP references found in scanned files.</div>
    </div>
  </div>

  <!-- ═══ IP HIT RATE VIEW ══════════════════════════════════════════════════ -->
  <div class="view" id="vIp">
    <div class="vtop">
      <label>Filter:</label>
      <input type="text" id="ipFilter" oninput="filterIp()" placeholder="IP address or file&#8230;" />
      <span id="ipCount" style="font-size:11px;color:#aaa;margin-left:8px"></span>
    </div>
    <div class="tscroll">
      <table id="ipTable">
        <thead><tr>
          <th onclick="sortIp(0)">IP Address</th>
          <th onclick="sortIp(1)">File Hits &#x25BC;</th>
          <th onclick="sortIp(2)">Resolved From Host(s)</th>
          <th onclick="sortIp(3)">Referenced In Files</th>
        </tr></thead>
        <tbody id="ipBody"></tbody>
      </table>
      <div id="ipNone" class="nodata" style="display:none">No IP data available. Run scan with DNS resolution enabled.</div>
    </div>
  </div>

</div>
<script type="text/javascript">
//<![CDATA[
document.addEventListener('DOMContentLoaded',function(){
(function(){
var D=JSON.parse(document.getElementById('rawdata').textContent);
var s=D.summary||{};

// ─── Tab switching ────────────────────────────────────────────────────────────
function swTab(t){
  ['Graph','Links','Ip'].forEach(function(n){
    document.getElementById('v'+n).classList.remove('active');
    document.getElementById('tb'+n).classList.remove('active');
  });
  document.getElementById('v'+t).classList.add('active');
  document.getElementById('tb'+t).classList.add('active');
}
window.swTab=swTab;

// ─── Summary ─────────────────────────────────────────────────────────────────
document.getElementById('sum').innerHTML=
  '<b>Date:</b> '+(D.generated||'').split('T')[0]+'<br/>'+
  '<b>Folders:</b> '+(s.folderCount||0)+'&#160;&#160;<b>Modules:</b> '+(s.moduleCount||0)+'<br/>'+
  '<b>Scripts:</b> '+(s.scriptCount||0)+'&#160;&#160;<b>Configs:</b> '+(s.configCount||0)+'<br/>'+
  '<b>Functions:</b> '+(s.functionCount||0)+'&#160;&#160;<b>Vars:</b> '+(s.variableCount||0)+'<br/>'+
  '<b>Edges:</b> '+(s.edgeCount||0)+'<br/>'+
  '<b>URL files:</b> '+(s.urlFileCount||0)+'&#160;&#160;<b>Hosts:</b> '+(s.uniqueHosts||0)+'<br/>'+
  '<b>Unique IPs:</b> '+(s.uniqueIPs||0);

// ─── Graph (optimised for 2000+ nodes) ────────────────────────────────────────
var TM={
  folder: {color:'#4a9eff',shape:'rect',   r:10,lbl:'Folders'},
  module: {color:'#ff8c42',shape:'circle', r:12,lbl:'Modules'},
  script: {color:'#51cf66',shape:'circle', r:7, lbl:'Scripts'},
  config: {color:'#22d3ee',shape:'diamond',r:8, lbl:'Configs'}
};
var EC={contains:'#1a3a5e',defines:'#3a2a5e',imports:'#1a4a2e',requires:'#1a4a4e'};
var NS=document.createElementNS.bind(document,'http://www.w3.org/2000/svg');
var TOTAL=(D.nodes||[]).length,IS_LARGE=TOTAL>500;
var showLbls=!IS_LARGE,selId=null;
var active=Object.keys(TM).reduce(function(a,k){a[k]=true;return a;},{});

// Filters
var fEl=document.getElementById('filters');
Object.keys(TM).forEach(function(t){
  var cnt=(D.nodes||[]).filter(function(n){return n.type===t;}).length;
  if(!cnt)return;
  var b=document.createElement('button');
  b.className='fb active';b.setAttribute('data-t',t);
  b.innerHTML='<span class="dot" style="background:'+TM[t].color+'"></span>'+TM[t].lbl+' <small>('+cnt+')</small>';
  b.onclick=function(){
    if(active[t]){delete active[t];b.classList.remove('active');}
    else{active[t]=true;b.classList.add('active');}
    updVis();
  };
  fEl.appendChild(b);
});

// SVG
var svg=document.getElementById('gsvg');
var W=svg.clientWidth||900,H=svg.clientHeight||680;
var vp=NS('g');svg.appendChild(vp);
var lg=NS('g');vp.appendChild(lg);
var ng=NS('g');vp.appendChild(ng);

function mk(t,a){var e=NS(t);Object.keys(a||{}).forEach(function(k){e.setAttribute(k,a[k]);});return e;}

// Initial positions — spread by type rings with jitter for large sets
var byType={folder:[],module:[],script:[],config:[]};
(D.nodes||[]).forEach(function(n){if(byType[n.type])byType[n.type].push(n);});
var rings={folder:80,module:220,script:420,config:560};
Object.keys(byType).forEach(function(t){
  var nodes=byType[t],R=rings[t]||300;
  if(IS_LARGE){R=R*Math.sqrt(TOTAL/500);}
  nodes.forEach(function(n,i){
    var a=2*Math.PI*i/Math.max(nodes.length,1);
    var jitter=IS_LARGE?(Math.random()-0.5)*R*0.3:0;
    n.x=W/2+(R+jitter)*Math.cos(a);n.y=H/2+(R+jitter)*Math.sin(a);n.vx=0;n.vy=0;
  });
});

var nById={};(D.nodes||[]).forEach(function(n){nById[n.id]=n;});

// ─── Progressive edge rendering ─────────────────────────────────────────────
var edgeQueue=[];
(D.edges||[]).forEach(function(e){
  var src=nById[e.source],tgt=nById[e.target];
  if(src&&tgt)edgeQueue.push(e);
});
var lEls={},EDGE_BATCH=IS_LARGE?150:9999,edgesRendered=0;
function renderEdgeBatch(){
  var end=Math.min(edgesRendered+EDGE_BATCH,edgeQueue.length);
  var frag=document.createDocumentFragment();
  for(var i=edgesRendered;i<end;i++){
    var e=edgeQueue[i],src=nById[e.source],tgt=nById[e.target];
    var l=mk('line',{class:'lnk',stroke:EC[e.rel]||'#1a3a5e','stroke-width':e.rel==='contains'?0.8:1.3,
      x1:src.x,y1:src.y,x2:tgt.x,y2:tgt.y});
    l._s=src;l._t=tgt;l._rel=e.rel;
    frag.appendChild(l);
    lEls[e.source+':'+e.target]=l;
  }
  lg.appendChild(frag);
  edgesRendered=end;
  if(edgesRendered<edgeQueue.length){
    setTimeout(renderEdgeBatch,20);
  }
}
renderEdgeBatch();

// ─── Progressive node rendering ──────────────────────────────────────────────
var nEls={},nodeQueue=(D.nodes||[]).slice(),NODE_BATCH=IS_LARGE?200:9999,nodesRendered=0;
function drawNode(n){
  var m=TM[n.type];if(!m)return;
  var g=mk('g',{class:'node',transform:'translate('+n.x+','+n.y+')'});
  var sh;
  if(m.shape==='rect'){sh=mk('rect',{x:-m.r,y:-(m.r*0.6),width:m.r*2,height:m.r*1.2,rx:2,fill:m.color+'bb',stroke:m.color});}
  else if(m.shape==='diamond'){sh=mk('polygon',{points:'0,'+ -m.r+' '+m.r+',0 0,'+m.r+' '+ -m.r+',0',fill:m.color+'bb',stroke:m.color});}
  else{sh=mk('circle',{cx:0,cy:0,r:m.r,fill:m.color+'bb',stroke:m.color});}
  g.appendChild(sh);
  if(showLbls){
    var lx=m.shape==='rect'?0:m.r+3,ta=m.shape==='rect'?'middle':'start';
    var lbl=mk('text',{class:'nlbl',x:lx,y:0,'text-anchor':ta});
    lbl.textContent=n.label.length>24?n.label.slice(0,22)+'...':n.label;
    g.appendChild(lbl);
  }
  g.addEventListener('click',function(){selNode(n.id);});
  nEls[n.id]={g:g,n:n};
  return g;
}
function renderNodeBatch(){
  var end=Math.min(nodesRendered+NODE_BATCH,nodeQueue.length);
  var frag=document.createDocumentFragment();
  for(var i=nodesRendered;i<end;i++){
    var g=drawNode(nodeQueue[i]);
    if(g)frag.appendChild(g);
  }
  ng.appendChild(frag);
  nodesRendered=end;
  if(nodesRendered<nodeQueue.length){
    setTimeout(renderNodeBatch,20);
  }
}
renderNodeBatch();

// ─── Barnes-Hut Quadtree for O(n log n) repulsion ───────────────────────────
var BH_THETA=0.9;
function QNode(x,y,w,h){this.x=x;this.y=y;this.w=w;this.h=h;this.body=null;this.mass=0;this.cx=0;this.cy=0;this.children=null;}
function qtInsert(qt,n){
  if(qt.mass===0){qt.body=n;qt.mass=1;qt.cx=n.x;qt.cy=n.y;return;}
  if(qt.body!==null){
    if(qt.w<1)return;
    var old=qt.body;qt.body=null;qt.children=qtSplit(qt);qtPut(qt,old);
  }
  qt.cx=(qt.cx*qt.mass+n.x)/(qt.mass+1);qt.cy=(qt.cy*qt.mass+n.y)/(qt.mass+1);qt.mass++;
  if(!qt.children)qt.children=qtSplit(qt);
  qtPut(qt,n);
}
function qtSplit(qt){var hw=qt.w/2,hh=qt.h/2;return[new QNode(qt.x,qt.y,hw,hh),new QNode(qt.x+hw,qt.y,hw,hh),new QNode(qt.x,qt.y+hh,hw,hh),new QNode(qt.x+hw,qt.y+hh,hw,hh)];}
function qtPut(qt,n){var hw=qt.w/2,hh=qt.h/2,i=(n.x>qt.x+hw?1:0)+(n.y>qt.y+hh?2:0);qtInsert(qt.children[i],n);}
function qtForce(qt,n,repel){
  if(qt.mass===0)return;
  var dx=qt.cx-n.x,dy=qt.cy-n.y,d2=dx*dx+dy*dy+1;
  if(qt.mass===1&&qt.body===n)return;
  if(qt.children===null||qt.w/Math.sqrt(d2)<BH_THETA){
    var d=Math.sqrt(d2),f=repel*qt.mass/d2,fx=f*dx/d,fy=f*dy/d;
    n.vx-=fx;n.vy-=fy;return;
  }
  for(var i=0;i<4;i++)qtForce(qt.children[i],n,repel);
}

// Simulation (adaptive)
var REPEL=IS_LARGE?600:900,ATTR=IS_LARGE?0.03:0.05,DAMP=IS_LARGE?0.82:0.88,LD=IS_LARGE?60:90,CG=0.003;
var TICKS_PER_FRAME=IS_LARGE?1:4;
function tick(){
  var nodes=D.nodes||[];
  // Build quadtree
  var minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity;
  for(var i=0;i<nodes.length;i++){var n=nodes[i];if(n.x<minX)minX=n.x;if(n.y<minY)minY=n.y;if(n.x>maxX)maxX=n.x;if(n.y>maxY)maxY=n.y;}
  var pad=50,sz=Math.max(maxX-minX+pad*2,maxY-minY+pad*2,100);
  var qt=new QNode(minX-pad,minY-pad,sz,sz);
  for(var i=0;i<nodes.length;i++)qtInsert(qt,nodes[i]);
  // Repulsion via quadtree
  for(var i=0;i<nodes.length;i++)qtForce(qt,nodes[i],REPEL);
  // Attraction along edges
  for(var i=0;i<edgeQueue.length;i++){
    var e=edgeQueue[i],src=nById[e.source],tgt=nById[e.target];if(!src||!tgt)continue;
    var dx=tgt.x-src.x,dy=tgt.y-src.y,d=Math.sqrt(dx*dx+dy*dy)||1;
    var f=(d-LD)*ATTR,fx=f*dx/d,fy=f*dy/d;
    src.vx+=fx;src.vy+=fy;tgt.vx-=fx;tgt.vy-=fy;
  }
  // Gravity + damping
  for(var i=0;i<nodes.length;i++){
    var n=nodes[i];
    n.vx+=(W/2-n.x)*CG;n.vy+=(H/2-n.y)*CG;
    n.vx*=DAMP;n.vy*=DAMP;n.x+=n.vx;n.y+=n.vy;
  }
}
function updPos(){
  var keys=Object.keys(lEls);
  for(var i=0;i<keys.length;i++){var l=lEls[keys[i]];l.setAttribute('x1',l._s.x);l.setAttribute('y1',l._s.y);l.setAttribute('x2',l._t.x);l.setAttribute('y2',l._t.y);}
  var ids=Object.keys(nEls);
  for(var i=0;i<ids.length;i++){var d=nEls[ids[i]];d.g.setAttribute('transform','translate('+d.n.x+','+d.n.y+')');}
}
var ticks=0,running=true,maxT=IS_LARGE?200:400;
var si=document.getElementById('sinfo');
function anim(){
  if(!running)return;
  for(var i=0;i<TICKS_PER_FRAME;i++)tick();
  ticks+=TICKS_PER_FRAME;
  updPos();
  if(IS_LARGE&&ticks%10===0)si.textContent='Simulating: '+Math.round(ticks/maxT*100)+'%';
  if(ticks<maxT)requestAnimationFrame(anim);else{si.textContent=TOTAL+' nodes rendered';running=false;}
}
anim();
function gRelax(){ticks=0;maxT=IS_LARGE?100:200;running=true;requestAnimationFrame(anim);}
window.gRelax=gRelax;

function updVis(){
  var ids=Object.keys(nEls);
  for(var i=0;i<ids.length;i++){var d=nEls[ids[i]];d.g.style.display=active[d.n.type]?'':'none';}
  var keys=Object.keys(lEls);
  for(var i=0;i<keys.length;i++){var l=lEls[keys[i]];var sv=active[(nById[l._s.id]||{type:''}).type];var tv=active[(nById[l._t.id]||{type:''}).type];l.style.display=(sv&&tv)?'':'none';}
}

function selNode(id){
  if(selId&&nEls[selId])nEls[selId].g.classList.remove('sel');
  selId=id;if(nEls[id])nEls[id].g.classList.add('sel');
  var n=nById[id];if(!n)return;
  var lines=['Type:  '+n.type,'Label: '+n.label,'Path:  '+(n.path||'-')];
  if(n.versionTag)lines.push('Ver:   '+n.versionTag);
  if(n.sizeBytes) lines.push('Size:  '+Math.round(n.sizeBytes/1024)+' KB');
  if(n.functions&&n.functions.length)lines.push('Fns ('+n.functions.length+'):\n  '+n.functions.slice(0,10).join('\n  ')+(n.functions.length>10?'\n  ...':''));
  if(n.urls&&n.urls.length)lines.push('URLs ('+n.urls.length+'):\n  '+n.urls.slice(0,5).join('\n  ')+(n.urls.length>5?'\n  ...':''));
  if(n.ips&&n.ips.length)lines.push('IPs:   '+n.ips.join(', '));
  if(n.topKeys&&n.topKeys.length)lines.push('Keys:  '+n.topKeys.slice(0,15).join(', '));
  document.getElementById('nodeInfo').textContent=lines.join('\n');
}

function gLbls(){
  showLbls=!showLbls;
  var ids=Object.keys(nEls);
  for(var i=0;i<ids.length;i++){
    var d=nEls[ids[i]],g=d.g,m=TM[d.n.type];if(!m)continue;
    var t=g.querySelector('.nlbl');
    if(showLbls&&!t){
      var lx=m.shape==='rect'?0:m.r+3,ta=m.shape==='rect'?'middle':'start';
      t=mk('text',{class:'nlbl',x:lx,y:0,'text-anchor':ta});
      t.textContent=d.n.label.length>24?d.n.label.slice(0,22)+'...':d.n.label;
      g.appendChild(t);
    } else if(t){t.style.display=showLbls?'':'none';}
  }
}
window.gLbls=gLbls;

var px=0,py=0,sc=1,pan=false,ps={x:0,y:0};
function atr(){vp.setAttribute('transform','translate('+px+','+py+') scale('+sc+')');document.getElementById('zlbl').textContent='Zoom: '+Math.round(sc*100)+'%';}
svg.addEventListener('mousedown',function(e){if(e.target.closest&&e.target.closest('.node'))return;pan=true;ps={x:e.clientX-px,y:e.clientY-py};svg.style.cursor='grabbing';});
window.addEventListener('mousemove',function(e){if(!pan)return;px=e.clientX-ps.x;py=e.clientY-ps.y;atr();});
window.addEventListener('mouseup',function(){pan=false;svg.style.cursor='';});
svg.addEventListener('wheel',function(e){
  e.preventDefault();
  var f=e.deltaY<0?1.12:0.89,r=svg.getBoundingClientRect();
  var mx=e.clientX-r.left,my=e.clientY-r.top;
  px=mx-f*(mx-px);py=my-f*(my-py);
  sc=Math.max(0.1,Math.min(6,sc*f));atr();
},{passive:false});
function gReset(){px=0;py=0;sc=1;atr();}
window.gReset=gReset;

// ─── Links table ──────────────────────────────────────────────────────────────
var linksData=D.urlIpByFile||[];
var urlTotal=0,ipTotal=0;
linksData.forEach(function(r){urlTotal+=(r.urls||[]).length;ipTotal+=(r.ips||[]).length;});
document.getElementById('urlTot').textContent='('+urlTotal+')';
document.getElementById('ipTot').textContent='('+ipTotal+')';
var linksSort={col:1,asc:false};

function renderLinksRow(r){
  var urlsHtml=(r.urls||[]).map(function(u){
    var safe=u.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    return '<a class="urllink" href="'+safe+'" target="_blank" rel="noopener noreferrer">'+safe+'</a>';
  }).join('<br/>');
  var ipsHtml=(r.ips||[]).map(function(ip){return '<span class="ipbadge">'+ip.replace(/&/g,'&amp;')+'</span>';}).join(' ');
  return '<td>'+r.file.replace(/&/g,'&amp;').replace(/</g,'&lt;')+'</td>'+
         '<td>'+(urlsHtml||'<span class="nil">&#8212;</span>')+'</td>'+
         '<td>'+(ipsHtml||'<span class="nil">&#8212;</span>')+'</td>';
}

function filterLinks(){
  var q=(document.getElementById('linksFilter').value||'').toLowerCase();
  var rows=document.getElementById('linksBody').querySelectorAll('tr');
  var vis=0;
  rows.forEach(function(tr){
    var show=!q||tr.textContent.toLowerCase().indexOf(q)!==-1;
    tr.style.display=show?'':'none';if(show)vis++;
  });
  document.getElementById('linksCount').textContent=vis+' / '+rows.length+' entries';
}
window.filterLinks=filterLinks;

function sortLinks(col){
  var asc=linksSort.col===col?!linksSort.asc:true;
  linksSort={col:col,asc:asc};
  linksData.sort(function(a,b){
    var va=col===0?a.file:(col===1?(a.urls||[]).length:(a.ips||[]).length);
    var vb=col===0?b.file:(col===1?(b.urls||[]).length:(b.ips||[]).length);
    return asc?(va>vb?1:-1):(va<vb?1:-1);
  });
  buildLinksTable();
}
window.sortLinks=sortLinks;

function buildLinksTable(){
  var tb=document.getElementById('linksBody');
  tb.innerHTML='';
  linksData.forEach(function(r){
    var tr=document.createElement('tr');
    tr.innerHTML=renderLinksRow(r);
    tb.appendChild(tr);
  });
  if(linksData.length===0)document.getElementById('linksNone').style.display='';
  document.getElementById('linksCount').textContent=linksData.length+' entries';
}

// Initial sort by URL count desc
linksData.sort(function(a,b){return (b.urls||[]).length-(a.urls||[]).length;});
buildLinksTable();

// ─── IP Hit Rate table ────────────────────────────────────────────────────────
var ipData=D.ipHitRate||[];
var dns=D.dnsResolution||{};
var ipSort={col:1,asc:false};

// Build reverse: ip -> hostnames
var ipToHosts={};
Object.keys(dns).forEach(function(host){
  var entry=dns[host];
  (entry.ips||[]).forEach(function(ip){
    if(!ipToHosts[ip])ipToHosts[ip]=[];
    if(ipToHosts[ip].indexOf(host)===-1)ipToHosts[ip].push(host);
  });
});

function renderIpRow(r){
  var hostsArr=ipToHosts[r.ip]||[];
  var hostsHtml=hostsArr.length?hostsArr.map(function(h){return h.replace(/&/g,'&amp;');}).join('<br/>'):'<span class="nil">direct ref</span>';
  var filesHtml=(r.files||[]).map(function(f){return f.replace(/&/g,'&amp;').replace(/</g,'&lt;');}).join('<br/>');
  return '<td><span class="ipbadge">'+r.ip+'</span></td>'+
         '<td><span class="badge">'+r.fileCount+'</span></td>'+
         '<td>'+hostsHtml+'</td>'+
         '<td>'+filesHtml+'</td>';
}

function filterIp(){
  var q=(document.getElementById('ipFilter').value||'').toLowerCase();
  var rows=document.getElementById('ipBody').querySelectorAll('tr');
  var vis=0;
  rows.forEach(function(tr){
    var show=!q||tr.textContent.toLowerCase().indexOf(q)!==-1;
    tr.style.display=show?'':'none';if(show)vis++;
  });
  document.getElementById('ipCount').textContent=vis+' / '+rows.length+' entries';
}
window.filterIp=filterIp;

function sortIp(col){
  var asc=ipSort.col===col?!ipSort.asc:true;
  ipSort={col:col,asc:asc};
  ipData.sort(function(a,b){
    var va=col===0?a.ip:col===1?a.fileCount:(ipToHosts[a.ip]||[]).join('');
    var vb=col===0?b.ip:col===1?b.fileCount:(ipToHosts[b.ip]||[]).join('');
    return asc?(va>vb?1:-1):(va<vb?1:-1);
  });
  buildIpTable();
}
window.sortIp=sortIp;

function buildIpTable(){
  var tb=document.getElementById('ipBody');
  tb.innerHTML='';
  ipData.forEach(function(r){
    var tr=document.createElement('tr');
    tr.innerHTML=renderIpRow(r);
    tb.appendChild(tr);
  });
  if(ipData.length===0)document.getElementById('ipNone').style.display='';
  document.getElementById('ipCount').textContent=ipData.length+' IPs';
}

ipData.sort(function(a,b){return b.fileCount-a.fileCount;});
buildIpTable();

})();
});
//]]>
</script>
<script type="application/json" id="rawdata">GRAPH_JSON_PLACEHOLDER</script>
</body>
</html>
"@

    $htmlContent = $htmlContent -replace 'GRAPH_JSON_PLACEHOLDER', $graphJson

    $htmlOutPath = Join-Path $WorkspacePath (Join-Path '~README.md' 'Dependency-Visualisation.html')
    try {
        Set-Content -Path $htmlOutPath -Value $htmlContent -Encoding UTF8
        Write-Output "  XHTML: $htmlOutPath ($([Math]::Round((Get-Item $htmlOutPath).Length / 1KB, 1)) KB)"
    } catch {
        Write-Output "  WARN: Could not write XHTML -- $($_.Exception.Message)"
    }
}

# ─── Done ─────────────────────────────────────────────────────────────────────
Write-Output '[100%] Workspace Dependency Map complete.'
Write-Output "  Nodes: $(@($allNodes).Count)   Edges: $(@($resolvedEdges).Count)"
Write-Output "  Folders: $($folderNodes.Count)  Modules: $($moduleNodes.Count)  Scripts: $($scriptNodes.Count)"
Write-Output "  Functions: $($functionNodes.Count)  Variables: $($variableNodes.Count)  Configs: $($configNodes.Count)"

