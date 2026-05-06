# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS
    Standardized Error Handling Templates for PowerShellGUI Workspace

.DESCRIPTION
    Canonical try/catch/trap patterns for consistent error handling across all scripts.
    All patterns comply with SIN-PATTERN-002 (no empty catch blocks) and
    REFERENCE-CONSISTENCY-STANDARD.md section 12 (Error Handling Standard).

    MANDATORY RULES:
    - Every catch block MUST log the error with Write-AppLog or equivalent
    - Use one-line catch for simple error suppression with intentional comments
    - Use multi-line catch for error handling with recovery logic
    - No empty catch blocks: catch { } is PROHIBITED
    - $ErrorActionPreference = 'Stop' in standalone scripts
    - Main-GUI.ps1 uses 'Continue' for GUI resilience (exception)

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 04 Apr 2026
    Modified : 04 Apr 2026

.LINK
    ~README.md/REFERENCE-CONSISTENCY-STANDARD.md
    sin_registry/SIN-PATTERN-002-EMPTY-CATCH-BLOCK.json
#>

# ═══════════════════════════════════════════════════════════════════════════
#  TEMPLATE 1: VERSION CHECK (ONE-LINE CATCH)
# ═══════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS  Check PowerShell version with one-line error handling
.USAGE     Copy/paste into scripts that need version validation
.COMPLIANT SIN-PATTERN-002, REFERENCE-CONSISTENCY-STANDARD §12
#>

# PowerShell Version Check Template (One-Liner)
$psVersion = try { $PSVersionTable.PSVersion } catch { Write-Warning "Version check failed: $_"; [version]'5.1.0.0' }

# With explicit minimum version validation (One-Liner)
$psVersion = try { $PSVersionTable.PSVersion } catch { Write-Warning "Version unavailable: $_"; [version]'5.1.0.0' }
if ($psVersion.Major -lt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -lt 1)) {
    throw "PowerShell 5.1 or higher required. Current: v$($psVersion.Major).$($psVersion.Minor)"
}

# With logging to Write-AppLog (One-Liner)
$psVersion = try { $PSVersionTable.PSVersion } catch { Write-AppLog -Message "Version check failed: $_" -Level Error; [version]'5.1.0.0' }

# ═══════════════════════════════════════════════════════════════════════════
#  TEMPLATE 2: MODULE IMPORT (ONE-LINE CATCH WITH INTENTIONAL COMMENT)
# ═══════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS  Import module with graceful failure handling
.USAGE     Use when module is optional or has fallback logic
.COMPLIANT SIN-PATTERN-002 (intentional comment explains why catch is minimal)
#>

# One-line catch with intentional comment (SIN-PATTERN-002 compliant)
try { Import-Module PwShGUICore -Force -ErrorAction Stop } catch { <# Intentional: module optional, fallback to inline functions #> }

# One-line catch with logging (preferred)
try { Import-Module PwShGUICore -Force -ErrorAction Stop } catch { Write-AppLog -Message "PwShGUICore import failed: $_" -Level Warning }

# One-line catch with Write-Warning (interactive scripts)
try { Import-Module PwShGUICore -Force -ErrorAction Stop } catch { Write-Warning "PwShGUICore unavailable: $_" }

# ═══════════════════════════════════════════════════════════════════════════
#  TEMPLATE 3: FILE OPERATIONS (MULTI-LINE CATCH WITH RECOVERY)
# ═══════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS  File I/O with error recovery
.USAGE     Use for file read/write operations that need fallback logic
.COMPLIANT REFERENCE-CONSISTENCY-STANDARD §12
#>

# File read with fallback to default value
try {
    $config = Get-Content -Path $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
} catch {
    Write-AppLog -Message "Config load failed: $_. Using defaults." -Level Warning
    $config = @{ version = '1.0'; enabled = $true }
}

# File write with error reporting
try {
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $outputPath -Encoding UTF8 -ErrorAction Stop
    Write-AppLog -Message "Data saved to $outputPath" -Level Info
} catch {
    Write-AppLog -Message "Failed to save data to ${outputPath}: $_" -Level Error
    throw  # Re-throw if operation is critical
}

# File copy with retry logic
$retries = 0
$maxRetries = 3
$success = $false
while (-not $success -and $retries -lt $maxRetries) {
    try {
        Copy-Item -Path $source -Destination $dest -Force -ErrorAction Stop
        $success = $true
        Write-AppLog -Message "File copied: $source → $dest" -Level Info
    } catch {
        $retries++
        Write-AppLog -Message "Copy attempt $retries failed: $_" -Level Warning
        if ($retries -ge $maxRetries) {
            Write-AppLog -Message "Copy failed after $maxRetries attempts" -Level Error
            throw
        }
        Start-Sleep -Seconds 2
    }
}

# ═══════════════════════════════════════════════════════════════════════════
#  TEMPLATE 4: EXTERNAL COMMAND EXECUTION (MULTI-LINE CATCH)
# ═══════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS  Execute external commands with error capture
.USAGE     Use for cmdlets, external executables, or script blocks
.COMPLIANT REFERENCE-CONSISTENCY-STANDARD §12
#>

# Cmdlet execution with error logging
try {
    $result = Get-Process -Name 'pwsh' -ErrorAction Stop
    Write-AppLog -Message "Found $(@($result).Count) PowerShell processes" -Level Debug
} catch {
    Write-AppLog -Message "Process query failed: $_" -Level Warning
    $result = @()
}

# External executable with exit code validation
try {
    $output = & git status 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed with exit code $LASTEXITCODE"
    }
    Write-AppLog -Message "Git status: clean" -Level Debug
} catch {
    Write-AppLog -Message "Git command failed: $Error[0]" -Level Warning
}

# Script block execution with timeout
$job = Start-Job -ScriptBlock { Start-Sleep -Seconds 120 }
try {
    $result = Wait-Job -Job $job -Timeout 30 -ErrorAction Stop | Receive-Job
    Write-AppLog -Message "Job completed: $($result)" -Level Info
} catch {
    Write-AppLog -Message "Job timeout or failure: $_" -Level Error
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
#  TEMPLATE 5: WINFORMS EVENT HANDLERS (NULL-SAFE ONE-LINER)
# ═══════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS  WinForms button click handlers with null guards
.USAGE     Use in Main-GUI.ps1 and Show-*.ps1 WinForms scripts
.COMPLIANT SIN-PATTERN-022 (null guard before method calls)
#>

# Button click with null guard and one-line catch
$button.Add_Click({
    try {
        if ($null -eq $this.Tag) { return }
        $itemId = $this.Tag.Id
        # Process item...
        Write-AppLog -Message "Button clicked: $itemId" -Level Debug
    } catch { Write-AppLog -Message "Button click handler failed: $_" -Level Error }
}.GetNewClosure())

# DataGridView selection with force-array and null guard
$dgv.Add_CellClick({
    try {
        if (@($dgv.SelectedRows).Count -eq 0) { return }
        $row = $dgv.SelectedRows[0]
        if ($null -eq $row.Cells['FileName']) { return }
        $fileName = $row.Cells['FileName'].Value
        # Process fileName...
    } catch { Write-AppLog -Message "Cell click failed: $_" -Level Error }
}.GetNewClosure())

# ═══════════════════════════════════════════════════════════════════════════
#  TEMPLATE 6: DATABASE/API OPERATIONS (MULTI-LINE WITH ROLLBACK)
# ═══════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS  Database transactions or API calls with rollback
.USAGE     Use for operations that modify state and need rollback on failure
.COMPLIANT REFERENCE-CONSISTENCY-STANDARD §12
#>

# API call with retry and backoff
$retries = 0
$maxRetries = 3
$backoff = 1
$result = $null
while ($retries -lt $maxRetries) {
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Body $payload -ErrorAction Stop
        $result = $response
        Write-AppLog -Message "API call succeeded" -Level Info
        break
    } catch {
        $retries++
        Write-AppLog -Message "API call failed (attempt $retries): $_" -Level Warning
        if ($retries -ge $maxRetries) {
            Write-AppLog -Message "API call failed after $maxRetries attempts" -Level Error
            throw
        }
        Start-Sleep -Seconds $backoff
        $backoff *= 2  # Exponential backoff
    }
}

# Transaction with rollback
$transaction = $null
try {
    $transaction = Start-Transaction
    # Perform operations...
    Update-Item -Path $item1 -Value $value1 -Transaction $transaction
    Update-Item -Path $item2 -Value $value2 -Transaction $transaction
    Complete-Transaction -Transaction $transaction
    Write-AppLog -Message "Transaction committed" -Level Info
} catch {
    Write-AppLog -Message "Transaction failed: $_. Rolling back." -Level Error
    if ($null -ne $transaction) {
        Undo-Transaction -Transaction $transaction
    }
    throw
}

# ═══════════════════════════════════════════════════════════════════════════
#  TEMPLATE 7: PIPELINE PROCESSING (MULTI-LINE WITH CLEANUP)
# ═══════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS  Pipeline processing with begin/process/end and cleanup
.USAGE     Use in advanced functions that process pipeline input
.COMPLIANT REFERENCE-CONSISTENCY-STANDARD §12
#>

function Process-Items {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [object]$InputObject
    )
    begin {
        $processed = 0
        $failed = 0
        try {
            Write-AppLog -Message "Starting pipeline processing" -Level Info
            # Initialize resources...
        } catch {
            Write-AppLog -Message "Initialization failed: $_" -Level Error
            throw
        }
    }
    process {
        try {
            # Process $InputObject...
            $processed++
            Write-AppLog -Message "Processed item $processed" -Level Debug
        } catch {
            $failed++
            Write-AppLog -Message "Failed to process item: $_" -Level Warning
            # Continue processing next item
        }
    }
    end {
        try {
            Write-AppLog -Message "Pipeline complete. Processed: $processed, Failed: $failed" -Level Info
            # Cleanup resources...
        } catch {
            Write-AppLog -Message "Pipeline cleanup failed: $_" -Level Warning
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
#  TEMPLATE 8: TRAP BLOCK (GLOBAL ERROR HANDLER)
# ═══════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS  Global trap for unhandled terminating errors
.USAGE     Place at top of script (Main-GUI.ps1, standalone scripts)
.COMPLIANT REFERENCE-CONSISTENCY-STANDARD §12
#>

# Global trap (use ONLY in Main-GUI.ps1 or critical standalone scripts)
trap {
    Write-AppLog -Message "Unhandled terminating error: $_" -Level Critical
    Write-AppLog -Message "Stack trace: $($_.ScriptStackTrace)" -Level Debug
    if (Get-Command Export-LogBuffer -ErrorAction SilentlyContinue) {
        Export-LogBuffer
    }
    # Continue execution for GUI resilience (Main-GUI.ps1)
    # OR: Break for standalone scripts
    Continue  # Or: Break
}

# Script-level trap for specific error types
trap [System.IO.IOException] {
    Write-AppLog -Message "I/O error: $_" -Level Error
    Write-AppLog -Message "File: $($_.TargetObject)" -Level Debug
    Continue
}

trap [System.UnauthorizedAccessException] {
    Write-AppLog -Message "Access denied: $_" -Level Error
    Continue
}

# ═══════════════════════════════════════════════════════════════════════════
#  ANTI-PATTERNS (DO NOT USE)
# ═══════════════════════════════════════════════════════════════════════════

<#
.SYNOPSIS  Common anti-patterns that violate SIN governance
.COMPLIANT SIN-PATTERN-002, REFERENCE-CONSISTENCY-STANDARD §12
#>

# ❌ ANTI-PATTERN 1: Empty catch block (SIN-PATTERN-002 violation)
try {
    # Some operation...
} catch { }  # PROHIBITED

# ✅ CORRECT: Add intentional comment or logging
try {
    # Some operation...
} catch { <# Intentional: non-fatal, operation optional #> }

# Or with logging:
try {
    # Some operation...
} catch { Write-AppLog -Message "Operation failed: $_" -Level Warning }

# ❌ ANTI-PATTERN 2: Catch without error handling
try {
    Import-Module SomeModule
} catch {
    # ERROR: No logging, no fallback, no recovery
}

# ✅ CORRECT: Log the error
try {
    Import-Module SomeModule -ErrorAction Stop
} catch {
    Write-AppLog -Message "Module import failed: $_" -Level Warning
}

# ❌ ANTI-PATTERN 3: Generic catch without specific handling
try {
    $result = Invoke-WebRequest -Uri $url
} catch {
    Write-Host "Error occurred"  # Too generic, no details
}

# ✅ CORRECT: Specific error message with details
try {
    $result = Invoke-WebRequest -Uri $url -ErrorAction Stop
} catch {
    Write-AppLog -Message "Web request failed for ${url}: $($_.Exception.Message)" -Level Error
}

# ❌ ANTI-PATTERN 4: Silently suppressing errors with -ErrorAction SilentlyContinue
Import-Module SomeModule -ErrorAction SilentlyContinue  # Errors hidden, no logging

# ✅ CORRECT: Use try/catch with logging
try {
    Import-Module SomeModule -ErrorAction Stop
} catch {
    Write-AppLog -Message "Failed to import SomeModule: $_" -Level Warning
}

# ❌ ANTI-PATTERN 5: Version check without fallback
$psVersion = $PSVersionTable.PSVersion  # Can throw in edge cases

# ✅ CORRECT: One-line version check with fallback
$psVersion = try { $PSVersionTable.PSVersion } catch { Write-Warning "Version unavailable: $_"; [version]'5.1.0.0' }

# ═══════════════════════════════════════════════════════════════════════════
#  REFERENCE QUICK LINKS
# ═══════════════════════════════════════════════════════════════════════════

<#
## Error Handling Standards Documentation

### Primary Standards:
1. **REFERENCE-CONSISTENCY-STANDARD.md § 12** - Error Handling Standard
   - $ErrorActionPreference guidelines
   - try/catch requirements
   - No empty catch blocks rule
   - Global trap usage
   - Logging function requirements

2. **SIN-PATTERN-002** - No Empty Catch Blocks
   - Every catch MUST log error or have intentional comment
   - Validation: Invoke-SINPatternScanner.ps1
   - Pattern: sin_registry/SIN-PATTERN-002-EMPTY-CATCH-BLOCK.json

3. **REFERENCE-CONSISTENCY-STANDARD.md § 11** - Logging Standard
   - Canonical levels: Debug, Info, Warning, Error, Critical, Audit
   - Functions: Write-AppLog, Write-ScriptLog, Export-LogBuffer
   - Log entry format: [yyyy-MM-dd HH:mm:ss] [Level] Message

4. **SIN-PATTERN-022** - Null Guard Before Method Calls
   - Always check `if ($null -eq $obj)` before accessing properties/methods
   - PS 5.1 has no `?.` null-conditional operator
   - WinForms handlers: Check `.Tag`, `.SelectedRows`, `.Cells` for null

### SIN Patterns Related to Error Handling:
- **P001**: No hardcoded credentials (can leak in error messages)
- **P002**: No empty catch blocks (MANDATORY)
- **P003**: No SilentlyContinue on Import-Module (use try/catch instead)
- **P010**: No Invoke-Expression (iex) with dynamic strings (security risk)
- **P022**: Null guard before method calls (prevents null reference errors)

### Logging Functions:
- **Write-AppLog** - Application-level events (modules/PwShGUICore.psm1)
- **Write-ScriptLog** - Script execution events with script name prefix
- **Write-CronLog** - Cron/scheduled task events (modules/CronAiAthon-EventLog.psm1)
- **Export-LogBuffer** - Flush buffered log entries to disk

### Severity Levels (ValidateSet):
- **Debug** - Development tracing (Write-Information)
- **Info** - Normal events (Write-Information)
- **Warning** - Recoverable issues (Write-Warning)
- **Error** - Operation failures (Write-Error)
- **Critical** - System-threatening failures (Write-Error)
- **Audit** - User actions, security events (Write-Information)

#>

# ═══════════════════════════════════════════════════════════════════════════
#  END OF TEMPLATES
# ══════════════════════════════════════════════════════════════════════════
