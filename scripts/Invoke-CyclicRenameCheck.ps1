#Requires -Version 5.1
# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
<#
.SYNOPSIS
    48-hour cyclic wrapper for Invoke-RenameProposal.ps1.
.DESCRIPTION
    Runs the rename proposal scanner in ScanOnly mode, creates todo items
    for any violations found, and updates the cyclic-tasks.json state file.
    Designed to be called by the PwShGUI-CyclicRenameCheck scheduled task.
.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 26th March 2026
    Config   : config\cyclic-tasks.json
.LINK
    ~README.md/REFERENCE-CONSISTENCY-STANDARD.md
#>

$ErrorActionPreference = 'Stop'
$scriptRoot  = $PSScriptRoot
$projectRoot = Split-Path $scriptRoot -Parent
$configDir   = Join-Path $projectRoot 'config'
$logsDir     = Join-Path $projectRoot 'logs'
$logFile     = Join-Path $logsDir 'cyclic-rename-check.log'
$stateFile   = Join-Path $configDir 'cyclic-tasks.json'
$renameScript = Join-Path $scriptRoot 'Invoke-RenameProposal.ps1'

function Write-CyclicLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Message"
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    $line | Add-Content -Path $logFile -Encoding UTF8
    Write-Host $line
}

function Get-CyclicState {
    if (-not (Test-Path $stateFile)) {
        return @{
            cyclicRenameCheck = @{
                lastRun       = $null
                intervalHours = 48
                lastResult    = @{ proposals = 0; todosCreated = 0 }
            }
        }
    }
    return Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-CyclicState {
    param($State)
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content $stateFile -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-CyclicLog '=== Cyclic Rename Check START ==='

if (-not (Test-Path $renameScript)) {
    Write-CyclicLog "ERROR: Rename proposal script not found: $renameScript"
    return
}

# Count existing rename proposals before
$todoDir = Join-Path $projectRoot 'todo'
$beforeCount = if (Test-Path $todoDir) {
    (Get-ChildItem -Path $todoDir -Filter 'todo-rename-*.json' -File -ErrorAction SilentlyContinue).Count
} else { 0 }

# Run rename proposal scanner (creates todos for violations)
Write-CyclicLog 'Running Invoke-RenameProposal.ps1 ...'
try {
    & $renameScript -Agent 'cron-cyclic'
} catch {
    Write-CyclicLog "ERROR: $($_.Exception.Message)"
}

# Count after
$afterCount = if (Test-Path $todoDir) {
    (Get-ChildItem -Path $todoDir -Filter 'todo-rename-*.json' -File -ErrorAction SilentlyContinue).Count
} else { 0 }
$newTodos = [Math]::Max(0, $afterCount - $beforeCount)

# Update state
$state = Get-CyclicState
if (-not $state.cyclicRenameCheck) {
    $state | Add-Member -NotePropertyName 'cyclicRenameCheck' -NotePropertyValue @{
        lastRun       = $null
        intervalHours = 48
        lastResult    = @{ proposals = 0; todosCreated = 0 }
    } -Force
}
$state.cyclicRenameCheck.lastRun = (Get-Date -Format 'o')
$state.cyclicRenameCheck.lastResult = @{
    proposals    = $afterCount
    todosCreated = $newTodos
}
Save-CyclicState $state

Write-CyclicLog "Completed: $afterCount total proposals, $newTodos new todos created."
Write-CyclicLog '=== Cyclic Rename Check END ==='


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




