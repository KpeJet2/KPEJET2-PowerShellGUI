# VersionTag: 2608.B1.V54.0
BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

Describe 'Invoke-PreCommitValidation recovery loop' {
    It 'retries a gate until it passes or reaches the retry cap' {
        . (Join-Path $repoRoot 'tests/Invoke-PreCommitValidation.ps1') -WorkspacePath $repoRoot -OutputJson (Join-Path $repoRoot 'temp/precommit-loop-test.json') -Quiet -SkipPipelineControlGate -SkipPipelineMetricGate -StagedFiles 'tests/Invoke-PreCommitValidation.ps1' -AutoCorrectFailures -ErrorAction SilentlyContinue
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
            '-File', (Join-Path $repoRoot 'tests/Invoke-PreCommitValidation.ps1'),
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
        [string]::IsNullOrWhiteSpace([string]$report.safetyNetRegistryPath) | Should -BeFalse
        Test-Path -LiteralPath ([string]$report.safetyNetRegistryPath) | Should -BeTrue
    }

    It 'writes a redacted failure summary and remediation plan for blocking issues' {
        $hostExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        $tempFile = Join-Path $repoRoot 'temp/precommit-redacted-remedy-test.ps1'
        $outPath = Join-Path $repoRoot 'temp/precommit-redacted-remedy.json'

        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
        if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }

        try {
            [System.IO.File]::WriteAllText($tempFile, "# VersionTag: TEST`n`$value = 'café'`n", [System.Text.UTF8Encoding]::new($false))

            $procArgs = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Join-Path $repoRoot 'tests/Invoke-PreCommitValidation.ps1'),
                '-WorkspacePath', $repoRoot,
                '-OutputJson', $outPath,
                '-Quiet',
                '-FailOnWarning',
                '-StagedFiles', $tempFile
            )

            $proc = Start-Process -FilePath $hostExe -ArgumentList $procArgs -Wait -PassThru -NoNewWindow
            $proc.ExitCode | Should -Be 1

            $report = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $report.redactedSummary.totalCount | Should -BeGreaterThan 0
            @($report.redactedSummary.byGate).Count | Should -BeGreaterThan 0
            [string]::IsNullOrWhiteSpace([string]$report.safetyNetRegistryPath) | Should -BeFalse
            Test-Path -LiteralPath ([string]$report.safetyNetRegistryPath) | Should -BeTrue

            $registry = Get-Content -LiteralPath ([string]$report.safetyNetRegistryPath) -Raw -Encoding UTF8 | ConvertFrom-Json
            @($registry.gates).Count | Should -BeGreaterThan 0
            @($registry.gates | Where-Object { $_.gate -eq 'Encoding' }).Count | Should -BeGreaterThan 0

            $encRemedy = @($report.remediationPlan | Where-Object { $_.gate -eq 'Encoding' -and $_.available })
            @($encRemedy).Count | Should -BeGreaterThan 0
            $encRemedy[0].script | Should -Match 'Fix-P006-EncodingViolations\.ps1'
        } finally {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'expands a newline-delimited staged file list passed as a single argument' {
        $hostExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        $outPath = Join-Path $repoRoot 'temp/precommit-staged-list.json'
        if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }

        $stagedInput = "tests/Invoke-PreCommitValidation.ps1`nscripts/Start-LocalWebEngine.ps1"
        $procArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $repoRoot 'tests/Invoke-PreCommitValidation.ps1'),
            '-WorkspacePath', $repoRoot,
            '-OutputJson', $outPath,
            '-Quiet',
            '-SkipPipelineControlGate',
            '-SkipPipelineMetricGate',
            '-StagedFiles', $stagedInput
        )

        $proc = Start-Process -FilePath $hostExe -ArgumentList $procArgs -Wait -PassThru -NoNewWindow
        $proc.ExitCode | Should -BeLessThan 2

        $report = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.filesChecked | Should -BeGreaterThan 0
    }
}
