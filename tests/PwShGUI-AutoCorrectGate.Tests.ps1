# VersionTag: 2607.B6.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: Test
#Requires -Version 5.1

Describe 'PwShGUI-AutoCorrectGate module surface' {
  BeforeAll {
    $script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:WorkspaceRoot 'modules\\PwShGUI-AutoCorrectGate.psm1'
    Import-Module -Name $script:ModulePath -Force -DisableNameChecking -ErrorAction Stop
  }

    It 'Imports and exports required functions' {
        $cmdInvoke = Get-Command Invoke-AutoCorrectGate -ErrorAction SilentlyContinue
        $cmdKernel = Get-Command Test-KernelStopCondition -ErrorAction SilentlyContinue
        $cmdAttempt = Get-Command New-CorrectionAttempt -ErrorAction SilentlyContinue

        $cmdInvoke | Should -Not -BeNullOrEmpty
        $cmdKernel | Should -Not -BeNullOrEmpty
        $cmdAttempt | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-AutoCorrectGate behavior' {
    It 'WhatIf mode does not modify files' {
        $ws = Join-Path $TestDrive 'ws-whatif'
        $null = New-Item -ItemType Directory -Path $ws -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $ws 'config') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $ws 'modules') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $ws 'scripts') -Force

        $target = Join-Path $ws 'sample.ps1'
        $originalContent = "function Test-Sample {`r`n    catch {}`r`n}`r`n"
        Set-Content -LiteralPath $target -Value $originalContent -Encoding UTF8
        $beforeBytes = [System.IO.File]::ReadAllBytes($target)

        $config = @'
{
  "MaxAttempts": 2,
  "StallAttempts": 2,
  "PerItemTimeoutSec": 30,
  "RegressionDelta": 0.03,
  "CorrectorOrder": ["AutoRemediate","SINRemedyEngine","RoutineRemediation"],
  "Guardrails": {
    "RequirePreWriteCheckpoint": true,
    "RequireDryRunFirst": true,
    "RequirePostWriteValidation": true,
    "BlockProtectedPathMutation": true,
    "RollbackOnAnyStopCondition": true,
    "RequireAiActionLog": true
  },
  "ProtectedPathPatterns": ["^pki($|[\\\\/])"],
  "StopConditions": {
    "K1": { "name": "significant-regression", "severity": "CRITICAL", "action": "rollback+escalate", "enabled": true },
    "K2": { "name": "resultant-sin", "severity": "CRITICAL", "action": "rollback+escalate", "enabled": true },
    "K3": { "name": "charter-protected-path-violation", "severity": "CRITICAL", "action": "rollback+escalate", "enabled": true },
    "K4": { "name": "paradox-oscillation", "severity": "HIGH", "action": "rollback+escalate", "enabled": true },
    "K5": { "name": "loop-cap-no-progress", "severity": "HIGH", "action": "rollback+escalate", "enabled": true },
    "K6": { "name": "error-timeout-crash-lockup", "severity": "CRITICAL", "action": "rollback+escalate", "enabled": true }
  }
}
'@
        Set-Content -LiteralPath (Join-Path $ws 'config\autocorrect-gate.config.json') -Value $config -Encoding UTF8

        $failItems = @([PSCustomObject]@{
            file     = $target
            gate     = 'SIN-PATTERN-002'
            severity = 'HIGH'
            message  = 'empty catch'
        })

        $null = Invoke-AutoCorrectGate -WorkspacePath $ws -FailItems $failItems -WhatIf

        $afterBytes = [System.IO.File]::ReadAllBytes($target)
        ([System.BitConverter]::ToString($afterBytes)) | Should -BeExactly ([System.BitConverter]::ToString($beforeBytes))
    }

    It 'Triggers K5 loop-cap/no-progress when attempts are exhausted without improvement' {
        $ws = Join-Path $TestDrive 'ws-k5'
        $null = New-Item -ItemType Directory -Path $ws -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $ws 'config') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $ws 'modules') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $ws 'scripts') -Force

        $target = Join-Path $ws 'sample.ps1'
        Set-Content -LiteralPath $target -Value 'function Broken-Case {' -Encoding UTF8

        $config = @'
{
  "MaxAttempts": 2,
  "StallAttempts": 1,
  "PerItemTimeoutSec": 30,
  "RegressionDelta": 0.03,
  "CorrectorOrder": ["RoutineRemediation"],
  "Guardrails": {
    "RequirePreWriteCheckpoint": true,
    "RequireDryRunFirst": true,
    "RequirePostWriteValidation": true,
    "BlockProtectedPathMutation": true,
    "RollbackOnAnyStopCondition": true,
    "RequireAiActionLog": false
  },
  "ProtectedPathPatterns": ["^pki($|[\\\\/])"],
  "StopConditions": {
    "K1": { "name": "significant-regression", "severity": "CRITICAL", "action": "rollback+escalate", "enabled": true },
    "K2": { "name": "resultant-sin", "severity": "CRITICAL", "action": "rollback+escalate", "enabled": true },
    "K3": { "name": "charter-protected-path-violation", "severity": "CRITICAL", "action": "rollback+escalate", "enabled": true },
    "K4": { "name": "paradox-oscillation", "severity": "HIGH", "action": "rollback+escalate", "enabled": true },
    "K5": { "name": "loop-cap-no-progress", "severity": "HIGH", "action": "rollback+escalate", "enabled": true },
    "K6": { "name": "error-timeout-crash-lockup", "severity": "CRITICAL", "action": "rollback+escalate", "enabled": true }
  }
}
'@
        Set-Content -LiteralPath (Join-Path $ws 'config\autocorrect-gate.config.json') -Value $config -Encoding UTF8

        $failItems = @([PSCustomObject]@{
            path     = $target
            gate     = 'SIN-PATTERN-999'
            severity = 'LOW'
            message  = 'non-progress sample'
        })

        $result = Invoke-AutoCorrectGate -WorkspacePath $ws -FailItems $failItems

        $result.escalated | Should -Be 1
        @($result.stopHits | Where-Object { $_.condition -eq 'K5' }).Count | Should -BeGreaterThan 0
    }
}
