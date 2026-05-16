# VersionTag: 2605.B5.V46.0
<#
.SYNOPSIS
    Pester smoke tests for PwShGUI-KillSwitch module.
.DESCRIPTION
    Verifies CSV-driven kill-switch row lookup, seed cloning + auto-hash,
    target registration, and Invoke-KillSwitch fan-out. Stop-Process /
    Stop-Service are mocked so the test never actually terminates anything.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\modules\PwShGUI-KillSwitch.psm1')).Path
    $script:TempCsv    = Join-Path ([System.IO.Path]::GetTempPath()) ("kill-switches-test-{0}.csv" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    @(
        '"Version","KillSwitch","Passphrase","Md5","Sha256","Cipher"',
        '"V=x","ctrl+shift+q","purplezero","b46cc331089e7d120b19e3f839c54234","87c91e5ac2c1c8653dd3360b16daf54b563f46a4656fcf6924cad655a93c487c","AES256"'
    ) | Set-Content -LiteralPath $script:TempCsv -Encoding UTF8
    $env:KILLSWITCH_NO_SELFTERMINATE = '1'
    Import-Module $script:ModulePath -Force
}

AfterAll {
    if (Test-Path -LiteralPath $script:TempCsv) { Remove-Item -LiteralPath $script:TempCsv -Force }
    Remove-Item Env:KILLSWITCH_NO_SELFTERMINATE -ErrorAction SilentlyContinue
    Remove-Module PwShGUI-KillSwitch -ErrorAction SilentlyContinue
}

Describe 'PwShGUI-KillSwitch module' {

    Context 'Get-VersionKillSwitch' {

        It 'returns the seed row when version is V=x' {
            $r = Get-VersionKillSwitch -Version 'V=x' -CsvPath $script:TempCsv
            $r | Should -Not -BeNullOrEmpty
            $r.Version    | Should -Be 'V=x'
            $r.KillSwitch | Should -Be 'ctrl+shift+q'
            $r.Passphrase | Should -Be 'purplezero'
        }

        It 'clones the seed row for a new version and computes hashes' {
            $newVer = 'TEST.V99.0'
            $r = Get-VersionKillSwitch -Version $newVer -CsvPath $script:TempCsv
            $r.Version    | Should -Be $newVer
            $r.KillSwitch | Should -Be 'ctrl+shift+q'
            $r.Md5        | Should -Be 'b46cc331089e7d120b19e3f839c54234'
            $r.Sha256     | Should -Be '87c91e5ac2c1c8653dd3360b16daf54b563f46a4656fcf6924cad655a93c487c'
            $r.Cipher     | Should -Be 'AES256'
        }

        It 'persists the cloned row to disk' {
            $rows = @(Import-Csv -LiteralPath $script:TempCsv)
            @($rows | Where-Object { $_.Version -eq 'TEST.V99.0' }).Count | Should -Be 1
        }

        It 'returns the same row on subsequent calls without duplicating' {
            $null = Get-VersionKillSwitch -Version 'TEST.V99.0' -CsvPath $script:TempCsv
            $rows = @(Import-Csv -LiteralPath $script:TempCsv)
            @($rows | Where-Object { $_.Version -eq 'TEST.V99.0' }).Count | Should -Be 1
        }
    }

    Context 'Register-KillTarget / Get-RegisteredKillTargets' {

        It 'tracks process targets' {
            $entry = Register-KillTarget -ProcessId 999999 -Description 'unit-test'
            $entry.ProcessId | Should -Be 999999
            @(Get-RegisteredKillTargets | Where-Object { $_.ProcessId -eq 999999 }).Count | Should -BeGreaterThan 0
        }

        It 'tracks service targets' {
            $entry = Register-KillTarget -ServiceName 'NoSuchSvc_Pester' -Description 'unit-test-svc'
            $entry.ServiceName | Should -Be 'NoSuchSvc_Pester'
        }
    }

    Context 'Invoke-KillSwitch' {

        It 'attempts to stop registered targets without throwing' {
            Mock -ModuleName PwShGUI-KillSwitch Stop-Process { } -Verifiable
            Mock -ModuleName PwShGUI-KillSwitch Stop-Service { } -Verifiable
            Mock -ModuleName PwShGUI-KillSwitch Get-Process { [pscustomobject]@{ Id = 999999 } }
            Mock -ModuleName PwShGUI-KillSwitch Get-Service { [pscustomobject]@{ Name = 'NoSuchSvc_Pester'; Status = 'Running' } }
            { Invoke-KillSwitch -Reason 'pester' } | Should -Not -Throw
        }
    }

    Context 'Test-KillSwitchIntegrity' {

        It 'returns no drift when Md5/Sha256 match the Passphrase' {
            $drift = Test-KillSwitchIntegrity -CsvPath $script:TempCsv
            @($drift).Count | Should -Be 0
        }

        It 'detects drift when Passphrase changes without hash recompute' {
            $tampered = Join-Path ([System.IO.Path]::GetTempPath()) ("kill-switches-tamper-{0}.csv" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
            @(
                '"Version","KillSwitch","Passphrase","Md5","Sha256","Cipher"',
                '"V=x","ctrl+shift+q","DIFFERENT","b46cc331089e7d120b19e3f839c54234","87c91e5ac2c1c8653dd3360b16daf54b563f46a4656fcf6924cad655a93c487c","AES256"'
            ) | Set-Content -LiteralPath $tampered -Encoding UTF8
            try {
                $drift = Test-KillSwitchIntegrity -CsvPath $tampered
                @($drift).Count | Should -Be 2
                @($drift | Where-Object Field -eq 'Md5').Count    | Should -Be 1
                @($drift | Where-Object Field -eq 'Sha256').Count | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $tampered -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'DPAPI Protect/Unprotect helpers (W3)' {

        It 'round-trips a passphrase via Protect/Unprotect' {
            $wrapped = Protect-KillSwitchPassphrase -PlainText 'purplezero'
            $wrapped | Should -Match '^DPAPI:'
            (Unprotect-KillSwitchPassphrase -Value $wrapped) | Should -Be 'purplezero'
        }

        It 'passes plaintext through Unprotect when no DPAPI prefix present' {
            (Unprotect-KillSwitchPassphrase -Value 'plain-thing') | Should -Be 'plain-thing'
        }

        It 'is idempotent: Protect of an already-wrapped value returns the input' {
            $first  = Protect-KillSwitchPassphrase -PlainText 'abc'
            $second = Protect-KillSwitchPassphrase -PlainText $first
            $second | Should -Be $first
        }

        It 'unwraps DPAPI-stored passphrase via Get-VersionKillSwitch' {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("kill-switches-dpapi-{0}.csv" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
            try {
                $wrapped = Protect-KillSwitchPassphrase -PlainText 'purplezero'
                @(
                    '"Version","KillSwitch","Passphrase","Md5","Sha256","Cipher"',
                    ('"V=x","ctrl+shift+q","{0}","b46cc331089e7d120b19e3f839c54234","87c91e5ac2c1c8653dd3360b16daf54b563f46a4656fcf6924cad655a93c487c","AES256"' -f $wrapped)
                ) | Set-Content -LiteralPath $tmp -Encoding UTF8
                $r = Get-VersionKillSwitch -Version 'V=x' -CsvPath $tmp
                $r.Passphrase | Should -Be 'purplezero'
                $drift = Test-KillSwitchIntegrity -CsvPath $tmp
                @($drift).Count | Should -Be 0
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

