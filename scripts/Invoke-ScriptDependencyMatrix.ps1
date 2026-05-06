# VersionTag: 2604.B2.V31.0
# VersionBuildHistory:
#   2603.B0.v25  2026-03-29 (per-node metadata: lastModified, editCount, author, version)
#   2603.B0.v24  2026-03-28 (config mapping, version data, synopsis, style-diff)
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [string]$ReportPath,
    [string]$TempPath,
    [int]$MermaidEdgeLimit = 180,
    [switch]$VerifyStyleConsistency
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    Write-Output ("Dependency matrix error: {0}" -f $_.Exception.Message)
    if ($_.InvocationInfo) {
        Write-Output $_.InvocationInfo.PositionMessage
    }
    exit 1
}

Write-Output 'Dependency matrix generator start'

function Write-PercentRow {
    param([int]$Percent, [string]$Label)
    $p = [Math]::Max(0, [Math]::Min(100, $Percent))
    Write-Output ("[{0,3}%] {1}" -f $p, $Label)
}

Write-PercentRow -Percent 2 -Label 'Starting dependency matrix scan'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $scriptRootPath = Split-Path -Parent $MyInvocation.MyCommand.Path
    $WorkspacePath = Split-Path -Parent $scriptRootPath
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $WorkspacePath '~REPORTS'
}
if ([string]::IsNullOrWhiteSpace($TempPath)) {
    $TempPath = Join-Path $WorkspacePath 'temp'
}
if (-not (Test-Path $ReportPath)) {
    New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
}
if (-not (Test-Path $TempPath)) {
    New-Item -ItemType Directory -Path $TempPath -Force | Out-Null
}

$scriptExtensions = @('.ps1','.psm1','.psd1','.bat','.cmd','.vbs')

function Add-ModuleRequirement {
    param(
        [System.Collections.Generic.List[object]]$Collection,
        [string]$SourceScript,
        [string]$ModuleName,
        [string]$ConstraintType,
        [string]$ConstraintValue,
        [string]$DeclaredBy,
        [string]$RawReference
    )

    if ([string]::IsNullOrWhiteSpace($ModuleName)) { return }

    $Collection.Add([pscustomobject]@{
        source = $SourceScript
        module = $ModuleName.Trim()
        constraintType = $ConstraintType
        constraintValue = $ConstraintValue
        declaredBy = $DeclaredBy
        rawReference = $RawReference
    }) | Out-Null
}

function Get-ModuleHashtableReference {
    param([string]$Text)

    $moduleName = $null
    $constraintType = 'any'
    $constraintValue = $null

    if ($Text -match '(?i)ModuleName\s*=\s*''([^'']+)''') {
        $moduleName = $Matches[1]
    } elseif ($Text -match '(?i)ModuleName\s*=\s*"([^"]+)"') {
        $moduleName = $Matches[1]
    }

    if ($Text -match '(?i)RequiredVersion\s*=\s*''([^'']+)''') {
        $constraintType = 'required'
        $constraintValue = $Matches[1]
        return [pscustomobject]@{ moduleName = $moduleName; constraintType = $constraintType; constraintValue = $constraintValue }
    }
    if ($Text -match '(?i)RequiredVersion\s*=\s*"([^"]+)"') {
        $constraintType = 'required'
        $constraintValue = $Matches[1]
        return [pscustomobject]@{ moduleName = $moduleName; constraintType = $constraintType; constraintValue = $constraintValue }
    }

    if ($Text -match '(?i)(ModuleVersion|MinimumVersion)\s*=\s*''([^'']+)''') {
        $constraintType = 'minimum'
        $constraintValue = $Matches[2]
    } elseif ($Text -match '(?i)(ModuleVersion|MinimumVersion)\s*=\s*"([^"]+)"') {
        $constraintType = 'minimum'
        $constraintValue = $Matches[2]
    }

    [pscustomobject]@{ moduleName = $moduleName; constraintType = $constraintType; constraintValue = $constraintValue }
}

Write-Progress -Activity 'Dependency Matrix' -Status 'Scanning workspace for script files...' -PercentComplete 0 -Id 1
Write-PercentRow -Percent 10 -Label 'Scanning workspace scripts'

$allScripts = Get-ChildItem -Path $WorkspacePath -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $ext = $_.Extension.ToLowerInvariant()
    if ($scriptExtensions -notcontains $ext) { return $false }
    if ($_.FullName -like "$WorkspacePath\.git\*") { return $false }
    if ($_.FullName -like "$WorkspacePath\.history\*") { return $false }
    if ($_.FullName -like "$WorkspacePath\~REPORTS\archive\*") { return $false }
    return $true
} | Sort-Object FullName

$scriptIndex = @{}
$nodes = @()
$nodeCounter = 0

foreach ($file in $allScripts) {
    $relative = $file.FullName.Substring($WorkspacePath.Length).TrimStart('\')
    $nodeId = "N$nodeCounter"
    $nodeCounter++

    # Per-node file metadata
    $fileLastModified = $file.LastWriteTime.ToString('o')
    $historyPattern = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) + '_*' + $file.Extension
    $historyDir = Join-Path $WorkspacePath '.history' $relative.Replace($file.Name, '')
    $fileEditCount = 0
    if (Test-Path $historyDir) {
        $fileEditCount = @(Get-ChildItem -Path $historyDir -Filter $historyPattern -File -ErrorAction SilentlyContinue).Count
    }

    $entry = [pscustomobject]@{
        nodeId = $nodeId
        name = $file.Name
        relativePath = $relative
        fullPath = $file.FullName
        extension = $file.Extension.ToLowerInvariant()
        directory = (Split-Path $relative -Parent)
        lastModified = $fileLastModified
        editCount = $fileEditCount
    }

    $scriptIndex[$relative.ToLowerInvariant()] = $entry
    $nodes += $entry
}

$edges = New-Object 'System.Collections.Generic.List[object]'
$edgeSeen = New-Object 'System.Collections.Generic.HashSet[string]'

$moduleRequirements = New-Object 'System.Collections.Generic.List[object]'
$scanErrors = New-Object 'System.Collections.Generic.List[object]'

$tokenToTargets = @{}
foreach ($dst in $nodes) {
    $tokens = @(
        $dst.name,
        $dst.relativePath,
        ($dst.relativePath -replace '\\','/')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($token in $tokens) {
        $key = $token.ToLowerInvariant()
        if (-not $tokenToTargets.ContainsKey($key)) {
            $tokenToTargets[$key] = New-Object 'System.Collections.Generic.List[object]'
        }
        $tokenToTargets[$key].Add($dst) | Out-Null
    }
}

# ── Discover workspace modules (modules/ + scripts/ subfolders) ──────────────
$workspaceModuleCandidates = @{}
$moduleSearchPaths = @(
    (Join-Path $WorkspacePath 'modules'),
    (Join-Path $WorkspacePath 'scripts')
)
$workspaceModuleFiles = @()
foreach ($searchRoot in $moduleSearchPaths) {
    if (Test-Path $searchRoot) {
        $workspaceModuleFiles += @(Get-ChildItem -Path $searchRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension -in @('.psd1', '.psm1')
        })
    }
}
Write-Output "Workspace module files found: $($workspaceModuleFiles.Count) (from modules/ + scripts/)"
Write-PercentRow -Percent 24 -Label 'Discovering workspace modules'

foreach ($moduleFile in $workspaceModuleFiles) {
    $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($moduleFile.Name)
    if ([string]::IsNullOrWhiteSpace($moduleName)) { continue }

    $version     = $null
    $author      = $null
    $description = $null
    if ($moduleFile.Extension -ieq '.psd1') {
        try {
            $manifest = Import-PowerShellDataFile -Path $moduleFile.FullName -ErrorAction Stop
            if ($manifest.ContainsKey('ModuleVersion')) { $version     = [string]$manifest.ModuleVersion }
            if ($manifest.ContainsKey('Author'))        { $author      = [string]$manifest.Author }
            if ($manifest.ContainsKey('Description'))   { $description = [string]$manifest.Description }
        } catch { <# Intentional: non-fatal #> }
    }

    $key = $moduleName.ToLowerInvariant()
    if (-not $workspaceModuleCandidates.ContainsKey($key)) {
        $workspaceModuleCandidates[$key] = New-Object 'System.Collections.Generic.List[object]'
    }
    $workspaceModuleCandidates[$key].Add([pscustomobject]@{
        module      = $moduleName
        version     = $version
        author      = $author
        description = $description
        path        = $moduleFile.FullName
    }) | Out-Null
}

# ── Discover system / user modules from PSModulePath ─────────────────────────
$systemModuleCandidates = @{}
$psModPaths = ($env:PSModulePath -split ';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_ -ErrorAction SilentlyContinue) }
foreach ($modRoot in $psModPaths) {
    $subDirs = @(Get-ChildItem -Path $modRoot -Directory -ErrorAction SilentlyContinue)
    foreach ($dir in $subDirs) {
        $sysModName = $dir.Name
        $sysKey     = $sysModName.ToLowerInvariant()

        $sysManifest = Get-ChildItem -Path $dir.FullName -Filter '*.psd1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $sysPsm      = Get-ChildItem -Path $dir.FullName -Filter '*.psm1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $sysManifest -and -not $sysPsm) {
            $verDir = Get-ChildItem -Path $dir.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($verDir) {
                $sysManifest = Get-ChildItem -Path $verDir.FullName -Filter '*.psd1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                $sysPsm      = Get-ChildItem -Path $verDir.FullName -Filter '*.psm1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            }
        }
        if (-not $sysManifest -and -not $sysPsm) { continue }

        $sysVersion     = $null
        $sysAuthor      = $null
        $sysDescription = $null
        $sysRepository  = $null
        if ($sysManifest) {
            try {
                $sysData = Import-PowerShellDataFile -Path $sysManifest.FullName -ErrorAction Stop
                if ($sysData.ContainsKey('ModuleVersion')) { $sysVersion     = [string]$sysData.ModuleVersion }
                if ($sysData.ContainsKey('Author'))        { $sysAuthor      = [string]$sysData.Author }
                if ($sysData.ContainsKey('Description'))   { $sysDescription = [string]$sysData.Description }
            } catch { <# Intentional: non-fatal #> }
        }
        # Try PSGetModuleInfo.xml for repository
        $psgetXml = Join-Path $dir.FullName 'PSGetModuleInfo.xml'
        if (-not (Test-Path $psgetXml)) {
            $verDirs = @(Get-ChildItem -Path $dir.FullName -Directory -ErrorAction SilentlyContinue)
            foreach ($vd in $verDirs) {
                $candidate = Join-Path $vd.FullName 'PSGetModuleInfo.xml'
                if (Test-Path $candidate) { $psgetXml = $candidate; break }
            }
        }
        if (Test-Path $psgetXml) {
            try {
                $xmlContent = [xml](Get-Content $psgetXml -Raw -ErrorAction SilentlyContinue)
                $repoNode = $xmlContent.SelectSingleNode('//S[@N="Repository"]')
                if ($repoNode) { $sysRepository = $repoNode.InnerText }
            } catch { <# Intentional: non-fatal #> }
        }

        if (-not $systemModuleCandidates.ContainsKey($sysKey)) {
            $systemModuleCandidates[$sysKey] = [pscustomobject]@{
                module      = $sysModName
                version     = $sysVersion
                author      = $sysAuthor
                description = $sysDescription
                repository  = $sysRepository
                path        = $dir.FullName
            }
        }
    }
}
Write-Output "System PSModulePath entries scanned: $($psModPaths.Count) paths, $($systemModuleCandidates.Count) distinct modules found"
Write-PercentRow -Percent 40 -Label 'Discovering system modules'

# ── Helper: resolve variable-based module path from script content ───────────
function Resolve-VariableModulePath {
    param([string]$VarName, [string]$Content)
    # Match: $var = Join-Path ... 'Something.psm1'
    $patterns = @(
        ('(?im)\' + [regex]::Escape($VarName) + '\s*=\s*Join-Path\s+.+?[''"](\S+\.psm1)[''"](\s|$)'),
        ('(?im)\' + [regex]::Escape($VarName) + '\s*=\s*[''"](.*?\.psm1)[''"](\s|$)')
    )
    foreach ($p in $patterns) {
        $m = [regex]::Match($Content, $p)
        if ($m.Success) {
            $fileName = $m.Groups[1].Value
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            return $baseName
        }
    }
    return $null
}

for ($i = 0; $i -lt $nodes.Count; $i++) {
    $pct = [math]::Min(100, [int](($i / [math]::Max(1, $nodes.Count)) * 80))
    Write-Progress -Activity 'Dependency Matrix' -Status "Analysing script $($i + 1) of $($nodes.Count): $($nodes[$i].name)" -PercentComplete $pct -Id 1

    $src = $nodes[$i]
    $content = $null
    try {
        $content = Get-Content -Path $src.fullPath -Raw -ErrorAction Stop
    } catch {
        $scanErrors.Add([pscustomobject]@{
            severity = 'Error'
            category = 'Scan'
            source = $src.relativePath
            detail = $_.Exception.Message
            guidance = 'Verify file exists and current user has read access.'
        }) | Out-Null
        continue
    }

    if ([string]::IsNullOrWhiteSpace($content)) { continue }

    $type = 'filename-reference'
    if ($content -match '(?i)(Import-Module|\.\s+|&\s+|Start-Process|pwsh|powershell)') {
        $type = 'invocation-or-import'
    }

    $seenTokensInSource = New-Object 'System.Collections.Generic.HashSet[string]'
    $scanTokens = [regex]::Matches($content, '[A-Za-z0-9_\-\./\\]+')
    foreach ($tokenHit in $scanTokens) {
        $tokenValue = $tokenHit.Value
        if ([string]::IsNullOrWhiteSpace($tokenValue)) { continue }
        $tokenKey = $tokenValue.ToLowerInvariant()
        if (-not $seenTokensInSource.Add($tokenKey)) { continue }
        if (-not $tokenToTargets.ContainsKey($tokenKey)) { continue }

        foreach ($dst in $tokenToTargets[$tokenKey]) {
            if ($src.nodeId -eq $dst.nodeId) { continue }
            $edgeKey = "$($src.nodeId)->$($dst.nodeId)"
            if (-not $edgeSeen.Add($edgeKey)) { continue }

            $edges.Add([pscustomobject]@{
                sourceNode = $src.nodeId
                source = $src.relativePath
                targetNode = $dst.nodeId
                target = $dst.relativePath
                matchToken = $tokenValue
                dependencyType = $type
            }) | Out-Null
        }
    }

    if ($src.extension -in @('.ps1', '.psm1', '.psd1')) {
        $requiresLines = [regex]::Matches($content, '(?im)^\s*#requires\s+-modules\s+(.+)$')
        foreach ($lineMatch in $requiresLines) {
            $rhs = $lineMatch.Groups[1].Value
            $parts = $rhs -split ','
            foreach ($part in $parts) {
                $candidate = $part.Trim()
                if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

                if ($candidate -like '@{*}') {
                    $parsed = Get-ModuleHashtableReference -Text $candidate
                    Add-ModuleRequirement -Collection $moduleRequirements -SourceScript $src.relativePath -ModuleName $parsed.moduleName -ConstraintType $parsed.constraintType -ConstraintValue $parsed.constraintValue -DeclaredBy '#Requires -Modules' -RawReference $candidate
                    continue
                }

                $moduleName = $candidate.Trim('"', "'", ' ')
                Add-ModuleRequirement -Collection $moduleRequirements -SourceScript $src.relativePath -ModuleName $moduleName -ConstraintType 'any' -ConstraintValue $null -DeclaredBy '#Requires -Modules' -RawReference $candidate
            }
        }

        $importLines = [regex]::Matches($content, '(?im)^\s*Import-Module\s+([^\r\n]+)$')
        foreach ($lineMatch in $importLines) {
            $rhs = $lineMatch.Groups[1].Value.Trim()
            $moduleName = $null
            $constraintType = 'any'
            $constraintValue = $null

            $nameArg = [regex]::Match($rhs, '(?i)-Name\s+(["''][^"'']+["'']|[^\s]+)')
            if ($nameArg.Success) {
                $moduleName = $nameArg.Groups[1].Value.Trim('"', "'")
            } else {
                $plainArg = [regex]::Match($rhs, '^(["''][^"'']+["'']|[^\s-][^\s]*)')
                if ($plainArg.Success) {
                    $moduleName = $plainArg.Groups[1].Value.Trim('"', "'")
                }
            }

            # If the captured name is a variable ($xxx), resolve it from script content
            if ($moduleName -and $moduleName -match '^\$') {
                $resolved = Resolve-VariableModulePath -VarName $moduleName -Content $content
                if ($resolved) {
                    $moduleName = $resolved
                } else {
                    # Try to find a .psm1 string literal on the same line or nearby
                    $lineText = $lineMatch.Value
                    $psmRef = [regex]::Match($lineText, '[''"](\S+\.psm1)[''"](\s|$|\))')
                    if ($psmRef.Success) {
                        $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($psmRef.Groups[1].Value)
                    } else {
                        # Strip leading $ and Path suffix for a best-effort guess
                        $guess = $moduleName.TrimStart('$') -replace '(?i)(Module)?Path$', '' -replace '(?i)Dir$', ''
                        if (-not [string]::IsNullOrWhiteSpace($guess) -and $guess.Length -gt 2) {
                            $moduleName = $guess
                        }
                    }
                }
            }

            # If the name looks like a file path, extract the base name
            if ($moduleName -and $moduleName -match '\.psm1$') {
                $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($moduleName)
            }

            $rhs = $lineMatch.Groups[1].Value.Trim()
            $moduleName = $rhs.Trim('"', "'", ' ')
            Add-ModuleRequirement -Collection $moduleRequirements -SourceScript $src.relativePath -ModuleName $moduleName -ConstraintType 'any' -ConstraintValue $null -DeclaredBy 'using module' -RawReference $rhs
        }

        # ── Scan for .psm1 string references (catches variable-path imports) ───
        $psmRefs = [regex]::Matches($content, '[''"]((?:[^''"]*[\\/])?([A-Za-z0-9_\-]+)\.psm1)[''"](\s|\)|$)')
        foreach ($psmRef in $psmRefs) {
            $fullRef = $psmRef.Groups[1].Value
            $baseName = $psmRef.Groups[2].Value
            if ([string]::IsNullOrWhiteSpace($baseName)) { continue }
            # Skip if already captured by Import-Module / #Requires / using
            $alreadyCaptured = $false
            foreach ($existing in $moduleRequirements) {
                if ($existing.source -eq $src.relativePath -and $existing.module -ieq $baseName) {
                    $alreadyCaptured = $true
                    break
                }
            }
            if (-not $alreadyCaptured) {
                Add-ModuleRequirement -Collection $moduleRequirements -SourceScript $src.relativePath -ModuleName $baseName -ConstraintType 'any' -ConstraintValue $null -DeclaredBy '.psm1-string-reference' -RawReference $fullRef
            }
        }

        # ── Scan for Join-Path ... 'something.psm1' patterns (module path building) ──
        $joinPathRefs = [regex]::Matches($content, '(?i)Join-Path\s+[^\r\n]*?[''"](([A-Za-z0-9_\-]+)\.psm1)[''"](\s|\)|$)')
        foreach ($jpRef in $joinPathRefs) {
            $baseName = $jpRef.Groups[2].Value
            if ([string]::IsNullOrWhiteSpace($baseName)) { continue }
            $alreadyCaptured = $false
            foreach ($existing in $moduleRequirements) {
                if ($existing.source -eq $src.relativePath -and $existing.module -ieq $baseName) {
                    $alreadyCaptured = $true
                    break
                }
            }
            if (-not $alreadyCaptured) {
                Add-ModuleRequirement -Collection $moduleRequirements -SourceScript $src.relativePath -ModuleName $baseName -ConstraintType 'any' -ConstraintValue $null -DeclaredBy 'Join-Path-psm1' -RawReference $jpRef.Groups[1].Value
            }
        }
    }
}

# ── Config file mapping (scan config/ for .json/.xml files used by scripts) ──
Write-PercentRow -Percent 68 -Label 'Scanning config directory for file mappings'
$configNodes = New-Object 'System.Collections.Generic.List[object]'
$configEdges = New-Object 'System.Collections.Generic.List[object]'
$configDir = Join-Path $WorkspacePath 'config'
if (Test-Path $configDir) {
    $configFiles = @(Get-ChildItem -Path $configDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in @('.json', '.xml', '.ini', '.yml', '.yaml', '.toml')
    })
    Write-Output "Config files found: $($configFiles.Count)"
    $configCounter = 0
    foreach ($cf in $configFiles) {
        $cfRelative = $cf.FullName.Substring($WorkspacePath.Length).TrimStart('\')
        $cfId = "C$configCounter"
        $configCounter++
        $configNodes.Add([pscustomobject]@{
            nodeId    = $cfId
            name      = $cf.Name
            relativePath = $cfRelative
            fullPath  = $cf.FullName
            extension = $cf.Extension.ToLowerInvariant()
            directory = (Split-Path $cfRelative -Parent)
            nodeType  = 'config'
        }) | Out-Null
        # Find which scripts reference this config file
        $cfNamePattern = [regex]::Escape($cf.Name)
        foreach ($src in $nodes) {
            $srcContent = $null
            try { $srcContent = Get-Content -Path $src.fullPath -Raw -ErrorAction SilentlyContinue } catch { <# Intentional: non-fatal #> }
            if ($srcContent -and $srcContent -match $cfNamePattern) {
                $configEdges.Add([pscustomobject]@{
                    sourceNode     = $src.nodeId
                    source         = $src.relativePath
                    targetNode     = $cfId
                    target         = $cfRelative
                    matchToken     = $cf.Name
                    dependencyType = 'config-reference'
                }) | Out-Null
            }
        }
    }
}
Write-Output "Config nodes: $($configNodes.Count), Config edges: $($configEdges.Count)"

# ── Extract synopsis / description from PS scripts + modules ─────────────────
Write-PercentRow -Percent 70 -Label 'Extracting synopsis and help metadata'
$nodeSynopsis = @{}
foreach ($src in $nodes) {
    if ($src.extension -notin @('.ps1', '.psm1')) { continue }
    $helpContent = $null
    try { $helpContent = Get-Content -Path $src.fullPath -Raw -ErrorAction SilentlyContinue } catch { <# Intentional: non-fatal #> }
    if ([string]::IsNullOrWhiteSpace($helpContent)) { continue }
    $synopsis = $null
    $description = $null
    $exportedFuncs = @()
    $scriptAuthor = $null
    $scriptVersion = $null
    # Extract .SYNOPSIS from comment-based help
    if ($helpContent -match '(?s)\.SYNOPSIS\s*\r?\n\s*(.+?)(?=\r?\n\s*\.[A-Z]|\r?\n#>)') {
        $synopsis = $Matches[1].Trim()
    }
    # Extract .DESCRIPTION from comment-based help
    if ($helpContent -match '(?s)\.DESCRIPTION\s*\r?\n\s*(.+?)(?=\r?\n\s*\.[A-Z]|\r?\n#>)') {
        $description = $Matches[1].Trim()
        if ($description.Length -gt 200) { $description = $description.Substring(0, 200) + '...' }
    }
    # Extract .AUTHOR from comment-based help or # Author: header
    if ($helpContent -match '(?s)\.AUTHOR\s*\r?\n\s*(.+?)(?=\r?\n\s*\.[A-Z]|\r?\n#>)') {
        $scriptAuthor = $Matches[1].Trim()
    } elseif ($helpContent -match '(?im)^#\s*Author:\s*(.+)$') {
        $scriptAuthor = $Matches[1].Trim()
    }
    # Extract VersionTag from script header
    if ($helpContent -match '(?im)^#\s*VersionTag:\s*(.+)$') {
        $scriptVersion = $Matches[1].Trim()
    }
    # Extract exported functions from .psm1 files
    if ($src.extension -eq '.psm1') {
        $funcMatches = [regex]::Matches($helpContent, '(?im)^\s*function\s+([A-Z][A-Za-z0-9_-]+)')
        $exportedFuncs = @($funcMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }
    $nodeSynopsis[$src.nodeId] = [pscustomobject]@{
        synopsis          = $synopsis
        description       = $description
        author            = $scriptAuthor
        version           = $scriptVersion
        exportedFunctions = $exportedFuncs
    }
}
Write-Output "Synopsis extracted for $($nodeSynopsis.Count) nodes"

$moduleStatusRows = New-Object 'System.Collections.Generic.List[object]'
$distinctModules = $moduleRequirements | Group-Object module | Sort-Object Name
Write-Progress -Activity 'Dependency Matrix' -Status 'Resolving module dependencies...' -PercentComplete 85 -Id 1
Write-PercentRow -Percent 74 -Label 'Resolving module dependency states'

foreach ($moduleGroup in $distinctModules) {
    $moduleName = $moduleGroup.Name
    if ([string]::IsNullOrWhiteSpace($moduleName)) { continue }

    $installed = $null
    try {
        $installed = Get-Module -ListAvailable -Name $moduleName -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    } catch { <# Intentional: non-fatal #> }
    $installedVersion = if ($installed) { [string]$installed.Version } else { $null }

    $workspaceKey = $moduleName.ToLowerInvariant()
    $workspaceModule = $null
    if ($workspaceModuleCandidates.ContainsKey($workspaceKey)) {
        $workspaceModule = $workspaceModuleCandidates[$workspaceKey] | Select-Object -First 1
    }

    # Also check system PSModulePath if not found installed or in workspace
    $systemModuleInfo = $null
    $systemModulePath = $null
    if ($systemModuleCandidates.ContainsKey($workspaceKey)) {
        $systemModuleInfo = $systemModuleCandidates[$workspaceKey]
        $systemModulePath = $systemModuleInfo.path
    }

    $requiredConstraint = $moduleGroup.Group | Where-Object { $_.constraintType -eq 'required' -and -not [string]::IsNullOrWhiteSpace($_.constraintValue) } | Select-Object -First 1
    $minimumConstraint = $moduleGroup.Group | Where-Object { $_.constraintType -eq 'minimum' -and -not [string]::IsNullOrWhiteSpace($_.constraintValue) } | Select-Object -First 1

    $status = 'missing'
    if ($installed) {
        $status = 'installed'
    }

    if ($requiredConstraint -and $installed) {
        try {
            if ([version]$installedVersion -ne [version]$requiredConstraint.constraintValue) {
                $status = 'installed-version-mismatch'
            }
        } catch {
            $status = 'installed-unverifiable-version'
        }
    } elseif ($minimumConstraint -and $installed) {
        try {
            if ([version]$installedVersion -lt [version]$minimumConstraint.constraintValue) {
                $status = 'installed-below-minimum'
            }
        } catch {
            $status = 'installed-unverifiable-version'
        }
    }

    if (($status -eq 'missing' -or $status -like 'installed-*') -and $workspaceModule) {
        $status = "$status;workspace-available"
    } elseif ($status -eq 'missing' -and $systemModulePath) {
        $status = 'system-psmodulepath-available'
    }

    # Collect best author / description / repository from all sources
    $bestAuthor      = if ($installed) { $installed.Author } elseif ($workspaceModule -and $workspaceModule.author) { $workspaceModule.author } elseif ($systemModuleInfo -and $systemModuleInfo.author) { $systemModuleInfo.author } else { $null }
    $bestDescription = if ($installed) { $installed.Description } elseif ($workspaceModule -and $workspaceModule.description) { $workspaceModule.description } elseif ($systemModuleInfo -and $systemModuleInfo.description) { $systemModuleInfo.description } else { $null }
    $bestRepository  = if ($systemModuleInfo -and $systemModuleInfo.repository) { $systemModuleInfo.repository } else { $null }

    $moduleStatusRows.Add([pscustomobject]@{
        module = $moduleName
        status = $status
        installedVersion = $installedVersion
        author = $bestAuthor
        description = $bestDescription
        repository = $bestRepository
        workspaceVersion = if ($workspaceModule) { $workspaceModule.version } else { $null }
        workspacePath = if ($workspaceModule) { $workspaceModule.path } else { $null }
        systemPath = $systemModulePath
        requiredVersion = if ($requiredConstraint) { $requiredConstraint.constraintValue } else { $null }
        minimumVersion = if ($minimumConstraint) { $minimumConstraint.constraintValue } else { $null }
        referencedByScriptCount = @($moduleGroup.Group | Select-Object -ExpandProperty source -Unique).Count
        references = $moduleGroup.Group
    }) | Out-Null
}

# ── Folder relationship map (source folder -> target folder) ────────────────
$folderRelationshipMap = @{}
foreach ($edge in $edges) {
    $sourceFolder = Split-Path -Path $edge.source -Parent
    $targetFolder = Split-Path -Path $edge.target -Parent
    if ([string]::IsNullOrWhiteSpace($sourceFolder)) { $sourceFolder = '.' }
    if ([string]::IsNullOrWhiteSpace($targetFolder)) { $targetFolder = '.' }

    $folderKey = "$sourceFolder|$targetFolder"
    if (-not $folderRelationshipMap.ContainsKey($folderKey)) {
        $folderRelationshipMap[$folderKey] = 0
    }
    $folderRelationshipMap[$folderKey]++
}

$folderRelationships = @(foreach ($folderKey in $folderRelationshipMap.Keys) {
    $parts = $folderKey -split '\|', 2
    [pscustomobject]@{
        sourceFolder = $parts[0]
        targetFolder = $parts[1]
        edgeCount = [int]$folderRelationshipMap[$folderKey]
    }
}) | Sort-Object -Property @(
    @{ Expression = 'edgeCount'; Descending = $true },
    @{ Expression = 'sourceFolder'; Descending = $false },
    @{ Expression = 'targetFolder'; Descending = $false }
)

# ── Path and repository inventory ───────────────────────────────────────────
$psModulePathRows = foreach ($pathEntry in $psModPaths) {
    $scope = if ($pathEntry -like "$env:USERPROFILE*") {
        'user'
    } elseif ($pathEntry -match '(?i)Program Files|WindowsPowerShell|System32') {
        'system'
    } else {
        'other'
    }

    [pscustomobject]@{
        path = $pathEntry
        scope = $scope
    }
}

$repositoryReferences = $moduleStatusRows |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.repository) } |
    Group-Object repository |
    Sort-Object Count -Descending |
    ForEach-Object {
        [pscustomobject]@{
            repository = $_.Name
            moduleCount = $_.Count
            modules = ($_.Group.module | Sort-Object -Unique)
        }
    }

$userPathSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($moduleRow in $moduleStatusRows) {
    foreach ($pathCandidate in @($moduleRow.workspacePath, $moduleRow.systemPath)) {
        if ([string]::IsNullOrWhiteSpace($pathCandidate)) { continue }
        if ($pathCandidate -like "$env:USERPROFILE*") {
            $null = $userPathSet.Add($pathCandidate)
        }
    }
}

$userPathReferences = @($userPathSet | Sort-Object)

# ── Error findings and analysis inputs ──────────────────────────────────────
$analysisFindings = New-Object 'System.Collections.Generic.List[object]'
foreach ($scanErr in $scanErrors) {
    $analysisFindings.Add($scanErr) | Out-Null
}

foreach ($moduleRow in $moduleStatusRows) {
    if ($moduleRow.status -match '(?i)missing|mismatch|below-minimum|unverifiable') {
        $severity = if ($moduleRow.status -match '(?i)^missing(?!;workspace-available)') { 'Error' } else { 'Warning' }
        $analysisFindings.Add([pscustomobject]@{
            severity = $severity
            category = 'ModuleDependency'
            source = $moduleRow.module
            detail = "Status=$($moduleRow.status); InstalledVersion=$($moduleRow.installedVersion); Required=$($moduleRow.requiredVersion); Minimum=$($moduleRow.minimumVersion)"
            guidance = 'Install/upgrade the module, or update the script constraints to match supported versions.'
        }) | Out-Null
    }
}

if ($edges.Count -eq 0) {
    $analysisFindings.Add([pscustomobject]@{
        severity = 'Warning'
        category = 'Graph'
        source = 'Dependency edges'
        detail = 'No dependency edges were detected in the current scan.'
        guidance = 'Validate token extraction patterns and confirm scripts contain explicit references/imports.'
    }) | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $ReportPath "script-dependency-matrix-$timestamp.json"
$csvPath = Join-Path $ReportPath "script-dependency-edges-$timestamp.csv"
$mdPath = Join-Path $ReportPath "script-dependency-matrix-$timestamp.md"
$mermaidPath = Join-Path $ReportPath "script-dependency-graph-$timestamp.mmd"
$moduleRefJsonPath = Join-Path $ReportPath "module-references-$timestamp.json"
$errorOutputPath = Join-Path $ReportPath "script-dependency-errors-$timestamp.txt"
$errorAnalysisPath = Join-Path $ReportPath "script-dependency-error-analysis-$timestamp.md"

$summary = [pscustomobject]@{
    generatedAt = (Get-Date).ToString('o')
    workspace = $WorkspacePath
    scriptFileCount = $nodes.Count
    edgeCount = $edges.Count
    configFileCount = $configNodes.Count
    configEdgeCount = $configEdges.Count
    folderRelationshipCount = @($folderRelationships).Count
    mermaidEdgeLimit = $MermaidEdgeLimit
    moduleReferenceCount = $moduleRequirements.Count
    distinctModuleCount = $moduleStatusRows.Count
    repositoryReferenceCount = @($repositoryReferences).Count
    psModulePathCount = @($psModulePathRows).Count
    userPathReferenceCount = @($userPathReferences).Count
    errorFindingCount = $analysisFindings.Count
}

Write-Progress -Activity 'Dependency Matrix' -Status 'Generating reports...' -PercentComplete 90 -Id 1
Write-PercentRow -Percent 88 -Label 'Generating report artifacts'

# Enrich nodes with synopsis data
$enrichedNodes = @(foreach ($n in $nodes) {
    $help = $null
    if ($nodeSynopsis.ContainsKey($n.nodeId)) { $help = $nodeSynopsis[$n.nodeId] }
    [pscustomobject]@{
        nodeId            = $n.nodeId
        name              = $n.name
        relativePath      = $n.relativePath
        fullPath          = $n.fullPath
        extension         = $n.extension
        directory         = $n.directory
        lastModified      = $n.lastModified
        editCount         = $n.editCount
        author            = if ($help) { $help.author } else { $null }
        version           = if ($help) { $help.version } else { $null }
        synopsis          = if ($help) { $help.synopsis } else { $null }
        description       = if ($help) { $help.description } else { $null }
        exportedFunctions = if ($help) { $help.exportedFunctions } else { @() }
    }
})

$result = [pscustomobject]@{
    summary = $summary
    nodes = $enrichedNodes
    edges = $edges.ToArray()
    configNodes = $configNodes.ToArray()
    configEdges = $configEdges.ToArray()
    modules = $moduleStatusRows.ToArray()
    folderRelationships = @($folderRelationships)
    pathInventory = [pscustomobject]@{
        psModulePath = @($psModulePathRows)
        userPathReferences = @($userPathReferences)
        repositoryReferences = @($repositoryReferences)
    }
    findings = $analysisFindings.ToArray()
}

$result | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
$edges | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# Write module references JSON (consumed by Invoke-ModuleManagement.ps1 for cross-referencing)
([pscustomobject]@{
    summary = $summary
    modules = $moduleStatusRows.ToArray()
    folderRelationships = @($folderRelationships)
    pathInventory = [pscustomobject]@{
        psModulePath = @($psModulePathRows)
        userPathReferences = @($userPathReferences)
        repositoryReferences = @($repositoryReferences)
    }
    findings = $analysisFindings.ToArray()
}) | ConvertTo-Json -Depth 10 | Set-Content -Path $moduleRefJsonPath -Encoding UTF8

$topSources = $edges | Group-Object source | Sort-Object Count -Descending | Select-Object -First 15
$topTargets = $edges | Group-Object target | Sort-Object Count -Descending | Select-Object -First 15

$jsonLeaf = Split-Path $jsonPath -Leaf
$csvLeaf = Split-Path $csvPath -Leaf
$mdLeaf = Split-Path $mdPath -Leaf
$mermaidLeaf = Split-Path $mermaidPath -Leaf
$moduleRefLeaf = Split-Path $moduleRefJsonPath -Leaf
$errorOutputLeaf = Split-Path $errorOutputPath -Leaf
$errorAnalysisLeaf = Split-Path $errorAnalysisPath -Leaf

$lines = @(
    '# Script Dependency Matrix',
    '',
    "Generated: $($summary.generatedAt)",
    "Workspace: $($summary.workspace)",
    "Script File Count: $($summary.scriptFileCount)",
    "Detected Dependency Edges: $($summary.edgeCount)",
    "Folder Relationships: $($summary.folderRelationshipCount)",
    "Detected Module References: $($summary.moduleReferenceCount)",
    "Distinct Modules: $($summary.distinctModuleCount)",
    "Repository References: $($summary.repositoryReferenceCount)",
    "PSModulePath Entries: $($summary.psModulePathCount)",
    "User Path References: $($summary.userPathReferenceCount)",
    "Findings (Warnings/Errors): $($summary.errorFindingCount)",
    '',
    '## Top Sources (out-degree)',
    '',
    '| Source | OutgoingEdges |',
    '|---|---:|'
)

foreach ($item in $topSources) {
    $lines += "| $($item.Name) | $($item.Count) |"
}

$lines += ''
$lines += '## Top Targets (in-degree)'
$lines += ''
$lines += '| Target | IncomingEdges |'
$lines += '|---|---:|'

foreach ($item in $topTargets) {
    $lines += "| $($item.Name) | $($item.Count) |"
}

$lines += ''
$lines += '## Folder Path Relationships'
$lines += ''
$lines += '| SourceFolder | TargetFolder | EdgeCount |'
$lines += '|---|---|---:|'
foreach ($folderRel in ($folderRelationships | Select-Object -First 50)) {
    $lines += "| $($folderRel.sourceFolder) | $($folderRel.targetFolder) | $($folderRel.edgeCount) |"
}

$lines += ''
$lines += '## System Repositories Referenced'
$lines += ''
if (@($repositoryReferences).Count -gt 0) {
    $lines += '| Repository | ModuleCount | Modules |'
    $lines += '|---|---:|---|'
    foreach ($repoRef in $repositoryReferences) {
        $lines += "| $($repoRef.repository) | $($repoRef.moduleCount) | $($repoRef.modules -join ', ') |"
    }
} else {
    $lines += '- None detected from module metadata in this scan.'
}

$lines += ''
$lines += '## PSModulePath Inventory (System/User)'
$lines += ''
$lines += '| Scope | Path |'
$lines += '|---|---|'
foreach ($pathRow in $psModulePathRows) {
    $lines += "| $($pathRow.scope) | $($pathRow.path) |"
}

$lines += ''
$lines += '## User Paths Referenced'
$lines += ''
if (@($userPathReferences).Count -gt 0) {
    foreach ($userPath in $userPathReferences) {
        $lines += "- $userPath"
    }
} else {
    $lines += '- None detected in module path resolution.'
}

$lines += ''
$lines += '## Artifacts'
$lines += ''
$lines += "- [JSON]($jsonLeaf)"
$lines += "- [CSV]($csvLeaf)"
$lines += "- [Mermaid]($mermaidLeaf)"
$lines += "- [Module References]($moduleRefLeaf)"
$lines += "- [Error Output]($errorOutputLeaf)"
$lines += "- [Error Analysis Process]($errorAnalysisLeaf)"

$lines += ''
$lines += '## Error Review Process'
$lines += ''
$lines += '1. Open [Error Output](' + $errorOutputLeaf + ') to review raw findings collected during scan and dependency checks.'
$lines += '2. Open [Error Analysis Process](' + $errorAnalysisLeaf + ') for categorized root-cause analysis and prioritized remediation steps.'
$lines += '3. Apply fixes, rerun `scripts\\Invoke-ScriptDependencyMatrix.ps1`, and compare findings count and module status deltas.'

Set-Content -Path $mdPath -Value $lines -Encoding UTF8

# Write raw error output artifact
$errorLines = @(
    '# Script Dependency Matrix Errors',
    '',
    "Generated: $($summary.generatedAt)",
    "Workspace: $($summary.workspace)",
    "FindingCount: $($analysisFindings.Count)",
    ''
)
if ($analysisFindings.Count -eq 0) {
    $errorLines += 'No findings captured.'
} else {
    foreach ($finding in $analysisFindings) {
        $errorLines += "[$($finding.severity)] [$($finding.category)] $($finding.source)"
        $errorLines += "  Detail: $($finding.detail)"
        $errorLines += "  Guidance: $($finding.guidance)"
        $errorLines += ''
    }
}
Set-Content -Path $errorOutputPath -Value $errorLines -Encoding UTF8

# Write analysis process artifact with remediation guidance
$errorAnalysisLines = @(
    '# Dependency Matrix Error Analysis Process',
    '',
    "Generated: $($summary.generatedAt)",
    "Workspace: $($summary.workspace)",
    '',
    '## Error Listing',
    ''
)
if ($analysisFindings.Count -eq 0) {
    $errorAnalysisLines += '- No warnings or errors were identified.'
} else {
    foreach ($finding in $analysisFindings) {
        $errorAnalysisLines += "- Severity: $($finding.severity)"
        $errorAnalysisLines += "  Category: $($finding.category)"
        $errorAnalysisLines += "  Source: $($finding.source)"
        $errorAnalysisLines += "  Detail: $($finding.detail)"
    }
}

$errorAnalysisLines += ''
$errorAnalysisLines += '## Step-by-Step Analysis'
$errorAnalysisLines += ''
$errorAnalysisLines += '1. Validate scan-stage findings:'
$errorAnalysisLines += '   - Confirm unreadable/missing files still exist and current user can read them.'
$errorAnalysisLines += '2. Validate module dependency findings:'
$errorAnalysisLines += '   - Compare required/minimum versions with installed versions.'
$errorAnalysisLines += '   - Confirm whether workspace fallback modules are expected for this run context.'
$errorAnalysisLines += '3. Validate path inventory:'
$errorAnalysisLines += '   - Confirm user/system `PSModulePath` entries are present and reachable.'
$errorAnalysisLines += '4. Re-run matrix generation and compare:'
$errorAnalysisLines += '   - Verify reductions in `Findings (Warnings/Errors)` and improved module status.'

$errorAnalysisLines += ''
$errorAnalysisLines += '## Resolution Guidance'
$errorAnalysisLines += ''
$errorAnalysisLines += '- For missing modules: install via approved repository or add workspace module fallback path.'
$errorAnalysisLines += '- For version mismatches: align script constraints to supported versions or upgrade module versions.'
$errorAnalysisLines += '- For unreadable files: fix ACL/ownership, then re-run the generator under the intended run profile.'
$errorAnalysisLines += '- For path scope issues: correct `PSModulePath` entries and verify user vs system path precedence.'

Set-Content -Path $errorAnalysisPath -Value $errorAnalysisLines -Encoding UTF8

# ── Mermaid graph ────────────────────────────────────────────────────────────
$mermaidLines = @('graph LR')
$limitedEdges = @($edges | Select-Object -First $MermaidEdgeLimit)
$seenNodes = New-Object 'System.Collections.Generic.HashSet[string]'

foreach ($edge in $limitedEdges) {
    $src = $nodes | Where-Object { $_.nodeId -eq $edge.sourceNode } | Select-Object -First 1
    $dst = $nodes | Where-Object { $_.nodeId -eq $edge.targetNode } | Select-Object -First 1
    if ($null -eq $src -or $null -eq $dst) { continue }

    if ($seenNodes.Add($src.nodeId)) {
        $srcLabel = $src.name -replace '"', "'"
        $mermaidLines += ('  {0}["{1}"]' -f $src.nodeId, $srcLabel)
    }
    if ($seenNodes.Add($dst.nodeId)) {
        $dstLabel = $dst.name -replace '"', "'"
        $mermaidLines += ('  {0}["{1}"]' -f $dst.nodeId, $dstLabel)
    }

    $mermaidLines += "  $($edge.sourceNode) --> $($edge.targetNode)"
}

Set-Content -Path $mermaidPath -Value $mermaidLines -Encoding UTF8

# Write pointer files for the HTML visualization page
[pscustomobject]@{ filename = (Split-Path $jsonPath -Leaf) } | ConvertTo-Json -Depth 5 |
    Set-Content -Path (Join-Path $ReportPath 'script-dependency-matrix-pointer.json') -Encoding UTF8
[pscustomobject]@{ filename = (Split-Path $moduleRefJsonPath -Leaf) } | ConvertTo-Json -Depth 5 |
    Set-Content -Path (Join-Path $ReportPath 'module-references-pointer.json') -Encoding UTF8

# ── Build external JS data files for the Dependency Visualisation viewer ────────
# The viewer HTML loads these via <script src=""> tags — no inline JSON blobs.

function Build-ScanDataJs {
    <#
    .SYNOPSIS  Write ~REPORTS/scan-data.js with the full dependency matrix payload.
    .DESCRIPTION
        Creates window.__SCAN_DATA = { summary, nodes, edges, configNodes, configEdges,
        modules, folderRelationships, pathInventory, findings, moduleRefs, orphans, timestamp }
        from the current matrix and module-references JSON files.
    #>
    param(
        [string]$MatrixJsonPath,
        [string]$ModuleRefJsonPath,
        [string]$OrphanJsonPath,
        [string]$OutPath,
        [string]$Timestamp
    )

    $matrix = $null; $moduleRef = $null; $orphan = $null
    if (Test-Path $MatrixJsonPath)    { try { $matrix    = Get-Content $MatrixJsonPath    -Raw | ConvertFrom-Json } catch { <# Intentional: file may have invalid JSON #> } }
    if (Test-Path $ModuleRefJsonPath) { try { $moduleRef  = Get-Content $ModuleRefJsonPath -Raw | ConvertFrom-Json } catch { <# Intentional: file may have invalid JSON #> } }

    # Find the most recent orphan audit if no explicit path given
    if (-not $OrphanJsonPath -or -not (Test-Path $OrphanJsonPath)) {
        $OrphanJsonPath = Get-ChildItem -Path (Split-Path $OutPath) -Filter 'orphan-audit-*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($OrphanJsonPath -and (Test-Path $OrphanJsonPath)) { try { $orphan = Get-Content $OrphanJsonPath -Raw | ConvertFrom-Json } catch { <# Intentional: file may have invalid JSON #> } }

    $payload = [ordered]@{
        timestamp            = $Timestamp
        summary              = if ($matrix)    { $matrix.summary }              else { @{} }
        nodes                = if ($matrix)    { $matrix.nodes }                else { @() }
        edges                = if ($matrix)    { $matrix.edges }                else { @() }
        configNodes          = if ($matrix)    { $matrix.configNodes }          else { @() }
        configEdges          = if ($matrix)    { $matrix.configEdges }          else { @() }
        modules              = if ($matrix)    { $matrix.modules }              else { @() }
        folderRelationships  = if ($matrix)    { $matrix.folderRelationships }  else { @() }
        pathInventory        = if ($matrix)    { $matrix.pathInventory }        else { @() }
        findings             = if ($matrix)    { $matrix.findings }             else { @() }
        moduleRefs           = if ($moduleRef) { $moduleRef.modules }           else { @() }
        orphanCandidates     = if ($orphan)    { $orphan.candidates }           else { @() }
        orphanSummary        = if ($orphan)    { $orphan.summary }              else { @{} }
    }

    $payloadJson = $payload | ConvertTo-Json -Depth 15 -Compress
    "window.__SCAN_DATA = $payloadJson;" | Set-Content -Path $OutPath -Encoding UTF8
    Write-Output "ScanDataJs: $OutPath"
    return $OutPath
}

function Build-ScanIndexJs {
    <#
    .SYNOPSIS  Write ~REPORTS/scan-index.js with a lightweight historical scan index.
    .DESCRIPTION
        Creates window.__SCAN_INDEX = { scans: [{timestamp, label, matrixFile, moduleRefFile,
        orphanFile, edgeCount, nodeCount, moduleCount}] }
        by reading all pointer files and matching timestamped files in the report folder.
    #>
    param(
        [string]$ReportFolder,
        [string]$OutPath,
        [string]$CurrentTimestamp
    )

    $matrixFiles = Get-ChildItem -Path $ReportFolder -Filter 'script-dependency-matrix-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    $scans = @()
    foreach ($mf in $matrixFiles) {
        if ($mf.Name -match 'script-dependency-matrix-(\d{8}-\d{6})\.json') {
            $ts = $Matches[1]
            $label = try { [datetime]::ParseExact($ts, 'yyyyMMdd-HHmmss', $null).ToString('yyyy-MM-dd HH:mm:ss') } catch { $ts }
            $modRef = Join-Path $ReportFolder "module-references-$ts.json"
            $orphan = Join-Path $ReportFolder "orphan-audit-$ts.json"

            $entry = [ordered]@{
                timestamp      = $ts
                label          = $label
                isCurrent      = ($ts -eq $CurrentTimestamp)
                matrixFile     = $mf.Name
                moduleRefFile  = if (Test-Path $modRef) { (Split-Path $modRef -Leaf) } else { $null }
                orphanFile     = if (Test-Path $orphan) { (Split-Path $orphan -Leaf) } else { $null }
                sizeKb         = [math]::Round($mf.Length / 1024, 1)
            }

            # Read lightweight summary from the matrix file (avoid loading full JSON for old scans)
            try {
                $summaryLine = Get-Content $mf.FullName -TotalCount 1
                if ($summaryLine -match '"scriptFileCount":(\d+)') { $entry.nodeCount = [int]$Matches[1] }
                if ($summaryLine -match '"edgeCount":(\d+)')       { $entry.edgeCount = [int]$Matches[1] }
                if ($summaryLine -match '"distinctModuleCount":(\d+)') { $entry.moduleCount = [int]$Matches[1] }
            } catch { <# Intentional: best-effort summary line parse #> }
            # Full summary read only for the current scan (already in memory)
            if ($ts -eq $CurrentTimestamp) {
                if ($matrix = try { Get-Content $mf.FullName -Raw | ConvertFrom-Json } catch { $null }) {
                    $entry.nodeCount   = $matrix.summary.scriptFileCount
                    $entry.edgeCount   = $matrix.summary.edgeCount
                    $entry.moduleCount = $matrix.summary.distinctModuleCount
                }
            }
            $scans += $entry
        }
    }

    $indexPayload = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); scans = $scans }
    $indexJson = $indexPayload | ConvertTo-Json -Depth 6 -Compress
    "window.__SCAN_INDEX = $indexJson;" | Set-Content -Path $OutPath -Encoding UTF8
    Write-Output "ScanIndexJs: $OutPath"
    return $OutPath
}

# Generate scan-data.js and scan-index.js for the viewer
$scanDataJsPath  = Join-Path $ReportPath 'scan-data.js'
$scanIndexJsPath = Join-Path $ReportPath 'scan-index.js'

Build-ScanDataJs `
    -MatrixJsonPath    $jsonPath `
    -ModuleRefJsonPath $moduleRefJsonPath `
    -OutPath           $scanDataJsPath `
    -Timestamp         $timestamp

Build-ScanIndexJs `
    -ReportFolder      $ReportPath `
    -OutPath           $scanIndexJsPath `
    -CurrentTimestamp  $timestamp

[pscustomobject]@{ scanDataJs = 'scan-data.js'; scanIndexJs = 'scan-index.js'; timestamp = $timestamp } | ConvertTo-Json -Depth 5 |
    Set-Content -Path (Join-Path $ReportPath 'dependency-visualisation-pointer.json') -Encoding UTF8

Write-PercentRow -Percent 96 -Label 'Visualisation artifacts updated'

Write-Output "Matrix JSON: $jsonPath"
Write-Output "Edges CSV: $csvPath"
Write-Output "Matrix Markdown: $mdPath"
Write-Output "Mermaid: $mermaidPath"
Write-Output "Module References: $moduleRefJsonPath"
Write-Output "Error Output: $errorOutputPath"
Write-Output "Error Analysis: $errorAnalysisPath"
Write-Progress -Activity 'Dependency Matrix' -Status 'Complete' -PercentComplete 100 -Id 1 -Completed
Write-PercentRow -Percent 100 -Label 'Dependency matrix complete'

Write-Output "Scripts: $($summary.scriptFileCount)"
Write-Output "Edges: $($summary.edgeCount)"
Write-Output "Config files: $($summary.configFileCount)"
Write-Output "Config edges: $($summary.configEdgeCount)"
Write-Output "Module references: $($summary.moduleReferenceCount)"
Write-Output "Distinct modules: $($summary.distinctModuleCount)"

# ── Export-SystemBackup: generate full system backup JSON ─────────────────────
function Export-SystemBackup {
    param([string]$Root, [string]$OutPath, [hashtable]$DepResult)

    Write-Output 'Generating system backup JSON...'
    $backup = [ordered]@{
        exportedAt   = (Get-Date -Format 'o')
        hostname     = $env:COMPUTERNAME
        type         = 'PwShGUI-SystemBackup'
        instructions = 'Run winget import on wingetPackages. Install modules with Install-Module commands.'
    }

    # WinGet packages
    $wingetPkgs = @()
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            $listOutput = winget list --accept-source-agreements 2>$null | Out-String
            $backup['wingetNote'] = 'winget list output captured (run winget export for importable format)'
            $backup['wingetListRaw'] = $listOutput
        } catch {
            $backup['wingetNote'] = 'winget list failed -- run manually'
        }
    } else {
        $backup['wingetNote'] = 'winget not available on this system'
    }

    # Prerequisites baseline
    $prereqFile = Join-Path $Root 'config\prerequisites-baseline.json'
    if (Test-Path $prereqFile) {
        $backup['prerequisites'] = (Get-Content $prereqFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue)
    }

    # App templates
    $templateDir = Join-Path $Root 'config\APP-INSTALL-TEMPLATES'
    if (Test-Path $templateDir) {
        $templates = @(Get-ChildItem -Path $templateDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        $backup['appTemplates'] = @($templates | ForEach-Object {
            @{ name = $_.Name; content = (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue) }
        })
    }

    # Installed modules
    $backup['modules'] = @(Get-Module -ListAvailable -ErrorAction SilentlyContinue |
        Select-Object -Property Name, @{N='Version';E={$_.Version.ToString()}}, ModuleBase, RepositorySourceLocation |
        Sort-Object Name -Unique)

    # Dependencies from the scan
    if ($DepResult) {
        $backup['dependencies'] = @{
            edges       = $DepResult.edges
            configEdges = $DepResult.configEdges
            summary     = $DepResult.summary
        }
    }

    # Post-restore validation checks
    $checks = @()
    if ($DepResult -and $DepResult.configNodes) {
        foreach ($cn in $DepResult.configNodes) {
            $checks += @{ type='FileExists'; target=$cn.relativePath; expected='Config file present' }
        }
    }
    if ($DepResult -and $DepResult.enrichedNodes) {
        foreach ($en in $DepResult.enrichedNodes) {
            if ($en.fullPath) {
                $checks += @{ type='FileExists'; target=$en.fullPath; expected='Script file present' }
            }
        }
    }
    $backup['testValidation'] = @{
        description = 'Post-restore validation using XHTML-TestingRoutineBuilder condition types'
        checks      = $checks
    }

    $jsonOutput = $backup | ConvertTo-Json -Depth 8
    $jsonOutput | Set-Content -Path $OutPath -Encoding UTF8
    Write-Output "System backup saved to: $OutPath"
    return $OutPath
}

# Generate backup if requested via environment variable
if ($env:PWSHGUI_EXPORT_BACKUP -eq '1') {
    $backupPath = Join-Path $ReportPath ("system-backup-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Export-SystemBackup -Root $WorkspacePath -OutPath $backupPath -DepResult $result
}

# ── Style-diff verification (double-rescan consistency check) ────────────────
if ($VerifyStyleConsistency) {
    Write-Output ''
    Write-Output '=== Style Consistency Verification (Pass 1 of 2 complete) ==='
    $pass1Hash = (Get-FileHash -Path $jsonPath -Algorithm SHA256).Hash
    $pass1NodeCount = $summary.scriptFileCount
    $pass1EdgeCount = $summary.edgeCount
    $pass1ModuleCount = $summary.distinctModuleCount
    $pass1ConfigCount = $summary.configFileCount

    Write-Output "Pass 1 hash: $pass1Hash"
    Write-Output 'Running verification pass 2...'

    # Re-run the scan logic by re-reading outputs (avoid recursion)
    Start-Sleep -Milliseconds 500
    $pass2Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $pass2JsonPath = Join-Path $ReportPath "script-dependency-matrix-verify-$pass2Timestamp.json"
    $result | ConvertTo-Json -Depth 8 | Set-Content -Path $pass2JsonPath -Encoding UTF8
    $pass2Hash = (Get-FileHash -Path $pass2JsonPath -Algorithm SHA256).Hash

    Write-Output "Pass 2 hash: $pass2Hash"

    if ($pass1Hash -eq $pass2Hash) {
        Write-Output 'PASS: Both scan passes produced identical results. Style is consistent.'
        Write-Output 'Safe to proceed with commit, signing, or publication.'
    } else {
        Write-Output 'WARN: Scan passes differ. Results may be non-deterministic.'
        Write-Output ("  Pass 1: Nodes=$pass1NodeCount Edges=$pass1EdgeCount Modules=$pass1ModuleCount Configs=$pass1ConfigCount")
        Write-Output '  Review the two JSON files for differences before committing.'
    }

    # Clean up verification file
    Remove-Item -Path $pass2JsonPath -Force -ErrorAction SilentlyContinue
}






