# VersionTag: 2608.B1.V1.0
# SupportPS5.1: YES
# SupportsPS7.6: YES
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'modules\SessionOutcomeClassifier.psm1'
    $script:ScriptPath = Join-Path $script:RepoRoot 'scripts\Invoke-SessionResilienceLoop.ps1'
    $script:ConfigPath = Join-Path $script:RepoRoot 'config\session-resilience-loop.json'
    $script:ControlProfilePath = Join-Path $script:RepoRoot 'config\session-resilience-control-profile.json'

    Import-Module -Name $script:ModulePath -Force

    function New-LoopFixtureWorkspace {
        param([string]$Name)

        $ws = Join-Path $TestDrive $Name
        $dirs = @('scripts', 'modules', 'config', 'logs', 'logs\session-loop', 'temp', '~REPORTS')
        foreach ($dir in $dirs) {
            $null = New-Item -ItemType Directory -Path (Join-Path $ws $dir) -Force
        }

        Copy-Item -LiteralPath $script:ScriptPath -Destination (Join-Path $ws 'scripts\Invoke-SessionResilienceLoop.ps1') -Force
        Copy-Item -LiteralPath $script:ModulePath -Destination (Join-Path $ws 'modules\SessionOutcomeClassifier.psm1') -Force
        Copy-Item -LiteralPath $script:ConfigPath -Destination (Join-Path $ws 'config\session-resilience-loop.json') -Force
        Copy-Item -LiteralPath $script:ControlProfilePath -Destination (Join-Path $ws 'config\session-resilience-control-profile.json') -Force

        return $ws
    }
}

Describe 'SessionOutcomeClassifier.Get-NextRetryPlan' {
    It 'turns on steering from attempt 7' {
        $cfg = Get-SessionLoopConfig -ConfigPath $script:ConfigPath

        $next = Get-NextRetryPlan -Config $cfg -PhaseIndex 0 -PhaseAttempt 6 -TotalAttempts 6 -NearImmediate $true
        $next.PhaseIndex | Should -Be 1
        $next.ApplySteering | Should -BeTrue
    }

    It 'resets the ladder on slow failures after phase 2' {
        $cfg = Get-SessionLoopConfig -ConfigPath $script:ConfigPath

        $next = Get-NextRetryPlan -Config $cfg -PhaseIndex 3 -PhaseAttempt 3 -TotalAttempts 30 -NearImmediate $false
        $next.PhaseIndex | Should -Be 0
        $next.LadderReset | Should -BeTrue
    }
}

Describe 'Session resilience control profile' {
    It 'declares the normalized operator order and prime gate' {
        $profile = Get-Content -LiteralPath $script:ControlProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        @($profile.operatorOrder).Count | Should -BeGreaterThan 5
        $profile.operatorOrder | Should -Contain 'VerifyCommitGate'
        $profile.secretGate.prime | Should -Be 7
        $profile.secretGate.switch | Should -Be '2BxPrimeTimesLucky'
        $profile.commitGate.enabled | Should -BeTrue
        $profile.sessionIndex.enabled | Should -BeTrue
    }
}

Describe 'SessionOutcomeClassifier.Find-RetryableSession' {
    It 'finds today logs that include failure plus Try Again/retry' {
        $ws = New-LoopFixtureWorkspace -Name 'retryable-discovery'
        $cfg = Get-SessionLoopConfig -ConfigPath (Join-Path $ws 'config\session-resilience-loop.json')

        $logFile = Join-Path $ws 'logs\session-loop\sample-session.log'
        @(
            'session run started',
            'ERROR: tests failed',
            'Try Again was offered to the operator',
            'last action: retry'
        ) | Set-Content -LiteralPath $logFile -Encoding UTF8

        $found = @(Find-RetryableSession -WorkspacePath $ws -Config $cfg -Since ([datetime]::Today))
        @($found).Count | Should -BeGreaterThan 0
        $found[0].OffersTryAgain | Should -BeTrue
        $found[0].Recommendation | Should -Be 'TRY_AGAIN'
    }
}

Describe 'Invoke-SessionResilienceLoop script behavior' {
    It 'detect-only mode reports retryable sessions and exits cleanly' {
        $ws = New-LoopFixtureWorkspace -Name 'detect-only'
        $logFile = Join-Path $ws 'logs\session-loop\session-a.log'
        @(
            'runtime failure',
            'retry',
            'ERROR: process terminated unexpectedly'
        ) | Set-Content -LiteralPath $logFile -Encoding UTF8

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ws 'scripts\Invoke-SessionResilienceLoop.ps1') `
            -WorkspacePath $ws -DetectOnly
        $LASTEXITCODE | Should -Be 0
    }

    It 'dry-run with ResumeToday produces a ledger and exits 0' {
        $ws = New-LoopFixtureWorkspace -Name 'dry-run-resume'

        $logFile = Join-Path $ws 'logs\session-loop\session-b.log'
        @(
            'crash happened',
            'Try Again',
            'ERROR: session aborted'
        ) | Set-Content -LiteralPath $logFile -Encoding UTF8

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ws 'scripts\Invoke-SessionResilienceLoop.ps1') `
            -WorkspacePath $ws -ResumeToday -DryRun -SessionCommand 'Write-Output "noop"'
        $LASTEXITCODE | Should -Be 0

        $ledger = Join-Path $ws 'logs\session-loop\ledger.json'
        Test-Path -LiteralPath $ledger | Should -BeTrue
        $rows = @(Get-Content -LiteralPath $ledger -Raw -Encoding UTF8 | ConvertFrom-Json)
        @($rows).Count | Should -BeGreaterThan 0
        $rows[0].TargetSessionPath | Should -Match 'session-b.log'
    }
}
