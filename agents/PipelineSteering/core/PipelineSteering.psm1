# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS
    PipelineSteering Agent -- workspace-wide code quality and documentation conformance steerer.
.DESCRIPTION
    Iterates all workspace .ps1 / .psm1 files and enforces:
      1. Internal function description fields (.SYNOPSIS, .DESCRIPTION, .NOTES)
      2. File-level header conformance: Outline, Problems, ToDo comment blocks
      3. Drift detection: identifies missing dotfiles (.outline / .problems / .todo)
      4. Template propagation: writes standard dotfiles to dirs that lack them
      5. Minor version increment on any file that is modified during steering
      6. Pipeline referential scans after all changes (bug scan + coverage audit)
      7. Steering report written to ~REPORTS/PipelineSteering/

    All runs are non-destructive by default (-WhatIf equivalent via -DryRun).
    Use -Apply to commit fixes.  Each fixed file has its minor version bumped.

    Outline / Problems / ToDo blocks use the canonical format:
        <# Outline: ... #>    or multi-line <# Outline: ... #>
        <# Problems: ... #>
        <# ToDo: ... #>
.NOTES
    Author  : The Establishment
    Date    : 2026-04-03
    FileRole: Agent-Core
    Version : 2604.B2.V31.0
#>

Set-StrictMode -Off

# ═══════════════════════════════════════════════════════════════════════════════
#  PRIVATE HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

function Write-SteerLog {
    [CmdletBinding()]
    param([string]$Message, [string]$Severity = 'Informational')
    try { Write-CronLog -Message $Message -Severity $Severity -Source 'PipelineSteering' } catch {
        try { Write-AppLog $Message $Severity } catch {
            Write-AppLog -Message "[PipelineSteering] $Message" -Level Warning
        }
    }
}

function Get-VersionTagFromContent {
    <#
    .SYNOPSIS  Extract VersionTag from script content string.
    #>
    [CmdletBinding()]
    param([string]$Content)
    if ($Content -match '# VersionTag:\s*([\w.\-]+)') { return $Matches[1] }
    return $null
}

function Set-VersionTagMinorBump {
    <#
    .SYNOPSIS  Increment the minor version number in a VersionTag string.
    .DESCRIPTION
        Handles VersionTag format: YYMM.BN.vMAJOR.MINOR
        Returns the new VersionTag string.
    #>
    [CmdletBinding()]
    param([string]$VersionTag)
    if ($VersionTag -match '^(\d{4}\.\w+\.[Vv]\d+\.)(\d+)$') {
        $prefix = $Matches[1]
        $minor  = [int]$Matches[2] + 1
        return "$prefix$minor"
    }
    return $VersionTag
}

function Update-FileVersionTag {
    <#
    .SYNOPSIS  Bump the minor version in a file's VersionTag header in-place.
    #>
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [switch]$DryRun
    )
    $content = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction Stop
    $oldTag  = Get-VersionTagFromContent -Content $content
    if (-not $oldTag) { return $false }
    $newTag  = Set-VersionTagMinorBump -VersionTag $oldTag
    if ($newTag -eq $oldTag) { return $false }
    if (-not $DryRun) {
        $updated = $content -replace [regex]::Escape("# VersionTag: $oldTag"), "# VersionTag: $newTag"
        Set-Content -LiteralPath $FilePath -Value $updated -Encoding UTF8 -ErrorAction Stop
        Write-SteerLog "VersionBump: $([IO.Path]::GetFileName($FilePath)) $oldTag -> $newTag" 'Informational'
    }
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  FUNCTION DESCRIPTION SCANNER
# ═══════════════════════════════════════════════════════════════════════════════

function Test-FunctionDescriptions {
    <#
    .SYNOPSIS
        Scan all .ps1 / .psm1 files for functions missing comment-based help blocks.
    .DESCRIPTION
        Looks for 'function Verb-Noun' declarations not immediately followed by a
        '<# .SYNOPSIS' comment block within 5 lines.  Returns an array of gap objects.
    .PARAMETER WorkspacePath
        Workspace root folder to scan.
    .PARAMETER ExcludePaths
        Optional array of partial paths to exclude (e.g. '.history', 'node_modules').
    .OUTPUTS
        [PSCustomObject[]]  FilePath, FunctionName, LineNumber
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [string[]]$ExcludePaths = @('.history', 'node_modules', '__pycache__', '.git')
    )

    $gaps = [System.Collections.ArrayList]::new()
    $files = Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
             Where-Object {
                 $p = $_.FullName
                 -not ($ExcludePaths | Where-Object { $p -like "*$_*" })
             }

    foreach ($file in $files) {
        $lines = @(Get-Content $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*function\s+([\w]+-[\w]+)\s*[\{(]?') {
                $fnName = $Matches[1]
                # Look forward up to 5 lines for '<#' comment block
                $hasHelp = $false
                $limit   = [math]::Min($i + 6, $lines.Count - 1)
                for ($j = $i + 1; $j -le $limit; $j++) {
                    if ($lines[$j] -match '<#|\.SYNOPSIS') { $hasHelp = $true; break }
                }
                if (-not $hasHelp) {
                    [void]$gaps.Add([PSCustomObject]@{
                        FilePath     = $file.FullName
                        FunctionName = $fnName
                        LineNumber   = $i + 1
                    })
                }
            }
        }
    }

    Write-SteerLog "Test-FunctionDescriptions: found $(@($gaps).Count) function(s) missing help" 'Informational'
    return @($gaps)
}

# ═══════════════════════════════════════════════════════════════════════════════
#  OUTLINE / PROBLEMS / TODO HEADER CONFORMANCE
# ═══════════════════════════════════════════════════════════════════════════════

function Resolve-OutlineConformance {
    <#
    .SYNOPSIS
        Check each .ps1 / .psm1 for Outline, Problems and ToDo comment blocks.
    .DESCRIPTION
        Scans for the presence of comment blocks with the markers:
            (* Outline:     *)
            (* Problems:    *)
            (* ToDo:        *)
        (Markers use angle-bracket-hash syntax in actual files.)
        Files missing any block are reported.  If -Apply is set, a stub block is
        appended after the header comment.
    .PARAMETER WorkspacePath
        Workspace root.
    .PARAMETER Apply
        If set, injects missing stub blocks into files.
    .PARAMETER ExcludePaths
        Partial paths to exclude.
    .OUTPUTS
        [PSCustomObject[]]  FilePath, MissingOutline, MissingProblems, MissingTodo, Fixed [bool]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$Apply,
        [string[]]$ExcludePaths = @('.history', 'node_modules', '__pycache__', '.git', 'CarGame', '~DOWNLOADS')
    )

    $results = [System.Collections.ArrayList]::new()
    $files   = Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
               Where-Object {
                   $p = $_.FullName
                   -not ($ExcludePaths | Where-Object { $p -like "*$_*" })
               }

    foreach ($file in $files) {
        $content      = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        $missingOL    = $content -notmatch '(?s)<#\s*Outline:'
        $missingProb  = $content -notmatch '(?s)<#\s*Problems?:'
        $missingTodo  = $content -notmatch '(?s)<#\s*To[-\s]?[Dd]o:'
        $fixed        = $false

        if (($missingOL -or $missingProb -or $missingTodo) -and $Apply) {
            $stubs = ''
            if ($missingOL)   { $stubs += "`n<# Outline:`n    Stub: describe module/script purpose here.`n#>`n" }
            if ($missingProb) { $stubs += "`n<# Problems:`n    Stub: list known issues here.`n#>`n" }
            if ($missingTodo) { $stubs += "`n<# ToDo:`n    Stub: list pending work here.`n#>`n" }
            # Append stubs before last Export-ModuleMember or at end of file
            if ($content -match 'Export-ModuleMember') {
                $updated = $content -replace '(Export-ModuleMember)', "$stubs`$1"
            } else {
                $updated = $content + $stubs
            }
            Set-Content -Path $file.FullName -Value $updated -Encoding UTF8 -ErrorAction SilentlyContinue
            Update-FileVersionTag -FilePath $file.FullName
            $fixed = $true
            Write-SteerLog "Resolve-OutlineConformance: patched $($file.Name)" 'Informational'
        }

        if ($missingOL -or $missingProb -or $missingTodo) {
            [void]$results.Add([PSCustomObject]@{
                FilePath        = $file.FullName
                MissingOutline  = $missingOL
                MissingProblems = $missingProb
                MissingTodo     = $missingTodo
                Fixed           = $fixed
            })
        }
    }

    Write-SteerLog "Resolve-OutlineConformance: $(@($results).Count) file(s) with missing header blocks" 'Informational'
    return @($results)
}

# ═══════════════════════════════════════════════════════════════════════════════
#  DOTFILE TEMPLATE PROPAGATION
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-DocTemplatePropagation {
    <#
    .SYNOPSIS
        Create standard dotfiles (.outline, .problems, .todo) in dirs that lack them.
    .DESCRIPTION
        Walks the workspace looking for directories containing .ps1 or .psm1 files.
        Any such directory that lacks a .outline, .problems, or .todo file gets the
        default template written.  Directories in ExcludePaths are skipped.
    .PARAMETER WorkspacePath
        Workspace root.
    .PARAMETER Apply
        If set, writes the dotfiles.  Otherwise reports what would be created.
    .PARAMETER ExcludePaths
        Partial path segments to exclude.
    .OUTPUTS
        [PSCustomObject[]] DirectoryPath, CreatedFiles [string[]]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$Apply,
        [string[]]$ExcludePaths = @('.git', '.history', 'node_modules', '__pycache__', '~DOWNLOADS', 'CarGame')
    )

    $created = [System.Collections.ArrayList]::new()
    $dirs    = Get-ChildItem -Path $WorkspacePath -Recurse -Directory -ErrorAction SilentlyContinue |
               Where-Object {
                   $dp = $_.FullName
                   -not ($ExcludePaths | Where-Object { $dp -like "*$_*" })
               }

    foreach ($dir in $dirs) {
        $hasPsFiles = @(Get-ChildItem -Path $dir.FullName -Filter '*.ps1' -ErrorAction SilentlyContinue) +
                      @(Get-ChildItem -Path $dir.FullName -Filter '*.psm1' -ErrorAction SilentlyContinue)
        if (@($hasPsFiles).Count -eq 0) { continue }

        $newFiles = [System.Collections.ArrayList]::new()
        $outlineFile  = Join-Path $dir.FullName '.outline'
        $problemsFile = Join-Path $dir.FullName '.problems'
        $todoFile     = Join-Path $dir.FullName '.todo'

        if (-not (Test-Path $outlineFile)) {
            if ($Apply) { Set-Content -Path $outlineFile -Value "# Outline`n# Describe the purpose of scripts in this directory." -Encoding UTF8 -ErrorAction SilentlyContinue }
            [void]$newFiles.Add('.outline')
        }
        if (-not (Test-Path $problemsFile)) {
            if ($Apply) { Set-Content -Path $problemsFile -Value "# Known Problems`n# List known issues and constraints here." -Encoding UTF8 -ErrorAction SilentlyContinue }
            [void]$newFiles.Add('.problems')
        }
        if (-not (Test-Path $todoFile)) {
            if ($Apply) { Set-Content -Path $todoFile -Value "# ToDo`n# List pending work items here." -Encoding UTF8 -ErrorAction SilentlyContinue }
            [void]$newFiles.Add('.todo')
        }

        if (@($newFiles).Count -gt 0) {
            [void]$created.Add([PSCustomObject]@{
                DirectoryPath = $dir.FullName
                CreatedFiles  = @($newFiles)
                Applied       = $Apply.IsPresent
            })
        }
    }

    Write-SteerLog "Invoke-DocTemplatePropagation: $(@($created).Count) dir(s) need dotfiles" 'Informational'
    return @($created)
}

# ═══════════════════════════════════════════════════════════════════════════════
#  POST-STEERING PIPELINE SCAN
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-SteeringPipelineScan {
    <#
    .SYNOPSIS
        Run bug scan and config-coverage audit after a steering session.
    .DESCRIPTION
        Calls Invoke-FullBugScan (if available) and Invoke-ConfigCoverageAudit.ps1
        to surface any new issues introduced or resolved during the steering pass.
        Writes a summary to the report object returned by Invoke-PipelineSteerSession.
    .PARAMETER WorkspacePath
        Workspace root.
    .OUTPUTS
        [PSCustomObject] BugScanResult, CoverageAuditResult
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $bugResult  = $null
    $covResult  = $null

    # Bug scan
    try {
        if (Get-Command Invoke-FullBugScan -ErrorAction SilentlyContinue) {
            $bugResult = Invoke-FullBugScan -WorkspacePath $WorkspacePath 2>&1
            Write-SteerLog 'SteeringPipelineScan: bug scan completed' 'Informational'
        } else {
            Write-SteerLog 'SteeringPipelineScan: Invoke-FullBugScan not available — skipping' 'Informational'
        }
    } catch {
        Write-SteerLog "SteeringPipelineScan: bug scan error: $($_.Exception.Message)" 'Warning'
    }

    # Config coverage audit script
    $covScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-ConfigCoverageAudit.ps1'
    try {
        if (Test-Path $covScript) {
            $covResult = & $covScript -WorkspacePath $WorkspacePath 2>&1
            Write-SteerLog 'SteeringPipelineScan: config coverage audit completed' 'Informational'
        } else {
            Write-SteerLog 'SteeringPipelineScan: Invoke-ConfigCoverageAudit.ps1 not found — skipping' 'Informational'
        }
    } catch {
        Write-SteerLog "SteeringPipelineScan: coverage audit error: $($_.Exception.Message)" 'Warning'
    }

    [PSCustomObject]@{
        BugScanResult       = $bugResult
        CoverageAuditResult = $covResult
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-PipelineSteerSession {
    <#
    .SYNOPSIS
        Run a full Pipeline Steering session across the workspace.
    .DESCRIPTION
        Orchestrates all steering phases in sequence:
          Phase 1 — Scan functions for missing help descriptions
          Phase 2 — Resolve Outline / Problems / ToDo header conformance
          Phase 3 — Propagate standard dotfile templates
          Phase 4 — Post-steering pipeline scan (bug scan + coverage audit)

        When -Apply is supplied, files are modified in-place and minor version
        bumped.  Without -Apply the session runs in DryRun mode (report only).

        Report is written to <WorkspacePath>\~REPORTS\PipelineSteering\steer-YYYYMMDD-HHmmss.json
    .PARAMETER WorkspacePath
        Workspace root.
    .PARAMETER Apply
        Commit fixes in-place.  Without this flag the session is read-only.
    .PARAMETER SkipPipelineScan
        Skip the post-fix bug scan and coverage audit.
    .OUTPUTS
        [PSCustomObject] with full session report.
    .EXAMPLE
        Invoke-PipelineSteerSession -WorkspacePath 'C:\PowerShellGUI' -Apply
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$Apply,
        [switch]$SkipPipelineScan
    )

    $sessionStart = Get-Date
    Write-SteerLog "Invoke-PipelineSteerSession: starting (Apply=$($Apply.IsPresent))" 'Informational'

    # Phase 1 — function description gaps
    Write-SteerLog 'PipelineSteer Phase 1: scanning function descriptions...' 'Informational'
    $fnGaps = Test-FunctionDescriptions -WorkspacePath $WorkspacePath

    # Phase 2 — Outline/Problems/ToDo header blocks
    Write-SteerLog 'PipelineSteer Phase 2: resolving outline conformance...' 'Informational'
    $outlineResults = Resolve-OutlineConformance -WorkspacePath $WorkspacePath -Apply:$Apply

    # Phase 3 — dotfile template propagation
    Write-SteerLog 'PipelineSteer Phase 3: propagating doc templates...' 'Informational'
    $dotfileResults = Invoke-DocTemplatePropagation -WorkspacePath $WorkspacePath -Apply:$Apply

    # Phase 4 — post-steering pipeline scan
    $scanResult = $null
    if (-not $SkipPipelineScan -and $Apply) {
        Write-SteerLog 'PipelineSteer Phase 4: running post-steering pipeline scan...' 'Informational'
        $scanResult = Invoke-SteeringPipelineScan -WorkspacePath $WorkspacePath
    }

    $sessionEnd = Get-Date
    $elapsed    = ($sessionEnd - $sessionStart).TotalSeconds

    $report = [PSCustomObject]@{
        SessionId          = [guid]::NewGuid().ToString('N').Substring(0,8)
        Timestamp          = $sessionStart.ToString('yyyy-MM-dd HH:mm:ss')
        DryRun             = (-not $Apply.IsPresent)
        ElapsedSeconds     = [math]::Round($elapsed, 1)
        FunctionGaps       = @($fnGaps)
        FunctionGapCount   = @($fnGaps).Count
        OutlineIssues      = @($outlineResults)
        OutlineIssueCount  = @($outlineResults).Count
        DotfilesNeeded     = @($dotfileResults)
        DotfileNeedCount   = @($dotfileResults).Count
        PipelineScanResult = $scanResult
    }

    # Write report
    $reportDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'PipelineSteering'
    if (-not (Test-Path $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $reportFile = Join-Path $reportDir ("steer-" + $sessionStart.ToString('yyyyMMdd-HHmmss') + ".json")
    try {
        $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportFile -Encoding UTF8 -ErrorAction Stop
        Write-SteerLog "PipelineSteer: report written to $reportFile" 'Informational'
    } catch {
        Write-SteerLog "PipelineSteer: failed to write report: $($_.Exception.Message)" 'Warning'
    }

    Write-SteerLog "Invoke-PipelineSteerSession: complete. Gaps=$($report.FunctionGapCount) OutlineIssues=$($report.OutlineIssueCount) DotfilesNeeded=$($report.DotfileNeedCount) Elapsed=$($report.ElapsedSeconds)s" 'Informational'
    return $report
}

# ═══════════════════════════════════════════════════════════════════════════════
Export-ModuleMember -Function @(
    'Invoke-PipelineSteerSession'
    'Test-FunctionDescriptions'
    'Resolve-OutlineConformance'
    'Invoke-DocTemplatePropagation'
    'Invoke-SteeringPipelineScan'
    'Update-FileVersionTag'
)


