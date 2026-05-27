# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-28
# SupportsPS7.6TestedDate: 2026-04-28
# FileRole: Builder
<#
.SYNOPSIS
    Generates a machine-readable JSON agentic API manifest for the entire PwShGUI workspace.
.DESCRIPTION
    Scans all modules (.psm1), scripts (.ps1), XHTML tools, config files, and agent
    directories to produce a single JSON manifest that any agent (human or AI) can load
    to understand the full callable API surface, dependency graph, and action taxonomy.

    Output: config/agentic-manifest.json  (canonical)
            config/agentic-manifest-history/<timestamp>.json  (snapshot)

    The manifest powers:
      - Rapid workspace digestion (one JSON read vs 60+ file scans)
      - Agentic action routing (action -> handler -> function mapping)
      - Dependency graph traversal (import/dot-source/call edges)
      - Coverage tracking (functions with/without tests, docs)
      - Schema version tracking across all modules
      - agenticAPI section: enriched routes, coverage map, call chains,
        agent tracking interface, topological boot order
.NOTES
    VersionTag: 2605.B5.V46.0
    VersionBuildHistory: 2604.B3.V33.0  2026-04-28  PS7.6/PS5.1 validation metadata and canonical VersionTag parsing updates
                         2604.B2.V31.1  2026-04-14  Add recursive tests, root launchers/utils, module psd1, agent coreModules+configFiles, recursive config subdirs, XHTML-Checker ps1
                         2604.B2.V31.0  2026-04-05  V31 alignment
    FileRole: Generator
    Category: Infrastructure
.EXAMPLE
    .\scripts\Build-AgenticManifest.ps1
    .\scripts\Build-AgenticManifest.ps1 -IncludeKernel -Verbose
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$IncludeKernel,
    [switch]$SkipHistory,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path $PSScriptRoot -Parent
$ModulesDir  = Join-Path $ProjectRoot 'modules'
$ScriptsDir  = Join-Path $ProjectRoot 'scripts'
$ConfigDir   = Join-Path $ProjectRoot 'config'
$TestsDir    = Join-Path $ProjectRoot 'tests'
$AgentsDir   = Join-Path $ProjectRoot 'agents'
$KernelDir   = Join-Path $ProjectRoot 'sovereign-kernel'
$XhtmlDir    = Join-Path $ScriptsDir 'XHTML-Checker'
$StylesDir   = Join-Path $ProjectRoot 'styles'
$TodoDir     = Join-Path $ProjectRoot 'todo'
$SinDir      = Join-Path $ProjectRoot 'sin_registry'

if (-not $OutputPath) {
    $OutputPath = Join-Path $ConfigDir 'agentic-manifest.json'
}

try {
    $writeAppLogCommand = Get-Command Write-AppLog -ErrorAction Stop
} catch {
    $writeAppLogCommand = $null
}
if (-not $writeAppLogCommand) {
    function Write-AppLog {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
        param(
            [Parameter(Mandatory = $true)][string]$Message,
            [Parameter(Mandatory = $true)][ValidateSet('Debug','Info','Warning','Error','Critical','Audit')][string]$Level
        )
        $tag = "[$Level]"
        Write-Host "$tag $Message" -ForegroundColor DarkGray
    }
}

function Get-VersionTagFromFile {
    param([string]$FilePath)
    try {
        $head = Get-Content $FilePath -TotalCount 10 -ErrorAction Stop
        foreach ($line in $head) {
            if ($line -match 'VersionTag:\s*([\d]+\.B\d+\.[Vv][\d\.]+)') {
                return $Matches[1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            }
            if ($line -match '<!--\s*VersionTag:\s*([\d]+\.B\d+\.[Vv][\d\.]+)') {
                return $Matches[1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            }
        }
        return $null
    } catch {
        Write-AppLog -Message "Failed to read $FilePath for VersionTag: $_" -Level Debug
        return $null
    }
}

function Get-FileRoleFromFile {
    param([string]$FilePath)
    try {
        $head = Get-Content $FilePath -TotalCount 15 -ErrorAction Stop
        foreach ($line in $head) {
            if ($line -match 'FileRole:\s*(.+)') {
                return ($Matches[1]).Trim()  # SIN-EXEMPT:P027 -- index access, context-verified safe
            }
        }
        return $null
    } catch {
        Write-AppLog -Message "Failed to read $FilePath for FileRole: $_" -Level Debug
        return $null
    }
}

function Extract-ExportedFunctions {
    <#
    .SYNOPSIS
        Returns function names referenced by Export-ModuleMember -Function in a .psm1 file.
    #>
    param([string]$FilePath)

    try {
        $content = Get-Content $FilePath -Raw -ErrorAction Stop
    } catch {
        Write-AppLog -Message "Failed to read $FilePath for export extraction: $_" -Level Debug
        return @()
    }

    if (-not $content) {
        return @()
    }

    $exports = [System.Collections.ArrayList]::new()
    $blocks = [regex]::Matches(
        $content,
        'Export-ModuleMember\s+-Function\s+(.+?)(?=\r?\n\s*(?:Export-ModuleMember|#>|<#|function\s|$)|\z)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    foreach ($blockMatch in $blocks) {
        $block = $blockMatch.Groups[1].Value
        $nameMatches = [regex]::Matches($block, '''([^'']+)''|"([^"]+)"|\b([A-Z][A-Za-z0-9]*-[A-Za-z0-9_-]+)\b')
        foreach ($nameMatch in $nameMatches) {
            $functionName = $nameMatch.Groups[1].Value
            if (-not $functionName) { $functionName = $nameMatch.Groups[2].Value }
            if (-not $functionName) { $functionName = $nameMatch.Groups[3].Value }
            if ($functionName -and $functionName -notin $exports) {
                $null = $exports.Add($functionName)
            }
        }
    }

    return $exports.ToArray()
}

function Extract-FunctionDefs {
    <#
    .SYNOPSIS Extracts function names and their parameter blocks from a PS file.
    #>
    param([string]$FilePath)
    try {
        $content = Get-Content $FilePath -Raw -ErrorAction Stop
    } catch {
        Write-AppLog -Message "Failed to read $FilePath for function extraction: $_" -Level Debug
        return @()
    }
    if (-not $content) { return @() }

    $results = [System.Collections.ArrayList]::new()
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
    $funcDefs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)  # SIN-EXEMPT: P027 - $args[N] in ScriptBlock/event-handler delegate (always populated by caller)

    foreach ($func in $funcDefs) {
        $paramNames = @()
        $paramTypes = @{}
        if ($func.Body.ParamBlock) {
            foreach ($p in $func.Body.ParamBlock.Parameters) {
                $pName = $p.Name.VariablePath.UserPath
                $paramNames += $pName
                if ($p.StaticType -and $p.StaticType.Name -ne 'Object') {
                    $paramTypes[$pName] = $p.StaticType.Name  # SIN-EXEMPT:P027 -- index access, context-verified safe
                } elseif ($p.Attributes) {
                    foreach ($attr in $p.Attributes) {
                        if ($attr.TypeName.Name -and $attr.TypeName.Name -ne 'Parameter' -and
                            $attr.TypeName.Name -ne 'ValidateNotNullOrEmpty' -and
                            $attr.TypeName.Name -ne 'ValidateSet' -and
                            $attr.TypeName.Name -ne 'Alias' -and
                            $attr.TypeName.Name -ne 'switch') {
                            $paramTypes[$pName] = $attr.TypeName.Name  # SIN-EXEMPT:P027 -- index access, context-verified safe
                            break
                        }
                    }
                }
                if (-not $paramTypes.ContainsKey($pName)) {
                    $paramTypes[$pName] = 'object'  # SIN-EXEMPT:P027 -- index access, context-verified safe
                }
            }
        } elseif ($func.Parameters) {
            foreach ($p in $func.Parameters) {
                $pName = $p.Name.VariablePath.UserPath
                $paramNames += $pName
                $paramTypes[$pName] = 'object'  # SIN-EXEMPT:P027 -- index access, context-verified safe
            }
        }

        # Derive verb-noun
        $verb = $null; $noun = $null
        if ($func.Name -match '^(\w+)-(.+)$') {
            $verb = $Matches[1]  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
            $noun = $Matches[2]  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
        }

        $null = $results.Add([PSCustomObject]@{
            Name       = $func.Name
            Verb       = $verb
            Noun       = $noun
            Params     = $paramNames
            ParamTypes = $paramTypes
            Line       = $func.Extent.StartLineNumber
        })
    }
    return $results.ToArray()
}

function Extract-Dependencies {
    <#
    .SYNOPSIS Finds Import-Module and dot-source references in a file.
    #>
    param([string]$FilePath)
    try {
        $content = Get-Content $FilePath -Raw -ErrorAction Stop
    } catch {
        Write-AppLog -Message "Failed to read $FilePath for dependency extraction: $_" -Level Debug
        return @()
    }
    if (-not $content) { return @() }

    $deps = [System.Collections.ArrayList]::new()

    # Import-Module patterns
    $importMatches = [regex]::Matches($content, 'Import-Module\s+[''"]?([^''";\s]+)')
    foreach ($m in $importMatches) {
        $target = $m.Groups[1].Value
        # Normalize: extract filename only
        $target = [System.IO.Path]::GetFileName($target)
        $null = $deps.Add([PSCustomObject]@{ Target = $target; Type = 'import' })
    }

    # Dot-source patterns: . "$dir\file.ps1" or . .\file.ps1
    $dotMatches = [regex]::Matches($content, '\.\s+[''"]?\$?\w*[\\\/]([^''";\s]+\.ps1)')
    foreach ($m in $dotMatches) {
        $target = $m.Groups[1].Value
        $target = [System.IO.Path]::GetFileName($target)
        $null = $deps.Add([PSCustomObject]@{ Target = $target; Type = 'dot-source' })
    }

    return $deps.ToArray()
}

function Categorize-Function {
    <#
    .SYNOPSIS Maps a verb-noun function to an agentic action category.
    #>
    param([string]$Verb, [string]$Noun, [string]$ModuleName)

    $category = switch -Wildcard ($Noun) {
        '*Log*'           { 'logging' }
        '*Config*'        { 'configuration' }
        '*Path*'          { 'filesystem' }
        '*Version*'       { 'versioning' }
        '*Theme*'         { 'theme' }
        '*Vault*'         { 'security.vault' }
        '*Cert*'          { 'security.pki' }
        '*SASC*'          { 'security.sasc' }
        '*Credential*'    { 'security.credentials' }
        '*AVPN*'          { 'device.tracking' }
        '*Pipeline*'      { 'pipeline' }
        '*Bug*'           { 'bugtracking' }
        '*Todo*'          { 'todotracking' }
        '*Feature*'       { 'featuretracking' }
        '*SIN*'           { 'governance' }
        '*Cron*'          { 'scheduling' }
        '*Schedule*'      { 'scheduling' }
        '*Event*'         { 'eventlog' }
        '*Profile*'       { 'profile' }
        '*Scan*'          { 'scanning' }
        '*Test*'          { 'testing' }
        '*Check*'         { 'validation' }
        '*Network*'       { 'network' }
        '*Remote*'        { 'remote' }
        '*Winget*'        { 'packagemgmt' }
        '*Package*'       { 'build' }
        '*Build*'         { 'build' }
        '*Export*'        { 'export' }
        '*Import*'        { 'import' }
        '*Report*'        { 'reporting' }
        '*GUI*'           { 'gui' }
        '*Form*'          { 'gui' }
        '*Dialog*'        { 'gui' }
        '*Menu*'          { 'gui' }
        '*Boot*'          { 'kernel' }
        '*Module*'        { 'modulemanagement' }
        '*Help*'          { 'help' }
        '*Integrity*'     { 'integrity' }
        '*Agent*'         { 'agent' }
        default           { 'general' }
    }

    # Build agentic action key: verb.category
    $verbMap = @{
        'Get'       = 'read'
        'Set'       = 'write'
        'New'       = 'create'
        'Remove'    = 'delete'
        'Test'      = 'test'
        'Invoke'    = 'invoke'
        'Start'     = 'start'
        'Stop'      = 'stop'
        'Show'      = 'show'
        'Write'     = 'write'
        'Read'      = 'read'
        'Export'    = 'export'
        'Import'    = 'import'
        'Update'    = 'update'
        'Initialize'= 'init'
        'Register'  = 'register'
        'Save'      = 'save'
        'Lock'      = 'lock'
        'Unlock'    = 'unlock'
        'Enable'    = 'enable'
        'Disable'   = 'disable'
        'Assert'    = 'assert'
        'Confirm'   = 'confirm'
        'Find'      = 'find'
        'Search'    = 'find'
        'Clear'     = 'clear'
        'Resolve'   = 'resolve'
        'Protect'   = 'protect'
        'Unprotect' = 'unprotect'
        'Compare'   = 'compare'
        'ConvertTo' = 'convert'
        'Install'   = 'install'
        'Build'     = 'build'
        'Wait'      = 'wait'
    }
    $actionVerb = if ($verbMap.ContainsKey($Verb)) { $verbMap[$Verb] } else { $Verb.ToLower() }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $actionKey = "$actionVerb.$category"

    return [PSCustomObject]@{
        Category  = $category
        ActionKey = $actionKey
    }
}

function Get-SideEffects {
    param([string]$Verb)
    switch ($Verb) {
        { $_ -in 'Get','Test','Find','Search','Read','Resolve','Compare' } { return @() }
        { $_ -in 'Write','Export','Save','New','Set','Update','Build' }    { return @('file-write') }
        { $_ -in 'Remove','Clear' }                                        { return @('file-delete') }
        { $_ -in 'Show' }                                                   { return @('gui-display') }
        { $_ -in 'Start','Invoke' }                                         { return @('process-launch') }
        { $_ -in 'Stop','Lock' }                                            { return @('state-change') }
        { $_ -in 'Unlock','Enable','Disable' }                              { return @('state-change') }
        { $_ -in 'Install','Register' }                                     { return @('system-modify') }
        { $_ -in 'Import' }                                                 { return @('data-load') }
        default { return @('unknown') }
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#   MAIN SCAN
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "[AgenticManifest] Scanning workspace at $ProjectRoot ..." -ForegroundColor Cyan

$manifest = [ordered]@{
    '$schema'  = 'PwShGUI-AgenticManifest/1.0'
    meta       = [ordered]@{
        version       = (Get-VersionTagFromFile (Join-Path $ProjectRoot 'Main-GUI.ps1'))
        generated     = (Get-Date -Format 'o')
        generator     = 'scripts/Build-AgenticManifest.ps1'
        projectRoot   = $ProjectRoot
        outlineSchema = 'PwShGUI-Outline/0.1'
        purpose       = 'Machine-readable API surface, dependency graph, and agentic action routing for the entire PwShGUI workspace. Load this single file to digest every callable function, every module, and every tracking item without scanning 60+ files.'
        counts        = [ordered]@{}
    }
    modules    = [System.Collections.ArrayList]::new()
    moduleManifests = [System.Collections.ArrayList]::new()
    scripts    = [System.Collections.ArrayList]::new()
    mainGui    = [ordered]@{}
    guiForms   = [System.Collections.ArrayList]::new()
    xhtmlTools = [System.Collections.ArrayList]::new()
    configs    = [System.Collections.ArrayList]::new()
    agents     = [System.Collections.ArrayList]::new()
    tests      = [System.Collections.ArrayList]::new()
    styles     = [System.Collections.ArrayList]::new()
    tracking   = [ordered]@{
        todoDir      = 'todo/'
        sinDir       = 'sin_registry/'
        todoCount    = 0
        bugCount     = 0
        featureCount = 0
        sinCount     = 0
    }
    actionTaxonomy = [ordered]@{}
    actionRoutes   = [System.Collections.ArrayList]::new()
    dependencyEdges = [System.Collections.ArrayList]::new()
}

$seenModuleManifestPaths = @{}

# ── 1. Scan Modules ──
Write-Host "  [1/14] Scanning modules..." -ForegroundColor DarkCyan
$moduleDirs = @($ModulesDir)
try {
    if ($IncludeKernel -and (Test-Path (Join-Path $KernelDir 'core'))) {
        $moduleDirs += Join-Path $KernelDir 'core'
    }
} catch {
    Write-AppLog -Message "Failed to check kernel directory: $_" -Level Debug
}

foreach ($mDir in $moduleDirs) {
    $isKernel = $mDir -like '*sovereign-kernel*'
    try {
        $psmFiles = Get-ChildItem $mDir -Filter '*.psm1' -ErrorAction Stop
    } catch {
        Write-AppLog -Message "Failed to scan $mDir for modules: $_" -Level Warning
        continue
    }

    foreach ($psm in $psmFiles) {
        $modName = [System.IO.Path]::GetFileNameWithoutExtension($psm.Name)
        $relPath = $psm.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/'))

        $version   = Get-VersionTagFromFile $psm.FullName
        $fileRole  = Get-FileRoleFromFile $psm.FullName
        $allFuncs  = @(Extract-FunctionDefs $psm.FullName)
        $exported  = @(Extract-ExportedFunctions $psm.FullName)
        $deps      = @(Extract-Dependencies $psm.FullName)

        # If no explicit Export-ModuleMember found; treat all discovered functions as exported.
        if (@($exported).Count -eq 0 -and @($allFuncs).Count -gt 0) {
            $exported = $allFuncs | ForEach-Object { $_.Name }
        }

        $tier = if ($isKernel) { 'kernel' }
                elseif ($modName -like 'PwShGUI*') { 'core' }
                elseif ($modName -like 'CronAiAthon*') { 'pipeline' }
                elseif ($modName -like 'Assisted*' -or $modName -like 'SASC*') { 'security' }
                else { 'tool' }

        $exportList = [System.Collections.ArrayList]::new()
        foreach ($fn in $allFuncs) {
            $isExported = $fn.Name -in $exported
            $cat = Categorize-Function -Verb $fn.Verb -Noun $fn.Noun -ModuleName $modName
            $se = if ($fn.Verb) { Get-SideEffects $fn.Verb } else { @() }

            $fnEntry = [ordered]@{
                function    = $fn.Name
                exported    = $isExported
                verb        = $fn.Verb
                noun        = $fn.Noun
                category    = $cat.Category
                agenticAction = $cat.ActionKey
                params      = $fn.Params
                paramTypes  = $fn.ParamTypes
                sideEffects = $se
                line        = $fn.Line
            }
            $null = $exportList.Add($fnEntry)

            # Register action route
            if ($isExported) {
                $null = $manifest.actionRoutes.Add([ordered]@{
                    action   = $cat.ActionKey
                    function = $fn.Name
                    module   = $modName
                    source   = $relPath
                    params   = $fn.Params
                })
            }
        }

        $depEdges = foreach ($d in $deps) {
            $null = $manifest.dependencyEdges.Add([ordered]@{
                from = $relPath
                to   = $d.Target
                type = $d.Type
            })
            $d.Target
        }

        $psd1Path = Join-Path $mDir "$modName.psd1"
        if (Test-Path $psd1Path) {
            $manifestRelPath = $psd1Path.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/'))
            if (-not $seenModuleManifestPaths.ContainsKey($manifestRelPath)) {
                $psd1Content = Get-Content $psd1Path -Raw -ErrorAction SilentlyContinue
                $null = $manifest.moduleManifests.Add([ordered]@{
                    name             = [System.IO.Path]::GetFileNameWithoutExtension($psd1Path)
                    path             = $manifestRelPath
                    rootModule       = if ($psd1Content -match 'RootModule\s*=\s*[''\"]([^''\"]+)[''\"]') { $Matches[1] } else { $null }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    moduleVersion    = if ($psd1Content -match 'ModuleVersion\s*=\s*[''\"]([^''\"]+)[''\"]') { $Matches[1] } else { $null }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    hasVersionTag    = [bool]($psd1Content -match '#\s*VersionTag:')
                    hasFileRole      = [bool]($psd1Content -match '#\s*FileRole:')
                    hasSchemaVersion = [bool]($psd1Content -match '#\s*SchemaVersion:')
                    sizeKB           = [math]::Round((Get-Item $psd1Path).Length / 1KB, 1)
                    pairedModule     = $psm.Name
                })
                $seenModuleManifestPaths[$manifestRelPath] = $true  # SIN-EXEMPT:P027 -- index access, context-verified safe
            }
        }
        $modEntry = [ordered]@{
            name         = $modName
            path         = $relPath
            manifestFile = if (Test-Path $psd1Path) { $psd1Path.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/')) } else { $null }
            version      = $version
            fileRole     = $fileRole
            tier         = $tier
            sizeKB       = [math]::Round($psm.Length / 1KB, 1)
            functionCount = @($allFuncs).Count
            exportedCount = @($exportList | Where-Object { $_.exported }).Count
            functions    = $exportList
            dependencies = ($depEdges | Select-Object -Unique)
        }
        $null = $manifest.modules.Add($modEntry)

        Write-Verbose "  Module: $modName ($(@($allFuncs).Count) functions, $(@($exported).Count) exported)"
    }

    try {
        $orphanPsd1Files = Get-ChildItem $mDir -Filter '*.psd1' -ErrorAction Stop
    } catch {
        $orphanPsd1Files = @()
    }
    foreach ($psd1 in $orphanPsd1Files) {
        $manifestRelPath = $psd1.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/'))
        if ($seenModuleManifestPaths.ContainsKey($manifestRelPath)) { continue }
        $psd1Content = Get-Content $psd1.FullName -Raw -ErrorAction SilentlyContinue
        $null = $manifest.moduleManifests.Add([ordered]@{
            name             = $psd1.BaseName
            path             = $manifestRelPath
            rootModule       = if ($psd1Content -match 'RootModule\s*=\s*[''\"]([^''\"]+)[''\"]') { $Matches[1] } else { $null }  # SIN-EXEMPT:P027 -- index access, context-verified safe
            moduleVersion    = if ($psd1Content -match 'ModuleVersion\s*=\s*[''\"]([^''\"]+)[''\"]') { $Matches[1] } else { $null }  # SIN-EXEMPT:P027 -- index access, context-verified safe
            hasVersionTag    = [bool]($psd1Content -match '#\s*VersionTag:')
            hasFileRole      = [bool]($psd1Content -match '#\s*FileRole:')
            hasSchemaVersion = [bool]($psd1Content -match '#\s*SchemaVersion:')
            sizeKB           = [math]::Round($psd1.Length / 1KB, 1)
            pairedModule     = $null
        })
        $seenModuleManifestPaths[$manifestRelPath] = $true  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
}

# ── 2. Scan Main-GUI.ps1 ──
Write-Host "  [2/14] Scanning Main-GUI.ps1..." -ForegroundColor DarkCyan
$mainGuiPath = Join-Path $ProjectRoot 'Main-GUI.ps1'
if (Test-Path $mainGuiPath) {
    $mgFuncs = @(Extract-FunctionDefs $mainGuiPath)
    $mgDeps  = @(Extract-Dependencies $mainGuiPath)

    $mgFuncList = [System.Collections.ArrayList]::new()
    foreach ($fn in $mgFuncs) {
        $cat = Categorize-Function -Verb $fn.Verb -Noun $fn.Noun -ModuleName 'Main-GUI'
        $se = if ($fn.Verb) { Get-SideEffects $fn.Verb } else { @() }

        $fnEntry = [ordered]@{
            function      = $fn.Name
            verb          = $fn.Verb
            noun          = $fn.Noun
            category      = $cat.Category
            agenticAction = $cat.ActionKey
            params        = $fn.Params
            paramTypes    = $fn.ParamTypes
            sideEffects   = $se
            line          = $fn.Line
        }
        $null = $mgFuncList.Add($fnEntry)

        # GUI forms -> separate list
        if ($fn.Name -like 'Show-*') {
            $null = $manifest.guiForms.Add([ordered]@{
                name     = $fn.Name
                source   = 'Main-GUI.ps1'
                category = $cat.Category
                params   = $fn.Params
                line     = $fn.Line
            })
        }

        # Register action route
        $null = $manifest.actionRoutes.Add([ordered]@{
            action   = $cat.ActionKey
            function = $fn.Name
            module   = 'Main-GUI'
            source   = 'Main-GUI.ps1'
            params   = $fn.Params
        })
    }

    foreach ($d in $mgDeps) {
        $null = $manifest.dependencyEdges.Add([ordered]@{
            from = 'Main-GUI.ps1'
            to   = $d.Target
            type = $d.Type
        })
    }

    try {
        $guiItem = Get-Item $mainGuiPath -ErrorAction Stop
    } catch {
        Write-AppLog -Message "Failed to get Main-GUI.ps1 file info: $_" -Level Error
        $guiItem = $null
    }
    
    $manifest.mainGui = [ordered]@{
        path          = 'Main-GUI.ps1'
        version       = Get-VersionTagFromFile $mainGuiPath
        sizeKB        = if ($guiItem) { [math]::Round($guiItem.Length / 1KB, 1) } else { 0 }
        functionCount = @($mgFuncs).Count
        functions     = $mgFuncList
    }
}

# ── 3. Scan Scripts ──
Write-Host "  [3/14] Scanning scripts..." -ForegroundColor DarkCyan
try {
    $scriptFiles = Get-ChildItem $ScriptsDir -Filter '*.ps1' -Recurse -ErrorAction Stop
} catch {
    Write-AppLog -Message "Failed to scan scripts directory: $_" -Level Warning
    $scriptFiles = @()
}
if ($scriptFiles) {
    $scriptFiles = $scriptFiles | Where-Object {
        $_.Name -notlike 'Script-?.ps1' -and
        $_.Name -notlike 'Script?.ps1' -and
        $_.Name -notlike 'PS-CheatSheet*'
    }
}

foreach ($sf in $scriptFiles) {
    $relPath = $sf.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/'))
    $funcs   = @(Extract-FunctionDefs $sf.FullName)
    $deps    = @(Extract-Dependencies $sf.FullName)

    $funcList = [System.Collections.ArrayList]::new()
    $actionKeys = [System.Collections.ArrayList]::new()
    foreach ($fn in $funcs) {
        $cat = Categorize-Function -Verb $fn.Verb -Noun $fn.Noun -ModuleName $sf.BaseName
        $null = $funcList.Add([ordered]@{
            function      = $fn.Name
            category      = $cat.Category
            agenticAction = $cat.ActionKey
            params        = $fn.Params
            line          = $fn.Line
        })
        if ($cat.ActionKey -notin $actionKeys) { $null = $actionKeys.Add($cat.ActionKey) }
    }

    foreach ($d in $deps) {
        $null = $manifest.dependencyEdges.Add([ordered]@{
            from = $relPath
            to   = $d.Target
            type = $d.Type
        })
    }

    $null = $manifest.scripts.Add([ordered]@{
        name          = $sf.BaseName
        path          = $relPath
        version       = Get-VersionTagFromFile $sf.FullName
        fileRole      = Get-FileRoleFromFile $sf.FullName
        sizeKB        = [math]::Round($sf.Length / 1KB, 1)
        functionCount = @($funcs).Count
        functions     = $funcList
        agenticActions = $actionKeys
    })
}

# ── 4. Scan XHTML Tools ──
Write-Host "  [4/14] Scanning XHTML tools..." -ForegroundColor DarkCyan
try {
    if (Test-Path $XhtmlDir) {
        $xhtmlFiles = Get-ChildItem $XhtmlDir -Filter '*.xhtml' -ErrorAction Stop
    } else {
        $xhtmlFiles = @()
    }
} catch {
    Write-AppLog -Message "Failed to scan XHTML directory: $_" -Level Debug
    $xhtmlFiles = @()
}
if ($xhtmlFiles) {
    foreach ($xf in $xhtmlFiles) {
        $relPath = $xf.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/'))
        $version = Get-VersionTagFromFile $xf.FullName
        $null = $manifest.xhtmlTools.Add([ordered]@{
            name    = $xf.BaseName
            path    = $relPath
            version = $version
            sizeKB  = [math]::Round($xf.Length / 1KB, 1)
            category = switch -Wildcard ($xf.BaseName) {
                '*FeatureRequests*' { 'tracking' }
                '*MasterToDo*'      { 'tracking' }
                '*TestingRoutine*'  { 'testing' }
                '*code-analysis*'   { 'analysis' }
                '*MCPServiceConfig*'{ 'configuration' }
                '*TEMPLATE*'        { 'template' }
                default             { 'tool' }
            }
        })
    }
}
# Root-level XHTML
try {
    $rootXhtml = Get-ChildItem $ProjectRoot -Filter '*.xhtml' -ErrorAction Stop
} catch {
    Write-AppLog -Message "Failed to scan root for XHTML files: $_" -Level Debug
    $rootXhtml = @()
}
foreach ($xf in $rootXhtml) {
    $relPath = $xf.Name
    $null = $manifest.xhtmlTools.Add([ordered]@{
        name     = $xf.BaseName
        path     = $relPath
        version  = Get-VersionTagFromFile $xf.FullName
        sizeKB   = [math]::Round($xf.Length / 1KB, 1)
        category = 'tool'
    })
}

# ── 5. Scan Config Files ──
Write-Host "  [5/14] Scanning config files..." -ForegroundColor DarkCyan
try {
    # Scan config root AND known subdirectories (templates, APP-INSTALL-TEMPLATES, etc.)
    $configFiles = Get-ChildItem $ConfigDir -File -Recurse -ErrorAction Stop |
        Where-Object {
            $_.Extension -in '.json','.xml','.csv','.bin','.ps1' -and
            $_.FullName -notlike '*\agentic-manifest-history\*'
        }
} catch {
    Write-AppLog -Message "Failed to scan config directory: $_" -Level Warning
    $configFiles = @()
}
foreach ($cf in $configFiles) {
    $relPath = $cf.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/'))
    $schema = $null
    if ($cf.Extension -eq '.json') {
        try {
            $jsonHead = Get-Content $cf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($jsonHead.meta.'$schema') { $schema = $jsonHead.meta.'$schema' }
            elseif ($jsonHead.'$schema') { $schema = $jsonHead.'$schema' }
        } catch {
            Write-AppLog -Message "Failed to parse JSON schema from $($cf.Name): $_" -Level Debug
            <# Intentional: non-fatal, schema extraction is optional #>
        }
    }
    $null = $manifest.configs.Add([ordered]@{
        name     = $cf.Name
        path     = $relPath
        format   = $cf.Extension.TrimStart('.')
        sizeKB   = [math]::Round($cf.Length / 1KB, 1)
        schema   = $schema
    })
}

# ── 6. Scan Tests ──
Write-Host "  [6/14] Scanning tests..." -ForegroundColor DarkCyan
try {
    if (Test-Path $TestsDir) {
        $testFiles = Get-ChildItem $TestsDir -Filter '*.ps1' -Recurse -ErrorAction Stop
    } else {
        $testFiles = @()
    }
} catch {
    Write-AppLog -Message "Failed to scan tests directory: $_" -Level Debug
    $testFiles = @()
}
if ($testFiles) {
    foreach ($tf in $testFiles) {
        $relPath = $tf.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/'))
        $isPester = $tf.Name -like '*.Tests.ps1'
        $null = $manifest.tests.Add([ordered]@{
            name    = $tf.BaseName
            path    = $relPath
            type    = if ($isPester) { 'pester' } else { 'harness' }
            sizeKB  = [math]::Round($tf.Length / 1KB, 1)
        })
    }
}

# ── 7. Scan Agents ──
Write-Host "  [7/14] Scanning agents..." -ForegroundColor DarkCyan
try {
    if (-not (Test-Path $AgentsDir)) {
        $agentDirs = @()
    } else {
        $agentDirs = Get-ChildItem $AgentsDir -Directory -ErrorAction Stop
    }
} catch {
    Write-AppLog -Message "Failed to scan agents directory: $_" -Level Debug
    $agentDirs = @()
}
if ($agentDirs) {
    foreach ($ad in $agentDirs) {
        try {
            $entryPoints = Get-ChildItem $ad.FullName -Filter '*.ps1' -ErrorAction Stop |
                Where-Object { $_.Name -like 'Start-*' -or $_.Name -like 'Chat-*' -or $_.Name -like 'main*' }
            $pyFiles = Get-ChildItem $ad.FullName -Filter '*.py' -ErrorAction Stop
        } catch {
            Write-AppLog -Message "Failed to scan agent directory $($ad.Name): $_" -Level Debug
            $entryPoints = @()
            $pyFiles = @()
        }
        # Scan core/*.psm1 for agent modules
        $agentCoreDir = Join-Path $ad.FullName 'core'
        $agentCoreModules = @()
        $agentCoreManifests = @()
        if (Test-Path $agentCoreDir) {
            try {
                $agentCoreModules = @(Get-ChildItem $agentCoreDir -Filter '*.psm1' -ErrorAction Stop | ForEach-Object { $_.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/')) })
                $agentCoreManifests = @(Get-ChildItem $agentCoreDir -Filter '*.psd1' -ErrorAction Stop | ForEach-Object { $_.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/')) })
            } catch {
                Write-AppLog -Message "Failed to scan agent core dir for $($ad.Name): $_" -Level Debug
            }
        }
        # Scan agent config subdir for JSON config files
        $agentConfigFiles = @()
        $agentConfigDir = Join-Path $ad.FullName 'config'
        if (Test-Path $agentConfigDir) {
            try {
                $agentConfigFiles = @(Get-ChildItem $agentConfigDir -Filter '*.json' -ErrorAction Stop | ForEach-Object { $_.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/')) })
            } catch {
                Write-AppLog -Message "Failed to scan agent config dir for $($ad.Name): $_" -Level Debug
            }
        }
        $null = $manifest.agents.Add([ordered]@{
            name         = $ad.Name
            path         = $ad.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/'))
            entryPoints  = @($entryPoints | ForEach-Object { $_.Name })
            coreModules  = $agentCoreModules
            coreManifests = $agentCoreManifests
            configFiles  = $agentConfigFiles
            languages    = @(
                $(if ($entryPoints -or $agentCoreModules) { 'PowerShell' })
                $(if ($pyFiles) { 'Python' })
            ) | Where-Object { $_ }
        })
    }
}

# ── 8. Scan Styles ──
Write-Host "  [8/14] Scanning styles..." -ForegroundColor DarkCyan
try {
    if (Test-Path $StylesDir) {
        $cssFiles = Get-ChildItem $StylesDir -Filter '*.css' -ErrorAction Stop
    } else {
        $cssFiles = @()
    }
} catch {
    Write-AppLog -Message "Failed to scan styles directory: $_" -Level Debug
    $cssFiles = @()
}
if ($cssFiles) {
    foreach ($cf in $cssFiles) {
        $null = $manifest.styles.Add([ordered]@{
            name = $cf.BaseName
            path = $cf.FullName.Replace($ProjectRoot, '').TrimStart([char[]]@('\', '/'))
        })
    }
}

# ── 8b. Scan Root-level Launchers and Utility Scripts ──
Write-Host "  [8b] Scanning root-level launchers and utility scripts..." -ForegroundColor DarkCyan
try {
    $rootBatFiles = Get-ChildItem $ProjectRoot -Filter '*.bat' -ErrorAction Stop |
        Where-Object { $_.Name -notlike '*.backup*' }
    foreach ($bf in $rootBatFiles) {
        $null = $manifest.scripts.Add([ordered]@{
            name          = $bf.BaseName
            path          = $bf.Name
            version       = Get-VersionTagFromFile $bf.FullName
            fileRole      = 'launcher'
            sizeKB        = [math]::Round($bf.Length / 1KB, 1)
            functionCount = 0
            functions     = @()
            agenticActions = @('invoke.launch')
        })
    }
} catch {
    Write-AppLog -Message "Failed to scan root bat files: $_" -Level Debug
}
try {
    $rootPs1Files = Get-ChildItem $ProjectRoot -Filter '*.ps1' -ErrorAction Stop |
        Where-Object { $_.Name -ne 'Main-GUI.ps1' }
    foreach ($rf in $rootPs1Files) {
        $relPath = $rf.Name
        $funcs   = @(Extract-FunctionDefs $rf.FullName)
        $funcList = [System.Collections.ArrayList]::new()
        $actionKeys = [System.Collections.ArrayList]::new()
        foreach ($fn in $funcs) {
            $cat = Categorize-Function -Verb $fn.Verb -Noun $fn.Noun -ModuleName $rf.BaseName
            $null = $funcList.Add([ordered]@{
                function      = $fn.Name
                category      = $cat.Category
                agenticAction = $cat.ActionKey
                params        = $fn.Params
                line          = $fn.Line
            })
            if ($cat.ActionKey -notin $actionKeys) { $null = $actionKeys.Add($cat.ActionKey) }
        }
        $null = $manifest.scripts.Add([ordered]@{
            name          = $rf.BaseName
            path          = $relPath
            version       = Get-VersionTagFromFile $rf.FullName
            fileRole      = 'utility'
            sizeKB        = [math]::Round($rf.Length / 1KB, 1)
            functionCount = @($funcs).Count
            functions     = $funcList
            agenticActions = $actionKeys
        })
    }
} catch {
    Write-AppLog -Message "Failed to scan root ps1 files: $_" -Level Debug
}

# ── 9. Scan Tracking Stats ──
Write-Host "  [9/14] Counting tracking items..." -ForegroundColor DarkCyan
try {
    if (Test-Path $TodoDir) {
        $todoFiles = Get-ChildItem $TodoDir -Filter '*.json' -ErrorAction Stop |
            Where-Object { $_.Name -notlike '_*' -and $_.FullName -notlike "*\~*\*" }
        $manifest.tracking.todoCount    = @($todoFiles | Where-Object { $_.Name -like 'ToDo-*' }).Count
        $manifest.tracking.bugCount     = @($todoFiles | Where-Object { $_.Name -like 'Bug-*' -or $_.Name -like 'Bugs2FIX-*' }).Count
        $manifest.tracking.featureCount = @($todoFiles | Where-Object { $_.Name -like 'FeatureRequest-*' }).Count
    }
} catch {
    Write-AppLog -Message "Failed to scan todo directory: $_" -Level Debug
}

try {
    if (Test-Path $SinDir) {
        $sinFiles = Get-ChildItem $SinDir -Filter 'SIN-*.json' -ErrorAction Stop
        $manifest.tracking.sinCount = @($sinFiles).Count
    }
} catch {
    Write-AppLog -Message "Failed to scan SIN registry: $_" -Level Debug
}

# ── 10. Build Action Taxonomy ──
Write-Host "  [10/14] Building action taxonomy..." -ForegroundColor DarkCyan
$taxonomy = @{}
foreach ($route in $manifest.actionRoutes) {
    $action = $route.action
    $parts = $action -split '\.'
    $domain = if (@($parts).Count -ge 2) { $parts[1] } else { $parts[0] }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    if (-not $taxonomy.ContainsKey($domain)) {
        $taxonomy[$domain] = [System.Collections.ArrayList]::new()  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    if ($action -notin $taxonomy[$domain]) {  # SIN-EXEMPT:P027 -- index access, context-verified safe
        $null = $taxonomy[$domain].Add($action)  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
}
foreach ($key in ($taxonomy.Keys | Sort-Object)) {
    $manifest.actionTaxonomy[$key] = @($taxonomy[$key] | Sort-Object -Unique)  # SIN-EXEMPT:P027 -- index access, context-verified safe
}

# ── 11. Build agenticAPI Section ──
Write-Host "  [11/14] Building agentic API action routes..." -ForegroundColor DarkCyan

# Build test-file-to-module lookup for coverage mapping
$testModuleMap = @{}
foreach ($t in $manifest.tests) {
    # Convention: tests/ModuleName.Tests.ps1 covers modules/ModuleName.psm1
    $baseName = $t.name -replace '\.Tests$', '' -replace '^Test-', '' -replace '^Invoke-', ''
    $testModuleMap[$baseName] = $t.path  # SIN-EXEMPT:P027 -- index access, context-verified safe
}

# Build enriched action routes with sideEffects + testCoverage
$enrichedRoutes = [System.Collections.ArrayList]::new()
foreach ($route in $manifest.actionRoutes) {
    # Find test coverage for this route's module
    $modName = $route.module
    $testFile = $null
    if ($testModuleMap.ContainsKey($modName)) {
        $testFile = $testModuleMap[$modName]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    # Look up sideEffects from the module's function entry
    $sideEffects = @()
    $modEntry = $manifest.modules | Where-Object { $_.name -eq $modName } | Select-Object -First 1
    if ($modEntry) {
        $fnEntry = $modEntry.functions | Where-Object { $_.function -eq $route.function } | Select-Object -First 1
        if ($fnEntry) { $sideEffects = @($fnEntry.sideEffects) }
    }
    if (-not $sideEffects -or @($sideEffects).Count -eq 0) {
        # Fallback: infer from verb
        $verb = ($route.function -split '-')[0]
        $sideEffects = Get-SideEffects $verb
    }

    $null = $enrichedRoutes.Add([ordered]@{
        action       = $route.action
        handler      = $route.function
        module       = $modName
        source       = $route.source
        sideEffects  = $sideEffects
        testCoverage = $testFile
    })
}

# ── 12. Build Coverage Map ──
Write-Host "  [12/14] Building coverage map..." -ForegroundColor DarkCyan
$coveredDomains = [System.Collections.ArrayList]::new()
$allDomains = @{}
foreach ($route in $enrichedRoutes) {
    $parts = $route.action -split '\.'
    $domain = if (@($parts).Count -ge 2) { $parts[1..(@($parts).Count - 1)] -join '.' } else { $parts[0] }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    if (-not $allDomains.ContainsKey($domain)) { $allDomains[$domain] = @{ covered = $false; testFile = $null } }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    if ($route.testCoverage) {
        $allDomains[$domain].covered = $true  # SIN-EXEMPT:P027 -- index access, context-verified safe
        $allDomains[$domain].testFile = $route.testCoverage  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
}
$uncoveredList = [System.Collections.ArrayList]::new()
foreach ($d in ($allDomains.Keys | Sort-Object)) {
    if ($allDomains[$d].covered) {  # SIN-EXEMPT:P027 -- index access, context-verified safe
        # Count test assertions (approximate: count 'It ' or 'Should' lines)
        $testCount = 0
        $testFullPath = Join-Path $ProjectRoot $allDomains[$d].testFile  # SIN-EXEMPT:P027 -- index access, context-verified safe
        try {
            if (Test-Path $testFullPath) {
                $testContent = Get-Content $testFullPath -Raw -ErrorAction Stop
                if ($testContent) {
                    $testCount = ([regex]::Matches($testContent, '\bIt\s+[''"]')).Count
                }
            }
        } catch {
            Write-AppLog -Message "Failed to read test content from $testFullPath : $_" -Level Debug
        }
        $null = $coveredDomains.Add([ordered]@{
            domain    = $d
            testFile  = $allDomains[$d].testFile  # SIN-EXEMPT:P027 -- index access, context-verified safe
            testCount = $testCount
        })
    } else {
        $null = $uncoveredList.Add($d)
    }
}
$covPct = if ($allDomains.Count -gt 0) { [math]::Round(($coveredDomains.Count / $allDomains.Count) * 100) } else { 0 }

# ── 13. Build Dependency Graph with Topological Sort ──
Write-Host "  [13/14] Computing dependency graph and boot order..." -ForegroundColor DarkCyan
$graphEdges = [System.Collections.ArrayList]::new()
$moduleNodes = @{}
foreach ($edge in $manifest.dependencyEdges) {
    $fromFile = [System.IO.Path]::GetFileName($edge.from)
    $toFile   = [System.IO.Path]::GetFileName($edge.to)
    if ($fromFile -like '*.psm1' -or $toFile -like '*.psm1') {
        $null = $graphEdges.Add([ordered]@{ from = $fromFile; to = $toFile; type = $edge.type })
        $moduleNodes[$fromFile] = $true  # SIN-EXEMPT:P027 -- index access, context-verified safe
        if ($toFile -ne '(none)') { $moduleNodes[$toFile] = $true }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
}
# Topological sort (Kahn's algorithm)
$inDegree = @{}
$adjList = @{}
foreach ($node in $moduleNodes.Keys) {
    $inDegree[$node] = 0  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $adjList[$node]  = [System.Collections.ArrayList]::new()  # SIN-EXEMPT:P027 -- index access, context-verified safe
}
foreach ($edge in $graphEdges) {
    if ($edge.to -ne '(none)' -and $moduleNodes.ContainsKey($edge.to) -and $moduleNodes.ContainsKey($edge.from)) {
        $null = $adjList[$edge.to].Add($edge.from)
        $inDegree[$edge.from] = ($inDegree[$edge.from]) + 1
    }
}
$queue = [System.Collections.Queue]::new()
foreach ($node in $inDegree.Keys) {
    if ($inDegree[$node] -eq 0) { $queue.Enqueue($node) }  # SIN-EXEMPT:P027 -- index access, context-verified safe
}
$bootOrder = [System.Collections.ArrayList]::new()
while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    $null = $bootOrder.Add($current)
    foreach ($dependent in $adjList[$current]) {  # SIN-EXEMPT:P027 -- index access, context-verified safe
        $inDegree[$dependent] = ($inDegree[$dependent]) - 1  # SIN-EXEMPT:P027 -- index access, context-verified safe
        if ($inDegree[$dependent] -eq 0) { $queue.Enqueue($dependent) }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
}
# Add any remaining nodes (cycles or isolates)
foreach ($node in ($moduleNodes.Keys | Sort-Object)) {
    if ($node -notin $bootOrder) { $null = $bootOrder.Add($node) }
}
# Filter to .psm1 only
$bootOrder = @($bootOrder | Where-Object { $_ -like '*.psm1' })

# ── 14. Assemble agenticAPI ──
Write-Host "  [14/14] Assembling agenticAPI section..." -ForegroundColor DarkCyan
$manifest['agenticAPI'] = [ordered]@{
    '$purpose' = 'Dedicated agentic action routing, coverage tracking, and agent interaction log interface. Agents read this section to resolve any action key to its handler in one lookup, determine test coverage, and log their invocations for audit.'
    version = '1.0'
    actionRoutes = $enrichedRoutes
    coverageMap = [ordered]@{
        '$purpose' = 'Quick lookup: which action domains have test coverage and which are untested.'
        covered = $coveredDomains
        uncovered = $uncoveredList
        coveragePercent = $covPct
    }
    callChains = [ordered]@{
        '$purpose' = 'Multi-step workflows with preconditions. Agents execute these sequences atomically.'
        scanAndTriageBugs = [ordered]@{
            description = 'Run all 6 bug vectors, push results into pipeline, then regenerate the todo bundle.'
            preconditions = @('init.pipeline')
            steps = @(
                [ordered]@{ seq = 1; action = 'invoke.bugtracking'; handler = 'Invoke-FullBugScan'; failAction = 'abort' }
                [ordered]@{ seq = 2; action = 'invoke.bugtracking'; handler = 'Invoke-BugToPipelineProcessor'; failAction = 'abort' }
                [ordered]@{ seq = 3; action = 'update.todotracking'; handler = 'Update-TodoBundle'; failAction = 'warn' }
            )
            postconditions = @('read.pipeline')
        }
        buildAndPackage = [ordered]@{
            description = 'Version bump, build manifest, export zip package.'
            preconditions = @('test.validation')
            steps = @(
                [ordered]@{ seq = 1; action = 'update.versioning'; handler = 'Step-MinorVersion'; failAction = 'abort' }
                [ordered]@{ seq = 2; action = 'build.infrastructure'; handler = 'Build-AgenticManifest.ps1'; failAction = 'warn' }
                [ordered]@{ seq = 3; action = 'create.build'; handler = 'Export-WorkspacePackage'; failAction = 'abort' }
            )
            postconditions = @('add.reporting')
        }
        fullCronCycle = [ordered]@{
            description = 'Execute all scheduled jobs, process bugs, update pipeline health.'
            preconditions = @('init.scheduling', 'init.pipeline')
            steps = @(
                [ordered]@{ seq = 1; action = 'invoke.scheduling'; handler = 'Invoke-AllCronJobs'; failAction = 'continue' }
                [ordered]@{ seq = 2; action = 'invoke.bugtracking'; handler = 'Invoke-BugToPipelineProcessor'; failAction = 'warn' }
                [ordered]@{ seq = 3; action = 'update.todotracking'; handler = 'Update-TodoBundle'; failAction = 'warn' }
                [ordered]@{ seq = 4; action = 'read.pipeline'; handler = 'Get-PipelineHealthMetrics'; failAction = 'warn' }
            )
            postconditions = @('write.eventlog')
        }
        secureVaultAccess = [ordered]@{
            description = 'Unlock vault, read a secret, re-lock. Ensures vault is never left open.'
            preconditions = @('init.security.sasc')
            steps = @(
                [ordered]@{ seq = 1; action = 'test.security.vault'; handler = 'Test-VaultStatus'; failAction = 'abort' }
                [ordered]@{ seq = 2; action = 'unlock.security.vault'; handler = 'Unlock-Vault'; failAction = 'abort' }
                [ordered]@{ seq = 3; action = 'read.security.vault'; handler = 'Get-VaultItem'; failAction = 'continue' }
                [ordered]@{ seq = 4; action = 'lock.security.vault'; handler = 'Lock-Vault'; failAction = 'force' }
            )
            postconditions = @('write.logging')
        }
        integrityAudit = [ordered]@{
            description = 'Build baseline, scan for changes, log findings.'
            preconditions = @()
            steps = @(
                [ordered]@{ seq = 1; action = 'build.integrity'; handler = 'Build-IntegrityBaseline'; failAction = 'abort' }
                [ordered]@{ seq = 2; action = 'invoke.integrity'; handler = 'Invoke-IntegrityScan'; failAction = 'abort' }
                [ordered]@{ seq = 3; action = 'write.logging'; handler = 'Write-AppLog'; failAction = 'warn' }
            )
            postconditions = @()
        }
        outlinePromotion = [ordered]@{
            description = 'Promote outline schema from v0 to v1 after Chief approval.'
            preconditions = @('read.pipeline')
            steps = @(
                [ordered]@{ seq = 1; action = 'read.pipeline'; handler = 'Get-PipelineHealthMetrics'; failAction = 'abort' }
                [ordered]@{ seq = 2; action = 'confirm.pipeline'; handler = 'Confirm-OutlineVersion'; failAction = 'abort' }
                [ordered]@{ seq = 3; action = 'write.eventlog'; handler = 'Write-CronEventLog'; failAction = 'warn' }
            )
            postconditions = @('update.todotracking')
        }
    }
    agentTrackingInterface = [ordered]@{
        '$purpose' = 'Schema and paths for agents to log their invocations for audit, replay, and performance analysis.'
        logPath = 'logs/agent-interactions.jsonl'
        logSchema = [ordered]@{
            timestamp     = 'ISO 8601 datetime'
            agentId       = 'string: agent name or ID'
            sessionId     = 'string: unique session identifier'
            actionKey     = 'string: agenticAction from actionRoutes'
            handler       = 'string: function name invoked'
            module        = 'string: source module name'
            params        = 'object: parameter key-value pairs passed'
            result        = "string: 'success' | 'error' | 'skipped' | 'timeout'"
            durationMs    = 'number: wall-clock milliseconds'
            errorMessage  = 'string|null: error details if result != success'
            pipelineItemId = 'string|null: linked pipeline/bug/todo ID if applicable'
            callChain     = 'string|null: callChain name if part of a workflow sequence'
        }
        registrationEndpoint = [ordered]@{
            function    = 'Register-SubagentCall'
            module      = 'CronAiAthon-Scheduler'
            source      = 'modules/CronAiAthon-Scheduler.psm1'
            description = 'Call this function to persist an agent interaction record'
        }
        queryEndpoints = [ordered]@{
            getHistory = [ordered]@{ function = 'Get-CronJobHistory'; module = 'CronAiAthon-Scheduler' }
            getSummary = [ordered]@{ function = 'Get-CronJobSummary'; module = 'CronAiAthon-Scheduler' }
        }
    }
    dependencyGraph = [ordered]@{
        '$purpose' = 'Module-level import edges. Agents use this to understand boot order and cascading impacts.'
        edges = $graphEdges
        bootOrder = $bootOrder
    }
}

# ── Compute Counts ──
$manifest.meta.counts = [ordered]@{
    modules         = $manifest.modules.Count
    moduleManifests = $manifest.moduleManifests.Count
    mainGuiFunctions = $manifest.mainGui.functionCount
    totalExportedFunctions = ($manifest.modules | ForEach-Object { $_.exportedCount } | Measure-Object -Sum).Sum
    scripts         = $manifest.scripts.Count
    xhtmlTools      = $manifest.xhtmlTools.Count
    configs         = $manifest.configs.Count
    tests           = $manifest.tests.Count
    agents          = $manifest.agents.Count
    styles          = $manifest.styles.Count
    guiForms        = $manifest.guiForms.Count
    actionDomains   = $manifest.actionTaxonomy.Count
    actionRoutes    = $enrichedRoutes.Count
    dependencyEdges = $graphEdges.Count
    trackingItems   = $manifest.tracking.todoCount + $manifest.tracking.bugCount +
                      $manifest.tracking.featureCount + $manifest.tracking.sinCount
}

# ── Write Output ──
try {
    $json = $manifest | ConvertTo-Json -Depth 10 -ErrorAction Stop
    Set-Content -Path $OutputPath -Value $json -Encoding UTF8 -ErrorAction Stop
} catch {
    Write-AppLog -Message "Failed to write agentic manifest to $OutputPath : $_" -Level Error
    throw "Critical: Cannot write agentic manifest file"
}
Write-Host "`n[AgenticManifest] Written to: $OutputPath" -ForegroundColor Green

# ── Auto-Generate MODULE-FUNCTION-INDEX.md ──
$readmeDir = Join-Path $ProjectRoot '~README.md'
$mfiPath   = Join-Path $readmeDir 'MODULE-FUNCTION-INDEX.md'
$mfiLines  = [System.Collections.Generic.List[string]]::new()
$mfiLines.Add("<!-- VersionTag: $($manifest.meta.version) -->")
$mfiLines.Add("<!-- VersionBuildHistory: $($manifest.meta.version)  $(Get-Date -Format 'yyyy-MM-dd HH:mm')  (auto-generated from agentic-manifest.json) -->")
$mfiLines.Add('<!-- FileRole: Index -->')
$mfiLines.Add('')
$mfiLines.Add('# PowerShellGUI - Module Function Index')
$mfiLines.Add('')
$mfiLines.Add("> **Auto-generated** by ``Build-AgenticManifest.ps1`` on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Do not edit manually.")
$mfiLines.Add("> Source: ``config/agentic-manifest.json`` | Total exported: $($manifest.meta.counts.totalExportedFunctions)")
$mfiLines.Add('')
$mfiLines.Add('| Module | Function | Source |')
$mfiLines.Add('| -------- | ---------- | -------- |')
foreach ($mod in ($manifest.modules | Sort-Object { $_['name'] })) {
    foreach ($fn in @($mod['functions'])) {
        if ($fn['exported']) {
            $mfiLines.Add("| $($mod['name']) | ``$($fn['function'])`` | $($mod['path']) |")
        }
    }
}
$mfiLines.Add('')
$mfiLines.Add("---")
$mfiLines.Add("*Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Modules: $($manifest.modules.Count) | Exported Functions: $($manifest.meta.counts.totalExportedFunctions)*")
[System.IO.File]::WriteAllLines($mfiPath, $mfiLines.ToArray(), [System.Text.UTF8Encoding]::new($false))
Write-Host "  MODULE-FUNCTION-INDEX.md: $($manifest.meta.counts.totalExportedFunctions) functions from $($manifest.modules.Count) modules" -ForegroundColor Cyan
Write-Host "  Modules: $($manifest.meta.counts.modules) | GUI Functions: $($manifest.meta.counts.mainGuiFunctions) | Exports: $($manifest.meta.counts.totalExportedFunctions)" -ForegroundColor White
Write-Host "  Scripts: $($manifest.meta.counts.scripts) | XHTML: $($manifest.meta.counts.xhtmlTools) | Tests: $($manifest.meta.counts.tests)" -ForegroundColor White
Write-Host "  Actions: $($manifest.meta.counts.actionRoutes) routes across $($manifest.meta.counts.actionDomains) domains" -ForegroundColor White
Write-Host "  Tracking: $($manifest.meta.counts.trackingItems) items (todo/bug/feature/SIN)" -ForegroundColor White
Write-Host "  Dependencies: $($manifest.meta.counts.dependencyEdges) edges | Boot order: $($bootOrder.Count) modules" -ForegroundColor White
Write-Host "  Coverage: $covPct% ($($coveredDomains.Count) covered / $($uncoveredList.Count) uncovered domains)" -ForegroundColor $(if ($covPct -ge 50) { 'Green' } else { 'Yellow' })
$chainCount = 0
try {
    $chainCount = @($manifest.agenticAPI.callChains.Keys).Count
} catch {
    Write-AppLog -Message "Failed to count call chains (agenticAPI.callChains may not exist): $_" -Level Debug
}
Write-Host "  Call chains: $chainCount workflows defined" -ForegroundColor White

# ── History Snapshot ──
if (-not $SkipHistory) {
    $histDir = Join-Path $ConfigDir 'agentic-manifest-history'
    if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Path $histDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $histPath = Join-Path $histDir "agentic-manifest_$stamp.json"
    Copy-Item $OutputPath $histPath -Force
    Write-Host "  Snapshot: $histPath" -ForegroundColor DarkGray
}

Write-Host "[AgenticManifest] Complete.`n" -ForegroundColor Green

# Return the manifest object for pipeline use
$manifest






