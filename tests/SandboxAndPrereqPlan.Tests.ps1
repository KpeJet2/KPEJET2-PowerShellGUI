# VersionTag: 2608.B1.V54.5
BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $sandboxLauncher = Join-Path $repoRoot 'tests\sandbox\Start-InteractiveSandbox.ps1'
    $prereqScript = Join-Path $repoRoot 'scripts\Invoke-WorkspacePreReqs.ps1'
    $smokeScript = Join-Path $repoRoot 'tests\Invoke-SandboxSmokeTest.ps1'
}

Describe 'Sandbox and prerequisite plan contracts' {
    It 'exposes sandbox reuse and readiness parameters' {
        $text = Get-Content -LiteralPath $sandboxLauncher -Raw -Encoding UTF8
        $text | Should -Match '\[switch\]\$NoReuseExisting'
        $text | Should -Match 'function Find-ExistingSandboxSession'
        $text | Should -Match 'function Get-SandboxReadiness'
        $text | Should -Match '\$maxWaitSec\s*=\s*90'
        $text | Should -Match '\$extraWaitSec\s*=\s*30'
    }

    It 'writes a durable master prerequisite report' {
        $text = Get-Content -LiteralPath $prereqScript -Raw -Encoding UTF8
        $text | Should -Match 'prereq-master-latest\.json'
        $text | Should -Match "ReportAction 'master-before'"
        $text | Should -Match "ReportAction 'master-after'"
    }

    It 'keeps the smoke orchestrator contract parseable' {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($smokeScript, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}
