# VersionTag: 2607.B7.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: Data

[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')]
    [switch]$Build,

    [Parameter(ParameterSetName = 'Query')]
    [switch]$RunQuery,

    [Parameter(ParameterSetName = 'Schedule')]
    [switch]$RegisterSchedule,

    [Parameter(ParameterSetName = 'Schedule')]
    [switch]$UnregisterSchedule,

    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [string[]]$SearchRoots = @('docs', 'config', 'modules', 'scripts', 'tests'),
    [string[]]$IncludePatterns = @('*.md', '*.json', '*.ps1', '*.txt', '*.xhtml'),
    [string]$Query = '',
    [switch]$UseRegex,
    [int]$MaxResults = 400,
    [ValidateSet('Json', 'Markdown', 'Csv')]
    [string]$OutputFormat = 'Json',
    [string]$OutputPath = '',
    [switch]$SaveQuery,
    [string]$QueryName = '',
    [string]$TaskName = 'PwShGUI-ListRun-Scheduler',
    [string]$DailyAt = '02:00',
    [ValidateSet('Json', 'Markdown', 'Csv')]
    [string]$ScheduledOutputFormat = 'Markdown',
    [string]$ScheduledOutputPath = 'reports/listgene/listgene-scheduled-output.md'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
    param([Parameter(Mandatory)] [string]$BasePath, [Parameter(Mandatory)] [string]$RelativeOrAbsolute)

    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolute)) {
        return $RelativeOrAbsolute
    }

    return (Join-Path $BasePath $RelativeOrAbsolute)
}

function Get-ListGenePaths {
    param([Parameter(Mandatory)] [string]$Root)

    $configDir = Join-Path (Join-Path $Root 'config') 'listgene'
    $queryDir = Join-Path $configDir 'queries'
    $reportDir = Join-Path (Join-Path $Root 'reports') 'listgene'
    $docsDir = Join-Path $Root 'docs'

    foreach ($dir in @($configDir, $queryDir, $reportDir, $docsDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }

    [pscustomobject]@{
        ConfigDir = $configDir
        QueryDir = $queryDir
        ReportDir = $reportDir
        DocsDir = $docsDir
        GlobalListFile = Join-Path $configDir 'global-list-set.json'
    }
}

function Get-SystematicMarkdownIndex {
    param([Parameter(Mandatory)] [string]$Root)

    $mdFiles = @(Get-ChildItem -LiteralPath $Root -Filter '*.md' -Recurse -File -ErrorAction SilentlyContinue)
    $items = @()

    foreach ($file in $mdFiles) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\\') -replace '\\', '/'
        $lineCount = 0
        try {
            $lineCount = @((Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)).Count
        } catch {
            $lineCount = 0
        }

        $items += [pscustomobject]@{
            path = $relative
            sizeBytes = [int64]$file.Length
            lineCount = [int]$lineCount
            lastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
        }
    }

    return $items | Sort-Object path
}

function Get-SystemObservedLists {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string[]]$Roots,
        [Parameter(Mandatory)] [string[]]$Patterns
    )

    $hits = @()

    foreach ($searchRoot in $Roots) {
        $absRoot = Resolve-AbsolutePath -BasePath $Root -RelativeOrAbsolute $searchRoot
        if (-not (Test-Path -LiteralPath $absRoot)) { continue }

        foreach ($pattern in $Patterns) {
            $files = @(Get-ChildItem -LiteralPath $absRoot -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue)
            foreach ($file in $files) {
                $relative = $file.FullName.Substring($Root.Length).TrimStart('\\') -replace '\\', '/'

                $listSignals = @()
                try {
                    $listSignals = @(Select-String -Path $file.FullName -Pattern '^\s*[-*+]\s+|^\s*\d+\.\s+|@\(|\[(ordered)?\]\s*@\{' -SimpleMatch:$false -Encoding UTF8 -ErrorAction SilentlyContinue)
                } catch {
                    $listSignals = @()
                }

                if (@($listSignals).Count -gt 0) {
                    $hits += [pscustomobject]@{
                        path = $relative
                        signalCount = @($listSignals).Count
                        sample = @($listSignals | Select-Object -First 3 -ExpandProperty Line)
                    }
                }
            }
        }
    }

    return $hits | Sort-Object path
}

function Get-GlobalListSet {
    param([Parameter(Mandatory)] [string]$GlobalListFile)

    if (-not (Test-Path -LiteralPath $GlobalListFile)) {
        throw ('Global list file not found: ' + $GlobalListFile)
    }

    return Get-Content -LiteralPath $GlobalListFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Expand-GlobalEntries {
    param([Parameter(Mandatory)] [pscustomobject]$Global)

    $flat = New-Object System.Collections.ArrayList
    $categories = $Global.categories.PSObject.Properties.Name
    $seq = 0

    foreach ($category in $categories) {
        $items = @($Global.categories.$category)
        foreach ($item in $items) {
            $seq++
            if ($item -is [string]) {
                [void]$flat.Add([pscustomobject]@{
                    seq = $seq
                    category = $category
                    name = $item
                    value = $item
                    unicode = ''
                })
            } else {
                $name = ''
                $value = ''
                $unicode = ''
                if ($item.PSObject.Properties.Name -contains 'name') { $name = [string]$item.name }
                if ($item.PSObject.Properties.Name -contains 'value') { $value = [string]$item.value }
                if ($item.PSObject.Properties.Name -contains 'unicode') { $unicode = [string]$item.unicode }

                if ([string]::IsNullOrWhiteSpace($name)) { $name = $value }

                [void]$flat.Add([pscustomobject]@{
                    seq = $seq
                    category = $category
                    name = $name
                    value = $value
                    unicode = $unicode
                })
            }
        }
    }

    return @($flat)
}

function Find-UniversalListGeneMatches {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string[]]$Roots,
        [Parameter(Mandatory)] [string[]]$Patterns,
        [Parameter(Mandatory)] [string]$SearchTerm,
        [Parameter(Mandatory)] [bool]$Regex,
        [Parameter(Mandatory)] [int]$Take
    )

    if ([string]::IsNullOrWhiteSpace($SearchTerm)) {
        return @()
    }

    $all = @()
    foreach ($searchRoot in $Roots) {
        $absRoot = Resolve-AbsolutePath -BasePath $Root -RelativeOrAbsolute $searchRoot
        if (-not (Test-Path -LiteralPath $absRoot)) { continue }

        foreach ($pattern in $Patterns) {
            $files = @(Get-ChildItem -LiteralPath $absRoot -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue)
            foreach ($file in $files) {
                $queryHits = @()
                try {
                    $queryHits = @(Select-String -Path $file.FullName -Pattern $SearchTerm -SimpleMatch:(-not $Regex) -Encoding UTF8 -ErrorAction SilentlyContinue)
                } catch {
                    $queryHits = @()
                }

                foreach ($m in $queryHits) {
                    $relative = $file.FullName.Substring($Root.Length).TrimStart('\\') -replace '\\', '/'
                    $all += [pscustomobject]@{
                        path = $relative
                        line = [int]$m.LineNumber
                        text = [string]$m.Line.Trim()
                    }
                }
            }
        }
    }

    return @($all | Select-Object -First $Take)
}

function Convert-ResultToMarkdown {
    param([Parameter(Mandatory)] [pscustomobject]$Result)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Universal List Gene Output')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('GeneratedUtc: ' + (Get-Date).ToUniversalTime().ToString('o')))
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## Area 1 - Systematically Indexed Lists')
    [void]$sb.AppendLine('| Path | Lines | Bytes |')
    [void]$sb.AppendLine('|---|---:|---:|')
    foreach ($item in @($Result.area1_systematicallyIndexedLists)) {
        [void]$sb.AppendLine(('| ' + $item.path + ' | ' + $item.lineCount + ' | ' + $item.sizeBytes + ' |'))
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## Area 2 - System Obtained Lists and Arrays')
    [void]$sb.AppendLine('| Path | SignalCount | Sample |')
    [void]$sb.AppendLine('|---|---:|---|')
    foreach ($item in @($Result.area2_systemObservedListsAndArrays)) {
        $sample = @($item.sample) -join ' ; '
        [void]$sb.AppendLine(('| ' + $item.path + ' | ' + $item.signalCount + ' | ' + $sample.Replace('|', '\\|') + ' |'))
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## Area 3 - Global List Set')
    [void]$sb.AppendLine('| Seq | Category | Name | Value | Unicode |')
    [void]$sb.AppendLine('|---:|---|---|---|---|')
    foreach ($item in @($Result.area3_globalSequentialList)) {
        [void]$sb.AppendLine(('| ' + $item.seq + ' | ' + $item.category + ' | ' + $item.name + ' | ' + $item.value + ' | ' + $item.unicode + ' |'))
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## Area 4 - Universal List Gene Query Results')
    [void]$sb.AppendLine('| Path | Line | Text |')
    [void]$sb.AppendLine('|---|---:|---|')
    foreach ($item in @($Result.area4_universalListGeneResults)) {
        [void]$sb.AppendLine(('| ' + $item.path + ' | ' + $item.line + ' | ' + $item.text.Replace('|', '\\|') + ' |'))
    }

    return $sb.ToString()
}

function Write-ResultOutput {
    param(
        [Parameter(Mandatory)] [pscustomobject]$Result,
        [Parameter(Mandatory)] [string]$Format,
        [Parameter(Mandatory)] [string]$Path
    )

    $targetDir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($targetDir) -and -not (Test-Path -LiteralPath $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }

    if ($Format -eq 'Json') {
        $Result | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $Path -Encoding UTF8
        return
    }

    if ($Format -eq 'Csv') {
        @($Result.area3_globalSequentialList) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        return
    }

    Convert-ResultToMarkdown -Result $Result | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Save-QueryDefinition {
    param(
        [Parameter(Mandatory)] [string]$QueryDir,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$SearchTerm,
        [Parameter(Mandatory)] [bool]$Regex,
        [Parameter(Mandatory)] [string[]]$Roots,
        [Parameter(Mandatory)] [string[]]$Patterns,
        [Parameter(Mandatory)] [int]$Take,
        [Parameter(Mandatory)] [string]$OutputFormat,
        [Parameter(Mandatory)] [string]$OutputPath
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'QueryName is required when SaveQuery is used.'
    }

    $queryFile = Join-Path $QueryDir ($Name + '.json')
    $payload = [ordered]@{
        name = $Name
        query = $SearchTerm
        useRegex = [bool]$Regex
        searchRoots = @($Roots)
        includePatterns = @($Patterns)
        maxResults = [int]$Take
        outputFormat = $OutputFormat
        outputPath = $OutputPath
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    $payload | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $queryFile -Encoding UTF8
    return $queryFile
}

function Register-ListRunTask {
    param(
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [string]$TaskName,
        [Parameter(Mandatory)] [string]$Time,
        [Parameter(Mandatory)] [string]$OutputFormat,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$Workspace
    )

    $quotedScriptPath = '"' + $ScriptPath + '"'
    $quotedWorkspace = '"' + $Workspace + '"'
    $quotedOutputPath = '"' + $OutputPath + '"'

    $argText = '-NoProfile -ExecutionPolicy Bypass -File ' + $quotedScriptPath + ' -Build -WorkspacePath ' + $quotedWorkspace + ' -OutputFormat ' + $OutputFormat + ' -OutputPath ' + $quotedOutputPath

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argText
    $trigger = New-ScheduledTaskTrigger -Daily -At $Time

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Description 'PwShGUI ListRun Scheduling task for UniversalListGene.' -Force | Out-Null
}

$paths = Get-ListGenePaths -Root $WorkspacePath
$globalListSet = Get-GlobalListSet -GlobalListFile $paths.GlobalListFile

if ($UnregisterSchedule) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output ('Unregistered task: ' + $TaskName)
    } else {
        Write-Output ('Task not found: ' + $TaskName)
    }
    return
}

if ($RegisterSchedule) {
    Register-ListRunTask -ScriptPath $PSCommandPath -TaskName $TaskName -Time $DailyAt -OutputFormat $ScheduledOutputFormat -OutputPath (Resolve-AbsolutePath -BasePath $WorkspacePath -RelativeOrAbsolute $ScheduledOutputPath) -Workspace $WorkspacePath
    Write-Output ('Registered task: ' + $TaskName)
    return
}

if ($RunQuery -and [string]::IsNullOrWhiteSpace($Query)) {
    throw 'RunQuery requires -Query.'
}

$area1 = Get-SystematicMarkdownIndex -Root $WorkspacePath
$area2 = Get-SystemObservedLists -Root $WorkspacePath -Roots $SearchRoots -Patterns $IncludePatterns
$area3 = Expand-GlobalEntries -Global $globalListSet
$area4 = @()
if ($RunQuery) {
    $area4 = Find-UniversalListGeneMatches -Root $WorkspacePath -Roots $SearchRoots -Patterns $IncludePatterns -SearchTerm $Query -Regex ([bool]$UseRegex) -Take $MaxResults
}

$result = [pscustomobject]@{
    schema = 'PwShGUI-UniversalListGene/1.0'
    generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    mode = if ($RunQuery) { 'query' } else { 'build' }
    query = $Query
    area1_systematicallyIndexedLists = @($area1)
    area2_systemObservedListsAndArrays = @($area2)
    area3_globalSequentialList = @($area3)
    area4_universalListGeneResults = @($area4)
}

$resolvedOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($resolvedOutputPath)) {
    if ($OutputFormat -eq 'Json') {
        $resolvedOutputPath = Join-Path $paths.ReportDir 'listgene-output.json'
    } elseif ($OutputFormat -eq 'Csv') {
        $resolvedOutputPath = Join-Path $paths.ReportDir 'listgene-global.csv'
    } else {
        $resolvedOutputPath = Join-Path $paths.DocsDir 'LISTS-UNIVERSAL-LIST-GENE.md'
    }
} else {
    $resolvedOutputPath = Resolve-AbsolutePath -BasePath $WorkspacePath -RelativeOrAbsolute $resolvedOutputPath
}

Write-ResultOutput -Result $result -Format $OutputFormat -Path $resolvedOutputPath

if ($SaveQuery) {
    $queryFilePath = Save-QueryDefinition -QueryDir $paths.QueryDir -Name $QueryName -SearchTerm $Query -Regex ([bool]$UseRegex -or $false) -Roots $SearchRoots -Patterns $IncludePatterns -Take $MaxResults -OutputFormat $OutputFormat -OutputPath $resolvedOutputPath
    Write-Output ('Saved query: ' + $queryFilePath)
}

Write-Output $result

