# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-27)
# SupportsPS7.6: YES(As of: 2026-04-27)
# SupportPS5.1TestedDate: 2026-04-27
# SupportsPS7.6TestedDate: 2026-04-27
# FileRole: Module
# SchemaVersion: ErrorLinking/1.0
# Author: The Establishment
# Date: 2026-04-27
#Requires -Version 5.1
<#
.SYNOPSIS
    CronAiAthon Error Linking -- Auto-creates Bugs2FIX items when functions/pipelines fail.
.DESCRIPTION
    Captures runtime errors, parse errors, and pipeline agent step failures, then automatically:
    1. Creates Bug item in pipeline registry
    2. Creates linked Bugs2FIX item for remediation
    3. Logs event with SYSLOG severity level
    4. Tracks in sin registry for recurrence detection

.NOTES
    Author   : The Establishment
    Version  : 2604.B0.V1.0
    Created  : 27th April 2026
    FileRole : Module
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ========================== ERROR LINKING FUNCTIONS ==========================

function New-ErrorBugItem {
    <#
    .SYNOPSIS  Create a Bug item from a caught exception.
    .PARAMETER Exception
        The System.Management.Automation.ErrorRecord to convert.
    .PARAMETER FunctionName
        Name of the function where error occurred.
    .PARAMETER Source
        Origin: RuntimeError, PipelineError, ParseError, etc.
    .PARAMETER AffectedFiles
        Files involved in the failure.
    .OUTPUTS   [hashtable] A Bug pipeline item.
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord]$Exception,
        [Parameter(Mandatory)] [string]$FunctionName,
        [ValidateSet('RuntimeError','PipelineError','ParseError','DataError','SecurityError','AccessError','DependencyError')]
        [string]$Source = 'RuntimeError',
        [string[]]$AffectedFiles = @()
    )
    if (-not $PSCmdlet.ShouldProcess('New-ErrorBugItem', 'Create')) { return }


    $category = switch -Regex ($Exception.CategoryInfo.Category.ToString()) {
        'ParseError' { 'parsing' }
        'RuntimeError' { 'runtime' }
        'InvalidArgument' { 'validation' }
        'PermissionDenied' { 'security' }
        'ObjectNotFound' { 'dependency' }
        default { 'runtime' }
    }

    $severity = if ($Exception.ErrorDetails -like '*CRITICAL*' -or $Exception.InvocationInfo.Line -like '*throw*') { 'CRITICAL' } else { 'HIGH' }

    $description = @(
        "Function: $FunctionName"
        "Category: $($Exception.CategoryInfo.Category)"
        "Message: $($Exception.Exception.Message)"
        "Script: $($Exception.InvocationInfo.ScriptName)"
        "Line: $($Exception.InvocationInfo.ScriptLineNumber)"
        ""
        "Stack Trace:"
        "$($Exception.ScriptStackTrace)"
    ) -join "`n"

    return @{
        type             = 'Bug'
        title            = "Error in ${FunctionName}: $($Exception.Exception.Message.Substring(0, 60))"
        description      = $description
        priority         = $severity
        source           = $Source
        category         = $category
        affectedFiles    = @($AffectedFiles)
        suggestedBy      = 'ErrorHandler'
        outlineTag       = 'ERROR-CAPTURE-v0'
        outlinePhase     = 'assessment'
        outlineVersion   = 'v0'
    }
}

function New-ErrorBugs2FIXItem {
    <#
    .SYNOPSIS  Create a Bugs2FIX item as child of a Bug.
    .PARAMETER BugItem
        The Bug item (or Bug ID) to fix.
    .PARAMETER SuggestedFix
        Optional: description of potential remediation.
    .OUTPUTS   [hashtable] A Bugs2FIX pipeline item.
        .DESCRIPTION
      Detailed behaviour: New error bugs2 f i x item.
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $BugItem,
        [string]$SuggestedFix = 'Root cause analysis required'
    )
    if (-not $PSCmdlet.ShouldProcess('New-ErrorBugs2FIXItem', 'Create')) { return }


    $bugId = if ($BugItem -is [hashtable]) { $BugItem.id } else { [string]$BugItem }
    $bugTitle = if ($BugItem -is [hashtable]) { $BugItem.title } else { 'Unknown Bug' }
    Write-Verbose "Creating Bugs2FIX child for Bug ID: $bugId"

    return @{
        type            = 'Bugs2FIX'
        title           = "FIX: $($bugTitle.Substring(0, 60))"
        description     = $SuggestedFix
        priority        = 'HIGH'
        source          = 'BugTracker'
        category        = 'remediation'
        parentId        = $bugId
        bugReferrals    = @($bugId)
        outlineTag      = 'BUGS2FIX-v0'
        outlinePhase    = 'planning'
        outlineVersion  = 'v0'
    }
}

function Add-ErrorToPipeline {
    <#
    .SYNOPSIS  Capture error, create Bug + Bugs2FIX, log event, persist to pipeline.
    .PARAMETER Exception
        The caught ErrorRecord.
    .PARAMETER FunctionName
        Name of the failing function.
    .PARAMETER WorkspacePath
        Path to workspace root (for pipeline registry).
    .PARAMETER AffectedFiles
        Files that were being processed.
    .PARAMETER ErrorSource
        Origin classification (RuntimeError, PipelineError, etc.)
    .OUTPUTS   [PSCustomObject] with bugId, bugs2FixId, and logStatus.
        .DESCRIPTION
      Detailed behaviour: Add error to pipeline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord]$Exception,
        [Parameter(Mandatory)] [string]$FunctionName,
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [string[]]$AffectedFiles = @(),
        [string]$ErrorSource = 'RuntimeError'
    )

    try {
        # 1. Create Bug item
        $bugItem = New-ErrorBugItem -Exception $Exception -FunctionName $FunctionName `
                                     -Source $ErrorSource -AffectedFiles $AffectedFiles
        $bugItem.created = (Get-Date).ToUniversalTime().ToString('o')
        $bugItem.modified = $bugItem.created
        $bugItem.status = 'OPEN'
        $bugItem.sessionModCount = 1

        # Assign ID
        $bugItem.id = "Bug-$(Get-Date -Format 'yyyyMMddHHmmss')-$(([guid]::NewGuid()).ToString().Substring(0,8))"

        # 2. Create Bugs2FIX item
        $bugs2fixItem = New-ErrorBugs2FIXItem -BugItem $bugItem
        $bugs2fixItem.created = $bugItem.created
        $bugs2fixItem.modified = $bugs2fixItem.created
        $bugs2fixItem.status = 'OPEN'
        $bugs2fixItem.sessionModCount = 1
        $bugs2fixItem.id = "Bugs2FIX-$(Get-Date -Format 'yyyyMMddHHmmss')-$(([guid]::NewGuid()).ToString().Substring(0,8))"

        # 3. Add both to pipeline (requires CronAiAthon-Pipeline module)
        if (Get-Command -Name 'Add-PipelineItem' -ErrorAction SilentlyContinue) {
            $null = Add-PipelineItem -WorkspacePath $WorkspacePath -Item $bugItem
            $null = Add-PipelineItem -WorkspacePath $WorkspacePath -Item $bugs2fixItem
        }

        # 4. Log event with SYSLOG level 3 (Error)
        if (Get-Command -Name 'Write-EventLogEntry' -ErrorAction SilentlyContinue) {
            Write-EventLogEntry -Source 'CronAiAthon-ErrorLinker' -Level 'Error' `
                -Message "Pipeline[$FunctionName] FAILED: $($Exception.Exception.Message) -> BugId: $($bugItem.id)" `
                -EventId 3000
        }

        return [PSCustomObject]@{
            Success         = $true
            BugId           = $bugItem.id
            Bugs2FixId      = $bugs2fixItem.id
            BugTitle        = $bugItem.title
            ErrorMessage    = $Exception.Exception.Message
            Timestamp       = (Get-Date).ToUniversalTime()
            AffectedFiles   = $AffectedFiles
        }
    } catch {
        return [PSCustomObject]@{
            Success         = $false
            Error           = $_.Exception.Message
            ErrorMessage    = "Failed to link error to pipeline: $_"
            Timestamp       = (Get-Date).ToUniversalTime()
        }
    }
}

function Add-PipelineStepErrorLink {
    <#
    .SYNOPSIS  Link a pipeline agent step error to Bugs2FIX.
    .PARAMETER AgentName
        Name of the agent running the step.
    .PARAMETER StepName
        Name of the failing step.
    .PARAMETER ErrorMessage
        Error text from step execution.
    .PARAMETER WorkspacePath
        Path to workspace.
    .PARAMETER Metrics
        Optional: metrics dict from step execution context.
    .OUTPUTS   [PSCustomObject]
        .DESCRIPTION
      Detailed behaviour: Add pipeline step error link.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$AgentName,
        [Parameter(Mandatory)] [string]$StepName,
        [Parameter(Mandatory)] [string]$ErrorMessage,
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [hashtable]$Metrics = @{}
    )

    $bugItem = @{
        type            = 'Bug'
        title           = "Pipeline Agent Error: [$AgentName] $StepName failed"
        description     = @(
            "Agent: $AgentName"
            "Step: $StepName"
            "Error: $ErrorMessage"
            "Timestamp: $(Get-Date -Format 'o')"
            ""
            "Metrics:"
            ($Metrics.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" } | Out-String)
        ) -join "`n"
        priority        = 'HIGH'
        source          = 'PipelineError'
        category        = 'pipeline-agent'
        suggestedBy     = $AgentName
        outlineTag      = 'PIPELINE-ERROR-v0'
        outlinePhase    = 'assessment'
    }

    $bugItem.id = "Bug-$(Get-Date -Format 'yyyyMMddHHmmss')-$(([guid]::NewGuid()).ToString().Substring(0,8))"
    $bugItem.created = (Get-Date).ToUniversalTime().ToString('o')
    $bugItem.modified = $bugItem.created
    $bugItem.status = 'OPEN'
    $bugItem.sessionModCount = 1

    $bugs2fixItem = @{
        type            = 'Bugs2FIX'
        title           = "FIX: [$AgentName] $StepName"
        description     = "Step $StepName on agent $AgentName failed. Error: $ErrorMessage`n`nAction: Analyze agent step implementation and error context. May require agent update or input data validation."
        priority        = 'HIGH'
        source          = 'PipelineError'
        category        = 'pipeline-agent'
        parentId        = $bugItem.id
        bugReferrals    = @($bugItem.id)
        outlineTag      = 'BUGS2FIX-v0'
        outlinePhase    = 'planning'
    }

    $bugs2fixItem.id = "Bugs2FIX-$(Get-Date -Format 'yyyyMMddHHmmss')-$(([guid]::NewGuid()).ToString().Substring(0,8))"
    $bugs2fixItem.created = $bugItem.created
    $bugs2fixItem.modified = $bugs2fixItem.created
    $bugs2fixItem.status = 'OPEN'
    $bugs2fixItem.sessionModCount = 1

    # Add to pipeline
    if (Get-Command -Name 'Add-PipelineItem' -ErrorAction SilentlyContinue) {
        $null = Add-PipelineItem -WorkspacePath $WorkspacePath -Item $bugItem
        $null = Add-PipelineItem -WorkspacePath $WorkspacePath -Item $bugs2fixItem
    }

    return [PSCustomObject]@{
        Success      = $true
        BugId        = $bugItem.id
        Bugs2FixId   = $bugs2fixItem.id
        Agent        = $AgentName
        Step         = $StepName
        ErrorMessage = $ErrorMessage
    }
}

# ========================== EXPORTS ================================

Export-ModuleMember -Function @(
    'New-ErrorBugItem',
    'New-ErrorBugs2FIXItem',
    'Add-ErrorToPipeline',
    'Add-PipelineStepErrorLink'
)

<# Outline:
    Module Purpose:
      Capture function/pipeline errors and auto-create Bug + Bugs2FIX items for tracking.
      Enables automatic error-to-action workflow without manual bug filing.

    Key Functions:
      - New-ErrorBugItem: Convert PowerShell ErrorRecord to Bug item
      - New-ErrorBugs2FIXItem: Create Bugs2FIX remediation item
      - Add-ErrorToPipeline: Full workflow (error → Bug → Bugs2FIX → log → persist)
      - Add-PipelineStepErrorLink: Agent step error capture

    Schema: ErrorLinking/1.0
    Outline Tag: ERROR-CAPTURE-v0, BUGS2FIX-v0
#>

<# Problems:
    - Requires CronAiAthon-Pipeline module to be loaded to auto-persist items
    - EventLog logging optional (Write-EventLogEntry must exist)
    - No deduplication yet for repeated errors (same function, same line)
#>

<# Todo:
    - [ ] Add error deduplication by function + line number
    - [ ] Implement error severity escalation (repeated errors → CRITICAL)
    - [ ] Add suggested fixes heuristics based on error message regex
    - [ ] Integrate with SinRegistry for recurring error detection
    - [ ] Add metrics: error rate per function, error trend over time
#>

