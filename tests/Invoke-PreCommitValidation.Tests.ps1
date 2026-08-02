BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $validatorScriptFile = Join-Path $repoRoot 'tests/Invoke-PreCommitValidation.ps1'
}

Describe 'Invoke-PreCommitValidation recovery loop' {
    It 'retries a gate until it passes or reaches the retry cap' {
        $retryLoop = . $validatorScriptFile -WorkspacePath $repoRoot -OutputJson (Join-Path $repoRoot 'temp/precommit-loop-test.json') -Quiet -SkipPipelineControlGate -SkipPipelineMetricGate -StagedFiles 'tests/Invoke-PreCommitValidation.ps1' -AutoCorrectFailures -ErrorAction SilentlyContinue
    }

    It 'includes a non-scanned candidate inventory in the JSON report' {
        $hostExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        $outPath = Join-Path $repoRoot 'temp/precommit-transparency-test.json'
        if (Test-Path -LiteralPath $outPath) {
            Remove-Item -LiteralPath $outPath -Force
        }

        $procArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $validatorScriptFile,
            '-WorkspacePath', $repoRoot,
            '-OutputJson', $outPath,
            '-Quiet',
            '-SkipPipelineControlGate',
            '-SkipPipelineMetricGate',
            '-StagedFiles', 'tests/Invoke-PreCommitValidation.ps1'
        )

        $proc = Start-Process -FilePath $hostExe -ArgumentList $procArgs -Wait -PassThru -NoNewWindow
        $proc.ExitCode | Should -BeLessThan 2

        $report = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.additionalScanCandidates | Should -Not -BeNullOrEmpty
        @($report.additionalScanCandidates.notScannedFolders).Count | Should -BeGreaterThan 0
        @($report.additionalScanCandidates.notScannedScripts).Count | Should -BeGreaterThan 0
        @($report.additionalScanCandidates.notScannedModules).Count | Should -BeGreaterThan 0
    }
}
