# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
#Requires -Version 5.1
<#
.SYNOPSIS
    WorkspaceIntentReview -- Intent sealing, indexed change logging, and development direction governance.
.DESCRIPTION
    Provides functions for:
      - Recording and reviewing development intent declarations
      - Sealing intents to pin development direction (prevents overrides without explicit unseal)
      - Indexed incremental change logging with timestamps and agent attribution
      - Intent history traversal with full audit trail
      - Integration with RE-memorAiZ pipeline for workspace memory continuity
# TODO: HelpMenu | Show-IntentReviewHelp | Actions: Review|Report|Classify|Help | Spec: config/help-menu-registry.json

    Intent States:
      DRAFT     -- Proposed intent, open for revision
      ACTIVE    -- Approved intent, guiding current development
      SEALED    -- Pinned direction, cannot be overridden without unseal
      ARCHIVED  -- Historical intent, no longer governing

    Change Log Schema:
      Each entry is indexed (monotonic), timestamped, attributed to an agent/user,
      and linked to the governing intent at time of change.

.NOTES
    Author   : The Establishment
    Date     : 2026-04-08
    FileRole : Module
    Version  : 2604.B2.V31.1
    Category : Workspace Governance
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

#  MODULE STATE

$script:IntentStorePath   = $null    # Set by Initialize-IntentStore
$script:ChangeLogPath     = $null
$script:IntentStore       = $null    # Loaded intent registry
$script:ChangeLog         = $null    # Loaded change log

#  INITIALIZATION

function Initialize-IntentStore {
    <#
    .SYNOPSIS  Initialize intent store and change log paths, create files if missing.
        .DESCRIPTION
      Detailed behaviour: Initialize intent store.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )

    $configDir = Join-Path $WorkspacePath 'config'
    if (-not (Test-Path $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }

    $script:IntentStorePath = Join-Path $configDir 'workspace-intent-registry.json'
    $script:ChangeLogPath   = Join-Path $configDir 'workspace-change-log.json'

    # Create intent store if missing
    if (-not (Test-Path $script:IntentStorePath)) {
        $initial = [ordered]@{
            '$schema'    = 'PwShGUI-IntentRegistry/1.0'
            lastUpdated  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            nextIntentId = 1
            intents      = @()
        }
        $initial | ConvertTo-Json -Depth 10 | Set-Content -Path $script:IntentStorePath -Encoding UTF8
    }

    # Create change log if missing
    if (-not (Test-Path $script:ChangeLogPath)) {
        $initial = [ordered]@{
            '$schema'    = 'PwShGUI-ChangeLog/1.0'
            lastUpdated  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            nextIndex    = 1
            entries      = @()
        }
        $initial | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ChangeLogPath -Encoding UTF8
    }

    # Load into memory
    $script:IntentStore = Get-Content $script:IntentStorePath -Raw | ConvertFrom-Json
    $script:ChangeLog   = Get-Content $script:ChangeLogPath -Raw | ConvertFrom-Json
}

function Save-IntentStore {
    <#
    .SYNOPSIS  Persist the in-memory intent store to disk.
    #>
    [CmdletBinding()]
    param()
    if ($null -eq $script:IntentStore -or $null -eq $script:IntentStorePath) { return }
    $script:IntentStore.lastUpdated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    $script:IntentStore | ConvertTo-Json -Depth 10 | Set-Content -Path $script:IntentStorePath -Encoding UTF8
}

function Save-ChangeLog {
    <#
    .SYNOPSIS  Persist the in-memory change log to disk.
        .DESCRIPTION
      Detailed behaviour: New development intent.
    #>
    [CmdletBinding()]
    param()
    if ($null -eq $script:ChangeLog -or $null -eq $script:ChangeLogPath) { return }
    $script:ChangeLog.lastUpdated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    $script:ChangeLog | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ChangeLogPath -Encoding UTF8
}

#  INTENT MANAGEMENT

function New-DevelopmentIntent {
    <#
    .SYNOPSIS  Create a new development intent declaration.
    .OUTPUTS   The created intent object.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Description,
        [string]$Author = $env:USERNAME,
        [ValidateSet('HIGH','MEDIUM','LOW')]
        [string]$Priority = 'MEDIUM',
        [string[]]$Tags = @(),
        [string[]]$AffectedModules = @(),
        [string[]]$AffectedScripts = @()
    )

    if ($null -eq $script:IntentStore) {
        Write-Warning 'Intent store not initialized. Call Initialize-IntentStore first.'
        return $null
    }

    $id = $script:IntentStore.nextIntentId
    $intent = [ordered]@{
        intentId        = $id
        title           = $Title
        description     = $Description
        status          = 'DRAFT'
        priority        = $Priority
        author          = $Author
        createdAt       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        updatedAt       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        sealedAt        = $null
        sealedBy        = $null
        unsealedAt      = $null
        tags            = $Tags
        affectedModules = $AffectedModules
        affectedScripts = $AffectedScripts
        history         = @(
            [ordered]@{
                action    = 'Created'
                timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
                by        = $Author
                detail    = "Intent #$id created: $Title"
            }
        )
    }

    $script:IntentStore.intents += $intent
    $script:IntentStore.nextIntentId = $id + 1
    Save-IntentStore
    return $intent
}

function Get-DevelopmentIntent {
    <#
    .SYNOPSIS  Retrieve intents by status filter or all.
        .DESCRIPTION
      Detailed behaviour: Get development intent.
    #>
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param(
        [ValidateSet('ALL','DRAFT','ACTIVE','SEALED','ARCHIVED')]
        [string]$Status = 'ALL',
        [int]$IntentId = 0
    )

    if ($null -eq $script:IntentStore) {
        Write-Warning 'Intent store not initialized. Call Initialize-IntentStore first.'
        return @()
    }

    $intents = @($script:IntentStore.intents)
    if ($IntentId -gt 0) {
        return @($intents | Where-Object { $_.intentId -eq $IntentId })
    }
    if ($Status -ne 'ALL') {
        return @($intents | Where-Object { $_.status -eq $Status })
    }
    return $intents
}

function Set-IntentStatus {
    <#
    .SYNOPSIS  Transition an intent to a new status.
        .DESCRIPTION
      Detailed behaviour: Set intent status.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$IntentId,
        [Parameter(Mandatory)][ValidateSet('DRAFT','ACTIVE','SEALED','ARCHIVED')]
        [string]$NewStatus,
        [string]$By = $env:USERNAME,
        [string]$Reason = ''
    )

    if ($null -eq $script:IntentStore) {
        Write-Warning 'Intent store not initialized.'
        return $null
    }

    $intent = $null
    $intents = @($script:IntentStore.intents)
    for ($i = 0; $i -lt @($intents).Count; $i++) {
        if ($intents[$i].intentId -eq $IntentId) {
            $intent = $intents[$i]
            break
        }
    }

    if ($null -eq $intent) {
        Write-Warning "Intent #$IntentId not found."
        return $null
    }

    $oldStatus = $intent.status

    # Enforce seal protection
    if ($oldStatus -eq 'SEALED' -and $NewStatus -ne 'ARCHIVED') {
        Write-Warning "Intent #$IntentId is SEALED. Use Invoke-IntentUnseal to unseal before changing status."
        return $null
    }

    $intent.status = $NewStatus
    $intent.updatedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')

    $historyEntry = [ordered]@{
        action    = "StatusChange: $oldStatus -> $NewStatus"
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        by        = $By
        detail    = if ($Reason -ne '') { $Reason } else { "Status changed from $oldStatus to $NewStatus" }
    }
    $intent.history += $historyEntry

    if ($NewStatus -eq 'SEALED') {
        $intent.sealedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        $intent.sealedBy = $By
    }

    Save-IntentStore
    return $intent
}

function Invoke-IntentSeal {
    <#
    .SYNOPSIS  Seal an intent to pin development direction. Sealed intents cannot be overridden.
        .DESCRIPTION
      Detailed behaviour: Invoke intent seal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$IntentId,
        [string]$By = $env:USERNAME,
        [string]$Reason = 'Intent sealed to pin development direction'
    )
    return Set-IntentStatus -IntentId $IntentId -NewStatus 'SEALED' -By $By -Reason $Reason
}

function Invoke-IntentUnseal {
    <#
    .SYNOPSIS  Unseal a sealed intent. Requires explicit action and reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$IntentId,
        [Parameter(Mandatory)][string]$Reason,
        [string]$By = $env:USERNAME
    )

    if ($null -eq $script:IntentStore) {
        Write-Warning 'Intent store not initialized.'
        return $null
    }

    $intent = $null
    $intents = @($script:IntentStore.intents)
    for ($i = 0; $i -lt @($intents).Count; $i++) {
        if ($intents[$i].intentId -eq $IntentId) {
            $intent = $intents[$i]
            break
        }
    }

    if ($null -eq $intent) {
        Write-Warning "Intent #$IntentId not found."
        return $null
    }

    if ($intent.status -ne 'SEALED') {
        Write-Warning "Intent #$IntentId is not SEALED (current: $($intent.status))."
        return $null
    }

    $intent.status = 'ACTIVE'
    $intent.unsealedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    $intent.updatedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')

    $historyEntry = [ordered]@{
        action    = 'Unsealed'
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        by        = $By
        detail    = "UNSEALED: $Reason"
    }
    $intent.history += $historyEntry

    Save-IntentStore
    return $intent
}

#  INDEXED CHANGE LOGGING

function Add-ChangeLogEntry {
    <#
    .SYNOPSIS  Record an indexed, timestamped change log entry.
    .OUTPUTS   The created change log entry.
        .DESCRIPTION
      Detailed behaviour: Add change log entry.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][ValidateSet('Created','Modified','Deleted','Refactored','Fixed','Enhanced','Sealed','Unsealed','Handback','PipelineRun')]
        [string]$ChangeType,
        [string]$Agent = $env:USERNAME,
        [string[]]$AffectedFiles = @(),
        [int]$GoverningIntentId = 0,
        [string]$VersionBefore = '',
        [string]$VersionAfter = ''
    )

    if ($null -eq $script:ChangeLog) {
        Write-Warning 'Change log not initialized. Call Initialize-IntentStore first.'
        return $null
    }

    $idx = $script:ChangeLog.nextIndex
    $entry = [ordered]@{
        index              = $idx
        timestamp          = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        changeType         = $ChangeType
        description        = $Description
        agent              = $Agent
        affectedFiles      = $AffectedFiles
        governingIntentId  = $GoverningIntentId
        versionBefore      = $VersionBefore
        versionAfter       = $VersionAfter
    }

    $script:ChangeLog.entries += $entry
    $script:ChangeLog.nextIndex = $idx + 1
    Save-ChangeLog
    return $entry
}

function Get-ChangeLogEntries {
    <#
    .SYNOPSIS  Retrieve change log entries with optional filtering.
        .DESCRIPTION
      Detailed behaviour: Get change log entries.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param(
        [int]$Last = 0,
        [string]$ChangeType = '',
        [string]$Agent = '',
        [int]$SinceIndex = 0,
        [int]$GoverningIntentId = 0
    )

    if ($null -eq $script:ChangeLog) {
        Write-Warning 'Change log not initialized.'
        return @()
    }

    $entries = @($script:ChangeLog.entries)

    if ($SinceIndex -gt 0) {
        $entries = @($entries | Where-Object { $_.index -ge $SinceIndex })
    }
    if ($ChangeType -ne '') {
        $entries = @($entries | Where-Object { $_.changeType -eq $ChangeType })
    }
    if ($Agent -ne '') {
        $entries = @($entries | Where-Object { $_.agent -eq $Agent })
    }
    if ($GoverningIntentId -gt 0) {
        $entries = @($entries | Where-Object { $_.governingIntentId -eq $GoverningIntentId })
    }
    if ($Last -gt 0) {
        $entries = @($entries | Select-Object -Last $Last)
    }

    return $entries
}

function Get-IntentHistory {
    <#
    .SYNOPSIS  Get the full audit trail for a specific intent, including related change log entries.
        .DESCRIPTION
      Detailed behaviour: Get intent history.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$IntentId
    )

    $intent = Get-DevelopmentIntent -IntentId $IntentId
    if (@($intent).Count -eq 0) {
        Write-Warning "Intent #$IntentId not found."
        return $null
    }

    $relatedChanges = Get-ChangeLogEntries -GoverningIntentId $IntentId

    return [ordered]@{
        intent         = $intent[0]
        intentHistory  = @($intent[0].history)
        relatedChanges = $relatedChanges
        summary        = [ordered]@{
            totalChanges   = @($relatedChanges).Count
            changeTypes    = @($relatedChanges | Group-Object -Property changeType | ForEach-Object { [ordered]@{ type = $_.Name; count = $_.Count } })
            agents         = @($relatedChanges | Group-Object -Property agent | ForEach-Object { [ordered]@{ agent = $_.Name; count = $_.Count } })
        }
    }
}

#  EXPORTS


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember -Function @(
    'Initialize-IntentStore',
    'New-DevelopmentIntent',
    'Get-DevelopmentIntent',
    'Set-IntentStatus',
    'Invoke-IntentSeal',
    'Invoke-IntentUnseal',
    'Add-ChangeLogEntry',
    'Get-ChangeLogEntries',
    'Get-IntentHistory'
)






