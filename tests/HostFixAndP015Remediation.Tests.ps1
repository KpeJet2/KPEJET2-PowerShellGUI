# VersionTag: 2608.B1.V54.6
BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $hostFix = Join-Path $repoRoot 'scripts\Invoke-HostPrereqFix.ps1'
    $p015Fix = Join-Path $repoRoot 'scripts\Invoke-SinHardcodedPathRemediation.ps1'
}

Describe 'Independent host fix and P015 remediation contracts' {
    It 'generates a unique instance manifest without invoking pipeline scripts' {
        $result = & $hostFix -WorkspacePath $repoRoot -Action Generate -NoPrereqCheck
        $result.FixId | Should -Match '^localhost-fix-'
        $result.InstanceId | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $result.ManifestPath | Should -BeTrue
        $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.workspacePath | Should -Be $repoRoot
        $manifest.processId | Should -BeGreaterThan 0
        $manifest.prereqCommand | Should -Match 'Invoke-WorkspacePreReqs\.ps1'
        $manifest.applyCommand | Should -Not -Match 'Invoke-Pipeline'
        Remove-Item -LiteralPath $result.ManifestPath -Force -ErrorAction SilentlyContinue
    }

    It 'produces a report-only P015 remediation result' {
        $scanPath = Join-Path $repoRoot 'temp\p015-test-scan.json'
        $outputPath = Join-Path $repoRoot 'temp\p015-test-report.json'
        @{ findings = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $scanPath -Encoding UTF8
        try {
            $result = & $p015Fix -WorkspacePath $repoRoot -ScanJson $scanPath -OutputJson $outputPath
            $result.applySafe | Should -BeFalse
            $result.changedFileCount | Should -Be 0
            Test-Path -LiteralPath $outputPath | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $scanPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        }
    }
}
