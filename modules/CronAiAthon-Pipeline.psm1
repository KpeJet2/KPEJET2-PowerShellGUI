# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
#Requires -Version 5.1
<#
.SYNOPSIS
    Cron-Ai-Athon Pipeline Registry -- unified pipeline for Feature Requests,
    Bugs2FIX, Items2ADD, ToDo items, and Sin Registry feedback loop.
# TODO: HelpMenu | Show-PipelineHelp | Actions: Register|Run|Status|Reset|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
    Central module that manages the full lifecycle:
      Feature Request Entry -> Planning (async subagent) -> ToDo -> Execution
      Bug Tracking -> Past Sins match -> Bugs2FIX / Items2ADD -> ToDo
      Aggregation into Central Master ToDo list.

    Pipeline item types:
      - FeatureRequest : New feature proposals
      - Bug            : Detected defects from any source
      - Items2ADD      : New items derived from bug analysis or autopilot suggestions
      - Bugs2FIX       : Bugs queued for fix implementation
      - ToDo           : Planned work items (from any source)

    Each item carries a session modification counter starting at 1.
    v26: Added outline schema v0, status machine, batch transitions,
         health metrics, bundle regeneration, category taxonomy.

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V32.0
    Created  : 28th March 2026
    Modified : 4th April 2026

.LINK
    ~README.md/VERSION-UPDATES.md
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name Write-AppLog -ErrorAction SilentlyContinue)) {
    function Write-AppLog {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Interactive UI banner / CLI progress output; intentional Write-Host for human-readable terminal display.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Message,

            [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
            [string]$Level = 'Info'
        )

        $color = switch ($Level) {
            'Error' { 'Red' }
            'Warning' { 'Yellow' }
            'Debug' { 'DarkGray' }
            default { 'Gray' }
        }

        Write-Host "[CronAiAthon][$Level] $Message" -ForegroundColor $color
    }
}

# ========================== PIPELINE ITEM SCHEMA ==========================

function New-PipelineItem {
    <#
    .SYNOPSIS  Create a new pipeline item with full metadata and session counter.
    .PARAMETER Type       FeatureRequest | Bug | Items2ADD | Bugs2FIX | ToDo
    .PARAMETER Title      Short descriptive title.
    .PARAMETER Description Detailed description.
    .PARAMETER Priority   CRITICAL | HIGH | MEDIUM | LOW
    .PARAMETER Source     Origin: Manual | AutoCron | Subagent | BugTracker | SinRegistry
    .PARAMETER Category   Functional category tag.
    .PARAMETER AffectedFiles  Array of file paths affected.
    .OUTPUTS   [hashtable] The new pipeline item.
        .DESCRIPTION
      Detailed behaviour: New pipeline item.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('FeatureRequest','Bug','Items2ADD','Bugs2FIX','ToDo')]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Title,

        [string]$Description = '',

        [ValidateSet('CRITICAL','HIGH','MEDIUM','LOW')]
        [string]$Priority = 'MEDIUM',

        [ValidateSet('Manual','AutoCron','Subagent','BugTracker','SinRegistry')]
        [string]$Source = 'Manual',

        [string]$Category = 'general',
        [string[]]$AffectedFiles = @(),
        [string]$SuggestedBy = 'Commander',
        [string]$SinId = '',
        [string]$ParentId = '',
        [string[]]$BugReferrals = @(),
        [string]$OutlineTag = 'OUTLINE-PROTO-v0',
        [string]$OutlinePhase = 'assessment',
        [string]$OutlineVersion = 'v0'
    )
    if (-not $PSCmdlet.ShouldProcess('New-PipelineItem', 'Create')) { return }


    $id = "$Type-" + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + ([guid]::NewGuid().ToString().Substring(0,8))

    return [ordered]@{
        id               = $id
        type             = $Type
        title            = $Title
        description      = $Description
        priority         = $Priority
        status           = 'OPEN'
        source           = $Source
        category         = $Category
        suggestedBy      = $SuggestedBy
        affectedFiles    = $AffectedFiles
        sinId            = $SinId
        parentId         = $ParentId
        created          = (Get-Date).ToUniversalTime().ToString('o')
        modified         = (Get-Date).ToUniversalTime().ToString('o')
        acknowledged     = $null
        plannedAt        = $null
        executedAt       = $null
        completedAt      = $null
        sessionModCount  = 1
        executionAgent   = ''
        executionMethod  = ''
        tags             = @()
        notes            = ''
        linkedBugs       = @()
        linkedFeatures   = @()
        result           = $null
        outlineTag               = $OutlineTag
        outlinePhase             = $OutlinePhase
        outlineVersion           = $OutlineVersion
        bugReferrals             = $BugReferrals
        bugResurfaced            = $false
        firstSeenAt              = (Get-Date).ToUniversalTime().ToString('o')
        lastSeenAt               = (Get-Date).ToUniversalTime().ToString('o')
        implementedAt            = $null
        reopenedAt               = $null
        fixesImplementedCount    = 0
        filesFixedCount          = 0
        filesRemainingCount      = 0
        countermeasures          = @()
        bugHistory               = @()
    }
}

# ========================== PIPELINE REGISTRY ==========================

<#
.SYNOPSIS
  Get pipeline registry path.
.DESCRIPTION
  Detailed behaviour: Initialize pipeline registry.
#>
function Get-PipelineRegistryPath {
    param([string]$WorkspacePath)
    return (Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-pipeline.json')
}

function Initialize-PipelineRegistry {
    <#
    .SYNOPSIS  Create or load the pipeline registry JSON.
    .NOTES     v27 - Added error handling per Section 12 + Template 3
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath
    )

    $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath

    # Try to load existing registry
    if (Test-Path $regPath) {
        try {
            $raw = Get-Content $regPath -Raw -ErrorAction Stop
            if ($raw -and $raw.Trim().Length -gt 0) {
                $loaded = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $loaded -and $null -ne $loaded.meta) {
                    Write-AppLog -Message "Pipeline registry loaded from $regPath" -Level Debug
                    return $loaded
                }
            }
        } catch {
            Write-AppLog -Message "Failed to load pipeline registry from $regPath : $_. Creating new registry." -Level Warning
            # Fall through to create new registry
        }
    }

    # Create new registry
    $registry = [ordered]@{
        meta = [ordered]@{
            schema        = 'CronAiAthon-Pipeline/1.1'
            outlineSchema = 'PwShGUI-Outline/0.1'
            created       = (Get-Date).ToUniversalTime().ToString('o')
            lastModified  = (Get-Date).ToUniversalTime().ToString('o')
            description   = 'Unified pipeline registry for Feature Requests, Bugs, ToDo, Items2ADD, Bugs2FIX.'
        }
        featureRequests = @()
        bugs            = @()
        items2ADD       = @()
        bugs2FIX        = @()
        todos           = @()
        statistics      = [ordered]@{
            totalItemsCreated   = 0
            totalBugsFound      = 0
            totalFeaturesAdded  = 0
            totalPlans          = 0
            totalTestsMade      = 0
            totalJobCycles      = 0
            totalErrors         = 0
            totalSubagentCalls  = 0
            totalItemsDone      = 0
            questionsTotal      = 0
            questionsAutopilot  = 0
            questionsCommander  = 0
            questionsUnanswered = 0
        }
        autopilotSuggestions = [ordered]@{
            items       = @()
            implemented = 0
            pending     = 0
            rejected    = 0
            blocked     = 0
            failed      = 0
        }
    }

    $configDir = Join-Path $WorkspacePath 'config'

    try {
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force -ErrorAction Stop | Out-Null
        }
        $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $regPath -Encoding UTF8 -ErrorAction Stop
        Write-AppLog -Message "New pipeline registry created at $regPath" -Level Info
        return ($registry | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    } catch {
        Write-AppLog -Message "Failed to create pipeline registry at $regPath : $_" -Level Error
        throw "Pipeline registry initialization failed: $_"
    }
}

function ConvertTo-PipelineItemType {
    <#
    .SYNOPSIS  Normalize item type aliases to the canonical pipeline types.
        .DESCRIPTION
      Detailed behaviour: ConvertTo pipeline item type.
    #>
    [OutputType([System.String])]
    [CmdletBinding()]
    param($Type)

    if ($Type -is [System.Array]) { $Type = @($Type | Select-Object -First 1)[0] }
    if ($null -eq $Type) { return 'ToDo' }

    $TypeText = [string]$Type
    if ([string]::IsNullOrWhiteSpace($TypeText)) { return 'ToDo' }

    switch -Regex ($TypeText.Trim().ToUpper()) {
        '^FEATUREREQUEST$' { return 'FeatureRequest' }
        '^FEATURE$' { return 'FeatureRequest' }
        '^BUG$' { return 'Bug' }
        '^BUGS2FIX$' { return 'Bugs2FIX' }
        '^ITEMS2ADD$' { return 'Items2ADD' }
        '^TODO$' { return 'ToDo' }
        default { return $TypeText }
    }
}

function ConvertTo-PipelineStatus {
    <#
    .SYNOPSIS  Normalize status aliases to the canonical pipeline state machine.
        .DESCRIPTION
      Detailed behaviour: ConvertTo pipeline status.
    #>
    [OutputType([System.String])]
    [CmdletBinding()]
    param($Status)

    if ($Status -is [System.Array]) { $Status = @($Status | Select-Object -First 1)[0] }
    if ($null -eq $Status) { return 'OPEN' }

    $statusText = [string]$Status
    if ([string]::IsNullOrWhiteSpace($statusText)) { return 'OPEN' }

    $token = $statusText.Trim().ToUpper()
    $token = $token -replace '[\s\-]+', '_'

    switch ($token) {
        'PROPOSED' { return 'OPEN' }
        'ALPHA' { return 'OPEN' }
        'ALPHA_TESTING' { return 'OPEN' }
        'BETA' { return 'OPEN' }
        'BETA_TESTING' { return 'OPEN' }
        'OPEN' { return 'OPEN' }
        'PENDING' { return 'PLANNED' }
        'PLANNED' { return 'PLANNED' }
        'PLAN' { return 'PLANNED' }
        'INPROGRESS' { return 'IN_PROGRESS' }
        'IN_PROGRESS' { return 'IN_PROGRESS' }
        'IN_PROGRESSS' { return 'IN_PROGRESS' }
        'TESTING' { return 'TESTING' }
        'QA' { return 'TESTING' }
        'REVIEW' { return 'TESTING' }
        'DONE' { return 'DONE' }
        'FIXED' { return 'DONE' }
        'IMPLEMENTED' { return 'DONE' }
        'RELEASED' { return 'DONE' }
        'COMPLETE' { return 'DONE' }
        'COMPLETED' { return 'DONE' }
        'RESOLVED' { return 'DONE' }
        'BLOCKED' { return 'BLOCKED' }
        'ON_HOLD' { return 'BLOCKED' }
        'FAILED' { return 'FAILED' }
        'ERROR' { return 'FAILED' }
        'WONTFIX' { return 'CLOSED' }
        'WON_T_FIX' { return 'CLOSED' }
        'DEFERRED' { return 'CLOSED' }
        'CANCELLED' { return 'CLOSED' }
        'CANCELED' { return 'CLOSED' }
        'CLOSED' { return 'CLOSED' }
        default { return $token }
    }
}

function Get-PipelineActiveTodoFiles {
    <#
    .SYNOPSIS  Return active todo JSON item files excluding generated and archived content.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $todoDir = Join-Path $WorkspacePath 'todo'
    if (-not (Test-Path $todoDir)) { return @() }

    $excludeNames = @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json')
    $files = @(
        Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $excludeNames -notcontains $_.Name -and $_.FullName -notlike "*\~*\*" } |
        Sort-Object Name
    )
    return $files
}

function Write-PipelineItemFile {
    <#
    .SYNOPSIS  Persist a single pipeline item to its backward-compatible todo JSON file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] $Item
    )

    $todoDir = Join-Path $WorkspacePath 'todo'
    if (-not (Test-Path $todoDir)) { New-Item -ItemType Directory -Path $todoDir -Force | Out-Null }
    $todoFile = Join-Path $todoDir "$($Item.id).json"
    $Item | ConvertTo-Json -Depth 10 | Set-Content -Path $todoFile -Encoding UTF8
    return $todoFile
}

function Add-PipelineItem {
    <#
    .SYNOPSIS  Add an item to the pipeline registry and persist.
        .DESCRIPTION
      Detailed behaviour: Add pipeline item.
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [hashtable]$Item
    )

    $Item.type = ConvertTo-PipelineItemType -Type $Item.type
    if ($Item.Contains('status')) {
        $Item.status = ConvertTo-PipelineStatus -Status $Item.status
    } else {
        $Item.status = 'OPEN'
    }

    $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath

    try {
        $registry = Get-Content $regPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-AppLog -Message "Failed to load pipeline registry from $regPath : $_" -Level Error
        throw "Add-PipelineItem failed: cannot load registry: $_"
    }

    $listName = switch ($Item.type) {
        'FeatureRequest' { 'featureRequests' }
        'Bug'            { 'bugs' }
        'Items2ADD'      { 'items2ADD' }
        'Bugs2FIX'       { 'bugs2FIX' }
        'ToDo'           { 'todos' }
    }

    $existing = @($registry.$listName)
    $existing += $Item
    $registry.$listName = $existing
    $registry.statistics.totalItemsCreated++
    $registry.meta.lastModified = (Get-Date).ToUniversalTime().ToString('o')

    try {
        $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $regPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-AppLog -Message "Failed to save pipeline registry to $regPath : $_" -Level Error
        throw "Add-PipelineItem failed: cannot save registry: $_"
    }

    # Also create individual todo JSON for backward compatibility
    $null = Write-PipelineItemFile -WorkspacePath $WorkspacePath -Item $Item

    try {
        $null = Invoke-PipelineArtifactRefresh -WorkspacePath $WorkspacePath
    } catch {
        Write-AppLog -Message "Pipeline artifact refresh failed after Add-PipelineItem for $($Item.id): $_" -Level Warning
    }

    return $Item
}

function Test-StatusTransition {
    <#
    .SYNOPSIS  Validate that a status transition is permitted by the state machine.
        .DESCRIPTION
      Detailed behaviour: Test status transition.
    #>
    [OutputType([System.Boolean])]
    [CmdletBinding()]
    param(
        [string]$CurrentStatus,
        [string]$NewStatus
    )

    $CurrentStatus = ConvertTo-PipelineStatus -Status $CurrentStatus
    $NewStatus = ConvertTo-PipelineStatus -Status $NewStatus

    # State machine: allowed transitions
    $validTransitions = @{
        'OPEN'        = @('PLANNED','IN_PROGRESS','BLOCKED','CLOSED')
        'PLANNED'     = @('IN_PROGRESS','BLOCKED','CLOSED')
        'IN_PROGRESS' = @('TESTING','DONE','BLOCKED','FAILED')
        'TESTING'     = @('DONE','IN_PROGRESS','FAILED')
        'DONE'        = @('CLOSED','IN_PROGRESS')
        'CLOSED'      = @('OPEN')
        'BLOCKED'     = @('OPEN','PLANNED','IN_PROGRESS','CLOSED')
        'FAILED'      = @('OPEN','IN_PROGRESS','CLOSED')
    }

    if (-not $validTransitions.ContainsKey($CurrentStatus)) { return $true }
    return ($NewStatus -in $validTransitions[$CurrentStatus])
}

function Update-PipelineItemStatus {
    <#
    .SYNOPSIS  Update the status of a pipeline item with state machine validation.
        .DESCRIPTION
      Detailed behaviour: Update pipeline item status.
    #>
    [OutputType([System.Boolean])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$ItemId,
        [Parameter(Mandatory)]
        [string]$NewStatus,
        [string]$Notes = '',
        [switch]$Force
    )

    $NewStatus = ConvertTo-PipelineStatus -Status $NewStatus
    if ($NewStatus -notin @('OPEN','PLANNED','IN_PROGRESS','TESTING','DONE','CLOSED','BLOCKED','FAILED')) {
        Write-AppLog -Message "Unsupported target status '$NewStatus' for item $ItemId." -Level Warning
        return $false
    }

    $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath

    try {
        $raw = Get-Content $regPath -Raw -ErrorAction Stop
        if (-not $raw -or $raw.Trim().Length -eq 0) {
            Write-AppLog -Message "Pipeline registry file empty: $regPath" -Level Warning
            return $false
        }
        $registry = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $registry) {
            Write-AppLog -Message "Pipeline registry JSON parse returned null: $regPath" -Level Warning
            return $false
        }
    } catch {
        Write-AppLog -Message "Failed to load pipeline registry from $regPath : $_" -Level Error
        return $false
    }

    $found = $false
    $updatedItem = $null
    foreach ($listName in @('featureRequests','bugs','items2ADD','bugs2FIX','todos')) {
        $listRef = @($registry.$listName)
        for ($i = 0; $i -lt $listRef.Count; $i++) {
            if ($null -eq $listRef[$i]) { continue }
            if ($listRef[$i].id -eq $ItemId) {
                $currentStatus = if ($listRef[$i].PSObject.Properties['status']) { ConvertTo-PipelineStatus -Status $listRef[$i].status } else { 'OPEN' }
                if (-not $Force -and -not (Test-StatusTransition -CurrentStatus $currentStatus -NewStatus $NewStatus)) {
                    Write-AppLog -Message "Invalid transition: $currentStatus -> $NewStatus for item $ItemId. Use -Force to override." -Level Warning
                    return $false
                }
                $listRef[$i].status = $NewStatus
                $listRef[$i].modified = (Get-Date).ToUniversalTime().ToString('o')
                $listRef[$i].sessionModCount++
                if ($Notes) { $listRef[$i].notes = $Notes }
                if ($NewStatus -eq 'PLANNED') { $listRef[$i].plannedAt = (Get-Date).ToUniversalTime().ToString('o') }
                if ($NewStatus -eq 'IN_PROGRESS') { $listRef[$i].executedAt = (Get-Date).ToUniversalTime().ToString('o') }
                if ($NewStatus -in @('DONE','CLOSED')) {
                    $listRef[$i].completedAt = (Get-Date).ToUniversalTime().ToString('o')
                    $registry.statistics.totalItemsDone++
                }

                # Backfill and update extended tracking fields (SIN-P022: null guard on PSObject.Properties)
                $nowTs = (Get-Date).ToUniversalTime().ToString('o')
                foreach ($fld in @('implementedAt','reopenedAt','lastSeenAt','firstSeenAt')) {
                    if (-not $listRef[$i].PSObject.Properties[$fld]) {
                        $listRef[$i] | Add-Member -NotePropertyName $fld -NotePropertyValue $null -Force
                    }
                }
                if (-not $listRef[$i].PSObject.Properties['bugResurfaced']) {
                    $listRef[$i] | Add-Member -NotePropertyName 'bugResurfaced' -NotePropertyValue $false -Force
                }
                foreach ($fld in @('bugHistory','bugReferrals','countermeasures')) {
                    if (-not $listRef[$i].PSObject.Properties[$fld]) {
                        $listRef[$i] | Add-Member -NotePropertyName $fld -NotePropertyValue @() -Force
                    }
                }
                foreach ($fld in @('fixesImplementedCount','filesFixedCount','filesRemainingCount')) {
                    if (-not $listRef[$i].PSObject.Properties[$fld]) {
                        $listRef[$i] | Add-Member -NotePropertyName $fld -NotePropertyValue 0 -Force
                    }
                }
                $listRef[$i].lastSeenAt = $nowTs
                if ($null -eq $listRef[$i].firstSeenAt) {
                    $listRef[$i].firstSeenAt = if ($listRef[$i].PSObject.Properties['created'] -and $null -ne $listRef[$i].created) { $listRef[$i].created } else { $nowTs }
                }
                if ($NewStatus -eq 'DONE') { $listRef[$i].implementedAt = $nowTs }
                if ($NewStatus -eq 'OPEN' -and $currentStatus -in @('DONE','CLOSED')) {
                    $listRef[$i].reopenedAt    = $nowTs
                    $listRef[$i].bugResurfaced = $true
                    $histEntry = [ordered]@{ event = 'reopened'; fromStatus = $currentStatus; timestamp = $nowTs }
                    $existHist = @($listRef[$i].bugHistory)
                    $listRef[$i].bugHistory = @($existHist) + @($histEntry)
                }

                $found = $true
                $updatedItem = $listRef[$i]
                $null = Write-PipelineItemFile -WorkspacePath $WorkspacePath -Item $listRef[$i]
                break
            }
        }
        if ($found) { break }
    }

    $registry.meta.lastModified = (Get-Date).ToUniversalTime().ToString('o')

    try {
        $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $regPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-AppLog -Message "Failed to save pipeline registry to $regPath : $_" -Level Error
        return $false
    }

    if ($found) {
        # Trigger bug-status rollup for parent bug and any referenced bugs (SIN-P022: null guard)
        if ($null -ne $updatedItem) {
            $rollupParentId = if ($updatedItem.PSObject.Properties['parentId']) { [string]$updatedItem.parentId } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($rollupParentId)) {
                try { $null = Invoke-BugStatusRollup -WorkspacePath $WorkspacePath -BugItemId $rollupParentId }
                catch { Write-AppLog -Message "BugStatusRollup failed for parent '$rollupParentId': $_" -Level Warning }
            }
            $rollupBugRefs = if ($updatedItem.PSObject.Properties['bugReferrals']) { @($updatedItem.bugReferrals) } else { @() }
            foreach ($bRef in $rollupBugRefs) {
                $bRefStr = [string]$bRef
                if (-not [string]::IsNullOrWhiteSpace($bRefStr)) {
                    try { $null = Invoke-BugStatusRollup -WorkspacePath $WorkspacePath -BugItemId $bRefStr }
                    catch { Write-AppLog -Message "BugStatusRollup failed for bugRef '$bRefStr': $_" -Level Warning }
                }
            }
        }
        try {
            $null = Invoke-PipelineArtifactRefresh -WorkspacePath $WorkspacePath
        } catch {
            Write-AppLog -Message "Pipeline artifact refresh failed after status update for $ItemId : $_" -Level Warning
        }
    }

    return $found
}

function Get-PipelineItems {
    <#
    .SYNOPSIS  Retrieve pipeline items with optional type/status filter.
        .DESCRIPTION
      Detailed behaviour: Get pipeline items.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [string]$Type = '',
        [string]$Status = '',
        [string]$Priority = ''
    )

    $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath
    if (-not (Test-Path $regPath)) { return @() }

    try {
        $raw = Get-Content $regPath -Raw -ErrorAction Stop
        if (-not $raw -or $raw.Trim().Length -eq 0) {
            Write-AppLog -Message "Pipeline registry file empty: $regPath" -Level Debug
            return @()
        }
        $registry = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $registry) {
            Write-AppLog -Message "Pipeline registry JSON parse returned null: $regPath" -Level Debug
            return @()
        }
    } catch {
        Write-AppLog -Message "Failed to load pipeline registry from $regPath : $_. Returning empty array." -Level Warning
        return @()
    }

    $allItems = @()
    foreach ($listName in @('featureRequests','bugs','items2ADD','bugs2FIX','todos')) {
        foreach ($item in @($registry.$listName)) {
            if ($null -ne $item) { $allItems += $item }
        }
    }

    if ($Type)     { $allItems = @($allItems | Where-Object { (ConvertTo-PipelineItemType -Type $_.type) -eq (ConvertTo-PipelineItemType -Type $Type) }) }
    if ($Status)   { $allItems = @($allItems | Where-Object { (ConvertTo-PipelineStatus -Status $_.status) -eq (ConvertTo-PipelineStatus -Status $Status) }) }
    if ($Priority) { $allItems = @($allItems | Where-Object { $_.priority -eq $Priority }) }

    return $allItems
}

function Get-PipelineStatistics {
    <#
    .SYNOPSIS  Return pipeline statistics summary.
        .DESCRIPTION
      Detailed behaviour: Get pipeline statistics.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath
    if (-not (Test-Path $regPath)) { return $null }
    $registry = Get-Content $regPath -Raw | ConvertFrom-Json
    return $registry.statistics
}

function Invoke-SinRegistryFeedback {
    <#
    .SYNOPSIS  Match a bug against the sin_registry. If matched, link it;
               if unencountered, create a new sin entry.
        .DESCRIPTION
      Detailed behaviour: Invoke sin registry feedback.
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [hashtable]$BugItem
    )

    $sinDir = Join-Path $WorkspacePath 'sin_registry'
    if (-not (Test-Path $sinDir)) { New-Item -ItemType Directory -Path $sinDir -Force | Out-Null }

    # Load existing sins
    $sinFiles = Get-ChildItem -Path $sinDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'fixes' }
    $matched = $false

    foreach ($sf in $sinFiles) {
        try {
            $sin = Get-Content $sf.FullName -Raw | ConvertFrom-Json
            if ($sin.title -and $BugItem.title -and
                ($sin.title -like "*$($BugItem.title)*" -or $BugItem.title -like "*$($sin.title)*")) {
                # Match found -- link bug to sin
                $BugItem.sinId = if ($sin.sin_id) { $sin.sin_id } else { $sf.BaseName }
                $BugItem.notes = "Matched existing sin: $($sin.title)"
                $matched = $true
                break
            }
        } catch { <# skip malformed files #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    }

    if (-not $matched) {
        # Create new sin entry
        $sinId = 'SIN-' + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + ([guid]::NewGuid().ToString().Substring(0,8))
        $newSin = [ordered]@{
            sin_id           = $sinId
            title            = $BugItem.title
            description      = $BugItem.description
            category         = $BugItem.category
            severity         = $BugItem.priority
            file_path        = if (@($BugItem.affectedFiles).Count -gt 0) { @($BugItem.affectedFiles)[0] } else { '' }
            agent_id         = 'CronAiAthon'
            reported_by      = $BugItem.suggestedBy
            is_resolved      = $false
            occurrence_count = 1
            regression_count = 0
            created_at       = (Get-Date).ToUniversalTime().ToString('o')
            last_seen_at     = (Get-Date).ToUniversalTime().ToString('o')
            detection_method = 'CronAiAthon-BugTracker'
            sessionModCount  = 1
        }

        $sinFile = Join-Path $sinDir "$sinId.json"
        $newSin | ConvertTo-Json -Depth 6 | Set-Content -Path $sinFile -Encoding UTF8
        $BugItem.sinId = $sinId
        $BugItem.notes = "New sin created: $sinId"
    }

    return $BugItem
}

function ConvertTo-Bugs2FIX {
    <#
    .SYNOPSIS  Convert a bug pipeline item into a Bugs2FIX planned item.
        .DESCRIPTION
      Detailed behaviour: ConvertTo bugs2 f i x.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] $BugItem,
        [string[]]$BugReferrals = @()
    )

    $refIds = @(@($BugReferrals) + @($BugItem.id) | Select-Object -Unique)
    $fixItem = New-PipelineItem -Type 'Bugs2FIX' -Title "FIX: $($BugItem.title)" `
        -Description "Fix for bug $($BugItem.id): $($BugItem.description)" `
        -Priority $BugItem.priority -Source 'BugTracker' -Category $BugItem.category `
        -AffectedFiles @($BugItem.affectedFiles) -SuggestedBy 'CronAiAthon' `
        -ParentId $BugItem.id -BugReferrals $refIds

    Add-PipelineItem -WorkspacePath $WorkspacePath -Item $fixItem
    return $fixItem
}

function ConvertTo-Items2ADD {
    <#
    .SYNOPSIS  Convert a feature or discovery into an Items2ADD planned item.
        .DESCRIPTION
      Detailed behaviour: ConvertTo items2 a d d.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$Title,
        [string]$Description = '',
        [string]$Priority = 'MEDIUM',
        [string]$Source = 'Subagent',
        [string]$Category = 'enhancement',
        [string]$ParentId = '',
        [string[]]$BugReferrals = @()
    )

    $addItem = New-PipelineItem -Type 'Items2ADD' -Title $Title `
        -Description $Description -Priority $Priority -Source $Source `
        -Category $Category -SuggestedBy 'CronAiAthon-Autopilot' -ParentId $ParentId `
        -BugReferrals $BugReferrals

    Add-PipelineItem -WorkspacePath $WorkspacePath -Item $addItem
    return $addItem
}

# ========================== CENTRAL MASTER TODO AGGREGATOR ==========================

function Get-CentralMasterToDo {
    <#
    .SYNOPSIS  Aggregate all pipeline items + existing todo/ JSON files into one master list.
        .DESCRIPTION
      Detailed behaviour: Get central master to do.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $master = @()

    # 1. Pipeline registry items
    $pipelineItems = Get-PipelineItems -WorkspacePath $WorkspacePath
    foreach ($pi in $pipelineItems) {
        $piProps = $pi.PSObject.Properties
        $master += [ordered]@{
            id              = $pi.id
            type            = ConvertTo-PipelineItemType -Type $pi.type
            title           = $pi.title
            description     = $pi.description
            priority        = $pi.priority
            status          = ConvertTo-PipelineStatus -Status $pi.status
            source          = if ($piProps.Name -contains 'source') { $pi.source } else { 'unknown' }
            category        = if ($piProps.Name -contains 'category') { $pi.category } else { '' }
            created         = if ($piProps.Name -contains 'created' -and $null -ne $pi.created) { $pi.created }
                              elseif ($piProps.Name -contains 'created_at' -and $null -ne $pi.created_at) { $pi.created_at }
                              else { (Get-Date).ToUniversalTime().ToString('o') }
            modified        = if ($piProps.Name -contains 'modified' -and $null -ne $pi.modified) { $pi.modified } else { (Get-Date).ToUniversalTime().ToString('o') }
            sessionModCount = if ($piProps.Name -contains 'sessionModCount' -and $null -ne $pi.sessionModCount) { $pi.sessionModCount } else { 0 }
            origin          = 'pipeline'
        }
    }

    # 2. Existing todo/ folder JSON files (backward compat)
    $todoDir = Join-Path $WorkspacePath 'todo'
    if (Test-Path $todoDir) {
        $todoFiles = Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '_*' -and $_.Name -notlike 'action-log*' -and $_.FullName -notlike "*\~*\*" }

        foreach ($tf in $todoFiles) {
            try {
                $td = Get-Content $tf.FullName -Raw | ConvertFrom-Json
                $tdProps = $td.PSObject.Properties
                $tdId = if ($tdProps['id']) { $td.id } elseif ($tdProps['todo_id']) { $td.todo_id } else { $tf.BaseName }

                # Skip if already in pipeline
                if ($master | Where-Object { $_.id -eq $tdId }) { continue }

                $master += [ordered]@{
                    id              = $tdId
                    type            = ConvertTo-PipelineItemType -Type (if ($tdProps['type']) { $td.type } else { 'ToDo' })
                    title           = if ($tdProps['title']) { $td.title } else { $tf.BaseName }
                    description     = if ($tdProps['description']) { $td.description } else { '' }
                    priority        = if ($tdProps['priority']) { $td.priority.ToUpper() } else { 'MEDIUM' }
                    status          = ConvertTo-PipelineStatus -Status (if ($tdProps['status']) { $td.status } else { 'OPEN' })
                    source          = 'Legacy'
                    category        = if ($tdProps['category']) { $td.category } else { 'general' }
                    created         = if ($tdProps['created']) { $td.created } elseif ($tdProps['created_at']) { $td.created_at } else { '' }
                    modified        = if ($tdProps['modified']) { $td.modified } else { '' }
                    sessionModCount = if ($tdProps['sessionModCount']) { $td.sessionModCount } else { 1 }
                    origin          = 'todo-folder'
                }
            } catch { <# skip malformed #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
        }
    }

    # 3. Feature Requests from XHTML-Checker JSON
    $frPath = Join-Path (Join-Path (Join-Path $WorkspacePath 'scripts') 'XHTML-Checker') 'PsGUI-FeatureRequests.json'
    if (Test-Path $frPath) {
        try {
            $frData = Get-Content $frPath -Raw | ConvertFrom-Json
            foreach ($feat in @($frData.features)) {
                if ($null -eq $feat) { continue }
                $fp = $feat.PSObject.Properties
                $featId = if ($fp['id']) { $feat.id } else { "FR-$(Get-Random)" }
                if ($master | Where-Object { $_.id -eq $featId }) { continue }
                $master += [ordered]@{
                    id              = $featId
                    type            = 'FeatureRequest'
                    title           = if ($fp['title']) { $feat.title } else { '' }
                    description     = if ($fp['description']) { $feat.description } else { '' }
                    priority        = 'MEDIUM'
                    status          = ConvertTo-PipelineStatus -Status (if ($fp['status']) { $feat.status } else { 'OPEN' })
                    source          = 'FeatureRegistry'
                    category        = 'feature'
                    created         = if ($fp['created']) { $feat.created } else { '' }
                    modified        = ''
                    sessionModCount = 1
                    origin          = 'feature-requests-json'
                }
            }
        } catch { <# skip malformed #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    }

    # 4. Bug Tracker JSON
    $btPath = Join-Path (Join-Path (Join-Path $WorkspacePath 'scripts') 'XHTML-Checker') 'PsGUI-BugTracker.json'
    if (Test-Path $btPath) {
        try {
            $btData = Get-Content $btPath -Raw | ConvertFrom-Json
            foreach ($bug in @($btData.bugs)) {
                if ($null -eq $bug) { continue }
                $bp = $bug.PSObject.Properties
                $bugId = if ($bp['id']) { $bug.id } else { "BUG-$(Get-Random)" }
                if ($master | Where-Object { $_.id -eq $bugId }) { continue }
                $master += [ordered]@{
                    id              = $bugId
                    type            = 'Bug'
                    title           = if ($bp['title']) { $bp['title'].Value } else { '' }
                    description     = if ($bp['description']) { $bp['description'].Value } else { '' }
                    priority        = if ($bp['severity']) { ([string]$bp['severity'].Value).ToUpper() } else { 'MEDIUM' }
                    status          = ConvertTo-PipelineStatus -Status (if ($bp['status']) { [string]$bp['status'].Value } else { 'OPEN' })
                    source          = 'BugTracker'
                    category        = 'bug'
                    created         = if ($bp['reported']) { [string]$bp['reported'].Value } else { '' }
                    modified        = if ($bp['fixed']) { [string]$bp['fixed'].Value } else { '' }
                    sessionModCount = 1
                    origin          = 'bug-tracker-json'
                }
            }
        } catch { <# skip malformed #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    }

    return $master
}

function Export-CentralMasterToDo {
    <#
    .SYNOPSIS  Export aggregated master list as JSON to todo/_master-aggregated.json.
        .DESCRIPTION
      Detailed behaviour: Export central master to do.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $master = Get-CentralMasterToDo -WorkspacePath $WorkspacePath
    $output = [ordered]@{
        meta = [ordered]@{
            schema       = 'CronAiAthon-MasterToDo/1.0'
            generated    = (Get-Date).ToUniversalTime().ToString('o')
            totalItems   = @($master).Count
            byType       = [ordered]@{
                FeatureRequest = @($master | Where-Object { $_.type -eq 'FeatureRequest' }).Count
                Bug            = @($master | Where-Object { $_.type -eq 'Bug' }).Count
                Items2ADD      = @($master | Where-Object { $_.type -eq 'Items2ADD' }).Count
                Bugs2FIX       = @($master | Where-Object { $_.type -eq 'Bugs2FIX' }).Count
                ToDo           = @($master | Where-Object { $_.type -eq 'ToDo' }).Count
            }
            byStatus     = [ordered]@{
                OPEN        = @($master | Where-Object { $_.status -eq 'OPEN' }).Count
                PLANNED     = @($master | Where-Object { $_.status -eq 'PLANNED' }).Count
                IN_PROGRESS = @($master | Where-Object { $_.status -eq 'IN_PROGRESS' }).Count
                TESTING     = @($master | Where-Object { $_.status -eq 'TESTING' }).Count
                DONE        = @($master | Where-Object { $_.status -eq 'DONE' }).Count
                CLOSED      = @($master | Where-Object { $_.status -eq 'CLOSED' }).Count
                BLOCKED     = @($master | Where-Object { $_.status -eq 'BLOCKED' }).Count
                FAILED      = @($master | Where-Object { $_.status -eq 'FAILED' }).Count
            }
        }
        items = $master
    }

    $todoDir = Join-Path $WorkspacePath 'todo'

    try {
        if (-not (Test-Path $todoDir)) {
            New-Item -ItemType Directory -Path $todoDir -Force -ErrorAction Stop | Out-Null
        }
        $outPath = Join-Path $todoDir '_master-aggregated.json'
        $output | ConvertTo-Json -Depth 10 | Set-Content -Path $outPath -Encoding UTF8 -ErrorAction Stop
        Write-AppLog -Message "Central master ToDo exported to $outPath ($(@($master).Count) items)" -Level Info
        return $outPath
    } catch {
        Write-AppLog -Message "Failed to export central master ToDo to $todoDir : $_" -Level Error
        throw "Export-CentralMasterToDo failed: $_"
    }
}

# ========================== BATCH TRANSITIONS ==========================

function Set-PipelineItemBatchStatus {
    <#
    .SYNOPSIS  Bulk-transition pipeline items matching filter criteria.
        .DESCRIPTION
      Detailed behaviour: Set pipeline item batch status.
    #>
    [OutputType([System.Int32])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$NewStatus,
        [string]$FilterType = '',
        [string]$FilterStatus = '',
        [string]$FilterCategory = '',
        [string]$FilterSinId = '',
        [string]$Notes = '',
        [switch]$Force
    )

    $items = Get-PipelineItems -WorkspacePath $WorkspacePath
    $changed = 0
    foreach ($item in $items) {
        if ($FilterType -and $item.type -ne $FilterType) { continue }
        if ($FilterStatus -and $item.status -ne $FilterStatus) { continue }
        if ($FilterCategory -and $item.category -ne $FilterCategory) { continue }
        if ($FilterSinId -and $item.sinId -ne $FilterSinId) { continue }

        $params = @{
            WorkspacePath = $WorkspacePath
            ItemId        = $item.id
            NewStatus     = $NewStatus
        }
        if ($Notes) { $params['Notes'] = $Notes }
        if ($Force) { $params['Force'] = $true }

        $result = Update-PipelineItemStatus @params
        if ($result) { $changed++ }
    }
    return $changed
}

# ========================== HEALTH METRICS ==========================

function Get-PipelineHealthMetrics {
    <#
    .SYNOPSIS  Return pipeline health: items/day created, items/day closed,
               mean-time-to-close, backlog age distribution.
        .DESCRIPTION
      Detailed behaviour: Get pipeline health metrics.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $items = Get-PipelineItems -WorkspacePath $WorkspacePath
    foreach ($item in @($items)) {
        if ($null -ne $item -and $item.PSObject.Properties['status']) {
            $item.status = ConvertTo-PipelineStatus -Status $item.status
        }
    }
    $now = [DateTime]::UtcNow

    $created = @($items | Where-Object { $null -ne $_ -and $_.PSObject.Properties['created'] -and -not [string]::IsNullOrWhiteSpace([string]$_.created) })
    $closed  = @($items | Where-Object { $_.status -in @('DONE','CLOSED') })
    $open    = @($items | Where-Object { $_.status -in @('OPEN','PLANNED','IN_PROGRESS','TESTING','BLOCKED','FAILED') })

    # Items per day (over last 30 days)
    $thirtyDaysAgo = $now.AddDays(-30)
    $recentCreated = @($created | Where-Object {
        try { [DateTime]::Parse($_.created) -gt $thirtyDaysAgo } catch { $false }
    })
    $recentClosed = @($closed | Where-Object {
        try { $_.completedAt -and [DateTime]::Parse($_.completedAt) -gt $thirtyDaysAgo } catch { $false }
    })

    $createdPerDay = if ($recentCreated.Count -gt 0) { [Math]::Round($recentCreated.Count / 30.0, 2) } else { 0 }
    $closedPerDay  = if ($recentClosed.Count -gt 0)  { [Math]::Round($recentClosed.Count / 30.0, 2) }  else { 0 }

    # Mean time to close (days)
    $closeTimes = @()
    foreach ($c in $closed) {
        $hasCreated = ($null -ne $c -and $c.PSObject.Properties['created'] -and -not [string]::IsNullOrWhiteSpace([string]$c.created))
        $hasCompletedAt = ($null -ne $c -and $c.PSObject.Properties['completedAt'] -and -not [string]::IsNullOrWhiteSpace([string]$c.completedAt))
        if ($hasCreated -and $hasCompletedAt) {
            try {
                $span = [DateTime]::Parse($c.completedAt) - [DateTime]::Parse($c.created)
                $closeTimes += $span.TotalDays
            } catch { <# skip #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
        }
    }
    $meanTimeToClose = if ($closeTimes.Count -gt 0) { [Math]::Round(($closeTimes | Measure-Object -Average).Average, 1) } else { 0 }

    # Backlog age distribution
    $ageBuckets = [ordered]@{ 'lt1d' = 0; '1d-7d' = 0; '7d-30d' = 0; 'gt30d' = 0 }
    foreach ($o in $open) {
        $hasCreated = ($null -ne $o -and $o.PSObject.Properties['created'] -and -not [string]::IsNullOrWhiteSpace([string]$o.created))
        if ($hasCreated) {
            try {
                $age = ($now - [DateTime]::Parse($o.created)).TotalDays
                if ($age -lt 1)     { $ageBuckets['lt1d']++ }
                elseif ($age -lt 7) { $ageBuckets['1d-7d']++ }
                elseif ($age -lt 30){ $ageBuckets['7d-30d']++ }
                else                { $ageBuckets['gt30d']++ }
            } catch { $ageBuckets['gt30d']++ }
        }
    }

    return [ordered]@{
        totalItems       = $items.Count
        openItems        = $open.Count
        closedItems      = $closed.Count
        createdPerDay    = $createdPerDay
        closedPerDay     = $closedPerDay
        meanTimeToClose  = $meanTimeToClose
        backlogAge       = $ageBuckets
        generatedAt      = $now.ToString('o')
    }
}

# ========================== CATEGORY TAXONOMY ==========================

$script:ValidCategories = @(
    'error-handling', 'compatibility', 'rendering', 'security',
    'performance', 'testing', 'documentation', 'ui', 'config',
    'parsing', 'crash-log', 'data-validation', 'dependency',
    'enhancement', 'feature', 'bug', 'general', 'maintenance',
    'integration', 'ux', 'new_agents'
)

function Get-ValidCategories {
    <#
    .SYNOPSIS  Return the standardized category taxonomy list.
        .DESCRIPTION
      Detailed behaviour: Get valid categories.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection; plural is semantically clearer.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return $script:ValidCategories
}

function Resolve-ItemCategory {
    <#
    .SYNOPSIS  Map a raw category string to the closest standard category.
    #>
    [OutputType([System.String])]
    [CmdletBinding()]
    param([string]$RawCategory)

    if ([string]::IsNullOrWhiteSpace($RawCategory)) { return 'general' }
    $lower = $RawCategory.ToLower().Trim()
    if ($lower -in $script:ValidCategories) { return $lower }

    # Fuzzy mapping for common variants
    $map = @{
        'parse'     = 'parsing'
        'render'    = 'rendering'
        'compat'    = 'compatibility'
        'perf'      = 'performance'
        'test'      = 'testing'
        'doc'       = 'documentation'
        'docs'      = 'documentation'
        'config'    = 'config'
        'ui'        = 'ui'
        'ux'        = 'ux'
        'sec'       = 'security'
        'dep'       = 'dependency'
        'int'       = 'integration'
        'feat'      = 'feature'
        'enh'       = 'enhancement'
        'maint'     = 'maintenance'
        'error'     = 'error-handling'
        'err'       = 'error-handling'
        'crash'     = 'crash-log'
        'data'      = 'data-validation'
        'agent'     = 'new_agents'
    }

    foreach ($key in $map.Keys) {
        if ($lower -like "*$key*") { return $map[$key] }
    }
    return 'general'
}

# ========================== OUTLINE SCHEMA v0 ==========================

function Set-OutlinePhase {
    <#
    .SYNOPSIS  Batch-update outlinePhase for all items matching filters.
    .PARAMETER Phase  assessment | planned | in-progress | review | accepted
        .DESCRIPTION
      Detailed behaviour: Set outline phase.
    #>
    [OutputType([System.Int32])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)]
        [ValidateSet('assessment','planned','in-progress','review','accepted')]
        [string]$Phase,
        [string]$FilterType = '',
        [string]$FilterStatus = ''
    )

    $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath
    $raw = Get-Content $regPath -Raw -ErrorAction SilentlyContinue
    if (-not $raw -or $raw.Trim().Length -eq 0) { return 0 }
    $registry = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -eq $registry) { return 0 }

    $changed = 0
    foreach ($listName in @('featureRequests','bugs','items2ADD','bugs2FIX','todos')) {
        foreach ($item in @($registry.$listName)) {
            if ($null -eq $item) { continue }
            if ($FilterType -and $item.type -ne $FilterType) { continue }
            if ($FilterStatus -and $item.status -ne $FilterStatus) { continue }

            if (-not $item.PSObject.Properties['outlinePhase']) {
                $item | Add-Member -NotePropertyName 'outlinePhase' -NotePropertyValue $Phase -Force
            } else {
                $item.outlinePhase = $Phase
            }
            if (-not $item.PSObject.Properties['outlineTag']) {
                $item | Add-Member -NotePropertyName 'outlineTag' -NotePropertyValue 'OUTLINE-PROTO-v0' -Force
            }
            if (-not $item.PSObject.Properties['outlineVersion']) {
                $item | Add-Member -NotePropertyName 'outlineVersion' -NotePropertyValue 'v0' -Force
            }
            $changed++
        }
    }

    $registry.meta.lastModified = (Get-Date).ToUniversalTime().ToString('o')
    $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $regPath -Encoding UTF8
    return $changed
}

function Confirm-OutlineVersion {
    <#
    .SYNOPSIS  Chief confirmation: bump all v0 items to v1 (accepted).
    .DESCRIPTION  Reviews v0 outline items, sets outlineVersion=v1 and outlinePhase=accepted.
    #>
    [OutputType([System.Int32])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath
    $raw = Get-Content $regPath -Raw -ErrorAction SilentlyContinue
    if (-not $raw -or $raw.Trim().Length -eq 0) { return 0 }
    $registry = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -eq $registry) { return 0 }

    $confirmed = 0
    foreach ($listName in @('featureRequests','bugs','items2ADD','bugs2FIX','todos')) {
        foreach ($item in @($registry.$listName)) {
            if ($null -eq $item) { continue }
            $ov = if ($item.PSObject.Properties['outlineVersion']) { $item.outlineVersion } else { '' }
            if ($ov -eq 'v0') {
                $item.outlineVersion = 'v1'
                $item.outlinePhase   = 'accepted'
                $item.outlineTag     = 'OUTLINE-CONFIRMED-v1'
                $item.modified       = (Get-Date).ToUniversalTime().ToString('o')
                $confirmed++
            }
        }
    }

    $registry.meta.lastModified = (Get-Date).ToUniversalTime().ToString('o')
    $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $regPath -Encoding UTF8
    return $confirmed
}

# ========================== BUNDLE REGENERATION ==========================

function Update-TodoBundle {
    <#
    .SYNOPSIS  Regenerate todo/_bundle.js from all todo/*.json files.
        .DESCRIPTION
      Detailed behaviour: Update todo bundle.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $todoDir = Join-Path $WorkspacePath 'todo'
    if (-not (Test-Path $todoDir)) { return $null }

    $items = @()
    $jsonFiles = @(Get-PipelineActiveTodoFiles -WorkspacePath $WorkspacePath)

    foreach ($jf in $jsonFiles) {
        try {
            $data = Get-Content $jf.FullName -Raw | ConvertFrom-Json
            $items += $data
        } catch { <# skip malformed #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    }

    $bundlePath = Join-Path $todoDir '_bundle.js'
    $json = $items | ConvertTo-Json -Depth 10
    $content = "/* Auto-generated todo data bundle`n   Generated: $((Get-Date).ToUniversalTime().ToString('o'))`n   Items: $($items.Count)`n   Regenerate: Import-Module modules/CronAiAthon-Pipeline.psm1; Update-TodoBundle -WorkspacePath . */`nvar _todoBundle = $json;"
    Set-Content -Path $bundlePath -Value $content -Encoding UTF8
    return $bundlePath
}

function Update-PipelineIndex {
    <#
    .SYNOPSIS  Regenerate todo/_index.json from the canonical master pipeline view.
        .DESCRIPTION
      Detailed behaviour: Update pipeline index.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $master = @(Get-CentralMasterToDo -WorkspacePath $WorkspacePath)
    $activeFiles = @(Get-PipelineActiveTodoFiles -WorkspacePath $WorkspacePath)
    $todoDir = Join-Path $WorkspacePath 'todo'
    if (-not (Test-Path $todoDir)) { New-Item -ItemType Directory -Path $todoDir -Force | Out-Null }

    $index = [ordered]@{
        generated = (Get-Date).ToUniversalTime().ToString('o')
        count     = @($master).Count
        fileCount = @($activeFiles).Count
        types     = [ordered]@{
            todos    = @($master | Where-Object { $_.type -in @('ToDo','Items2ADD') }).Count
            bugs     = @($master | Where-Object { $_.type -in @('Bug','Bugs2FIX') }).Count
            features = @($master | Where-Object { $_.type -eq 'FeatureRequest' }).Count
        }
        pipelineTypes = [ordered]@{
            FeatureRequest = @($master | Where-Object { $_.type -eq 'FeatureRequest' }).Count
            Bug            = @($master | Where-Object { $_.type -eq 'Bug' }).Count
            Items2ADD      = @($master | Where-Object { $_.type -eq 'Items2ADD' }).Count
            Bugs2FIX       = @($master | Where-Object { $_.type -eq 'Bugs2FIX' }).Count
            ToDo           = @($master | Where-Object { $_.type -eq 'ToDo' }).Count
        }
        statusCounts = [ordered]@{
            OPEN        = @($master | Where-Object { $_.status -eq 'OPEN' }).Count
            PLANNED     = @($master | Where-Object { $_.status -eq 'PLANNED' }).Count
            IN_PROGRESS = @($master | Where-Object { $_.status -eq 'IN_PROGRESS' }).Count
            TESTING     = @($master | Where-Object { $_.status -eq 'TESTING' }).Count
            DONE        = @($master | Where-Object { $_.status -eq 'DONE' }).Count
            CLOSED      = @($master | Where-Object { $_.status -eq 'CLOSED' }).Count
            BLOCKED     = @($master | Where-Object { $_.status -eq 'BLOCKED' }).Count
            FAILED      = @($master | Where-Object { $_.status -eq 'FAILED' }).Count
        }
        files = @($activeFiles | ForEach-Object { $_.Name })
        ids   = @($master | ForEach-Object { $_.id })
    }

    $indexPath = Join-Path $todoDir '_index.json'
    $index | ConvertTo-Json -Depth 6 | Set-Content -Path $indexPath -Encoding UTF8
    return $indexPath
}

function Get-PipelineInterruptions {
    <#
    .SYNOPSIS  Return stale items that likely indicate interrupted plan execution.
        .DESCRIPTION
      Detailed behaviour: Get pipeline interruptions.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [int]$OpenDays = 14,
        [int]$PlannedDays = 7,
        [int]$InProgressDays = 3,
        [int]$BlockedDays = 7
    )

    $now = [DateTime]::UtcNow
    $items = @(Get-PipelineItems -WorkspacePath $WorkspacePath)
    $interruptions = @()

    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $status = ConvertTo-PipelineStatus -Status $item.status
        $propNames = $item.PSObject.Properties.Name
        $anchor = if (($propNames -contains 'modified') -and $item.modified) { $item.modified } elseif (($propNames -contains 'created') -and $item.created) { $item.created } else { '' }
        if ([string]::IsNullOrWhiteSpace($anchor)) { continue }

        try {
            $ageDays = ($now - [DateTime]::Parse($anchor)).TotalDays
        } catch {
            continue
        }

        $threshold = switch ($status) {
            'OPEN' { $OpenDays }
            'PLANNED' { $PlannedDays }
            'IN_PROGRESS' { $InProgressDays }
            'BLOCKED' { $BlockedDays }
            default { -1 }
        }

        if ($threshold -ge 0 -and $ageDays -ge $threshold) {
            $interruptions += [ordered]@{
                id        = $item.id
                type      = ConvertTo-PipelineItemType -Type $item.type
                title     = $item.title
                status    = $status
                ageDays   = [Math]::Round($ageDays, 1)
                threshold = $threshold
                source    = if ($item.PSObject.Properties.Name -contains 'source') { $item.source } else { 'unknown' }
                category  = if ($item.PSObject.Properties.Name -contains 'category') { $item.category } else { '' }
            }
        }
    }

    return [ordered]@{
        generatedAt = $now.ToString('o')
        total       = @($interruptions).Count
        byStatus    = [ordered]@{
            OPEN        = @($interruptions | Where-Object { $_.status -eq 'OPEN' }).Count
            PLANNED     = @($interruptions | Where-Object { $_.status -eq 'PLANNED' }).Count
            IN_PROGRESS = @($interruptions | Where-Object { $_.status -eq 'IN_PROGRESS' }).Count
            BLOCKED     = @($interruptions | Where-Object { $_.status -eq 'BLOCKED' }).Count
        }
        items       = $interruptions
    }
}

function Test-PipelineArtifactIntegrity {
    <#
    .SYNOPSIS  Validate coherence across pipeline registry, master aggregate, index, and bundle.
        .DESCRIPTION
      Detailed behaviour: Test pipeline artifact integrity.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$IncludeStaleCheck,
        [int]$OpenDays = 14,
        [int]$PlannedDays = 7,
        [int]$InProgressDays = 3,
        [int]$BlockedDays = 7
    )

    $todoDir = Join-Path $WorkspacePath 'todo'
    $indexPath = Join-Path $todoDir '_index.json'
    $masterPath = Join-Path $todoDir '_master-aggregated.json'
    $bundlePath = Join-Path $todoDir '_bundle.js'
    $activeFiles = @(Get-PipelineActiveTodoFiles -WorkspacePath $WorkspacePath)

    $index = if (Test-Path $indexPath) { Get-Content $indexPath -Raw | ConvertFrom-Json } else { $null }
    $master = if (Test-Path $masterPath) { Get-Content $masterPath -Raw | ConvertFrom-Json } else { $null }

    $bundleCount = 0
    if (Test-Path $bundlePath) {
        try {
            $bundleRaw = Get-Content $bundlePath -Raw
            $start = $bundleRaw.IndexOf('[')
            $end = $bundleRaw.LastIndexOf(']')
            if ($start -ge 0 -and $end -gt $start) {
                $bundleJson = $bundleRaw.Substring($start, ($end - $start + 1))
                $bundleItems = @($bundleJson | ConvertFrom-Json)
                $bundleCount = @($bundleItems).Count
            }
        } catch {
            $bundleCount = -1
        }
    }

    $stale = $null
    if ($IncludeStaleCheck) {
        $stale = Get-PipelineInterruptions -WorkspacePath $WorkspacePath -OpenDays $OpenDays -PlannedDays $PlannedDays -InProgressDays $InProgressDays -BlockedDays $BlockedDays
    }

    $indexCount = if ($null -ne $index) { [int]$index.count } else { -1 }
    $indexFileCount = if ($null -ne $index -and $index.PSObject.Properties['fileCount']) { [int]$index.fileCount } else { if ($null -ne $index) { @($index.files).Count } else { -1 } }
    $masterCount = if ($null -ne $master) { [int]$master.meta.totalItems } else { -1 }
    $activeFileCount = @($activeFiles).Count

    $checks = [ordered]@{
        indexCountMatchesMaster     = ($indexCount -eq $masterCount)
        indexFileCountMatchesActive = ($indexFileCount -eq $activeFileCount)
        bundleCountMatchesActive    = ($bundleCount -eq $activeFileCount)
    }

    $isHealthy = ($checks.indexCountMatchesMaster -and $checks.indexFileCountMatchesActive -and $checks.bundleCountMatchesActive)
    if ($IncludeStaleCheck -and $null -ne $stale -and $stale.total -gt 0) { $isHealthy = $false }

    return [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        isHealthy   = $isHealthy
        counts      = [ordered]@{
            indexCount      = $indexCount
            masterCount     = $masterCount
            indexFileCount  = $indexFileCount
            bundleCount     = $bundleCount
            activeFileCount = $activeFileCount
        }
        checks      = $checks
        interruptions = $stale
    }
}

function Invoke-PipelineBatchCycle {
    <#
    .SYNOPSIS  Process pipeline items in configurable small batches.
    .DESCRIPTION
        Selects up to BatchSize items whose status matches TargetStatus (default: IN_PROGRESS)
        and attempts to advance each one toward completion.  Advancement logic:
          - Bug/SchedulerFailure items → calls Invoke-BugToPipelineProcessor if available
          - Items with all 'steps' marked done → transitions to TESTING
          - Items stale beyond StaleDays with no updates → transitions to BLOCKED with a note
          - All others → records a lastChecked audit stamp without a state change
        Returns a summary hashtable: batchSize, target, processed, advanced, stalled, skipped, errors.
    .PARAMETER WorkspacePath  Root workspace path.
    .PARAMETER BatchSize      Maximum items to process per cycle (default: 10).
    .PARAMETER TargetStatus   Status filter for items to pick up (default: IN_PROGRESS).
    .PARAMETER StaleDays      Days without update before moving to BLOCKED (default: 7).
    .PARAMETER WhatIf         Simulate without persisting any changes.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [ValidateRange(1,500)] [int]$BatchSize    = 10,
        [string]$TargetStatus                     = 'IN_PROGRESS',
        [ValidateRange(1,365)] [int]$StaleDays    = 7,
        [switch]$WhatIf
    )

    $result = [ordered]@{
        batchSize = $BatchSize
        target    = $TargetStatus
        processed = 0
        advanced  = 0
        stalled   = 0
        skipped   = 0
        errors    = @()
    }

    try {
        $normTarget = ConvertTo-PipelineStatus -Status $TargetStatus
        $items      = @(Get-PipelineItems -WorkspacePath $WorkspacePath -Status $normTarget |
                         Select-Object -First $BatchSize)

        if ($items.Count -eq 0) {
            Write-AppLog -Message "PipelineBatchCycle: no $normTarget items found (batch=$BatchSize)" -Level 'Info'
            return $result
        }

        $staleCutoff = (Get-Date).AddDays(-[Math]::Abs($StaleDays)).ToUniversalTime()

        foreach ($item in $items) {
            $result.processed++
            $itemId = $item.id
            try {
                $advanced = $false

                # 1. Bug items — delegate to BugToPipelineProcessor
                $isBug = ($item.type -in @('Bug','bug','BUG','SchedulerFailure'))
                if ($isBug -and (Get-Command 'Invoke-BugToPipelineProcessor' -ErrorAction SilentlyContinue)) {
                    if (-not $WhatIf) {
                        $bugResult = Invoke-BugToPipelineProcessor -WorkspacePath $WorkspacePath -DetectedBugs @($item)
                        if ($bugResult -and ($bugResult.resolved -gt 0 -or $bugResult.processed -gt 0)) {
                            $advanced = $true
                        }
                    } else {
                        $advanced = $true
                    }
                }

                # 2. Steps-based completion — all steps done → advance to TESTING
                if (-not $advanced -and $item.PSObject.Properties['steps']) {
                    $steps = @($item.steps)
                    if ($steps.Count -gt 0 -and ($steps | Where-Object { $_.done -ne $true }).Count -eq 0) {
                        if (-not $WhatIf) {
                            Update-PipelineItemStatus -WorkspacePath $WorkspacePath -ItemId $itemId -NewStatus 'TESTING' -Notes 'All steps complete — auto-advanced by BatchCycle' | Out-Null
                        }
                        $advanced = $true
                    }
                }

                # 3. Stale check — no update within StaleDays → BLOCKED
                if (-not $advanced) {
                    $tsRaw = if ($item.PSObject.Properties['lastUpdated'] -and $item.lastUpdated) { $item.lastUpdated }
                             elseif ($item.PSObject.Properties['executedAt'] -and $item.executedAt) { $item.executedAt }
                             else { $null }
                    if ($tsRaw) {
                        $ts = $null
                        if ([System.DateTimeOffset]::TryParse($tsRaw, [ref]$ts) -and $ts.UtcDateTime -lt $staleCutoff) {
                            if (-not $WhatIf) {
                                Update-PipelineItemStatus -WorkspacePath $WorkspacePath -ItemId $itemId -NewStatus 'BLOCKED' -Notes "Auto-blocked: no activity for ${StaleDays}+ days (BatchCycle)" | Out-Null
                            }
                            $result.stalled++
                            Write-AppLog -Message "PipelineBatchCycle: stale $itemId moved to BLOCKED" -Level 'Warning'
                            continue
                        }
                    }
                }

                # 4. Audit stamp — record lastChecked, no state change
                if ($advanced) {
                    $result.advanced++
                } else {
                    if (-not $WhatIf) {
                        try {
                            $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath
                            if (Test-Path $regPath) {
                                $registry = Get-Content $regPath -Raw -Encoding UTF8 | ConvertFrom-Json
                                $found = @($registry.items) | Where-Object { $_.id -eq $itemId }
                                if ($found) {
                                    $found | Add-Member -MemberType NoteProperty -Name 'lastChecked' -Value (Get-Date).ToUniversalTime().ToString('o') -Force
                                    $registry | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path $regPath -Encoding UTF8
                                }
                            }
                        } catch { }
                    }
                    $result.skipped++
                }
            } catch {
                $result.errors += "Item $itemId : $($_.Exception.Message)"
                Write-AppLog -Message "PipelineBatchCycle error on $itemId : $($_.Exception.Message)" -Level 'Error'
            }
        }
        Write-AppLog -Message "PipelineBatchCycle: processed=$($result.processed) advanced=$($result.advanced) stalled=$($result.stalled) skipped=$($result.skipped) errors=$($result.errors.Count) [batch=$BatchSize target=$normTarget]" -Level 'Info'
    } catch {
        $result.errors += $_.Exception.Message
        Write-AppLog -Message "PipelineBatchCycle fatal: $($_.Exception.Message)" -Level 'Error'
    }
    return $result
}

function Invoke-PipelineArtifactRefresh {
    <#
    .SYNOPSIS  Refresh the derived pipeline artifacts used by reports and dashboards.
        .DESCRIPTION
      Detailed behaviour: Invoke pipeline artifact refresh.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $result = [ordered]@{}
    $result.master = Export-CentralMasterToDo -WorkspacePath $WorkspacePath
    $result.bundle = Update-TodoBundle -WorkspacePath $WorkspacePath
    $result.index  = Update-PipelineIndex -WorkspacePath $WorkspacePath
    return $result
}

function Invoke-PipelineRegistryCompact {
    <#
    .SYNOPSIS  Archive old completed/closed pipeline items to reduce live registry size.
    .DESCRIPTION
        Items with status Done or Closed whose lastUpdated is older than AgeDays are moved
        to a monthly archive file (config/cron-aiathon-pipeline-archive-YYYY-MM.json).
        The live registry is then rewritten with the remaining items.
        No data is deleted; archive files are cumulative across months.
    .PARAMETER WorkspacePath  Root workspace path.
    .PARAMETER AgeDays        Age threshold in days (default: 30).
    .PARAMETER WhatIf         Report what would be archived without making changes.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [int]$AgeDays   = 30
    )

    $result = [ordered]@{
        archived = 0
        kept     = 0
        errors   = @()
        archiveFile = $null
    }

    try {
        $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath
        if (-not (Test-Path $regPath)) {
            $result.errors += "Registry file not found: $regPath"
            return $result
        }

        $raw = Get-Content $regPath -Raw -Encoding UTF8
        if (-not $raw -or $raw.Trim().Length -eq 0) {
            $result.errors += "Registry file is empty"
            return $result
        }

        $registry = $raw | ConvertFrom-Json
        if (-not $registry.items) {
            $result.errors += "Registry has no items array"
            return $result
        }

        $cutoff      = (Get-Date).AddDays(-[Math]::Abs($AgeDays)).ToUniversalTime()
        $archivable  = [System.Collections.Generic.List[object]]::new()
        $live        = [System.Collections.Generic.List[object]]::new()
        $archiveStatuses = @('Done','Closed','done','closed','DONE','CLOSED')

        foreach ($item in $registry.items) {
            $isArchivable = $false
            if ($item.status -in $archiveStatuses) {
                $ts = $null
                $tsRaw = if ($item.lastUpdated) { $item.lastUpdated } elseif ($item.createdAt) { $item.createdAt } else { $null }
                if ($tsRaw -and [System.DateTimeOffset]::TryParse($tsRaw, [ref]$ts)) {
                    if ($ts.UtcDateTime -lt $cutoff) { $isArchivable = $true }
                }
            }
            if ($isArchivable) { $archivable.Add($item) } else { $live.Add($item) }
        }

        $result.archived = $archivable.Count
        $result.kept     = $live.Count

        if ($WhatIfPreference) {
            Write-AppLog -Message "PipelineCompact WhatIf: would archive $($archivable.Count) items, keep $($live.Count)" -Level 'Info'
            return $result
        }

        if ($archivable.Count -eq 0) {
            Write-AppLog -Message "PipelineCompact: no items eligible for archiving (threshold: ${AgeDays}d)" -Level 'Info'
            return $result
        }

        # Write archive file (cumulative append per month)
        $monthTag   = (Get-Date).ToString('yyyy-MM')
        $archiveDir = Join-Path $WorkspacePath 'config'
        $archivePath = Join-Path $archiveDir "cron-aiathon-pipeline-archive-$monthTag.json"
        $result.archiveFile = $archivePath

        $existingArchive = @()
        if (Test-Path $archivePath) {
            $archRaw = Get-Content $archivePath -Raw -Encoding UTF8
            if ($archRaw -and $archRaw.Trim().Length -gt 0) {
                $existingArchive = ($archRaw | ConvertFrom-Json)
                if ($existingArchive -isnot [array]) { $existingArchive = @($existingArchive) }
            }
        }
        $combined = @($existingArchive) + @($archivable)
        $combined | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path $archivePath -Encoding UTF8

        # Write trimmed live registry (Compress for storage efficiency)
        $registry.items = @($live)
        $registry | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path $regPath -Encoding UTF8

        Write-AppLog -Message "PipelineCompact: archived $($archivable.Count) items to $archivePath; $($live.Count) items remain in live registry" -Level 'Info'
    } catch {
        $result.errors += $_.Exception.Message
        Write-AppLog -Message "PipelineCompact error: $($_.Exception.Message)" -Level 'Error'
    }

    return $result
}

# ========================== BUG STATUS ROLLUP ==========================

function Invoke-BugStatusRollup {
    <#
    .SYNOPSIS  Aggregate child Bugs2FIX and Items2ADD statuses to drive Bug item status.
    .DESCRIPTION
        Finds all Bugs2FIX children (parentId = BugItemId) and Items2ADD with bugReferrals
        containing BugItemId. Computes aggregate state and promotes the Bug:
          - Any child IN_PROGRESS and Bug is OPEN -> Bug becomes IN_PROGRESS
          - All children DONE or CLOSED (at least one) -> Bug becomes DONE (implementedAt stamped)
        Does NOT call Update-PipelineItemStatus to avoid recursive loops.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$BugItemId
    )

    $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath
    try {
        $raw = Get-Content $regPath -Raw -ErrorAction Stop
        if (-not $raw -or $raw.Trim().Length -eq 0) {
            Write-AppLog -Message "Invoke-BugStatusRollup: registry empty, skipping rollup for '$BugItemId'." -Level Warning
            return
        }
        $registry = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $registry) {
            Write-AppLog -Message "Invoke-BugStatusRollup: registry parse returned null for '$BugItemId'." -Level Warning
            return
        }
    } catch {
        Write-AppLog -Message "Invoke-BugStatusRollup: failed to load registry: $_" -Level Warning
        return
    }

    # Locate the Bug item (only rollup Bug-typed items)
    $bugItem = $null
    foreach ($item in @($registry.bugs)) {
        if ($null -ne $item -and $item.PSObject.Properties['id'] -and $item.id -eq $BugItemId) {
            $bugItem = $item
            break
        }
    }
    if ($null -eq $bugItem) {
        Write-AppLog -Message "Invoke-BugStatusRollup: Bug '$BugItemId' not found — may not be a Bug type item." -Level Debug
        return
    }

    $currentBugStatus = ConvertTo-PipelineStatus -Status $bugItem.status

    # Collect child statuses: Bugs2FIX with parentId + Items2ADD with bugReferrals containing BugItemId
    $childStatuses = @()
    foreach ($fx in @($registry.bugs2FIX)) {
        if ($null -ne $fx -and $fx.PSObject.Properties['parentId'] -and [string]$fx.parentId -eq $BugItemId) {
            $childStatuses += ConvertTo-PipelineStatus -Status $fx.status
        }
    }
    foreach ($add in @($registry.items2ADD)) {
        if ($null -ne $add -and $add.PSObject.Properties['bugReferrals']) {
            if (@($add.bugReferrals) -contains $BugItemId) {
                $childStatuses += ConvertTo-PipelineStatus -Status $add.status
            }
        }
    }
    if (@($childStatuses).Count -eq 0) { return }  # no children to aggregate

    $nonDoneCount  = @($childStatuses | Where-Object { $_ -notin @('DONE','CLOSED') }).Count
    $allDone       = ($nonDoneCount -eq 0)
    $anyInProgress = $childStatuses -contains 'IN_PROGRESS'

    $newBugStatus = $null
    if ($allDone) {
        $newBugStatus = 'DONE'
    } elseif ($anyInProgress -and $currentBugStatus -eq 'OPEN') {
        $newBugStatus = 'IN_PROGRESS'
    }

    if ($null -eq $newBugStatus -or $newBugStatus -eq $currentBugStatus) { return }
    if (-not (Test-StatusTransition -CurrentStatus $currentBugStatus -NewStatus $newBugStatus)) { return }

    # Apply transition directly to avoid recursion through Update-PipelineItemStatus
    $nowTs = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($item in @($registry.bugs)) {
        if ($null -ne $item -and $item.PSObject.Properties['id'] -and $item.id -eq $BugItemId) {
            $item.status   = $newBugStatus
            $item.modified = $nowTs
            if ($item.PSObject.Properties['sessionModCount']) { $item.sessionModCount++ }
            # Backfill and update extended tracking fields
            foreach ($fld in @('lastSeenAt','implementedAt','firstSeenAt')) {
                if (-not $item.PSObject.Properties[$fld]) {
                    $item | Add-Member -NotePropertyName $fld -NotePropertyValue $null -Force
                }
            }
            if (-not $item.PSObject.Properties['fixesImplementedCount']) {
                $item | Add-Member -NotePropertyName 'fixesImplementedCount' -NotePropertyValue 0 -Force
            }
            $item.lastSeenAt = $nowTs
            if ($null -eq $item.firstSeenAt) {
                $item.firstSeenAt = if ($item.PSObject.Properties['created'] -and $null -ne $item.created) { $item.created } else { $nowTs }
            }
            if ($newBugStatus -eq 'DONE') {
                $item.implementedAt       = $nowTs
                $item.fixesImplementedCount++
                $registry.statistics.totalItemsDone++
            }
            $null = Write-PipelineItemFile -WorkspacePath $WorkspacePath -Item $item
            break
        }
    }

    $registry.meta.lastModified = $nowTs
    try {
        $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $regPath -Encoding UTF8 -ErrorAction Stop
        Write-AppLog -Message "BugStatusRollup: '$BugItemId' $currentBugStatus -> $newBugStatus" -Level Info
    } catch {
        Write-AppLog -Message "Invoke-BugStatusRollup: failed to save registry for '$BugItemId': $_" -Level Warning
    }
}

# ========================== REGRESSION GUARD ==========================

function Test-BugSinResolved {
    <#
    .SYNOPSIS  Before closing a Bug, verify its linked SIN is resolved.
        .DESCRIPTION
      Detailed behaviour: Test bug sin resolved.
    #>
    [OutputType([System.Boolean])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$SinId
    )

    if ([string]::IsNullOrWhiteSpace($SinId)) { return $true }
    $sinDir = Join-Path $WorkspacePath 'sin_registry'
    $sinFile = Join-Path $sinDir "$SinId.json"
    if (-not (Test-Path $sinFile)) { return $true }

    try {
        $sin = Get-Content $sinFile -Raw | ConvertFrom-Json
        return ([bool]$sin.is_resolved)
    } catch { return $true }
}

# ========================== HELP MENU ==========================

function Show-PipelineHelp {
    <#
    .SYNOPSIS  Display quick usage help for CronAiAthon pipeline operations.
        .DESCRIPTION
      Detailed behaviour: Show pipeline help.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Register','Run','Status','Reset','Help')]
        [string]$Action = 'Help',

        [ValidateSet('Debug','Info','Warning','Error','Critical')]
        [string]$EventLevel = 'Info',

        [string]$LogToFile = 'auto',
        [switch]$ShowRainbow
    )

    if ($ShowRainbow) {
        Write-Host '=== CronAiAthon Pipeline Help ===' -ForegroundColor Cyan
    }

    $lines = @(
        'Actions: Register | Run | Status | Reset | Help',
        "Selected Action: $Action",
        "EventLevel: $EventLevel",
        'Examples:',
        '  Show-PipelineHelp -Action Status',
        '  Show-PipelineHelp -Action Run -EventLevel Warning',
        '  Show-PipelineHelp -Action Register -LogToFile auto',
        '  Show-PipelineHelp -Action Help -ShowRainbow'
    )
    foreach ($line in $lines) {
        Write-Host $line
    }

    if (-not [string]::IsNullOrWhiteSpace($LogToFile)) {
        $logPath = if ($LogToFile -eq 'auto') {
            Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs') 'pipeline-events-help.log'
        } else {
            $LogToFile
        }
        try {
            $logDir = Split-Path -Path $logPath -Parent
            if ($logDir -and -not (Test-Path $logDir)) {
                New-Item -Path $logDir -ItemType Directory -Force | Out-Null
            }
            Add-Content -Path $logPath -Value ("[{0}] Help viewed: Action={1}; EventLevel={2}" -f (Get-Date -Format o), $Action, $EventLevel) -Encoding UTF8
        } catch {
            Write-Verbose "Show-PipelineHelp log write failed: $($_.Exception.Message)"
        }
    }
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
Export-ModuleMember -Function @(
    'New-PipelineItem',
    'ConvertTo-PipelineItemType',
    'ConvertTo-PipelineStatus',
    'Initialize-PipelineRegistry',
    'Add-PipelineItem',
    'Update-PipelineItemStatus',
    'Test-StatusTransition',
    'Get-PipelineItems',
    'Get-PipelineStatistics',
    'Invoke-SinRegistryFeedback',
    'ConvertTo-Bugs2FIX',
    'ConvertTo-Items2ADD',
    'Get-CentralMasterToDo',
    'Export-CentralMasterToDo',
    'Get-PipelineRegistryPath',
    'Set-PipelineItemBatchStatus',
    'Get-PipelineHealthMetrics',
    'Get-ValidCategories',
    'Resolve-ItemCategory',
    'Set-OutlinePhase',
    'Confirm-OutlineVersion',
    'Update-TodoBundle',
    'Update-PipelineIndex',
    'Get-PipelineInterruptions',
    'Test-PipelineArtifactIntegrity',
    'Invoke-PipelineArtifactRefresh',
    'Invoke-PipelineBatchCycle',
    'Invoke-PipelineRegistryCompact',
    'Test-BugSinResolved',
    'Invoke-BugStatusRollup',
    'Show-PipelineHelp'
)








