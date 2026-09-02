# VersionTag: 2607.B6.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: Module
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AutoCorrectGateConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath
    )

    $configDir = Join-Path $WorkspacePath 'config'
    $primary = Join-Path $configDir 'autocorrect-gate.config.json'
    if (Test-Path -LiteralPath $primary) { return $primary }

    $fallback = Join-Path $configDir 'autocorrect-gate.json'
    if (Test-Path -LiteralPath $fallback) { return $fallback }

    return $primary
}

function Read-AutoCorrectGateConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Auto-correct gate config not found: $ConfigPath"
    }

    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $cfg) { throw "Auto-correct gate config is empty: $ConfigPath" }
    return $cfg
}

function ConvertTo-AutoCorrectGateConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Config
    )

    $maxAttempts = 3
    if ($Config.PSObject.Properties.Name -contains 'MaxAttempts' -and [int]$Config.MaxAttempts -gt 0) {
        $maxAttempts = [int]$Config.MaxAttempts
    } elseif ($Config.PSObject.Properties.Name -contains 'maxAttempts' -and [int]$Config.maxAttempts -gt 0) {
        $maxAttempts = [int]$Config.maxAttempts
    }

    $stallAttempts = 2
    if ($Config.PSObject.Properties.Name -contains 'StallAttempts' -and [int]$Config.StallAttempts -gt 0) {
        $stallAttempts = [int]$Config.StallAttempts
    } elseif ($Config.PSObject.Properties.Name -contains 'stallAttempts' -and [int]$Config.stallAttempts -gt 0) {
        $stallAttempts = [int]$Config.stallAttempts
    }

    $timeoutSec = 120
    if ($Config.PSObject.Properties.Name -contains 'PerItemTimeoutSec' -and [int]$Config.PerItemTimeoutSec -gt 0) {
        $timeoutSec = [int]$Config.PerItemTimeoutSec
    } elseif ($Config.PSObject.Properties.Name -contains 'perItemTimeoutSec' -and [int]$Config.perItemTimeoutSec -gt 0) {
        $timeoutSec = [int]$Config.perItemTimeoutSec
    }

    $protectedPaths = @()
    if ($Config.PSObject.Properties.Name -contains 'ProtectedPathPatterns' -and $null -ne $Config.ProtectedPathPatterns) {
        $protectedPaths = @($Config.ProtectedPathPatterns)
    } elseif ($Config.PSObject.Properties.Name -contains 'protectedPaths' -and $null -ne $Config.protectedPaths) {
        $protectedPaths = @($Config.protectedPaths)
    }

    $guardrails = [ordered]@{
        RequirePreWriteCheckpoint = $true
        RollbackOnAnyStopCondition = $true
    }
    if ($Config.PSObject.Properties.Name -contains 'Guardrails' -and $null -ne $Config.Guardrails) {
        if ($Config.Guardrails.PSObject.Properties.Name -contains 'RequirePreWriteCheckpoint') {
            $guardrails.RequirePreWriteCheckpoint = [bool]$Config.Guardrails.RequirePreWriteCheckpoint
        }
        if ($Config.Guardrails.PSObject.Properties.Name -contains 'RollbackOnAnyStopCondition') {
            $guardrails.RollbackOnAnyStopCondition = [bool]$Config.Guardrails.RollbackOnAnyStopCondition
        }
    }

    $stopConditions = [ordered]@{
        K1 = [ordered]@{ enabled = $true; name = 'significant-regression'; action = 'rollback+escalate'; severity = 'high' }
        K2 = [ordered]@{ enabled = $true; name = 'resultant-sin'; action = 'rollback+escalate'; severity = 'high' }
        K3 = [ordered]@{ enabled = $true; name = 'charter-violation'; action = 'rollback+escalate'; severity = 'high' }
        K4 = [ordered]@{ enabled = $true; name = 'paradox-oscillation'; action = 'rollback+escalate'; severity = 'high' }
        K5 = [ordered]@{ enabled = $true; name = 'loop-cap-no-progress'; action = 'rollback+escalate'; severity = 'medium' }
        K6 = [ordered]@{ enabled = $true; name = 'error-timeout-crash-lockup'; action = 'rollback+escalate'; severity = 'high' }
    }
    if ($Config.PSObject.Properties.Name -contains 'StopConditions' -and $null -ne $Config.StopConditions) {
        foreach ($key in @('K1','K2','K3','K4','K5','K6')) {
            if ($Config.StopConditions.PSObject.Properties.Name -contains $key) {
                $stopConditions[$key] = $Config.StopConditions.$key
            }
        }
    }

    return [pscustomobject][ordered]@{
        MaxAttempts           = $maxAttempts
        StallAttempts         = $stallAttempts
        PerItemTimeoutSec     = $timeoutSec
        ProtectedPathPatterns = @($protectedPaths)
        Guardrails            = [pscustomobject]$guardrails
        StopConditions        = [pscustomobject]$stopConditions
    }
}

function Get-FirstPresentPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string[]]$Names
    )

    foreach ($name in @($Names)) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($name) -and $null -ne $InputObject[$name] -and -not [string]::IsNullOrWhiteSpace([string]$InputObject[$name])) {
                return [string]$InputObject[$name]
            }
        } else {
            if ($InputObject.PSObject.Properties.Name -contains $name) {
                $value = $InputObject.$name
                if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                    return [string]$value
                }
            }
        }
    }

    return $null
}

function ConvertTo-WorkspaceRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$Path
    )

    $workspaceFull = [System.IO.Path]::GetFullPath($WorkspacePath)
    $candidate = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $WorkspacePath $candidate
    }

    $full = [System.IO.Path]::GetFullPath($candidate)
    if ($full.StartsWith($workspaceFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($workspaceFull.Length).TrimStart('\', '/') -replace '/', '\\'
    }

    return $Path -replace '/', '\\'
}

function Resolve-AffectedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$RawPath
    )

    if ([string]::IsNullOrWhiteSpace($RawPath)) { return $null }

    if ([System.IO.Path]::IsPathRooted($RawPath)) {
        return [System.IO.Path]::GetFullPath($RawPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $WorkspacePath $RawPath))
}

function ConvertTo-NormalizedFailItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$FailItem,
        [Parameter(Mandatory)] [string]$WorkspacePath
    )

    $rawPath = Get-FirstPresentPropertyValue -InputObject $FailItem -Names @('path','file','file_path','targetPath','target','relativePath')
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        return $null
    }

    $gate = Get-FirstPresentPropertyValue -InputObject $FailItem -Names @('gate','category','sinId','sin','pattern','rule')
    $severity = Get-FirstPresentPropertyValue -InputObject $FailItem -Names @('severity','level','priority')
    $message = Get-FirstPresentPropertyValue -InputObject $FailItem -Names @('message','reason','description','content','title')

    $fullPath = Resolve-AffectedPath -WorkspacePath $WorkspacePath -RawPath $rawPath
    $relativePath = ConvertTo-WorkspaceRelativePath -WorkspacePath $WorkspacePath -Path $fullPath

    return [PSCustomObject]@{
        Path         = $fullPath
        RelativePath = $relativePath
        Gate         = if ([string]::IsNullOrWhiteSpace($gate)) { 'UNKNOWN' } else { $gate }
        Severity     = if ([string]::IsNullOrWhiteSpace($severity)) { 'UNKNOWN' } else { $severity }
        Message      = if ([string]::IsNullOrWhiteSpace($message)) { '' } else { $message }
        RawItem      = $FailItem
    }
}

function Get-NormalizedItemKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject]$Item)

    $rel = ''
    if ($Item.PSObject.Properties.Name -contains 'RelativePath' -and -not [string]::IsNullOrWhiteSpace([string]$Item.RelativePath)) {
        $rel = [string]$Item.RelativePath
    }

    if ([string]::IsNullOrWhiteSpace($rel) -and $Item.PSObject.Properties.Name -contains 'Path') {
        $rel = [string]$Item.Path
    }

    return ($rel -replace '/', '\').ToLowerInvariant()
}

function Get-UniqueNormalizedItems {
    [CmdletBinding()]
    param([AllowNull()] [object[]]$Items)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $unique = @()

    foreach ($entry in @($Items)) {
        if ($null -eq $entry) { continue }
        $item = [PSCustomObject]$entry
        $key = Get-NormalizedItemKey -Item $item
        if ([string]::IsNullOrWhiteSpace($key)) {
            $unique += $item
            continue
        }
        if ($seen.Add($key)) {
            $unique += $item
        }
    }

    return @($unique)
}

function Test-AutoCorrectTargetSupported {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $ext = [System.IO.Path]::GetExtension($Path)
    return ($ext -in @('.ps1','.psm1','.psd1'))
}

function Get-ParserValidationResult {
    [CmdletBinding()]
    param(
        [AllowNull()] [string[]]$Paths
    )

    $parseErrors = @()
    $checked = 0

    foreach ($filePath in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($filePath)) { continue }
        if (-not (Test-Path -LiteralPath $filePath)) { continue }

        $ext = [System.IO.Path]::GetExtension($filePath)
        if ($ext -notin @('.ps1','.psm1','.psd1')) { continue }

        $checked++
        $tokens = $null
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($filePath, [ref]$tokens, [ref]$errs)
        foreach ($err in @($errs)) {
            $parseErrors += [PSCustomObject]@{
                Path    = $filePath
                Message = $err.Message
                Line    = $err.Extent.StartLineNumber
            }
        }
    }

    return [PSCustomObject]@{
        CheckedFiles = $checked
        ErrorCount   = @($parseErrors).Count
        Errors       = @($parseErrors)
        Passed       = (@($parseErrors).Count -eq 0)
    }
}

function Invoke-ResultantSinScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [AllowNull()] [string[]]$Paths
    )

    $scanner = Join-Path (Join-Path $WorkspacePath 'tests') 'Invoke-SINPatternScanner.ps1'
    if (-not (Test-Path -LiteralPath $scanner)) {
        return [PSCustomObject]@{
            Available = $false
            Total     = 0
            Critical  = 0
            High      = 0
            Medium    = 0
            Low       = 0
            Raw       = $null
            Error     = 'scanner-unavailable'
        }
    }

    try {
        $scanOut = Join-Path (Join-Path $WorkspacePath 'temp') ('sin-scan-autocorrect-' + [guid]::NewGuid().ToString('N') + '.json')
        $scanArgs = @{
            WorkspacePath = $WorkspacePath
            Runtime       = 'Both'
            OutputJson    = $scanOut
            Quiet         = $true
        }
        $validPaths = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) })
        if (@($validPaths).Count -gt 0) {
            $scanArgs['IncludeFiles'] = @($validPaths)
        }

        $raw = & $scanner @scanArgs
        return [PSCustomObject]@{
            Available = $true
            Total     = if ($raw -and $raw.totalFindings) { [int]$raw.totalFindings } else { 0 }
            Critical  = if ($raw -and $raw.critical) { [int]$raw.critical } else { 0 }
            High      = if ($raw -and $raw.high) { [int]$raw.high } else { 0 }
            Medium    = if ($raw -and $raw.medium) { [int]$raw.medium } else { 0 }
            Low       = if ($raw -and $raw.low) { [int]$raw.low } else { 0 }
            Raw       = $raw
            Error     = ''
        }
    } catch {
        return [PSCustomObject]@{
            Available = $false
            Total     = 0
            Critical  = 0
            High      = 0
            Medium    = 0
            Low       = 0
            Raw       = $null
            Error     = $_.Exception.Message
        }
    }
}

function Import-OptionalModuleFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ModulePath)

    if (-not (Test-Path -LiteralPath $ModulePath)) { return $false }
    try {
        Import-Module -Name $ModulePath -Force -DisableNameChecking -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Invoke-CorrectorStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Corrector,
        [Parameter(Mandatory)] [PSCustomObject]$Item,
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$DryRun
    )

    switch ($Corrector) {
        'CanonicalRegistryRemediation' {
            if ([string]::IsNullOrWhiteSpace($Item.Path) -or -not (Test-Path -LiteralPath $Item.Path)) {
                return [PSCustomObject]@{ Name = $Corrector; Invoked = $false; Succeeded = $false; Message = 'Target file unavailable' }
            }

            $targetName = [System.IO.Path]::GetFileName($Item.Path)
            if ($targetName -ne 'pipeline-canonical-paths.json') {
                return [PSCustomObject]@{ Name = $Corrector; Invoked = $false; Succeeded = $true; Message = 'Skipped: not canonical registry file' }
            }

            try {
                $raw = Get-Content -LiteralPath $Item.Path -Raw -Encoding UTF8
                $json = $raw | ConvertFrom-Json
                if ($null -eq $json) {
                    return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $false; Message = 'Cannot parse canonical registry JSON' }
                }

                if (-not ($json.PSObject.Properties.Name -contains 'deprecatedPathLiterals')) {
                    return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $true; Message = 'No deprecatedPathLiterals property present' }
                }

                $current = @($json.deprecatedPathLiterals)
                $replacement = @('config/pipeline-refine-baseline-full.json')

                $changed = $false
                if (@($current).Count -ne @($replacement).Count) {
                    $changed = $true
                } else {
                    if (@($current).Count -gt 0 -and [string]$current[0] -ne [string]$replacement[0]) {  # SIN-EXEMPT:P027 -- guarded by count check
                        $changed = $true
                    }
                }

                if (-not $changed) {
                    return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $true; Message = 'Canonical deprecatedPathLiterals already normalized' }
                }

                if ($DryRun) {
                    return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $true; Message = 'WhatIf: would normalize deprecatedPathLiterals' }
                }

                $json.deprecatedPathLiterals = @($replacement)
                $out = $json | ConvertTo-Json -Depth 10
                Set-Content -LiteralPath $Item.Path -Value $out -Encoding UTF8
                return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $true; Message = 'Normalized deprecatedPathLiterals to canonical baseline literal' }
            } catch {
                return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $false; Message = $_.Exception.Message }
            }
        }
        'AutoRemediate' {
            $modulePath = Join-Path (Join-Path $WorkspacePath 'modules') 'PwShGUI-AutoRemediate.psm1'
            $loaded = Import-OptionalModuleFile -ModulePath $modulePath
            if (-not $loaded -or -not (Get-Command Invoke-AutoRemediate -ErrorAction SilentlyContinue)) {
                return [PSCustomObject]@{ Name = $Corrector; Invoked = $false; Succeeded = $false; Message = 'Invoke-AutoRemediate unavailable' }
            }

            try {
                $null = Invoke-AutoRemediate -Path $Item.Path -WhatIf:$DryRun -ErrorAction Stop
                return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $true; Message = '' }
            } catch {
                return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $false; Message = $_.Exception.Message }
            }
        }
        'SINRemedyEngine' {
            $scriptPath = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-SINRemedyEngine.ps1'
            if (-not (Test-Path -LiteralPath $scriptPath)) {
                return [PSCustomObject]@{ Name = $Corrector; Invoked = $false; Succeeded = $false; Message = 'Invoke-SINRemedyEngine unavailable' }
            }

            $targetPattern = '*'
            if (-not [string]::IsNullOrWhiteSpace($Item.Gate)) { $targetPattern = $Item.Gate }

            try {
                if ($DryRun) {
                    $null = & $scriptPath -WorkspacePath $WorkspacePath -MaxRetries 1 -TargetPattern $targetPattern -DryRun
                } else {
                    $null = & $scriptPath -WorkspacePath $WorkspacePath -MaxRetries 1 -TargetPattern $targetPattern
                }
                return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $true; Message = '' }
            } catch {
                return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $false; Message = $_.Exception.Message }
            }
        }
        'RoutineRemediation' {
            # Safe no-op stub for future routine remediators.
            return [PSCustomObject]@{ Name = $Corrector; Invoked = $true; Succeeded = $true; Message = 'RoutineRemediation stub no-op' }
        }
        default {
            return [PSCustomObject]@{ Name = $Corrector; Invoked = $false; Succeeded = $false; Message = 'Unknown corrector' }
        }
    }
}

function New-ItemCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [PSCustomObject]$Item,
        [AllowNull()] [string[]]$Paths,
        [switch]$DryRun
    )

    $validFiles = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) })
    if (@($validFiles).Count -eq 0) { return $null }
    if ($DryRun) { return $null }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $nameSegment = ([System.IO.Path]::GetFileNameWithoutExtension($Item.RelativePath) -replace '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($nameSegment)) { $nameSegment = 'item' }

    $checkpointRoot = Join-Path (Join-Path $WorkspacePath 'checkpoints') 'autocorrect-gate'
    if (-not (Test-Path -LiteralPath $checkpointRoot)) {
        New-Item -ItemType Directory -Path $checkpointRoot -Force | Out-Null
    }

    $checkpointDir = Join-Path $checkpointRoot ($stamp + '-' + $nameSegment)
    if (-not (Test-Path -LiteralPath $checkpointDir)) {
        New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null
    }

    $records = @()

    foreach ($filePath in @($validFiles)) {
        $relative = ConvertTo-WorkspaceRelativePath -WorkspacePath $WorkspacePath -Path $filePath
        $backupPath = Join-Path $checkpointDir ($relative -replace '[\\/]', '__')
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        [System.IO.File]::WriteAllBytes($backupPath, $bytes)
        $records += [PSCustomObject]@{ Path = $filePath; RelativePath = $relative; BackupPath = $backupPath }
    }

    return [PSCustomObject]@{
        Directory = $checkpointDir
        Files     = @($records)
    }
}

function Restore-FromItemCheckpoint {
    [CmdletBinding()]
    param([AllowNull()] [PSCustomObject]$Checkpoint)

    if ($null -eq $Checkpoint -or $null -eq $Checkpoint.Files) { return 0 }

    $restored = 0
    foreach ($entry in @($Checkpoint.Files)) {
        if ($null -eq $entry) { continue }
        if (-not (Test-Path -LiteralPath $entry.BackupPath)) { continue }

        $bytes = [System.IO.File]::ReadAllBytes($entry.BackupPath)
        [System.IO.File]::WriteAllBytes($entry.Path, $bytes)
        $restored++
    }

    return $restored
}

function Test-ProtectedPathViolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [AllowNull()] [string[]]$Paths,
        [AllowNull()] [string[]]$ProtectedPathPatterns
    )

    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $relative = ConvertTo-WorkspaceRelativePath -WorkspacePath $WorkspacePath -Path $path
        foreach ($rx in @($ProtectedPathPatterns)) {
            if ([string]::IsNullOrWhiteSpace($rx)) { continue }
            if ($relative -match $rx) {
                return $true
            }
        }
    }

    return $false
}

function Write-AutoCorrectAttemptActionLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$ActionId,
        [Parameter(Mandatory)] [string]$Summary,
        [Parameter(Mandatory)] [string]$Result,
        [Parameter(Mandatory)] [string]$FilePath,
        [switch]$IsStart
    )

    $modulePath = Join-Path (Join-Path $WorkspacePath 'modules') 'PwShGUI-AiActionLog.psm1'
    $loaded = Import-OptionalModuleFile -ModulePath $modulePath
    if (-not $loaded) { return }

    if (-not (Get-Command Write-AiActionStart -ErrorAction SilentlyContinue) -or -not (Get-Command Write-AiActionFinish -ErrorAction SilentlyContinue)) {
        return
    }

    $logFiles = @(@{ path = $FilePath; change = 'modified' })

    try {
        if ($IsStart) {
            Write-AiActionStart -WorkspacePath $WorkspacePath -ActionId $ActionId -ActionName 'AutoCorrectGateAttempt' -AgentId 'AutoCorrectGate' -Summary $Summary -Files $logFiles | Out-Null
        } else {
            Write-AiActionFinish -WorkspacePath $WorkspacePath -ActionId $ActionId -ActionName 'AutoCorrectGateAttempt' -AgentId 'AutoCorrectGate' -Summary $Summary -Files $logFiles -Result $Result | Out-Null
        }
    } catch {
        # Intentional non-fatal best-effort logging.
    }
}

function Resolve-AutoCorrectScopeItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [object[]]$Items,
        [Parameter(Mandatory)] [string]$Scope,
        [AllowNull()] [string[]]$FocusTargets,
        [int]$RecentDays = 14
    )

    $scopeName = [string]$Scope
    $selection = @($Items)
    $correctorOrder = @('AutoRemediate', 'SINRemedyEngine', 'RoutineRemediation')

    switch ($scopeName) {
        'KnowSafeRemidiations' {
            $correctorOrder = @('AutoRemediate', 'SINRemedyEngine')
        }
        'KnowSafeRemediations' {
            $correctorOrder = @('AutoRemediate', 'SINRemedyEngine')
        }
        'FastFix_Auto-Correct' {
            $correctorOrder = @('AutoRemediate')
            $cutoff = (Get-Date).AddDays(-1 * [Math]::Abs($RecentDays)).ToUniversalTime()
            $recent = @()
            foreach ($item in @($selection)) {
                $pathValue = if ($item.PSObject.Properties.Name -contains 'Path') { [string]$item.Path } else { '' }
                if ([string]::IsNullOrWhiteSpace($pathValue) -or -not (Test-Path -LiteralPath $pathValue)) {
                    $recent += $item
                    continue
                }
                $writeTime = (Get-Item -LiteralPath $pathValue).LastWriteTimeUtc
                if ($writeTime -ge $cutoff) {
                    $recent += $item
                }
            }
            $selection = @($recent)
        }
        'SpecificFocus' {
            if (@($FocusTargets).Count -eq 0) {
                throw 'SpecificFocus scope requires at least one target path or batch target.'
            }

            $correctorOrder = @('AutoRemediate', 'SINRemedyEngine')
            $focusHits = @()
            foreach ($item in @($selection)) {
                $relative = if ($item.PSObject.Properties.Name -contains 'RelativePath') { [string]$item.RelativePath } else { '' }
                $fullPath = if ($item.PSObject.Properties.Name -contains 'Path') { [string]$item.Path } else { '' }
                foreach ($target in @($FocusTargets)) {
                    if ([string]::IsNullOrWhiteSpace($target)) { continue }
                    if ($relative -like $target -or $fullPath -like $target -or $relative -like ('*' + $target + '*') -or $fullPath -like ('*' + $target + '*')) {
                        $focusHits += $item
                        break
                    }
                }
            }
            $selection = @($focusHits)
        }
        'FullWorkspace' {
            $correctorOrder = @('AutoRemediate', 'SINRemedyEngine', 'RoutineRemediation')
        }
        default {
            $correctorOrder = @('AutoRemediate', 'SINRemedyEngine')
        }
    }

    if (@($selection).Count -eq 0 -and $scopeName -notin @('FastFix_Auto-Correct','SpecificFocus')) {
        $selection = @($Items)
    }

    return [pscustomobject]@{
        Scope         = $scopeName
        Items         = @($selection)
        Correctors    = @($correctorOrder)
        TargetCount   = @($selection).Count
    }
}

function Invoke-AutoCorrectPreCommitValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [AllowNull()] [string[]]$Paths,
        [switch]$Quiet
    )

    $scriptPath = Join-Path (Join-Path $WorkspacePath 'tests') 'Invoke-PreCommitValidation.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return [pscustomobject]@{
            Available = $false
            Passed    = $false
            ErrorCount = 0
            WarnCount = 0
            Findings  = @()
            ReportPath = ''
            Error     = 'precommit-unavailable'
        }
    }

    $reportPath = Join-Path (Join-Path $WorkspacePath 'temp') ('autocorrect-precommit-' + [guid]::NewGuid().ToString('N') + '.json')
    $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath,
        '-WorkspacePath', $WorkspacePath,
        '-OutputJson', $reportPath,
        '-SkipPipelineMetricGate'
    )
    if ($Quiet) { $args += '-Quiet' }
    if (@($Paths).Count -gt 0) {
        $args += '-StagedFiles'
        $args += @($Paths)
    }

    $engine = Get-Command -Name pwsh -ErrorAction SilentlyContinue
    if ($null -eq $engine) {
        $engine = Get-Command -Name powershell -ErrorAction SilentlyContinue
    }
    if ($null -eq $engine) {
        return [pscustomobject]@{
            Available = $false
            Passed    = $false
            ErrorCount = 0
            WarnCount = 0
            Findings  = @()
            ReportPath = $reportPath
            Error     = 'powershell-host-unavailable'
        }
    }

    $enginePath = $engine.Path
    if ([string]::IsNullOrWhiteSpace($enginePath)) { $enginePath = $engine.Source }

    try {
        & $enginePath @args 2>$null | Out-Null
        if (Test-Path -LiteralPath $reportPath) {
            $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            return [pscustomobject]@{
                Available = $true
                Passed    = [bool]$report.passed
                ErrorCount = [int]$report.errorCount
                WarnCount = [int]$report.warnCount
                Findings  = @($report.findings)
                ReportPath = $reportPath
                Error     = ''
            }
        }
        return [pscustomobject]@{
            Available = $false
            Passed    = $false
            ErrorCount = 0
            WarnCount = 0
            Findings  = @()
            ReportPath = $reportPath
            Error     = 'report-missing'
        }
    } catch {
        return [pscustomobject]@{
            Available = $false
            Passed    = $false
            ErrorCount = 0
            WarnCount = 0
            Findings  = @()
            ReportPath = $reportPath
            Error     = $_.Exception.Message
        }
    }
}

function New-CorrectionAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$AttemptNumber,
        [Parameter(Mandatory)] [string]$ItemPath,
        [Parameter(Mandatory)] [string]$Corrector,
        [int]$PreTotalFindings = 0,
        [int]$PostTotalFindings = 0,
        [bool]$ParsePassed = $false,
        [string]$Status = 'UNKNOWN',
        [string]$StopCondition = '',
        [string]$Notes = ''
    )

    return [PSCustomObject]@{
        AttemptNumber     = $AttemptNumber
        ItemPath          = $ItemPath
        Corrector         = $Corrector
        TimestampUtc      = (Get-Date).ToUniversalTime().ToString('o')
        PreTotalFindings  = $PreTotalFindings
        PostTotalFindings = $PostTotalFindings
        ParsePassed       = $ParsePassed
        Status            = $Status
        StopCondition     = $StopCondition
        Notes             = $Notes
    }
}

function Test-KernelStopCondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('K1','K2','K3','K4','K5','K6')] [string]$ConditionId,
        [Parameter(Mandatory)] [object]$Config,
        [Parameter(Mandatory)] [hashtable]$Context
    )

    $stopCfg = $null
    if ($Config.PSObject.Properties.Name -contains 'StopConditions' -and $Config.StopConditions.PSObject.Properties.Name -contains $ConditionId) {
        $stopCfg = $Config.StopConditions.$ConditionId
    }

    if ($null -eq $stopCfg) {
        return [PSCustomObject]@{ Id = $ConditionId; Hit = $false; Enabled = $false; Action = ''; Severity = ''; Reason = 'missing-config'; Name = '' }
    }

    if ($stopCfg.PSObject.Properties.Name -contains 'enabled' -and -not [bool]$stopCfg.enabled) {
        return [PSCustomObject]@{ Id = $ConditionId; Hit = $false; Enabled = $false; Action = [string]$stopCfg.action; Severity = [string]$stopCfg.severity; Reason = 'disabled'; Name = [string]$stopCfg.name }
    }

    $hit = $false
    $reason = ''

    switch ($ConditionId) {
        'K1' {
            $ratio = 0.0
            if ($Context.ContainsKey('RegressionRatio')) { $ratio = [double]$Context['RegressionRatio'] }
            $threshold = if ($Config.PSObject.Properties.Name -contains 'RegressionDelta') { [double]$Config.RegressionDelta } else { 0.0 }
            $parseRegression = $false
            if ($Context.ContainsKey('ParseErrorsBefore') -and $Context.ContainsKey('ParseErrorsAfter')) {
                $parseRegression = ([int]$Context['ParseErrorsAfter'] -gt [int]$Context['ParseErrorsBefore'])
            }
            $preCommitRegression = $false
            if ($Context.ContainsKey('PreCommitErrorsBefore') -and $Context.ContainsKey('PreCommitErrorsAfter')) {
                $preCommitRegression = ([int]$Context['PreCommitErrorsAfter'] -gt [int]$Context['PreCommitErrorsBefore'])
            }
            if ($ratio -gt $threshold -or $parseRegression -or $preCommitRegression) {
                $hit = $true
                $reason = 'quality-regression'
            }
        }
        'K2' {
            if ($Context.ContainsKey('ScanAvailable') -and [bool]$Context['ScanAvailable']) {
                $newCritical = ([int]$Context['PostCritical'] -gt [int]$Context['PreCritical'])
                $newTotal = ([int]$Context['PostTotal'] -gt [int]$Context['PreTotal'])
                if ($newCritical -or $newTotal) {
                    $hit = $true
                    $reason = 'resultant-sin-regression'
                }
            }
        }
        'K3' {
            if ($Context.ContainsKey('ProtectedPathViolation') -and [bool]$Context['ProtectedPathViolation']) {
                $hit = $true
                $reason = 'protected-path-violation'
            }
        }
        'K4' {
            if ($Context.ContainsKey('Oscillation') -and [bool]$Context['Oscillation']) {
                $hit = $true
                $reason = 'paradox-oscillation'
            }
        }
        'K5' {
            if ($Context.ContainsKey('NoProgressCapHit') -and [bool]$Context['NoProgressCapHit']) {
                $hit = $true
                $reason = 'loop-cap-no-progress'
            }
        }
        'K6' {
            $timedOut = ($Context.ContainsKey('TimedOut') -and [bool]$Context['TimedOut'])
            $hadError = ($Context.ContainsKey('AttemptError') -and [bool]$Context['AttemptError'])
            if ($timedOut -or $hadError) {
                $hit = $true
                $reason = 'error-timeout-crash-lockup'
            }
        }
    }

    return [PSCustomObject]@{
        Id       = $ConditionId
        Hit      = $hit
        Enabled  = $true
        Action   = [string]$stopCfg.action
        Severity = [string]$stopCfg.severity
        Reason   = $reason
        Name     = [string]$stopCfg.name
    }
}

function Invoke-AutoCorrectGate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
        [AllowNull()] [object[]]$FailItems = @(),
        [string]$ConfigPath = '',
        [ValidateSet('FullWorkspace','KnowSafeRemidiations','KnowSafeRemediations','FastFix_Auto-Correct','SpecificFocus')]
        [string]$Scope = 'KnowSafeRemidiations',
        [AllowNull()] [string[]]$FocusTargets = @(),
        [int]$RecentDays = 14,
        [int]$MaxAttempts = 0
    )

    $workspaceFull = [System.IO.Path]::GetFullPath($WorkspacePath)
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Resolve-AutoCorrectGateConfigPath -WorkspacePath $workspaceFull
    }

    $cfg = ConvertTo-AutoCorrectGateConfig -Config (Read-AutoCorrectGateConfig -ConfigPath $ConfigPath)

    $resolvedMaxAttempts = if ($MaxAttempts -gt 0) { $MaxAttempts } else { [int]$cfg.MaxAttempts }
    if ($resolvedMaxAttempts -lt 1) { $resolvedMaxAttempts = 1 }
    $stallAttempts = [int]$cfg.StallAttempts
    if ($stallAttempts -lt 1) { $stallAttempts = 1 }
    $timeoutSec = [int]$cfg.PerItemTimeoutSec
    if ($timeoutSec -lt 1) { $timeoutSec = 1 }

    $normalized = @()
    foreach ($raw in @($FailItems)) {
        $item = ConvertTo-NormalizedFailItem -FailItem $raw -WorkspacePath $workspaceFull
        if ($null -ne $item) { $normalized += $item }
    }

    if (@($normalized).Count -eq 0) {
        return [PSCustomObject]@{
            processed         = 0
            corrected         = 0
            escalated         = 0
            rolledBack        = 0
            stopHits          = @()
            errors            = 0
            attempts          = @()
            items             = @()
            scope             = $Scope
            focusTargets      = @($FocusTargets)
            recentDays        = $RecentDays
            finalParsePassed  = $true
            finalParseErrors  = 0
            finalErrorCount   = 0
            finalWarnCount    = 0
            finalFindingCount = 0
            passed            = $true
            stopped           = $false
        }
    }

    $scopeSelection = Resolve-AutoCorrectScopeItems -WorkspacePath $workspaceFull -Items $normalized -Scope $Scope -FocusTargets $FocusTargets -RecentDays $RecentDays
    $normalized = Get-UniqueNormalizedItems -Items @($scopeSelection.Items)

    $correctorOrder = @($scopeSelection.Correctors)
    if (@($correctorOrder).Count -eq 0) {
        $correctorOrder = @('AutoRemediate','SINRemedyEngine','RoutineRemediation')
    }

    $summary = [ordered]@{
        processed  = 0
        corrected  = 0
        escalated  = 0
        rolledBack = 0
        stopHits   = @()
        errors     = 0
        attempts   = @()
        items      = @()
        scope      = $Scope
        focusTargets = @($FocusTargets)
        recentDays = $RecentDays
    }

    $isWhatIf = [bool]$WhatIfPreference

    foreach ($item in @($normalized)) {
        $summary.processed++

        $itemCorrectorOrder = @($correctorOrder)

        $paths = @()
        if (-not [string]::IsNullOrWhiteSpace($item.Path)) {
            $paths += $item.Path
        }
        $paths = @($paths | Select-Object -Unique)

        $checkpoint = $null
        $itemEscalated = $false
        $itemCorrected = $false
        $stallCounter = 0
        $improvementTrend = @()
        $attemptCount = 0

        $preParse = Get-ParserValidationResult -Paths $paths
        $preScan = Invoke-ResultantSinScan -WorkspacePath $workspaceFull -Paths $paths
        $preCommit = Invoke-AutoCorrectPreCommitValidation -WorkspacePath $workspaceFull -Paths @($item.RelativePath) -Quiet

        $isCanonicalRegistryTarget = ($item.Gate -eq 'deprecated-reference' -and [System.IO.Path]::GetFileName($item.Path) -eq 'pipeline-canonical-paths.json')

        if (-not $isCanonicalRegistryTarget -and -not (Test-AutoCorrectTargetSupported -Path $item.Path)) {
            $summary.stopHits += [PSCustomObject]@{ item = $item.RelativePath; condition = 'K5'; reason = 'unsupported-target-type' }
            $summary.escalated++
            $itemEscalated = $true

            $summary.items += [PSCustomObject]@{
                path        = $item.RelativePath
                gate        = $item.Gate
                severity    = $item.Severity
                corrected   = $false
                escalated   = $true
                attempts    = 0
                checkpoint  = ''
            }
            continue
        }

        if ($isCanonicalRegistryTarget) {
            $itemCorrectorOrder = @('CanonicalRegistryRemediation')
        }

        if ($PSCmdlet.ShouldProcess($item.Path, 'Auto-correct gate attempt loop')) {
            if ($cfg.Guardrails.RequirePreWriteCheckpoint -and -not $isWhatIf) {
                $checkpoint = New-ItemCheckpoint -WorkspacePath $workspaceFull -Item $item -Paths $paths
            }

            while ($attemptCount -lt $resolvedMaxAttempts -and -not $itemEscalated -and -not $itemCorrected) {
                $attemptCount++
                $attemptSw = [System.Diagnostics.Stopwatch]::StartNew()
                $attemptError = $false
                $lastCorrector = ''
                $correctorMessage = ''

                $actionId = 'autocorrect-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
                Write-AutoCorrectAttemptActionLog -WorkspacePath $workspaceFull -ActionId $actionId -Summary ('attempt-start #' + $attemptCount) -Result 'unknown' -FilePath $item.RelativePath -IsStart

                foreach ($corrector in @($itemCorrectorOrder)) {
                    $step = Invoke-CorrectorStep -Corrector ([string]$corrector) -Item $item -WorkspacePath $workspaceFull -DryRun:$isWhatIf
                    $lastCorrector = [string]$step.Name
                    $correctorMessage = [string]$step.Message
                    if (-not $step.Succeeded) {
                        $attemptError = $true
                    }
                }

                $postParse = Get-ParserValidationResult -Paths $paths
                $postScan = Invoke-ResultantSinScan -WorkspacePath $workspaceFull -Paths $paths
                $postCommit = Invoke-AutoCorrectPreCommitValidation -WorkspacePath $workspaceFull -Paths @($item.RelativePath) -Quiet

                $preTotal = if ($preScan.Available) { [int]$preScan.Total } else { 0 }
                $postTotal = if ($postScan.Available) { [int]$postScan.Total } else { 0 }
                $preCritical = if ($preScan.Available) { [int]$preScan.Critical } else { 0 }
                $postCritical = if ($postScan.Available) { [int]$postScan.Critical } else { 0 }

                $improved = $false
                if ($postScan.Available) {
                    $improved = ($postTotal -lt $preTotal) -and $postParse.Passed -and ($postCommit.Passed -or -not $postCommit.Available)
                } else {
                    $improved = $postParse.Passed -and ($postParse.ErrorCount -le $preParse.ErrorCount) -and ($postCommit.Passed -or -not $postCommit.Available)
                }

                if ($improved) {
                    $stallCounter = 0
                    $improvementTrend += 1
                } else {
                    $stallCounter++
                    $improvementTrend += -1
                }

                $timedOut = ($attemptSw.Elapsed.TotalSeconds -gt $timeoutSec)
                $regressionRatio = 0.0
                if ($preTotal -gt 0) {
                    $regressionRatio = ([double]($postTotal - $preTotal) / [double]$preTotal)
                } elseif ($postTotal -gt 0) {
                    $regressionRatio = 1.0
                }

                $oscillation = $false
                if (@($improvementTrend).Count -ge 4) {
                    $t = @($improvementTrend)
                    $n = @($t).Count
                    if ($t[$n - 1] -ne $t[$n - 2] -and $t[$n - 2] -ne $t[$n - 3] -and $t[$n - 3] -ne $t[$n - 4]) {  # SIN-EXEMPT:P027 -- index access, context-verified safe
                        $oscillation = $true
                    }
                }

                $context = @{
                    RegressionRatio       = $regressionRatio
                    ParseErrorsBefore     = [int]$preParse.ErrorCount
                    ParseErrorsAfter      = [int]$postParse.ErrorCount
                    PreCommitErrorsBefore = if ($preCommit.Available) { [int]$preCommit.ErrorCount } else { 0 }
                    PreCommitErrorsAfter  = if ($postCommit.Available) { [int]$postCommit.ErrorCount } else { 0 }
                    PreCommitPassedBefore = [bool]$preCommit.Passed
                    PreCommitPassedAfter  = [bool]$postCommit.Passed
                    ScanAvailable         = [bool]$postScan.Available
                    PreTotal              = $preTotal
                    PostTotal             = $postTotal
                    PreCritical           = $preCritical
                    PostCritical          = $postCritical
                    ProtectedPathViolation = (Test-ProtectedPathViolation -WorkspacePath $workspaceFull -Paths $paths -ProtectedPathPatterns @($cfg.ProtectedPathPatterns))
                    Oscillation           = $oscillation
                    NoProgressCapHit      = (($attemptCount -ge $resolvedMaxAttempts) -or ($stallCounter -ge $stallAttempts)) -and (-not $improved)
                    TimedOut              = $timedOut
                    AttemptError          = $attemptError
                }

                $hit = $null
                foreach ($conditionId in @('K1','K2','K3','K4','K5','K6')) {
                    $result = Test-KernelStopCondition -ConditionId $conditionId -Config $cfg -Context $context
                    if ($result.Hit) {
                        $hit = $result
                        break
                    }
                }

                $attemptStatus = if ($null -ne $hit) { 'STOP' } elseif ($improved) { 'IMPROVED' } else { 'NO_PROGRESS' }
                $stopConditionId = ''
                if ($null -ne $hit) {
                    $stopConditionId = $hit.Id
                }
                $attemptObj = New-CorrectionAttempt -AttemptNumber $attemptCount -ItemPath $item.RelativePath -Corrector $lastCorrector -PreTotalFindings $preTotal -PostTotalFindings $postTotal -ParsePassed $postParse.Passed -Status $attemptStatus -StopCondition $stopConditionId -Notes $correctorMessage
                $summary.attempts += $attemptObj

                $preCommit = $postCommit

                if ($null -ne $hit) {
                    $summary.stopHits += [PSCustomObject]@{ item = $item.RelativePath; condition = $hit.Id; reason = $hit.Reason }
                    if ($cfg.Guardrails.RollbackOnAnyStopCondition -and $null -ne $checkpoint -and -not $isWhatIf) {
                        $restored = Restore-FromItemCheckpoint -Checkpoint $checkpoint
                        if ($restored -gt 0) {
                            $summary.rolledBack++
                        }
                    }
                    $itemEscalated = $true
                    Write-AutoCorrectAttemptActionLog -WorkspacePath $workspaceFull -ActionId $actionId -Summary ('attempt-stop #' + $attemptCount + ' ' + $hit.Id) -Result 'failed' -FilePath $item.RelativePath
                    break
                }

                if ($improved) {
                    $itemCorrected = $true
                    Write-AutoCorrectAttemptActionLog -WorkspacePath $workspaceFull -ActionId $actionId -Summary ('attempt-success #' + $attemptCount) -Result 'success' -FilePath $item.RelativePath
                    break
                }

                Write-AutoCorrectAttemptActionLog -WorkspacePath $workspaceFull -ActionId $actionId -Summary ('attempt-no-progress #' + $attemptCount) -Result 'unknown' -FilePath $item.RelativePath
            }
        }

        if ($itemCorrected) {
            $summary.corrected++
        } else {
            $summary.escalated++
            $itemEscalated = $true
        }

        $summary.items += [PSCustomObject]@{
            path        = $item.RelativePath
            gate        = $item.Gate
            severity    = $item.Severity
            corrected   = $itemCorrected
            escalated   = $itemEscalated
            attempts    = $attemptCount
            checkpoint  = if ($null -ne $checkpoint) { $checkpoint.Directory } else { '' }
        }
    }

    $allPaths = @($normalized | ForEach-Object { $_.Path } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $finalParse = Get-ParserValidationResult -Paths $allPaths
    $finalScan = Invoke-ResultantSinScan -WorkspacePath $workspaceFull -Paths $allPaths

    $summary.finalParsePassed = $finalParse.Passed
    $summary.finalParseErrors = $finalParse.ErrorCount
    $summary.finalErrorCount = if ($finalScan.Available) { [int]$finalScan.Critical + [int]$finalScan.High } else { [int]$finalParse.ErrorCount }
    $summary.finalWarnCount = if ($finalScan.Available) { [int]$finalScan.Medium + [int]$finalScan.Low } else { 0 }
    $summary.finalFindingCount = if ($finalScan.Available) { [int]$finalScan.Total } else { [int]$finalParse.ErrorCount }
    $summary.passed = ($summary.finalParsePassed -and $summary.finalFindingCount -eq 0 -and $summary.escalated -eq 0)
    $summary.stopped = ($summary.escalated -gt 0)

    return [PSCustomObject]$summary
}

Export-ModuleMember -Function @(
    'Invoke-AutoCorrectGate',
    'Test-KernelStopCondition',
    'New-CorrectionAttempt',
    'Resolve-AutoCorrectGateConfigPath',
    'Read-AutoCorrectGateConfig',
    'ConvertTo-AutoCorrectGateConfig',
    'New-AutoCorrectApprovalItem'
)
