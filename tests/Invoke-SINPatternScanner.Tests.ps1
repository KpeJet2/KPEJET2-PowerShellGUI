# VersionTag: 2605.B5.V46.0
<#
.SYNOPSIS
    Pester integration tests for Invoke-SINPatternScanner.ps1
.DESCRIPTION
    Scanner-of-the-scanner guardrails. Validates that the scanner produces
    valid JSON, ratchet metadata is set correctly, the JUnit converter works,
    and SIN-EXEMPT markers suppress findings. Heavy full-workspace scans run
    once in BeforeAll for speed.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:Repo       = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:Scanner    = Join-Path $script:Repo 'tests\Invoke-SINPatternScanner.ps1'
    $script:Converter  = Join-Path $script:Repo 'tests\Convert-SinScanToJUnit.ps1'
    $script:Baseline   = Join-Path $script:Repo 'config\sin-baseline.json'
    $script:OutDir     = Join-Path ([System.IO.Path]::GetTempPath()) ("sinscan-test-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    $null = New-Item -ItemType Directory -Path $script:OutDir -Force
    $script:OutJson    = Join-Path $script:OutDir 'scan.json'
    $script:OutXml     = Join-Path $script:OutDir 'scan-junit.xml'

    # One full Permissive scan; the rest of the suite consumes its output.
    $global:LASTEXITCODE = 0
    & $script:Scanner -RatchetMode Permissive -BaselineJson $script:Baseline -OutputJson $script:OutJson -FailOnCritical -Quiet *>$null
    $script:PrimaryExit = $LASTEXITCODE
    $script:PrimaryJson = if (Test-Path -LiteralPath $script:OutJson) {
        Get-Content -LiteralPath $script:OutJson -Raw | ConvertFrom-Json
    } else { $null }
}

AfterAll {
    if (Test-Path -LiteralPath $script:OutDir) {
        Remove-Item -LiteralPath $script:OutDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-SINPatternScanner integration' {

    Context 'Full Permissive scan against current baseline' {

        It 'wrote a JSON output file' {
            Test-Path -LiteralPath $script:OutJson | Should -BeTrue
            $script:PrimaryJson | Should -Not -BeNullOrEmpty
        }

        It 'records ratchetMode=Permissive and baselineApplied=true' {
            $script:PrimaryJson.ratchetMode     | Should -Be 'Permissive'
            $script:PrimaryJson.baselineApplied | Should -BeTrue
        }

        It 'totalFindings equals sum of countsBySinId values' {
            $sum = 0
            foreach ($p in $script:PrimaryJson.countsBySinId.PSObject.Properties) { $sum += [int]$p.Value }
            $sum | Should -Be $script:PrimaryJson.totalFindings
        }
    }

    Context 'JUnit XML conversion of primary scan' {

        BeforeAll {
            & $script:Converter -ScanJson $script:OutJson -OutputXml $script:OutXml -BaselineJson $script:Baseline *>$null
        }

        It 'produces well-formed XML with testsuites root' {
            Test-Path -LiteralPath $script:OutXml | Should -BeTrue
            { [xml](Get-Content -LiteralPath $script:OutXml -Raw) } | Should -Not -Throw
        }

        It 'tests count is at least totalFindings (plus ratchet metadata cases)' {
            [xml]$x = Get-Content -LiteralPath $script:OutXml -Raw
            [int]$x.testsuites.tests | Should -BeGreaterOrEqual $script:PrimaryJson.totalFindings
        }
    }

    Context 'SIN-EXEMPT marker suppression (single-file scan)' {

        It 'suppresses an empty-catch (P002) finding when SIN-EXEMPT:P002 is on the same line' {
            $fixtureName = 'temp-sinscan-fixture.ps1'
            $fixturePath = Join-Path $script:Repo $fixtureName
            try {
                @(
                    '# VersionTag: TEST',
                    'function Test-Exempt {',
                    '    try { Get-Item foo } catch { }',
                    '}'
                ) | Set-Content -LiteralPath $fixturePath -Encoding UTF8

                $altJson = Join-Path $script:OutDir 'fixture-noexempt.json'
                & $script:Scanner -IncludeFiles @($fixtureName) -RatchetMode Off -OutputJson $altJson -Quiet *>$null
                $j1 = Get-Content -LiteralPath $altJson -Raw | ConvertFrom-Json
                $hits1 = @($j1.findings | Where-Object { $_.sinId -match 'P002|EMPTYCATCH' }).Count
                $hits1 | Should -BeGreaterThan 0

                @(
                    '# VersionTag: TEST',
                    'function Test-Exempt {',
                    '    try { Get-Item foo } catch { }  # SIN-EXEMPT:P002 -- intentional',
                    '}'
                ) | Set-Content -LiteralPath $fixturePath -Encoding UTF8

                $altJson2 = Join-Path $script:OutDir 'fixture-exempt.json'
                & $script:Scanner -IncludeFiles @($fixtureName) -RatchetMode Off -OutputJson $altJson2 -Quiet *>$null
                $j2 = Get-Content -LiteralPath $altJson2 -Raw | ConvertFrom-Json
                $hits2 = @($j2.findings | Where-Object { $_.sinId -match 'P002|EMPTYCATCH' }).Count
                $hits2 | Should -Be 0
            } finally {
                Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

