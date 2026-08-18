# VersionTag: 2608.B1.V1.0
# SupportPS5.1: YES
# SupportsPS7.6: YES
# FileRole: Module

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Join-VsCodePath {
    param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Child)
    if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
    return Join-Path $Base $Child
}

function Get-VsCodePathDiscovery {
    [CmdletBinding()]
    param(
        [string]$UserDataRoot,
        [string]$ProgramFilesRoot,
        [string]$LocalAppDataRoot,
        [string]$WorkspacePath
    )

    if ([string]::IsNullOrWhiteSpace($UserDataRoot)) { $UserDataRoot = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($ProgramFilesRoot)) { $ProgramFilesRoot = $env:ProgramFiles }
    if ([string]::IsNullOrWhiteSpace($LocalAppDataRoot)) { $LocalAppDataRoot = $env:LOCALAPPDATA }

    $channels = [ordered]@{}
    foreach ($channel in @('Stable', 'Insiders')) {
        $appName = if ($channel -eq 'Insiders') { 'Microsoft VS Code Insiders' } else { 'Microsoft VS Code' }
        $userName = if ($channel -eq 'Insiders') { 'Code - Insiders' } else { 'Code' }
        $installCandidates = @()
        if (-not [string]::IsNullOrWhiteSpace($ProgramFilesRoot)) {
            $installCandidates += Join-VsCodePath -Base $ProgramFilesRoot -Child $appName
        }
        if (-not [string]::IsNullOrWhiteSpace($LocalAppDataRoot)) {
            $programs = Join-VsCodePath -Base $LocalAppDataRoot -Child 'Programs'
            $installCandidates += Join-VsCodePath -Base $programs -Child $appName
        }
        $installRoot = ($installCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -First 1)
        $userRoot = if ($UserDataRoot) { Join-VsCodePath -Base $UserDataRoot -Child $userName } else { $null }
        $defaultPath = if ($installRoot) { Join-VsCodePath -Base (Join-VsCodePath -Base (Join-VsCodePath -Base $installRoot -Child 'resources') -Child 'app') -Child 'defaults\settings.json' } else { $null }
        $currentUserPath = if ($userRoot) { Join-VsCodePath -Base $userRoot -Child 'settings.json' } else { $null }
        $workspaceSettingsPath = $null
        if (-not [string]::IsNullOrWhiteSpace($WorkspacePath)) {
            $workspaceSettingsPath = Join-VsCodePath -Base (Join-VsCodePath -Base $WorkspacePath -Child '.vscode') -Child 'settings.json'
        }
        $channels[$channel] = [ordered]@{
            Channel              = $channel
            UserDataRoot         = $userRoot
            InstallRoot          = $installRoot
            InstallDefaultPath   = $defaultPath
            CurrentUserPath      = $currentUserPath
            CurrentWorkspacePath = $workspaceSettingsPath
            StableExecutable     = if ($installRoot) { Join-VsCodePath -Base $installRoot -Child 'bin\code.cmd' } else { $null }
        }
    }
    return $channels
}

function Remove-VsCodeJsonComments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Content)
    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false
    $i = 0
    while ($i -lt $Content.Length) {
        $ch = $Content.Substring($i, 1)
        $next = if (($i + 1) -lt $Content.Length) { $Content.Substring($i + 1, 1) } else { [char]0 }
        if ($lineComment) {
            if ($ch -eq "`r" -or $ch -eq "`n") { $lineComment = $false; [void]$builder.Append($ch) }
            else { [void]$builder.Append(' ') }
        }
        elseif ($blockComment) {
            if ($ch -eq '*' -and $next -eq '/') { $blockComment = $false; [void]$builder.Append(' '); $i++ }
            elseif ($ch -eq "`r" -or $ch -eq "`n") { [void]$builder.Append($ch) }
            else { [void]$builder.Append(' ') }
        }
        elseif ($inString) {
            [void]$builder.Append($ch)
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
        }
        elseif ($ch -eq '"') {
            $inString = $true; [void]$builder.Append($ch)
        }
        elseif ($ch -eq '/' -and $next -eq '/') {
            $lineComment = $true; [void]$builder.Append(' '); $i++
        }
        elseif ($ch -eq '/' -and $next -eq '*') {
            $blockComment = $true; [void]$builder.Append(' '); $i++
        }
        else { [void]$builder.Append($ch) }
        $i++
    }
    return ([regex]::Replace($builder.ToString(), ',\s*([}\]])', '$1'))
}

function ConvertFrom-VsCodeJsonc {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Content)
    $clean = Remove-VsCodeJsonComments -Content $Content
    return ($clean | ConvertFrom-Json -ErrorAction Stop)
}

function Test-VsCodeSecretKey {
    param([string]$KeyPath)
    return $KeyPath -match '(?i)(password|passwd|secret|token|api[-_]?key|apikey|credential|private[-_]?key|authorization|proxyAuthorization|certificate)'
}

function ConvertTo-VsCodeValueText {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [string]) { return $Value }
    return ($Value | ConvertTo-Json -Depth 10 -Compress)
}

function Add-VsCodeNormalizedRecords {
    param([Parameter(Mandatory)][object]$Value, [string]$KeyPath = '', [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$Records)
    if ($null -eq $Value) {
        [void]$Records.Add([ordered]@{ KeyPath = $KeyPath; Value = '[REDACTED]'; ValueType = 'Null'; Redacted = $true }); return
    }
    if (Test-VsCodeSecretKey -KeyPath $KeyPath) {
        [void]$Records.Add([ordered]@{ KeyPath = $KeyPath; Value = '[REDACTED]'; ValueType = 'Secret'; Redacted = $true }); return
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [PSCustomObject]) {
        $properties = @($Value.PSObject.Properties)
        if ($Value -is [System.Collections.IDictionary]) { $properties = @($Value.Keys | ForEach-Object { [PSCustomObject]@{ Name = [string]$_; Value = $Value[$_] } }) }
        if (@($properties).Count -eq 0 -and $KeyPath) { [void]$Records.Add([ordered]@{ KeyPath = $KeyPath; Value = '{}'; ValueType = 'Object'; Redacted = $false }); return }
        foreach ($property in $properties) {
            $childPath = if ($KeyPath) { "$KeyPath.$($property.Name)" } else { [string]$property.Name }
            $childValue = if ($Value -is [System.Collections.IDictionary]) { $property.Value } else { $property.Value }
            Add-VsCodeNormalizedRecords -Value $childValue -KeyPath $childPath -Records $Records
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @($Value)
        if (@($items).Count -eq 0) { [void]$Records.Add([ordered]@{ KeyPath = $KeyPath; Value = '[]'; ValueType = 'Array'; Redacted = $false }); return }
        for ($index = 0; $index -lt @($items).Count; $index++) {
            Add-VsCodeNormalizedRecords -Value $items[$index] -KeyPath "$KeyPath[$index]" -Records $Records
        }
        return
    }
    [void]$Records.Add([ordered]@{ KeyPath = $KeyPath; Value = (ConvertTo-VsCodeValueText -Value $Value); ValueType = $Value.GetType().Name; Redacted = $false })
}

function ConvertTo-VsCodeNormalizedRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document)
    $records = New-Object System.Collections.ArrayList
    Add-VsCodeNormalizedRecords -Value $Document -Records $records
    return @($records | Sort-Object KeyPath)
}

function New-VsCodeUnavailableSource {
    param([string]$Scope, [string]$BaselineKind, [string]$Channel, [string]$Path)
    return [ordered]@{ Scope = $Scope; BaselineKind = $BaselineKind; Channel = $Channel; Path = $Path; Available = $false; Records = @(); Error = 'Settings file unavailable' }
}

function Get-VsCodeSource {
    param([string]$Scope, [string]$BaselineKind, [string]$Channel, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return New-VsCodeUnavailableSource -Scope $Scope -BaselineKind $BaselineKind -Channel $Channel -Path $Path }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        $document = ConvertFrom-VsCodeJsonc -Content $raw
        return [ordered]@{ Scope = $Scope; BaselineKind = $BaselineKind; Channel = $Channel; Path = $Path; Available = $true; Records = @(ConvertTo-VsCodeNormalizedRecords -Document $document); Error = $null }
    }
    catch {
        return [ordered]@{ Scope = $Scope; BaselineKind = $BaselineKind; Channel = $Channel; Path = $Path; Available = $false; Records = @(); Error = $_.Exception.Message }
    }
}

function Get-VsCodeConfigSnapshot {
    [CmdletBinding()]
    param([string]$WorkspacePath, [hashtable]$Discovery)
    if ($null -eq $Discovery) { $Discovery = Get-VsCodePathDiscovery -WorkspacePath $WorkspacePath }
    $sources = New-Object System.Collections.ArrayList
    foreach ($channel in @($Discovery.Keys)) {
        $paths = $Discovery[$channel]
        [void]$sources.Add((Get-VsCodeSource -Scope 'user' -BaselineKind 'install-default' -Channel $channel -Path $paths.InstallDefaultPath))
        [void]$sources.Add((Get-VsCodeSource -Scope 'user' -BaselineKind 'current' -Channel $channel -Path $paths.CurrentUserPath))
        [void]$sources.Add((Get-VsCodeSource -Scope 'workspace' -BaselineKind 'current' -Channel $channel -Path $paths.CurrentWorkspacePath))
    }
    return [ordered]@{ Meta = [ordered]@{ SchemaVersion = '1.0'; CapturedOn = (Get-Date).ToString('o'); WorkspacePath = $WorkspacePath; Redaction = 'key-path' }; Sources = @($sources) }
}

function Get-VsCodeSourceForComparison {
    param([object[]]$Sources, [string]$Scope, [string]$Channel, [string]$BaselineKind)
    return @($Sources | Where-Object { $_.Scope -eq $Scope -and $_.Channel -eq $Channel -and $_.BaselineKind -eq $BaselineKind } | Select-Object -First 1)
}

function Compare-VsCodeConfigSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ReferenceSnapshot, [Parameter(Mandatory)]$CurrentSnapshot, [ValidateSet('user', 'workspace', 'combined')][string]$Scope = 'combined')
    $scopes = if ($Scope -eq 'combined') { @('user', 'workspace') } else { @($Scope) }
    $rows = New-Object System.Collections.ArrayList
    foreach ($currentSource in @($CurrentSnapshot.Sources | Where-Object { $scopes -contains $_.Scope -and $_.BaselineKind -eq 'current' })) {
        $baseline = Get-VsCodeSourceForComparison -Sources $ReferenceSnapshot.Sources -Scope 'user' -Channel $currentSource.Channel -BaselineKind 'install-default'
        if (@($baseline).Count -eq 0) { $baseline = Get-VsCodeSourceForComparison -Sources $CurrentSnapshot.Sources -Scope 'user' -Channel $currentSource.Channel -BaselineKind 'install-default' }
        $baselineMap = @{}; $currentMap = @{}
        if (@($baseline).Count -gt 0) { $baselineSource = $baseline | Select-Object -First 1; foreach ($record in @($baselineSource.Records)) { $baselineMap[$record.KeyPath] = $record } }
        foreach ($record in @($currentSource.Records)) { $currentMap[$record.KeyPath] = $record }
        $keys = @(@($baselineMap.Keys) + @($currentMap.Keys)) | Sort-Object -Unique
        if (-not $currentSource.Available -or @($baseline).Count -eq 0 -or -not $baseline.Available) {
            [void]$rows.Add([ordered]@{ Scope = $currentSource.Scope; Channel = $currentSource.Channel; KeyPath = '*'; Status = 'UNAVAILABLE'; ReferenceValue = $null; CurrentValue = $null; Reason = if ($currentSource.Error) { $currentSource.Error } else { 'Baseline unavailable' } }); continue
        }
        foreach ($key in $keys) {
            $hasReference = $baselineMap.ContainsKey($key); $hasCurrent = $currentMap.ContainsKey($key)
            $status = if (-not $hasReference) { 'ADDED' } elseif (-not $hasCurrent) { 'REMOVED' } elseif ($baselineMap[$key].Value -ne $currentMap[$key].Value) { 'CHANGED' } else { 'UNCHANGED' }
            $referenceValue = if ($hasReference) { $baselineMap[$key].Value } else { $null }
            $currentValue = if ($hasCurrent) { $currentMap[$key].Value } else { $null }
            $currentRedacted = if ($hasCurrent) { [bool]$currentMap[$key].Redacted } else { $false }
            $referenceRedacted = if ($hasReference) { [bool]$baselineMap[$key].Redacted } else { $false }
            [void]$rows.Add([ordered]@{ Scope = $currentSource.Scope; Channel = $currentSource.Channel; KeyPath = $key; Status = $status; ReferenceValue = $referenceValue; CurrentValue = $currentValue; Redacted = [bool]($currentRedacted -or $referenceRedacted) })
        }
    }
    return [ordered]@{ SchemaVersion = '1.0'; Scope = $Scope; GeneratedOn = (Get-Date).ToString('o'); Rows = @($rows | Sort-Object Scope, Channel, KeyPath); Summary = [ordered]@{ Unchanged = @($rows | Where-Object Status -EQ 'UNCHANGED').Count; Added = @($rows | Where-Object Status -EQ 'ADDED').Count; Removed = @($rows | Where-Object Status -EQ 'REMOVED').Count; Changed = @($rows | Where-Object Status -EQ 'CHANGED').Count; Unavailable = @($rows | Where-Object Status -EQ 'UNAVAILABLE').Count } }
}

function Get-VsCodeConfigRecommendations {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report, [ValidateSet('all', 'feature', 'menu', 'nature', 'security hardening', 'feature development', 'newly added configs/parameters')][string]$Category = 'all', [string]$Filter)
    $rules = @(
        @{ Pattern = '(?i)(workbench|editor|files|terminal|language)'; Category = 'feature'; Title = 'Review feature behavior'; Priority = 'MEDIUM' },
        @{ Pattern = '(?i)(menu|commandPalette|activityBar|contextMenu)'; Category = 'menu'; Title = 'Review menu and command visibility'; Priority = 'LOW' },
        @{ Pattern = '(?i)(theme|color|font|layout|zoom)'; Category = 'nature'; Title = 'Review presentation and workspace nature'; Priority = 'LOW' },
        @{ Pattern = '(?i)(security|trust|telemetry|proxy|certificate|credential|token|password)'; Category = 'security hardening'; Title = 'Apply security hardening review'; Priority = 'HIGH' },
        @{ Pattern = '(?i)(extension|language|debug|testing|git)'; Category = 'feature development'; Title = 'Consider developer workflow support'; Priority = 'MEDIUM' },
        @{ Pattern = '.*'; Category = 'newly added configs/parameters'; Title = 'Document newly added configuration'; Priority = 'MEDIUM' }
    )
    $items = New-Object System.Collections.ArrayList
    foreach ($row in @($Report.Rows | Where-Object { $_.Status -in @('ADDED', 'CHANGED', 'REMOVED') })) {
        foreach ($rule in $rules) {
            if ($row.KeyPath -match $rule.Pattern -and ($Category -eq 'all' -or $Category -eq $rule.Category) -and ([string]::IsNullOrWhiteSpace($Filter) -or $row.KeyPath -match [regex]::Escape($Filter) -or $rule.Title -match [regex]::Escape($Filter))) {
                [void]$items.Add([ordered]@{ Category = $rule.Category; KeyPath = $row.KeyPath; Scope = $row.Scope; Channel = $row.Channel; Status = $row.Status; Priority = $rule.Priority; Title = $rule.Title; Recommendation = "$($rule.Title): $($row.KeyPath) is $($row.Status.ToLowerInvariant())." }); break
            }
        }
    }
    return @($items | Sort-Object Priority, Category, KeyPath)
}

function New-VsCodeConfigCoverageReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$InstallBaseline, [ValidateSet('user', 'workspace', 'combined')][string]$Scope = 'combined', [string]$FilterCategory = 'all', [string]$Filter)
    $comparison = Compare-VsCodeConfigSnapshot -ReferenceSnapshot $InstallBaseline -CurrentSnapshot $Snapshot -Scope $Scope
    return [ordered]@{ SchemaVersion = '1.0'; GeneratedOn = (Get-Date).ToString('o'); Scope = $Scope; Snapshot = $Snapshot; Comparison = $comparison; Recommendations = @(Get-VsCodeConfigRecommendations -Report $comparison -Category $FilterCategory -Filter $Filter) }
}

Export-ModuleMember -Function @('Get-VsCodePathDiscovery', 'Remove-VsCodeJsonComments', 'ConvertFrom-VsCodeJsonc', 'ConvertTo-VsCodeNormalizedRecords', 'Get-VsCodeConfigSnapshot', 'Compare-VsCodeConfigSnapshot', 'Get-VsCodeConfigRecommendations', 'New-VsCodeConfigCoverageReport') # SIN-EXEMPT:P044 -- all exports have smoke coverage in tests\VsCodeConfigCoverage.Tests.ps1
