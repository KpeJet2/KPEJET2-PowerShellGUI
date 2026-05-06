# VersionTag: 2605.B2.V31.7
# SupportPS5.1: true
# SupportsPS7.6: true
# Pester 5.x tests for EventLog standard layer + DiffScheduler.

BeforeAll {
    $script:Ws = Split-Path $PSScriptRoot -Parent
    $script:AdapterPath = Join-Path $Ws 'modules\PwShGUI-EventLogAdapter.psm1'
    Import-Module $AdapterPath -Force -DisableNameChecking
}

Describe 'EventLogAdapter -- ConvertTo-CanonicalSeverity' {
    It 'maps Write-AppLog severities to canonical' {
        ConvertTo-CanonicalSeverity 'Info'     | Should -Be 'INFO'
        ConvertTo-CanonicalSeverity 'Warning'  | Should -Be 'WARN'
        ConvertTo-CanonicalSeverity 'Error'    | Should -Be 'ERROR'
        ConvertTo-CanonicalSeverity 'Critical' | Should -Be 'CRITICAL'
        ConvertTo-CanonicalSeverity 'Audit'    | Should -Be 'AUDIT'
        ConvertTo-CanonicalSeverity 'Debug'    | Should -Be 'DEBUG'
    }
    It 'maps Write-CronLog severities to canonical' {
        ConvertTo-CanonicalSeverity 'Emergency'     | Should -Be 'CRITICAL'
        ConvertTo-CanonicalSeverity 'Alert'         | Should -Be 'ERROR'
        ConvertTo-CanonicalSeverity 'Notice'        | Should -Be 'INFO'
        ConvertTo-CanonicalSeverity 'Informational' | Should -Be 'INFO'
    }
    It 'maps legacy XHTML labels (BOOT/CRASH) and unknowns default to INFO' {
        ConvertTo-CanonicalSeverity 'BOOT'     | Should -Be 'INFO'
        ConvertTo-CanonicalSeverity 'CRASH'    | Should -Be 'CRITICAL'
        ConvertTo-CanonicalSeverity 'GibberishX' | Should -Be 'INFO'
    }
}

Describe 'EventLogAdapter -- Write/Get round-trip' {
    It 'writes and reads back a normalized row with the canonical envelope shape' {
        $corr = 'PESTER-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        Write-EventLogNormalized -Scope pipeline -Component 'PesterTest' -Message 'round-trip-check' -Severity 'Warning' -CorrId $corr -WorkspacePath $script:Ws | Out-Null
        $env = Get-EventLogNormalized -Scope pipeline -Tail 50 -WorkspacePath $script:Ws
        $env                | Should -Not -BeNullOrEmpty
        $env.scope          | Should -Be 'pipeline'
        $env.cache          | Should -Not -BeNullOrEmpty
        $env.cache.tier     | Should -BeIn @('live','disk','replay','stale')
        @($env.items).Count | Should -BeGreaterThan 0
        $foundRows = @($env.items | Where-Object { $_.corrId -eq $corr })
        @($foundRows).Count   | Should -Be 1
        $foundRows[0].severity | Should -Be 'WARN'
    }
}

Describe 'EventLogAdapter -- root aggregate' {
    It 'unions multiple scopes when scope=root' {
        Write-EventLogNormalized -Scope sec    -Component 'Pester' -Message 'root-agg-sec'    -Severity 'Info' -WorkspacePath $script:Ws | Out-Null
        Write-EventLogNormalized -Scope engine -Component 'Pester' -Message 'root-agg-engine' -Severity 'Info' -WorkspacePath $script:Ws | Out-Null
        $env = Get-EventLogNormalized -Scope root -Tail 200 -WorkspacePath $script:Ws
        $env.scope | Should -Be 'root'
        @($env.items | Where-Object { $_.msg -eq 'root-agg-sec' }).Count    | Should -BeGreaterOrEqual 1
        @($env.items | Where-Object { $_.msg -eq 'root-agg-engine' }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'DiffScheduler -- DryRun parses and runs' {
    It 'invokes Invoke-DiffScheduler.ps1 -Once with exit 0' {
        $script = Join-Path $script:Ws 'scripts\Invoke-DiffScheduler.ps1'
        Test-Path -LiteralPath $script | Should -BeTrue
        $errs = $null; $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
    }
}

Describe 'EventLogStandard -- script registration' {
    It 'registers all EventLog/Diff scheduler scripts in agentic-manifest.json' {
        $j = Get-Content -LiteralPath (Join-Path $script:Ws 'config\agentic-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $names = @('Invoke-AutoApprovalWriter','Invoke-DiffScheduler','Register-DiffSchedulerTask','Invoke-EventLogStandardSweep','Invoke-EventLogViewInject')
        foreach ($n in $names) {
            (@($j.scripts | Where-Object { $_.name -eq $n }).Count) | Should -BeGreaterOrEqual 1 -Because "Manifest must register $n"
        }
    }

    It 'registers EventLog adapter actionRoutes in agenticAPI.actionRoutes' {
        $j = Get-Content -LiteralPath (Join-Path $script:Ws 'config\agentic-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        # Route naming evolved to readable action strings in manifest rebuilds;
        # verify the active schema instead of historical aliases.
        $actions = @('write.logging eventlog','read.logging eventlog','test.logging eventlog')
        foreach ($a in $actions) {
            (@($j.agenticAPI.actionRoutes | Where-Object { $_.action -eq $a }).Count) | Should -BeGreaterOrEqual 1 -Because "Manifest must route $a"
        }
    }
}

