#Requires -Version 5.1
# Author: The Establishment
# Date: 2604
# VersionTag: 2604.B2.V31.0
# FileRole: Script
<#
.SYNOPSIS
    Normalize todo item status/type values to canonical pipeline vocabulary.
.DESCRIPTION
    Scans active todo JSON files, maps legacy aliases through CronAiAthon-Pipeline
    conversion functions, and optionally writes normalized values back to disk.
.PARAMETER WorkspacePath
    Root workspace path. Defaults to repository root.
.PARAMETER Apply
    Persist normalized status/type values to disk. Without -Apply, runs in preview mode.
.PARAMETER WriteReport
    Write a machine-readable JSON report under ~REPORTS/PipelineNormalization.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [switch]$Apply,
    [switch]$WriteReport,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $WorkspacePath) {
    $WorkspacePath = Split-Path -Parent $PSScriptRoot
}

$modulePath = Join-Path $WorkspacePath 'modules\CronAiAthon-Pipeline.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Pipeline module not found: $modulePath"
}
Import-Module $modulePath -Force -ErrorAction Stop

$todoDir = Join-Path $WorkspacePath 'todo'
if (-not (Test-Path $todoDir)) {
    throw "Todo directory not found: $todoDir"
}

$excludeNames = @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json')
$files = @(
    Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $excludeNames -notcontains $_.Name -and $_.FullName -notlike "*\~*\*" } |
    Sort-Object Name
)
$changes = @()
$errors = @()

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string]$PropertyName,
        $DefaultValue = ''
    )

    if ($null -eq $InputObject) { return $DefaultValue }
    if ($InputObject.PSObject.Properties.Name -contains $PropertyName) {
        return $InputObject.$PropertyName
    }
    return $DefaultValue
}

foreach ($file in $files) {
    try {
        $item = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $currentStatus = [string](Get-ObjectPropertyValue -InputObject $item -PropertyName 'status' -DefaultValue '')
        $currentType = [string](Get-ObjectPropertyValue -InputObject $item -PropertyName 'type' -DefaultValue '')
        $normalizedStatus = ConvertTo-PipelineStatus -Status $currentStatus
        $normalizedType = ConvertTo-PipelineItemType -Type $currentType

        $hasStatusChange = ($currentStatus -ne $normalizedStatus)
        $hasTypeChange = ($currentType -ne $normalizedType)
        if (-not $hasStatusChange -and -not $hasTypeChange) { continue }

        $changes += [ordered]@{
            file = $file.Name
            id = [string](Get-ObjectPropertyValue -InputObject $item -PropertyName 'id' -DefaultValue (Get-ObjectPropertyValue -InputObject $item -PropertyName 'todo_id' -DefaultValue ''))
            statusFrom = $currentStatus
            statusTo = $normalizedStatus
            typeFrom = $currentType
            typeTo = $normalizedType
        }

        if ($Apply) {
            if ($item.PSObject.Properties.Name -contains 'status') {
                $item.status = $normalizedStatus
            } else {
                Add-Member -InputObject $item -MemberType NoteProperty -Name 'status' -Value $normalizedStatus
            }

            if ($item.PSObject.Properties.Name -contains 'type') {
                $item.type = $normalizedType
            } else {
                Add-Member -InputObject $item -MemberType NoteProperty -Name 'type' -Value $normalizedType
            }

            if ($item.PSObject.Properties.Name -contains 'modified') {
                $item.modified = (Get-Date).ToUniversalTime().ToString('o')
            } else {
                Add-Member -InputObject $item -MemberType NoteProperty -Name 'modified' -Value ((Get-Date).ToUniversalTime().ToString('o'))
            }
            $item | ConvertTo-Json -Depth 10 | Set-Content -Path $file.FullName -Encoding UTF8
        }
    } catch {
        $errors += [ordered]@{
            file = $file.Name
            error = [string]$_.Exception.Message
        }
    }
}

$summary = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    workspacePath = $WorkspacePath
    applyMode = [bool]$Apply
    totalFilesScanned = @($files).Count
    changedFiles = @($changes).Count
    errorCount = @($errors).Count
    changes = $changes
    errors = $errors
}

$effectiveWriteReport = ($WriteReport -or -not [string]::IsNullOrWhiteSpace($ReportPath))
if ($effectiveWriteReport) {
    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        $reportDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'PipelineNormalization'
        if (-not (Test-Path $reportDir)) {
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        }
        $ReportPath = Join-Path $reportDir ("normalization-{0}.json" -f (Get-Date -Format 'yyMMddHHmm'))
    }
    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $ReportPath -Encoding UTF8
    $summary['reportPath'] = $ReportPath
}

$summary
