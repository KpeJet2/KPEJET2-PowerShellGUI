# VersionTag: 2608.B1.V54.7
BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $triageScript = Join-Path $repoRoot 'scripts\Invoke-StaleQueueTriage.ps1'
}

Describe 'Stale queue triage contract' {
    It 'defines a safe stale queue triage entrypoint' {
        Test-Path -LiteralPath $triageScript | Should -BeTrue
        $text = Get-Content -LiteralPath $triageScript -Raw -Encoding UTF8
        $text | Should -Match '\[CmdletBinding\(\)\]'
        $text | Should -Match '\$ThresholdDays'
        $text | Should -Match 'QueuePath|todo/QUEUES-ToDo|stale'
    }

    It 'keeps generated reports out of source commits' {
        $gitIgnore = Join-Path $repoRoot '.gitignore'
        $text = Get-Content -LiteralPath $gitIgnore -Raw -Encoding UTF8
        $text | Should -Match 'reports/interop-iter/'
        $text | Should -Match 'temp/host-fixes/'
        $text | Should -Match 'reports/sin-hardcoded-path-remediation\.json'
    }
}
