# VersionTag: 2607.B7.V53.0
# SupportPS5.1: yes
# SupportsPS7.6: yes
# SupportPS5.1TestedDate: 2026-08-03
# SupportsPS7.6TestedDate: 2026-08-03
# FileRole: Validation
# Show-Objectives: Run dual-engine parser checks and targeted cert/approvals contract tests in one command.
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [switch]$IncludeIntegration,
    [switch]$RunPs51Pester
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ValidationLog {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
    Write-Host "[$ts][$Level][CertApprovalsValidation] $Message"
}

function Invoke-PwshParseCheck {
    param([Parameter(Mandatory)] [string[]]$RelativePaths)

    Write-ValidationLog "Running pwsh parser checks for $(@($RelativePaths).Count) file(s)."
    $failed = @()
    foreach ($rel in $RelativePaths) {
        $targetPath = Join-Path $WorkspacePath $rel
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $targetPath), [ref]$tokens, [ref]$errors) | Out-Null
        if (@($errors).Count -gt 0) {
            $failed += [pscustomobject]@{
                file = $rel
                messages = @($errors | ForEach-Object { $_.Message })
            }
        }
    }

    if (@($failed).Count -gt 0) {
        foreach ($f in $failed) {
            Write-ValidationLog "pwsh parse failed: $($f.file)" 'ERROR'
            foreach ($msg in @($f.messages)) {
                Write-Host "  - $msg"
            }
        }
        throw "pwsh parser checks failed."
    }

    Write-ValidationLog 'pwsh parser checks passed.'
}

function Invoke-Ps51ParseCheck {
    param([Parameter(Mandatory)] [string[]]$RelativePaths)

    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51)) {
        throw "Windows PowerShell 5.1 executable not found: $ps51"
    }

    Write-ValidationLog "Running PS5.1 parser checks for $(@($RelativePaths).Count) file(s)."

    $targetsLiteral = @($RelativePaths | ForEach-Object {
        "'{0}'" -f ($_ -replace "'", "''")
    }) -join ','

    $ps51Script = @"
`$ErrorActionPreference = 'Stop'
`$workspace = '$($WorkspacePath -replace "'", "''")'
`$targets = @($targetsLiteral)
`$failed = @()
foreach (`$rel in `$targets) {
  `$tok = `$null
  `$err = `$null
  `$path = Join-Path `$workspace `$rel
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath `$path), [ref]`$tok, [ref]`$err) | Out-Null
  if (@(`$err).Count -gt 0) {
    `$failed += [PSCustomObject]@{ file = `$rel; messages = @(`$err | ForEach-Object { `$_.Message }) }
  }
}
if (@(`$failed).Count -gt 0) {
  foreach (`$item in `$failed) {
    Write-Host ('[PS5.1][FAIL] ' + `$item.file)
    foreach (`$m in @(`$item.messages)) { Write-Host ('  - ' + `$m) }
  }
  exit 1
}
Write-Host '[PS5.1][PASS] Parser checks passed.'
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps51Script))
    & $ps51 -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) {
        throw 'PS5.1 parser checks failed.'
    }

    Write-ValidationLog 'PS5.1 parser checks passed.'
}

function Invoke-TargetedPester {
    param(
        [Parameter(Mandatory)] [string[]]$RelativePaths,
        [switch]$Ps51
    )

    $label = if ($Ps51) { 'PS5.1' } else { 'pwsh' }
    $fullPaths = @($RelativePaths | ForEach-Object { Join-Path $WorkspacePath $_ })

    if ($Ps51) {
        $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $ps51)) {
            throw "Windows PowerShell 5.1 executable not found: $ps51"
        }

        $pesterPathLiteral = @($RelativePaths | ForEach-Object {
            "'{0}'" -f ($_ -replace "'", "''")
        }) -join ','

        $ps51Script = @"
`$ErrorActionPreference = 'Stop'
`$workspace = '$($WorkspacePath -replace "'", "''")'
if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { `$_.Version -ge [version]'5.0' })) {
  Install-Module Pester -RequiredVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser
}
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
`$targets = @($pesterPathLiteral) | ForEach-Object { Join-Path `$workspace `$_ }
`$run = Invoke-Pester -Path `$targets -Output Normal -PassThru
if ([int]`$run.FailedCount -gt 0) { exit 1 }
"@

        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps51Script))
        Write-ValidationLog "Running targeted Pester on $label for $(@($RelativePaths).Count) file(s)."
        & $ps51 -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
        if ($LASTEXITCODE -ne 0) {
            throw 'PS5.1 targeted Pester failed.'
        }
    } else {
        Write-ValidationLog "Running targeted Pester on $label for $(@($RelativePaths).Count) file(s)."
        Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
        $run = Invoke-Pester -Path $fullPaths -Output Detailed -PassThru
        if ([int]$run.FailedCount -gt 0) {
            throw 'pwsh targeted Pester failed.'
        }
        Write-ValidationLog ("pwsh Pester: passed={0} failed={1} skipped={2}" -f [int]$run.PassedCount, [int]$run.FailedCount, [int]$run.SkippedCount)
    }
}

$parserTargets = @(
    'scripts/Start-LocalWebEngine.ps1',
    'tests/Start-LocalWebEngine.Tests.ps1',
    'tests/CertHubAndApprovalsSurface.Tests.ps1'
)
if ($IncludeIntegration) {
    $parserTargets += 'tests/Start-LocalWebEngineIntegration.Tests.ps1'
}

$testTargets = @(
    'tests/Start-LocalWebEngine.Tests.ps1',
    'tests/CertHubAndApprovalsSurface.Tests.ps1'
)
if ($IncludeIntegration) {
    $testTargets += 'tests/Start-LocalWebEngineIntegration.Tests.ps1'
}

$started = Get-Date
Write-ValidationLog "Validation start. includeIntegration=$([bool]$IncludeIntegration) runPs51Pester=$([bool]$RunPs51Pester)"

Invoke-PwshParseCheck -RelativePaths $parserTargets
Invoke-Ps51ParseCheck -RelativePaths $parserTargets
Invoke-TargetedPester -RelativePaths $testTargets

if ($RunPs51Pester) {
    $ps51StaticTargets = @(
        'tests/Start-LocalWebEngine.Tests.ps1',
        'tests/CertHubAndApprovalsSurface.Tests.ps1'
    )
    Invoke-TargetedPester -RelativePaths $ps51StaticTargets -Ps51
}

$elapsed = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)
Write-ValidationLog "Validation completed successfully in $elapsed second(s)."

[PSCustomObject]@{
    status = 'PASS'
    workspacePath = $WorkspacePath
    includeIntegration = [bool]$IncludeIntegration
    runPs51Pester = [bool]$RunPs51Pester
    parserTargets = $parserTargets
    testTargets = $testTargets
    completedAt = (Get-Date).ToString('o')
    elapsedSeconds = $elapsed
}
