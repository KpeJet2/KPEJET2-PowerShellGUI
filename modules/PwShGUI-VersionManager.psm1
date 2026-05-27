# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
#Requires -Version 5.1
<#
.SYNOPSIS
    PwShGUI-VersionManager -- Major.Minor versioning, CPSR HTML reports, and checkpoint epoch management.
# TODO: HelpMenu | Show-VersionManagerHelp | Actions: Bump|Align|Audit|Tag|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
    Implements the versioning standard:
      - VersionTag format: YYMM.B<build>.V<major>.<minor>  (V is always uppercase)
      - Minor version increments per pipeline session change (file-by-file)
      - Major build ("Build NEXT NEW MAJOR Version.0") raises all workspace major versions,
        resets all minors to 0, with missing minor shown as "Zero.Null"
      - After Major Build, manifest and meta-tagged versions align with minor=0

    Chief Project Summary Report (CPSR):
      - HTML reports logging every pipeline action with before/after versions
      - Named: Major.Minor-CPSR-yyyymmdd-hhmm.html
      - Subfolder per date under ~REPORTS/CPSR/CPSR_yyyymmdd
      - Aggregation overview when >1 CPSR exists in subfolder

    Checkpoint Epochs:
      - Pipeline processing epochs saved as JSON snapshots
      - Matched to memory store resume artifacts

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 29th March 2026
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ========================== VERSION CONSTANTS ==========================

$script:VersionPrefix   = '2604.B2'
$script:CurrentMajor    = 31
$script:CurrentMinor    = 0
$script:VersionPattern  = '^#\s*VersionTag:\s*(\S+)'
$script:ZeroNullString  = 'Zero.Null'

# ========================== VERSION PARSING ==========================

function ConvertFrom-VersionTag {
    <#
    .SYNOPSIS  Parse a VersionTag string into components.
    .OUTPUTS   Hashtable with prefix, major, minor, full.
        .DESCRIPTION
      Detailed behaviour: ConvertFrom version tag.
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tag)

    # Format: 2604.B1.V1.0  (V uppercase, minor always present)
    # Also accepts legacy lowercase v for backward-compatible read of old tags
    if ($Tag -match '^(\d{4}\.B\d+)\.[Vv](\d+)(?:\.(\d+))?$') {
        $prefix = $Matches[1]
        $major  = [int]$Matches[2]
        $minor  = if ($null -ne $Matches[3] -and $Matches[3] -ne '') { [int]$Matches[3] } else { 0 }
        $hasMinor = ($null -ne $Matches[3] -and $Matches[3] -ne '')
        return @{
            prefix      = $prefix
            major       = $major
            minor       = $minor
            full        = "$prefix.V$major.$minor"
            display     = "$prefix.V$major.$minor"
            isZeroNull  = ($minor -eq 0 -and -not $hasMinor)
        }
    }
    return $null
}

function Format-VersionTag {
    <#
    .SYNOPSIS  Build a VersionTag string from components.
        .DESCRIPTION
      Detailed behaviour: Format version tag.
    #>
    [OutputType([System.String])]
    [CmdletBinding()]
    param(
        [string]$Prefix = $script:VersionPrefix,
        [int]$Major = $script:CurrentMajor,
        [int]$Minor = 0
    )
    return "$Prefix.V$Major.$Minor"
}

# ========================== FILE VERSION OPERATIONS ==========================

function Get-FileVersion {
    <#
    .SYNOPSIS  Read the VersionTag from a file.
    .OUTPUTS   Parsed version hashtable or $null.
        .DESCRIPTION
      Detailed behaviour: Get file version.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $null }
    $match = Select-String -Path $FilePath -Pattern $script:VersionPattern | Select-Object -First 1
    if ($match -and $match.Matches[0].Groups[1].Value) {
        return ConvertFrom-VersionTag -Tag $match.Matches[0].Groups[1].Value
    }
    return $null
}

function Set-FileVersion {
    <#
    .SYNOPSIS  Update the VersionTag in a file. Returns before/after info.
        .DESCRIPTION
      Detailed behaviour: Set file version.
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$NewTag
    )
    $before = Get-FileVersion -FilePath $FilePath
    $content = Get-Content $FilePath -Raw
    $newContent = $content -replace '(#\s*VersionTag:\s*)\S+', "`${1}$NewTag"
    Set-Content -Path $FilePath -Value $newContent -Encoding UTF8 -NoNewline
    $after = Get-FileVersion -FilePath $FilePath
    return @{ file = $FilePath; before = $before; after = $after; newTag = $NewTag }
}

function Step-MinorVersion {
    <#
    .SYNOPSIS  Increment the minor version of a specific file.
    .OUTPUTS   Version change record.
        .DESCRIPTION
      Detailed behaviour: Step minor version.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)
    $current = Get-FileVersion -FilePath $FilePath
    if (-not $current) {
        Write-AppLog -Message "No VersionTag found in $FilePath" -Level Warning
        return $null
    }
    $newMinor = $current.minor + 1
    $newTag = Format-VersionTag -Prefix $current.prefix -Major $current.major -Minor $newMinor
    return Set-FileVersion -FilePath $FilePath -NewTag $newTag
}

function Invoke-MajorBuildIncrement {
    <#
    .SYNOPSIS  "Build NEXT NEW MAJOR Version.0" -- raise all workspace major versions,
               reset all minors to 0. Missing minor = "Zero.Null" display.
    .DESCRIPTION
        Scans all .ps1, .psm1, .md, .json files with VersionTag lines.
        Increments major version by 1, sets minor to 0 on every file.
        Returns full change manifest.
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [int]$NewMajor = 0
    )

    $files = Get-ChildItem -Path $WorkspacePath -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\|\\\.history\\|\\node_modules\\|\\__pycache__\\' }

    $changes = @()
    foreach ($file in $files) {
        $ver = Get-FileVersion -FilePath $file.FullName
        if ($ver) {
            $targetMajor = if ($NewMajor -gt 0) { $NewMajor } else { $ver.major + 1 }
            $newTag = Format-VersionTag -Prefix $ver.prefix -Major $targetMajor -Minor 0
            $change = Set-FileVersion -FilePath $file.FullName -NewTag $newTag
            $change.displayNote = "$($script:VersionPrefix).V$targetMajor.0"
            $changes += $change
        }
    }

    # Update pipeline registry meta
    $pipelinePath = Join-Path $WorkspacePath 'config\cron-aiathon-pipeline.json'
    if (Test-Path $pipelinePath) {
        $reg = Get-Content $pipelinePath -Raw | ConvertFrom-Json
        $targetMajor = if ($NewMajor -gt 0) { $NewMajor } else { $script:CurrentMajor + 1 }
        $reg.meta | Add-Member -NotePropertyName buildVersion -NotePropertyValue (Format-VersionTag -Prefix $script:VersionPrefix -Major $targetMajor -Minor 0) -Force
        $reg.meta | Add-Member -NotePropertyName lastMajorBuild -NotePropertyValue (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') -Force
        $reg | ConvertTo-Json -Depth 10 | Set-Content $pipelinePath -Encoding UTF8
    }

    $script:CurrentMajor = if ($NewMajor -gt 0) { $NewMajor } else { $script:CurrentMajor + 1 }
    $script:CurrentMinor = 0

    return @{
        newMajor   = $script:CurrentMajor
        newMinor   = 0
        display    = "$($script:VersionPrefix).V$($script:CurrentMajor).0"
        filesChanged = $changes.Count
        changes    = $changes
    }
}

function Get-WorkspaceVersionInventory {
    <#
    .SYNOPSIS  Scan all workspace files and return version inventory.
        .DESCRIPTION
      Detailed behaviour: Get workspace version inventory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath)

    $files = Get-ChildItem -Path $WorkspacePath -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\|\\\.history\\|\\node_modules\\|\\__pycache__\\' }

    $inventory = @()
    foreach ($file in $files) {
        $ver = Get-FileVersion -FilePath $file.FullName
        if ($ver) {
            $inventory += @{
                file    = $file.FullName
                name    = $file.Name
                version = $ver
            }
        }
    }
    return $inventory
}

# ========================== CPSR (Chief Project Summary Report) ==========================

$script:CPSRActionsFile = Join-Path $PSScriptRoot "..\temp\cpsr-actions-session.json"
$script:CPSRSessionId = if (Test-Path (Join-Path $PSScriptRoot "..\temp\cpsr-session-id.txt")) { Get-Content (Join-Path $PSScriptRoot "..\temp\cpsr-session-id.txt") -Raw } else { $id = [guid]::NewGuid().ToString().Substring(0,8); $id | Set-Content (Join-Path $PSScriptRoot "..\temp\cpsr-session-id.txt") -Encoding UTF8; $id }
$script:CPSRStartTime = Get-Date

function Add-CPSRAction {
    <#
    .SYNOPSIS  Log an action to the current CPSR session.
        .DESCRIPTION
      Detailed behaviour: Add c p s r action.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$Agent = 'CronAiAthon',
        [string]$ItemId = '',
        [string]$ItemType = '',
        [string]$VersionBefore = '',
        [string]$VersionAfter = '',
        [string]$Detail = '',
        [string]$ChatInput = ''
    )
    $entry = [ordered]@{
        timestamp     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        action        = $Action
        agent         = $Agent
        itemId        = $ItemId
        itemType      = $ItemType
        versionBefore = $VersionBefore
        versionAfter  = $VersionAfter
        detail        = $Detail
        chatInput     = $ChatInput
        sessionId     = $script:CPSRSessionId
    }
    $line = $entry | ConvertTo-Json -Depth 5 -Compress; Add-Content -Path $script:CPSRActionsFile -Value $line -Encoding UTF8
    return $entry
}

function Export-CPSRReport {
    <#
    .SYNOPSIS  Generate CPSR HTML report and save to ~REPORTS/CPSR/CPSR_yyyymmdd/ subfolder.
    .OUTPUTS   Path to generated HTML file.
        .DESCRIPTION
      Detailed behaviour: Export c p s r report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$MajorVersion = "$($script:CurrentMajor)",
        [string]$MinorVersion = "$($script:CurrentMinor)"
    )

    $now = Get-Date
    $dateFolder = "CPSR_$($now.ToString('yyyyMMdd'))"
    $cpsrDir = Join-Path $WorkspacePath "~REPORTS\CPSR\$dateFolder"
    if (-not (Test-Path $cpsrDir)) { New-Item -ItemType Directory -Path $cpsrDir -Force | Out-Null }

    $fileName = "$MajorVersion.$MinorVersion-CPSR-$($now.ToString('yyyyMMdd'))-$($now.ToString('HHmm')).html"
    $filePath = Join-Path $cpsrDir $fileName

    $actionRows = ''
    $allActions = @(if (Test-Path $script:CPSRActionsFile) { Get-Content $script:CPSRActionsFile | ForEach-Object { $_ | ConvertFrom-Json } } else { @() })
    foreach ($a in $allActions) {
        $safeDetail = [System.Net.WebUtility]::HtmlEncode($a.detail)
        $safeChat   = if ($a.chatInput -and $a.chatInput.Length -gt 0) {
            [System.Net.WebUtility]::HtmlEncode($a.chatInput)
        } else { '-' }
        $actionRows += @"
        <tr>
            <td>$($a.timestamp)</td>
            <td>$($a.action)</td>
            <td>$($a.agent)</td>
            <td>$($a.itemId)</td>
            <td>$($a.itemType)</td>
            <td>$($a.versionBefore)</td>
            <td>$($a.versionAfter)</td>
            <td>$safeDetail</td>
            <td>$safeChat</td>
        </tr>`n
"@
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8" />
    <title>CPSR $MajorVersion.$MinorVersion -- $($now.ToString('yyyy-MM-dd HH:mm'))</title>
    <style>
        body { font-family: 'Segoe UI', Consolas, monospace; background: #1e1e1e; color: #d4d4d4; margin: 20px; }
        h1 { color: #007acc; border-bottom: 2px solid #007acc; padding-bottom: 8px; }
        h2 { color: #4ec9b0; }
        table { border-collapse: collapse; width: 100%; margin: 16px 0; }
        th { background: #252526; color: #007acc; padding: 8px 10px; text-align: left; border-bottom: 2px solid #007acc; }
        td { padding: 6px 10px; border-bottom: 1px solid #333; font-size: 0.9em; }
        tr:hover { background: #2a2d2e; }
        .meta { background: #252526; padding: 12px 16px; border-radius: 6px; margin: 12px 0; }
        .meta span { color: #ce9140; font-weight: bold; }
        .epoch-badge { display: inline-block; background: #007acc; color: #fff; padding: 2px 10px; border-radius: 12px; font-size: 0.85em; }
        .zero-null { color: #ce9140; font-style: italic; }
    </style>
</head>
<body>
    <h1>Chief Project Summary Report</h1>
    <div class="meta">
        <span>Session ID:</span> $($script:CPSRSessionId) &nbsp; | &nbsp;
        <span>Build Version:</span> $($script:VersionPrefix).V$MajorVersion.$MinorVersion &nbsp; | &nbsp;
        <span>Generated:</span> $($now.ToString('yyyy-MM-dd HH:mm:ss')) &nbsp; | &nbsp;
        <span>Actions Logged:</span> $($(if (Test-Path $script:CPSRActionsFile) { @(Get-Content $script:CPSRActionsFile).Count } else { 0 })) &nbsp; | &nbsp;
        <span class="epoch-badge">Epoch Checkpoint</span>
    </div>

    <h2>Pipeline Actions Log</h2>
    <table>
        <thead>
            <tr>
                <th>Timestamp</th>
                <th>Action</th>
                <th>Agent</th>
                <th>Item ID</th>
                <th>Item Type</th>
                <th>Version Before</th>
                <th>Version After</th>
                <th>Detail</th>
                <th>Chat Input</th>
            </tr>
        </thead>
        <tbody>
$actionRows
        </tbody>
    </table>

    <h2>Version State at Report Time</h2>
    <div class="meta">
        <span>Major:</span> $MajorVersion &nbsp; | &nbsp;
        <span>Minor:</span> $MinorVersion &nbsp; | &nbsp;
        <span>Full Tag:</span> $($script:VersionPrefix).V$MajorVersion.$MinorVersion
    </div>
</body>
</html>
"@

    Set-Content -Path $filePath -Value $html -Encoding UTF8
    return $filePath
}

function Export-CPSRAggregation {
    <#
    .SYNOPSIS  Generate aggregation overview HTML when >1 CPSR exists in a date subfolder.
        .DESCRIPTION
      Detailed behaviour: Export c p s r aggregation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$DateFolder = ''
    )

    if (-not $DateFolder) { $DateFolder = "CPSR_$(Get-Date -Format 'yyyyMMdd')" }
    $cpsrDir = Join-Path $WorkspacePath "~REPORTS\CPSR\$DateFolder"
    if (-not (Test-Path $cpsrDir)) { return $null }

    $cpsrFiles = Get-ChildItem -Path $cpsrDir -Filter '*.html' | Where-Object { $_.Name -notmatch '^OVERVIEW-' }
    if ($cpsrFiles.Count -lt 2) { return $null }

    $fileRows = ''
    foreach ($f in ($cpsrFiles | Sort-Object Name)) {
        $fileRows += "        <tr><td><a href=`"$($f.Name)`">$($f.Name)</a></td><td>$($f.LastWriteTime.ToString('HH:mm:ss'))</td><td>$([math]::Round($f.Length / 1024, 1)) KB</td></tr>`n"
    }

    $now = Get-Date
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8" />
    <title>CPSR Aggregation -- $DateFolder</title>
    <style>
        body { font-family: 'Segoe UI', Consolas, monospace; background: #1e1e1e; color: #d4d4d4; margin: 20px; }
        h1 { color: #007acc; }
        table { border-collapse: collapse; width: 60%; margin: 16px 0; }
        th { background: #252526; color: #4ec9b0; padding: 8px; text-align: left; }
        td { padding: 6px 8px; border-bottom: 1px solid #333; }
        a { color: #007acc; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <h1>CPSR Aggregation: $DateFolder</h1>
    <p>Generated: $($now.ToString('yyyy-MM-dd HH:mm:ss')) | Reports in folder: $($cpsrFiles.Count)</p>
    <table>
        <thead><tr><th>Report</th><th>Time</th><th>Size</th></tr></thead>
        <tbody>
$fileRows
        </tbody>
    </table>
</body>
</html>
"@
    $aggPath = Join-Path $cpsrDir "OVERVIEW-$DateFolder.html"
    Set-Content -Path $aggPath -Value $html -Encoding UTF8
    return $aggPath
}

# ========================== CHECKPOINT EPOCHS ==========================

function Save-PipelineEpoch {
    <#
    .SYNOPSIS  Save a pipeline checkpoint epoch for work resumption.
    .DESCRIPTION
        Captures current state: version inventory, CPSR actions, pipeline stats.
        Saved to checkpoints/ and referenced in memory store.
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$Phase = 'unknown',
        [string]$Description = ''
    )

    $epochId = [guid]::NewGuid().ToString().Substring(0,8)
    $now = Get-Date

    $epoch = [ordered]@{
        epochId       = $epochId
        timestamp     = $now.ToString('yyyy-MM-ddTHH:mm:ss')
        sessionId     = $script:CPSRSessionId
        phase         = $Phase
        description   = $Description
        versionState  = @{
            major     = $script:CurrentMajor
            minor     = $script:CurrentMinor
            fullTag   = Format-VersionTag
        }
        actionCount   = $(if (Test-Path $script:CPSRActionsFile) { @(Get-Content $script:CPSRActionsFile).Count } else { 0 })
        lastAction    = if ($(if (Test-Path $script:CPSRActionsFile) { @(Get-Content $script:CPSRActionsFile).Count } else { 0 }) -gt 0) { (Get-Content $script:CPSRActionsFile | Select-Object -Last 1 | ConvertFrom-Json) } else { $null }
        cpsrSessionId = $script:CPSRSessionId
    }

    $epochDir = Join-Path $WorkspacePath 'checkpoints'
    if (-not (Test-Path $epochDir)) { New-Item -ItemType Directory -Path $epochDir -Force | Out-Null }
    $epochPath = Join-Path $epochDir "epoch-$($Phase)-$epochId.json"
    $epoch | ConvertTo-Json -Depth 5 | Set-Content -Path $epochPath -Encoding UTF8

    # Update index
    $indexPath = Join-Path $epochDir '_index.json'
    $index = @{}
    if (Test-Path $indexPath) {
        $index = Get-Content $indexPath -Raw | ConvertFrom-Json
        $props = @{}
        $index.PSObject.Properties | ForEach-Object { $props[$_.Name] = $_.Value }
        $index = $props
    }
    $index["epoch-$epochId"] = "checkpoints/epoch-$($Phase)-$epochId.json"
    $index | ConvertTo-Json -Depth 3 | Set-Content $indexPath -Encoding UTF8

    return @{ epochId = $epochId; path = $epochPath; phase = $Phase }
}

function Add-AgentEditLedgerEntry {
    <#
    .SYNOPSIS  Record a single agent coding edit to the per-major-version ledger.
    .DESCRIPTION
        Appends an edit entry to checkpoints/ledger-v{Major}.json.
        Creates the ledger file on first call for a given major version.
        Each entry records which files were modified and their version before/after.
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$AgentId     = 'CronAiAthon',
        [string]$TaskType    = 'edit',
        [string]$Description = '',
        [array]$FilesModified = @()
    )

    $epochDir = Join-Path $WorkspacePath 'checkpoints'
    if (-not (Test-Path $epochDir)) { New-Item -ItemType Directory -Path $epochDir -Force | Out-Null }

    $ledgerPath = Join-Path $epochDir "ledger-v$($script:CurrentMajor).json"

    $ledger = $null
    if (Test-Path $ledgerPath) {
        try { $ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json } catch { <# Intentional: file may have invalid JSON, will recreate #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    }
    if ($null -eq $ledger) {
        $ledger = [ordered]@{
            ledgerVersion = '1'
            workspace     = $WorkspacePath
            majorVersion  = $script:CurrentMajor
            created       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            edits         = @()
        }
    }

    $entry = [ordered]@{
        epochId       = [guid]::NewGuid().ToString().Substring(0, 8)
        timestamp     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        agentId       = $AgentId
        taskType      = $TaskType
        description   = $Description
        sessionId     = $script:CPSRSessionId
        filesModified = @($FilesModified)
    }

    # Ensure edits is mutable array
    $existingEdits = @(if ($ledger.edits) { $ledger.edits } else { @() })
    $existingEdits += $entry
    $ledger.edits = $existingEdits

    $ledger | ConvertTo-Json -Depth 8 | Set-Content -Path $ledgerPath -Encoding UTF8
    return @{ ledgerPath = $ledgerPath; epochId = $entry.epochId; editCount = $existingEdits.Count }
}

function Get-LatestEpoch {
    <#
    .SYNOPSIS  Load the most recent pipeline epoch checkpoint.
        .DESCRIPTION
      Detailed behaviour: Get latest epoch.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath)

    $epochDir = Join-Path $WorkspacePath 'checkpoints'
    $epochs = Get-ChildItem -Path $epochDir -Filter 'epoch-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($epochs) {
        return Get-Content $epochs.FullName -Raw | ConvertFrom-Json
    }
    return $null
}

# ========================== EXPORTS ==========================

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
# Back-compat alias (P030: Parse- is unapproved; canonical is ConvertFrom-VersionTag)
Set-Alias -Name Parse-VersionTag -Value ConvertFrom-VersionTag -Scope Script -Force

Export-ModuleMember -Function @(
    'ConvertFrom-VersionTag',
    'Format-VersionTag',
    'Get-FileVersion',
    'Set-FileVersion',
    'Step-MinorVersion',
    'Invoke-MajorBuildIncrement',
    'Get-WorkspaceVersionInventory',
    'Add-CPSRAction',
    'Export-CPSRReport',
    'Export-CPSRAggregation',
    'Save-PipelineEpoch',
    'Get-LatestEpoch',
    'Add-AgentEditLedgerEntry'
) -Alias 'Parse-VersionTag'








