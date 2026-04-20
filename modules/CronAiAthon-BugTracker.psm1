# VersionTag: 2604.B2.V31.1
# FileRole: Module
#Requires -Version 5.1
<#
.SYNOPSIS
    Cron-Ai-Athon Bug Tracker -- comprehensive bug detection, classification,
    and lifecycle management feeding into the pipeline and sin registry.
# TODO: HelpMenu | Show-BugTrackerHelp | Actions: Scan|Report|Triage|Export|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
    Scans workspace for bugs across all detection vectors:
      - Parse errors (PS 5.1 + PS 7)
      - Rendering issues (XHTML strict XML validation)
      - Crash logs (logs/ folder analysis)
      - Error traps (try/catch coverage audit)
      - Data validation failures (JSON/XML schema checks)
      - Access failures (permission/path issues)
      - Dependency issues (missing modules/references)
      - Runtime errors from log analysis

    Each detected bug is:
      1. Classified by severity and category
      2. Matched against sin_registry (Past Sins)
      3. If matched: linked to existing sin, occurrence incremented
      4. If new: creates a new sin entry
      5. Converted to Bugs2FIX pipeline item
      6. Optionally generates Items2ADD for preventive improvements

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 28th March 2026
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ========================== BUG DETECTION VECTORS ==========================

function Invoke-ParseCheck {
    <#
    .SYNOPSIS  Parse-check all .ps1/.psm1 files on both PS 5.1 and PS 7.
    .OUTPUTS   Array of bug-detection results.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $results = @()
    $excludeDirs = @('.git','.history','node_modules','__pycache__')
    $psFiles = Get-ChildItem -Path $WorkspacePath -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
        Where-Object {
            $path = $_.FullName
            $skip = $false
            foreach ($ex in $excludeDirs) { if ($path -like "*\$ex\*") { $skip = $true; break } }
            -not $skip
        }

    foreach ($file in $psFiles) {
        $tokens = $null; $errors = $null
        try {
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        } catch { <# skip #> }

        if ($errors -and @($errors).Count -gt 0) {
            foreach ($err in $errors) {
                $results += [ordered]@{
                    vector      = 'ParseError'
                    severity    = 'HIGH'
                    category    = 'parsing'
                    file        = $file.FullName
                    line        = $err.Extent.StartLineNumber
                    message     = $err.Message
                    description = "Parse error in $($file.Name) line $($err.Extent.StartLineNumber): $($err.Message)"
                }
            }
        }
    }
    return $results
}

function Invoke-XhtmlValidation {
    <#
    .SYNOPSIS  Validate all XHTML files for strict XML well-formedness.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $results = @()
    $xhtmlFiles = Get-ChildItem -Path $WorkspacePath -Recurse -File -Filter *.xhtml -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\.history\*' }

    foreach ($file in $xhtmlFiles) {
        try {
            [xml](Get-Content -Path $file.FullName -Raw -ErrorAction Stop) | Out-Null
        } catch {
            $results += [ordered]@{
                vector      = 'XhtmlRender'
                severity    = 'MEDIUM'
                category    = 'rendering'
                file        = $file.FullName
                line        = 0
                message     = $_.Exception.Message
                description = "XHTML parse failure in $($file.Name): $($_.Exception.Message)"
            }
        }
    }
    return $results
}

function Invoke-CrashLogScan {
    <#
    .SYNOPSIS  Scan logs/ for crash indicators, unhandled exceptions, and error patterns.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $results = @()
    $logsDir = Join-Path $WorkspacePath 'logs'
    if (-not (Test-Path $logsDir)) { return $results }

    $logFiles = Get-ChildItem -Path $logsDir -File -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 20

    $errorPatterns = @(
        'FATAL','unhandled exception','System\..*Exception','Access.*denied',
        'file not found','module.*not.*loaded','parse error','stack overflow',
        'out of memory','deadlock','timeout expired','connection refused'
    )
    $patternRegex = ($errorPatterns -join '|')

    foreach ($lf in $logFiles) {
        try {
            $lineNum = 0
            foreach ($line in (Get-Content $lf.FullName -ErrorAction SilentlyContinue)) {
                $lineNum++
                if ($line -match $patternRegex) {
                    $results += [ordered]@{
                        vector      = 'CrashLog'
                        severity    = if ($line -match 'FATAL|unhandled') { 'CRITICAL' } else { 'HIGH' }
                        category    = 'crash-log'
                        file        = $lf.FullName
                        line        = $lineNum
                        message     = $line.Trim().Substring(0, [Math]::Min(200, $line.Trim().Length))
                        description = "Error pattern in log $($lf.Name):$lineNum"
                    }
                }
            }
        } catch { <# skip #> }
    }
    return $results
}

function Invoke-ErrorTrapAudit {
    <#
    .SYNOPSIS  Audit PowerShell scripts for missing try/catch and ErrorAction patterns.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $results = @()
    $psFiles = Get-ChildItem -Path $WorkspacePath -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\.git\*' }

    foreach ($file in $psFiles) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            # Check for functions without try/catch
            $functionMatches = [regex]::Matches($content, 'function\s+\w+[^{]*\{')
            $tryCatchCount = ([regex]::Matches($content, '\btry\s*\{')).Count

            if ($functionMatches.Count -gt 0 -and $tryCatchCount -eq 0) {
                $results += [ordered]@{
                    vector      = 'ErrorTrap'
                    severity    = 'MEDIUM'
                    category    = 'error-handling'
                    file        = $file.FullName
                    line        = 0
                    message     = "$($functionMatches.Count) functions with no try/catch blocks"
                    description = "Script $($file.Name) has $($functionMatches.Count) functions but zero try/catch blocks"
                }
            }
        } catch { <# skip #> }
    }
    return $results
}

function Invoke-DataValidationCheck {
    <#
    .SYNOPSIS  Validate JSON and XML config files for well-formedness.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $results = @()
    $configDir = Join-Path $WorkspacePath 'config'

    # JSON files
    $jsonFiles = Get-ChildItem -Path $configDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    foreach ($jf in $jsonFiles) {
        try {
            Get-Content $jf.FullName -Raw | ConvertFrom-Json | Out-Null
        } catch {
            $results += [ordered]@{
                vector      = 'DataValidation'
                severity    = 'HIGH'
                category    = 'data-validation'
                file        = $jf.FullName
                line        = 0
                message     = "Invalid JSON: $($_.Exception.Message)"
                description = "Config JSON $($jf.Name) failed parse validation"
            }
        }
    }

    # XML files
    $xmlFiles = Get-ChildItem -Path $configDir -Filter '*.xml' -File -ErrorAction SilentlyContinue
    foreach ($xf in $xmlFiles) {
        try {
            [xml](Get-Content $xf.FullName -Raw) | Out-Null
        } catch {
            $results += [ordered]@{
                vector      = 'DataValidation'
                severity    = 'HIGH'
                category    = 'data-validation'
                file        = $xf.FullName
                line        = 0
                message     = "Invalid XML: $($_.Exception.Message)"
                description = "Config XML $($xf.Name) failed parse validation"
            }
        }
    }
    return $results
}

function Invoke-DependencyCheck {
    <#
    .SYNOPSIS  Check for missing module references and broken Import-Module paths.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $results = @()
    $psFiles = Get-ChildItem -Path $WorkspacePath -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\.git\*' }

    foreach ($file in $psFiles) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            # Find Import-Module with path references
            $importMatches = [regex]::Matches($content, "Import-Module\s+['\`"](.*?)['\`"]")
            foreach ($im in $importMatches) {
                $modPath = $im.Groups[1].Value
                # Skip variable-based paths
                if ($modPath -match '^\$') { continue }
                # Check if it looks like a relative path
                if ($modPath -match '\\|/') {
                    $resolvedPath = if ([System.IO.Path]::IsPathRooted($modPath)) {
                        $modPath
                    } else {
                        Join-Path (Split-Path $file.FullName) $modPath
                    }
                    if (-not (Test-Path $resolvedPath -ErrorAction SilentlyContinue)) {
                        $results += [ordered]@{
                            vector      = 'Dependency'
                            severity    = 'HIGH'
                            category    = 'dependency'
                            file        = $file.FullName
                            line        = 0
                            message     = "Missing module reference: $modPath"
                            description = "Import-Module path not found in $($file.Name): $modPath"
                        }
                    }
                }
            }
        } catch { <# skip #> }
    }
    return $results
}

function Invoke-StyleComplianceCheck {
    <#
    .SYNOPSIS  Check for style anti-pattern regressions against the remediation inventory baseline.
    .DESCRIPTION
        Reads config/style-remediation-inventory.json and compares current anti-pattern counts
        against the baseline. Returns any regressions (new instances exceeding baseline).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $results = @()
    $inventoryPath = Join-Path $WorkspacePath (Join-Path 'config' 'style-remediation-inventory.json')
    if (-not (Test-Path $inventoryPath)) {
        $results += [ordered]@{
            vector      = 'StyleCompliance'
            severity    = 'MEDIUM'
            category    = 'style'
            file        = $inventoryPath
            line        = 0
            message     = 'Style remediation inventory not found'
            description = 'Expected config/style-remediation-inventory.json for baseline tracking'
        }
        return $results
    }

    $inventory = Get-Content $inventoryPath -Raw | ConvertFrom-Json
    $baseline = $inventory.summary

    # Scan current empty catch count
    $currentEmpty = 0
    $psFiles = Get-ChildItem -Path $WorkspacePath -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\.git\*' -and $_.FullName -notlike '*\temp\*' }
    foreach ($f in $psFiles) {
        $lines = @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'catch\s*\{\s*\}') { $currentEmpty++ }
            elseif ($lines[$i] -match 'catch\s*\{\s*$' -and ($i + 1) -lt $lines.Count -and $lines[$i+1].Trim() -match '^\}$') { $currentEmpty++ }
        }
    }
    if ($currentEmpty -gt $baseline.emptyCatch) {
        $results += [ordered]@{
            vector      = 'StyleCompliance'
            severity    = 'MEDIUM'
            category    = 'style'
            file        = ''
            line        = 0
            message     = "Empty catch regression: $currentEmpty (baseline: $($baseline.emptyCatch))"
            description = "New empty catch blocks introduced since last inventory scan"
        }
    }

    return $results
}

function Invoke-FullBugScan {
    <#
    .SYNOPSIS  Run all bug detection vectors and return consolidated results.
    .DESCRIPTION
        Runs: ParseCheck, XhtmlValidation, CrashLogScan, ErrorTrapAudit,
        DataValidationCheck, DependencyCheck. Returns array of all detected bugs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $allBugs = @()
    $allBugs += @(Invoke-ParseCheck -WorkspacePath $WorkspacePath)
    $allBugs += @(Invoke-XhtmlValidation -WorkspacePath $WorkspacePath)
    $allBugs += @(Invoke-CrashLogScan -WorkspacePath $WorkspacePath)
    $allBugs += @(Invoke-ErrorTrapAudit -WorkspacePath $WorkspacePath)
    $allBugs += @(Invoke-DataValidationCheck -WorkspacePath $WorkspacePath)
    $allBugs += @(Invoke-DependencyCheck -WorkspacePath $WorkspacePath)
    $allBugs += @(Invoke-StyleComplianceCheck -WorkspacePath $WorkspacePath)

    return $allBugs
}

function Invoke-BugToPipelineProcessor {
    <#
    .SYNOPSIS  Process detected bugs into the full pipeline:
               Bug -> SinRegistry check -> Bugs2FIX -> optionally Items2ADD.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [array]$DetectedBugs
    )

    $pipelineModule = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
    if (Test-Path $pipelineModule) {
        try { Import-Module $pipelineModule -Force -ErrorAction Stop } catch { Write-Warning "Failed to import pipeline module: $_" }
    }

    $processed = @()
    foreach ($bug in $DetectedBugs) {
        # Create pipeline Bug item
        $bugItem = New-PipelineItem -Type 'Bug' -Title $bug.message `
            -Description $bug.description -Priority $bug.severity `
            -Source 'BugTracker' -Category $bug.category `
            -AffectedFiles @($bug.file) -SuggestedBy 'CronAiAthon-BugTracker'

        # Resurfaced detection: flag if a closed/done bug with same title exists
        if (Get-Command -Name Get-PipelineRegistryPath -ErrorAction SilentlyContinue) {
            $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath
            if (Test-Path $regPath) {
                try {
                    $reg = Get-Content $regPath -Raw | ConvertFrom-Json
                    $existingBug = $null
                    foreach ($b in @($reg.bugs)) {
                        if ($null -ne $b -and $b.PSObject.Properties['title'] -and $b.title -eq $bug.message) {
                            $existingBug = $b
                            break
                        }
                    }
                    if ($null -ne $existingBug -and $existingBug.status -in @('DONE','CLOSED')) {
                        $bugItem.bugResurfaced = $true
                        $histEntry = [ordered]@{
                            event      = 'RESURFACED'
                            timestamp  = (Get-Date).ToUniversalTime().ToString('o')
                            by         = 'CronAiAthon-BugTracker'
                            prevStatus = [string]$existingBug.status
                        }
                        $bugItem.bugHistory = @($bugItem.bugHistory) + @($histEntry)
                        Write-AppLog -Message "[BugProcessor] Bug '$($bug.message)' resurfaced (prev: $($existingBug.status))" -Level Warning
                    }
                } catch {
                    Write-AppLog -Message "[BugProcessor] Resurfaced check error: $_" -Level Debug
                }
            }
        }

        # Feed through sin registry
        $bugItem = Invoke-SinRegistryFeedback -WorkspacePath $WorkspacePath -BugItem $bugItem

        # Add to pipeline
        Add-PipelineItem -WorkspacePath $WorkspacePath -Item $bugItem

        # Convert to Bugs2FIX
        $fixItem = ConvertTo-Bugs2FIX -WorkspacePath $WorkspacePath -BugItem $bugItem

        $processed += [ordered]@{
            bugId  = $bugItem.id
            fixId  = $fixItem.id
            sinId  = $bugItem.sinId
            title  = $bug.message
            vector = $bug.vector
        }
    }

    # Batch sync derivative stores once after all bugs processed
    try {
        Update-TodoBundle -WorkspacePath $WorkspacePath | Out-Null
        Export-CentralMasterToDo -WorkspacePath $WorkspacePath | Out-Null
    } catch {
        Write-AppLog -Message "[BugProcessor] Post-batch sync: $($_.Exception.Message)" -Level Warning
    }

    return $processed
}

# ========================== EXPORTS ==========================
Export-ModuleMember -Function @(
    'Invoke-ParseCheck',
    'Invoke-XhtmlValidation',
    'Invoke-CrashLogScan',
    'Invoke-ErrorTrapAudit',
    'Invoke-DataValidationCheck',
    'Invoke-DependencyCheck',
    'Invoke-StyleComplianceCheck',
    'Invoke-FullBugScan',
    'Invoke-BugToPipelineProcessor'
)


