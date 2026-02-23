#Requires -Version 5.1
# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS
# --- Structured lifecycle logging ---
if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
    Write-AppLog -Message "Started: $($MyInvocation.MyCommand.Name)" -Level 'Info'
}
    Scans workspace for files violating naming conventions and generates rename proposals as todo items.
.DESCRIPTION
    Checks files against naming rules defined in REFERENCE-CONSISTENCY-STANDARD.md:
      - Modules: PascalCase (.psm1)
      - Scripts: Verb-Noun (.ps1)
      - Config:  kebab-lower-case (.json/.xml)
      - Folders: lowercase; tilde-prefix for meta-dirs
      - No spaces in filenames

    Modes:
      -ScanOnly  List violations without creating todos
      -DryRun    Show what todos would be created
      -Execute   Perform renames, track with FileChangeTracker, create todos for manual review
.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 26th March 2026
    Config   : config\system-variables.xml
.LINK
    ~README.md/REFERENCE-CONSISTENCY-STANDARD.md
#>
param(
    [switch]$ScanOnly,
    [switch]$DryRun,
    [switch]$Execute,
    [string]$Agent = 'user'
)

$ErrorActionPreference = 'Stop'
$scriptRoot  = $PSScriptRoot
$projectRoot = Split-Path $scriptRoot -Parent
$todoDir     = Join-Path $projectRoot 'todo'
$trackerScript = Join-Path $scriptRoot 'Invoke-FileChangeTracker.ps1'
$todoMgrScript = Join-Path $scriptRoot 'Invoke-TodoManager.ps1'

# Approved PowerShell verbs (common subset)
$approvedVerbs = @(
    'Add','Clear','Close','Compare','Complete','Confirm','Connect','Convert','ConvertFrom','ConvertTo',
    'Copy','Debug','Disable','Disconnect','Enable','Enter','Exit','Export','Find','Format',
    'Get','Grant','Group','Hide','Import','Initialize','Install','Invoke','Join','Limit',
    'Lock','Measure','Merge','Mount','Move','New','Open','Optimize','Out','Ping',
    'Pop','Protect','Publish','Push','Read','Receive','Redo','Register','Remove','Rename',
    'Repair','Request','Reset','Resize','Resolve','Restart','Restore','Resume','Revoke','Save',
    'Search','Select','Send','Set','Show','Skip','Split','Start','Step','Stop',
    'Submit','Suspend','Switch','Sync','Test','Trace','Unblock','Undo','Uninstall','Unlock',
    'Unprotect','Unregister','Update','Use','Wait','Watch','Write','Launch'
)

$excludePaths = @('.history','node_modules','__pycache__','temp','.git','agents\focalpoint-null\focalpoint_null')

function Test-ExcludedPath {
    param([string]$FullPath)
    foreach ($ex in $excludePaths) {
        if ($FullPath -like "*\$ex\*" -or $FullPath -like "*\$ex") { return $true }
    }
    return $false
}

function Get-RelativePath {
    param([string]$FullPath)
    return $FullPath -replace [regex]::Escape($projectRoot), '' -replace '^[\\/]', ''
}

function Get-SuggestedName {
    param([string]$CurrentName, [string]$Rule)
    switch ($Rule) {
        'no-spaces'    { return $CurrentName -replace ' ', '-' }
        'kebab-lower'  { return ($CurrentName -creplace '([A-Z])', '-$1').TrimStart('-').ToLower() -replace '--+', '-' }
        default        { return $CurrentName }
    }
}

# ---------------------------------------------------------------------------
# Naming rules checks
# ---------------------------------------------------------------------------
function Get-NamingViolations {
    $violations = @()

    # Check .psm1 modules for PascalCase
    Get-ChildItem -Path (Join-Path $projectRoot 'modules') -Filter '*.psm1' -File -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-ExcludedPath $_.FullName) } |
        ForEach-Object {
            $baseName = $_.BaseName
            if ($baseName -match '\s') {
                $violations += [PSCustomObject]@{
                    Path = Get-RelativePath $_.FullName
                    Rule = 'no-spaces'
                    Message = "Module filename contains spaces: $($_.Name)"
                    Suggested = $_.Name -replace ' ', ''
                }
            }
        }

    # Check .ps1 scripts for Verb-Noun pattern (skip numbered payloads like Script1.ps1)
    $scriptDirs = @(
        (Join-Path $projectRoot 'scripts'),
        (Join-Path $projectRoot 'tests')
    )
    foreach ($dir in $scriptDirs) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem -Path $dir -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-ExcludedPath $_.FullName) } |
            ForEach-Object {
                $baseName = $_.BaseName
                # Skip numbered payload scripts (Script1, Script-A, etc.)
                if ($baseName -match '^Script[-]?[A-Z0-9]') { return }
                # Skip launcher/batch-adjacent scripts
                if ($baseName -match '^Launch-') { return }
                # Check for spaces
                if ($baseName -match '\s') {
                    $violations += [PSCustomObject]@{
                        Path = Get-RelativePath $_.FullName
                        Rule = 'no-spaces'
                        Message = "Script filename contains spaces: $($_.Name)"
                        Suggested = $_.Name -replace ' ', '-'
                    }
                }
                # Check Verb-Noun pattern
                elseif ($baseName -match '^([A-Za-z]+)-(.+)$') {
                    $verb = $Matches[1]
                    if ($verb -notin $approvedVerbs) {
                        $violations += [PSCustomObject]@{
                            Path = Get-RelativePath $_.FullName
                            Rule = 'verb-noun'
                            Message = "Script uses non-standard verb '$verb': $($_.Name)"
                            Suggested = $_.Name
                        }
                    }
                }
            }
    }

    # Check config files for kebab-lower-case (.json/.xml in config/)
    $configPath = Join-Path $projectRoot 'config'
    if (Test-Path $configPath) {
        Get-ChildItem -Path $configPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.json','.xml') -and -not (Test-ExcludedPath $_.FullName) } |
            ForEach-Object {
                $baseName = $_.BaseName
                if ($baseName -match '\s') {
                    $violations += [PSCustomObject]@{
                        Path = Get-RelativePath $_.FullName
                        Rule = 'no-spaces'
                        Message = "Config filename contains spaces: $($_.Name)"
                        Suggested = $_.Name -replace ' ', '-'
                    }
                }
                elseif ($baseName -cmatch '[A-Z]' -and $baseName -notmatch 'BASE$' -and $baseName -notmatch '^AVPN_') {
                    $violations += [PSCustomObject]@{
                        Path = Get-RelativePath $_.FullName
                        Rule = 'kebab-lower'
                        Message = "Config file should be kebab-lower-case: $($_.Name)"
                        Suggested = Get-SuggestedName $_.Name 'kebab-lower'
                    }
                }
            }
    }

    # Check for spaces in any filename at project root level
    Get-ChildItem -Path $projectRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\s' -and $_.Extension -ne '.md' -and -not (Test-ExcludedPath $_.FullName) } |
        ForEach-Object {
            $violations += [PSCustomObject]@{
                Path = Get-RelativePath $_.FullName
                Rule = 'no-spaces'
                Message = "Filename contains spaces: $($_.Name)"
                Suggested = $_.Name -replace ' ', '-'
            }
        }

    return $violations
}

# ---------------------------------------------------------------------------
# Todo creation for proposals
# ---------------------------------------------------------------------------
function New-RenameProposalTodo {
    param(
        [PSCustomObject]$Violation
    )
    if (-not (Test-Path $todoDir)) { New-Item -ItemType Directory -Path $todoDir -Force | Out-Null }
    $id = [guid]::NewGuid().ToString()
    $slug = ($Violation.Path -replace '[\\/ .]', '-') -replace '-+', '-'
    $filename = "todo-rename-$slug.json"
    $filepath = Join-Path $todoDir $filename

    # Check for existing proposal with same path
    $existing = Get-ChildItem -Path $todoDir -Filter 'todo-rename-*.json' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } |
        Where-Object { $_.file_refs -contains $Violation.Path }
    if ($existing) {
        Write-Host "  [SKIP] Existing proposal for: $($Violation.Path)" -ForegroundColor Yellow
        return $null
    }

    $todo = [ordered]@{
        id              = $id
        title           = "Rename Proposal: $($Violation.Path)"
        description     = "$($Violation.Message) -- Suggested: $($Violation.Suggested)"
        category        = 'maintenance'
        priority        = 'LOW'
        status          = 'OPEN'
        type            = 'todo'
        file_refs       = @($Violation.Path)
        created         = (Get-Date -Format 'o')
        source_scan_id  = 'rename-proposal'
        naming_rule     = $Violation.Rule
        suggested_name  = $Violation.Suggested
    }

    $todo | ConvertTo-Json -Depth 5 | Set-Content $filepath -Encoding UTF8
    Write-Host "  [TODO] Created: $filename" -ForegroundColor Green
    return $filepath
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
Write-Host "`n=== Rename Proposal Scanner ===" -ForegroundColor Cyan
$violations = Get-NamingViolations

if ($violations.Count -eq 0) {
    Write-Host "[OK] No naming violations found." -ForegroundColor Green
    return
}

Write-Host "Found $($violations.Count) naming violation(s):`n" -ForegroundColor Yellow
foreach ($v in $violations) {
    Write-Host ("  [{0}] {1}" -f $v.Rule.ToUpper(), $v.Message) -ForegroundColor White
    Write-Host ("         Path:      {0}" -f $v.Path) -ForegroundColor Gray
    Write-Host ("         Suggested: {0}" -f $v.Suggested) -ForegroundColor DarkCyan
    Write-Host ""
}

if ($ScanOnly) {
    Write-Host "[ScanOnly] No changes made." -ForegroundColor Cyan
    return
}

if ($DryRun) {
    Write-Host "[DryRun] Would create $($violations.Count) todo item(s). No changes made." -ForegroundColor Cyan
    return
}

# Create todo items for each violation
$created = 0
foreach ($v in $violations) {
    $result = New-RenameProposalTodo -Violation $v
    if ($result) { $created++ }
}

Write-Host "`n[RenameProposal] Created $created new todo item(s)." -ForegroundColor Green

# Reindex todos
if (Test-Path $todoMgrScript) {
    Write-Host "[RenameProposal] Reindexing todo directory..." -ForegroundColor Cyan
    & $todoMgrScript -Reindex
}

if ($Execute) {
    Write-Host "`n[Execute] Executing approved renames is not yet implemented." -ForegroundColor Yellow
    Write-Host "[Execute] Review proposals in todo/ and manually approve before running -Execute." -ForegroundColor Yellow
}

# --- End lifecycle logging ---
if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
    Write-AppLog -Message "Completed: $($MyInvocation.MyCommand.Name)" -Level 'Info'
}
