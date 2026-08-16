# VersionTag: 2608.B1.V53.0
# SupportPS5.1: YES
# SupportsPS7.6: YES
# FileRole: Pipeline
<#
.SYNOPSIS
    Recycle a pipeline item into approval, or explicitly re-approve it into planning.
.DESCRIPTION
    Keeps the original item identity and records recycle history in the registry and
    item JSON. Use -Reapprove only after the item has been reviewed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$WorkspacePath,
    [Parameter(Mandatory)] [string]$ItemId,
    [string]$Reason = 'Reconsider for a future pipeline cycle',
    [switch]$Reapprove,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $WorkspacePath 'modules\CronAiAthon-Pipeline.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Pipeline module not found: $modulePath" }
try {
    Import-Module -Name $modulePath -Force -ErrorAction Stop
} catch {
    throw "Failed to import pipeline module: $($_.Exception.Message)"
}

$result = Invoke-PipelineItemRecycle -WorkspacePath $WorkspacePath -ItemId $ItemId -Reason $Reason -Reapprove:$Reapprove
if ($null -eq $result) { exit 1 }

[ordered]@{
    id = [string]$result.id
    status = [string]$result.status
    approvalState = [string]$result.approvalState
    recycleCount = [int]$result.recycleCount
    reapproved = [bool]$Reapprove.IsPresent
} | ConvertTo-Json -Depth 5
if (-not $PassThru) { exit 0 }
$result
