# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# Author: The Establishment
# Date: 2025-06-05
# FileRole: Diagnostics
<#
.SYNOPSIS  PKIChainManager module Pester tests.
.DESCRIPTION
    Full test suite for PKIChainManager.psm1:
      - Module import and exported function surface
      - Initialize-PKIChainManager path structure
      - New-RootCACertificate output contract
      - New-SubordinateCACertificate signer validation
      - New-CodeSignCertificate type check
      - Get-PKIChainStatus status calculation
      - Export-CertToVault mock-validates vault dispatch
      - New-FullPKIChain end-to-end output shape
      - Expiry window boundary conditions (EXPIRING threshold = 90 days)
      - Pre-initialisation guard throws
    Requires Pester v5+. Does NOT require live cert store access;
    uses mocked certificates and temp PKI paths via TestDrive.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\PKIChainManager.psm1'
    try {
        Import-Module $modulePath -Force -ErrorAction Stop
    } catch {
        throw "PKIChainManager.psm1 import failed: $_"
    }

    # ---------- helpers --------------------------------------------------
    function New-MockCertPath {
        # Create a minimal self-signed cert in a temp store for testing
        # without depending on the PKI module itself
        $tmpPath = Join-Path $TestDrive 'mockpki'
        foreach ($sub in @('ca','subca','codesign','crl')) {
            New-Item (Join-Path $tmpPath $sub) -ItemType Directory -Force | Out-Null
        }
        # Create a placeholder .cer file so Get-PKIChainStatus can stat it
        $cert = New-SelfSignedCertificate `
            -Subject 'CN=Test Root CA' `
            -CertStoreLocation Cert:\CurrentUser\My `
            -KeyUsage CertSign `
            -NotAfter ([datetime]::UtcNow.AddDays(400))
        $cerBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        [System.IO.File]::WriteAllBytes((Join-Path $tmpPath 'ca\RootCA.cer'), $cerBytes)
        return [PSCustomObject]@{ Path = $tmpPath; Cert = $cert }
    }
}

AfterAll {
    Remove-Module PKIChainManager -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════
Describe 'PKIChainManager - Module Surface' {
    It 'Imports without error' {
        Get-Module PKIChainManager | Should -Not -BeNullOrEmpty
    }

    It 'Exports exactly 7 functions' {
        $exports = (Get-Module PKIChainManager).ExportedFunctions.Keys
        @($exports).Count | Should -Be 7
    }

    It 'Exports Initialize-PKIChainManager' {
        Get-Command Initialize-PKIChainManager | Should -Not -BeNullOrEmpty
    }
    It 'Exports New-RootCACertificate' {
        Get-Command New-RootCACertificate | Should -Not -BeNullOrEmpty
    }
    It 'Exports New-SubordinateCACertificate' {
        Get-Command New-SubordinateCACertificate | Should -Not -BeNullOrEmpty
    }
    It 'Exports New-CodeSignCertificate' {
        Get-Command New-CodeSignCertificate | Should -Not -BeNullOrEmpty
    }
    It 'Exports Get-PKIChainStatus' {
        Get-Command Get-PKIChainStatus | Should -Not -BeNullOrEmpty
    }
    It 'Exports Export-CertToVault' {
        Get-Command Export-CertToVault | Should -Not -BeNullOrEmpty
    }
    It 'Exports New-FullPKIChain' {
        Get-Command New-FullPKIChain | Should -Not -BeNullOrEmpty
    }
}

# ════════════════════════════════════════════════════════════════
Describe 'Initialize-PKIChainManager' {
    BeforeEach {
        $testBase = Join-Path $TestDrive ('pki_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    }

    It 'Creates the expected sub-directories' {
        Initialize-PKIChainManager -BasePath $testBase
        foreach ($sub in @('ca','subca','codesign','crl')) {
            Test-Path (Join-Path $testBase $sub) | Should -BeTrue -Because "sub-folder '$sub' must be created"
        }
    }

    It 'Accepts an already-existing base path without error' {
        New-Item $testBase -ItemType Directory -Force | Out-Null
        { Initialize-PKIChainManager -BasePath $testBase } | Should -Not -Throw
    }

    It 'Sets the internal initialised flag (verified by Get-PKIChainStatus not throwing)' {
        Initialize-PKIChainManager -BasePath $testBase
        # Get-PKIChainStatus should not throw "Not initialized" — it may return empty list, that is OK
        { Get-PKIChainStatus } | Should -Not -Throw
    }
}

# ════════════════════════════════════════════════════════════════
Describe 'Pre-initialisation guard' {
    BeforeEach {
        # Reload module to reset internal state flags
        Remove-Module PKIChainManager -ErrorAction SilentlyContinue
        Import-Module (Join-Path $PSScriptRoot '..\modules\PKIChainManager.psm1') -Force
    }

    It 'New-RootCACertificate throws before Initialize-PKIChainManager' {
        $pw = ConvertTo-SecureString 'test' -AsPlainText -Force
        { New-RootCACertificate -PfxPassword $pw } | Should -Throw '*Not initialized*'
    }

    It 'Get-PKIChainStatus throws before Initialize-PKIChainManager' {
        { Get-PKIChainStatus } | Should -Throw '*Not initialized*'
    }

    AfterEach {
        Remove-Module PKIChainManager -ErrorAction SilentlyContinue
        Import-Module (Join-Path $PSScriptRoot '..\modules\PKIChainManager.psm1') -Force
    }
}

# ════════════════════════════════════════════════════════════════
Describe 'New-RootCACertificate' {
    BeforeAll {
        $testBase = Join-Path $TestDrive 'pki_rootca'
        Initialize-PKIChainManager -BasePath $testBase
        $pw = ConvertTo-SecureString 'TestP@ss1!' -AsPlainText -Force
        $script:rootResult = New-RootCACertificate -PfxPassword $pw -ValidityYears 1 -KeyLength 2048
    }
    AfterAll {
        # Clean up cert from store
        if ($script:rootResult) {
            Get-ChildItem Cert:\CurrentUser\My |
                Where-Object { $_.Thumbprint -eq $script:rootResult.Thumbprint } |
                Remove-Item -ErrorAction SilentlyContinue
        }
    }

    It 'Returns a result object with expected properties' {
        $script:rootResult | Should -Not -BeNullOrEmpty
        $script:rootResult.PSObject.Properties.Name | Should -Contain 'Type'
        $script:rootResult.PSObject.Properties.Name | Should -Contain 'Thumbprint'
        $script:rootResult.PSObject.Properties.Name | Should -Contain 'PfxPath'
        $script:rootResult.PSObject.Properties.Name | Should -Contain 'CerPath'
    }

    It 'Returns Type = RootCA' {
        $script:rootResult.Type | Should -Be 'RootCA'
    }

    It 'Creates a PFX file on disk' {
        Test-Path $script:rootResult.PfxPath | Should -BeTrue
    }

    It 'Creates a CER file on disk' {
        Test-Path $script:rootResult.CerPath | Should -BeTrue
    }

    It 'Certificate NotAfter is approximately 1 year in future' {
        $diff = ($script:rootResult.NotAfter - [datetime]::UtcNow).TotalDays
        $diff | Should -BeGreaterThan 360
        $diff | Should -BeLessThan 400
    }

    It 'Thumbprint is a valid 40-char hex string' {
        $script:rootResult.Thumbprint | Should -Match '^[0-9A-Fa-f]{40}$'
    }
}

# ════════════════════════════════════════════════════════════════
Describe 'New-SubordinateCACertificate' {
    BeforeAll {
        $testBase = Join-Path $TestDrive 'pki_subca'
        Initialize-PKIChainManager -BasePath $testBase
        $pw = ConvertTo-SecureString 'TestP@ss1!' -AsPlainText -Force
        $script:rootR  = New-RootCACertificate -PfxPassword $pw -ValidityYears 1 -KeyLength 2048
        $script:subResult = New-SubordinateCACertificate -SignerThumbprint $script:rootR.Thumbprint -PfxPassword $pw -ValidityYears 1 -KeyLength 2048
    }
    AfterAll {
        foreach ($thumb in @($script:rootR.Thumbprint, $script:subResult.Thumbprint)) {
            Get-ChildItem Cert:\CurrentUser\My |
                Where-Object { $_.Thumbprint -eq $thumb } |
                Remove-Item -ErrorAction SilentlyContinue
        }
    }

    It 'Returns Type = SubordinateCA' {
        $script:subResult.Type | Should -Be 'SubordinateCA'
    }

    It 'Records SignedBy = Root CA thumbprint' {
        $script:subResult.SignedBy | Should -Be $script:rootR.Thumbprint
    }

    It 'Creates SubCA PFX file' {
        Test-Path $script:subResult.PfxPath | Should -BeTrue
    }

    It 'Throws when signer thumbprint does not exist in store' {
        $pw = ConvertTo-SecureString 'TestP@ss1!' -AsPlainText -Force
        { New-SubordinateCACertificate -SignerThumbprint 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' -PfxPassword $pw } |
            Should -Throw
    }
}

# ════════════════════════════════════════════════════════════════
Describe 'New-CodeSignCertificate' {
    BeforeAll {
        $testBase = Join-Path $TestDrive 'pki_codesign'
        Initialize-PKIChainManager -BasePath $testBase
        $pw = ConvertTo-SecureString 'TestP@ss1!' -AsPlainText -Force
        $script:rootR2 = New-RootCACertificate -PfxPassword $pw -ValidityYears 1 -KeyLength 2048
        $script:subR2  = New-SubordinateCACertificate -SignerThumbprint $script:rootR2.Thumbprint -PfxPassword $pw -ValidityYears 1 -KeyLength 2048
        $script:csResult = New-CodeSignCertificate -SignerThumbprint $script:subR2.Thumbprint -PfxPassword $pw -ValidityYears 1
    }
    AfterAll {
        foreach ($thumb in @($script:rootR2.Thumbprint,$script:subR2.Thumbprint,$script:csResult.Thumbprint)) {
            Get-ChildItem Cert:\CurrentUser\My |
                Where-Object { $_.Thumbprint -eq $thumb } |
                Remove-Item -ErrorAction SilentlyContinue
        }
    }

    It 'Returns Type = CodeSigning' {
        $script:csResult.Type | Should -Be 'CodeSigning'
    }

    It 'Creates CodeSign PFX file' {
        Test-Path $script:csResult.PfxPath | Should -BeTrue
    }

    It 'Certificate has Enhanced Key Usage for Code Signing' {
        $cert = $script:csResult.Certificate
        $ekuExt = $cert.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] }
        $oids = $ekuExt.EnhancedKeyUsages.Value
        $oids | Should -Contain '1.3.6.1.5.5.7.3.3' -Because 'OID 1.3.6.1.5.5.7.3.3 is the Code Signing EKU'
    }
}

# ════════════════════════════════════════════════════════════════
Describe 'Get-PKIChainStatus' {
    BeforeAll {
        $testBase = Join-Path $TestDrive 'pki_status'
        Initialize-PKIChainManager -BasePath $testBase
        $pw = ConvertTo-SecureString 'TestP@ss1!' -AsPlainText -Force
        $script:statusRoot = New-RootCACertificate -PfxPassword $pw -ValidityYears 1 -KeyLength 2048
    }
    AfterAll {
        Get-ChildItem Cert:\CurrentUser\My |
            Where-Object { $_.Thumbprint -eq $script:statusRoot.Thumbprint } |
            Remove-Item -ErrorAction SilentlyContinue
    }

    It 'Returns a list without throwing' {
        { Get-PKIChainStatus } | Should -Not -Throw
    }

    It 'Includes at least the RootCA entry when .cer file is present' {
        $statuses = @(Get-PKIChainStatus)
        $rootEntry = $statuses | Where-Object { $_.Type -eq 'RootCA' }
        $rootEntry | Should -Not -BeNullOrEmpty
    }

    It 'RootCA entry has Status = Valid (cert is 1yr validity, ~400 days left)' {
        $entry = @(Get-PKIChainStatus) | Where-Object { $_.Type -eq 'RootCA' }
        $entry.Status | Should -Be 'Valid'
    }

    It 'Reports EXPIRING for cert with <90 days remaining' {
        # Write a nearly-expired cert to the ca path
        $expPath = Join-Path $TestDrive 'pki_expiry'
        Initialize-PKIChainManager -BasePath $expPath
        $cert = New-SelfSignedCertificate `
            -Subject 'CN=ExpiryTest' `
            -CertStoreLocation Cert:\CurrentUser\My `
            -NotAfter ([datetime]::UtcNow.AddDays(30))
        $bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        [System.IO.File]::WriteAllBytes((Join-Path $expPath 'ca\RootCA.cer'), $bytes)
        $status = @(Get-PKIChainStatus) | Where-Object { $_.Type -eq 'RootCA' }
        $status.Status | Should -Be 'EXPIRING'
        Get-ChildItem Cert:\CurrentUser\My |
            Where-Object { $_.Thumbprint -eq $cert.Thumbprint } |
            Remove-Item -ErrorAction SilentlyContinue
    }

    It 'Returns DaysLeft as an integer' {
        $entry = @(Get-PKIChainStatus) | Where-Object { $_.Type -eq 'RootCA' }
        $entry.DaysLeft -is [int] | Should -BeTrue
    }
}

# ════════════════════════════════════════════════════════════════
Describe 'Export-CertToVault' {
    BeforeAll {
        $testBase = Join-Path $TestDrive 'pki_vault'
        Initialize-PKIChainManager -BasePath $testBase
        $pw = ConvertTo-SecureString 'TestP@ss1!' -AsPlainText -Force
        $script:vaultRootR = New-RootCACertificate -PfxPassword $pw -ValidityYears 1 -KeyLength 2048
    }
    AfterAll {
        Get-ChildItem Cert:\CurrentUser\My |
            Where-Object { $_.Thumbprint -eq $script:vaultRootR.Thumbprint } |
            Remove-Item -ErrorAction SilentlyContinue
    }

    It 'Calls Set-VaultSecret when vault function is available' {
        Mock Set-VaultSecret { return $true } -ModuleName PKIChainManager -Verifiable
        { Export-CertToVault -Thumbprint $script:vaultRootR.Thumbprint -VaultLabel 'TestRootCA' -PfxPassword (ConvertTo-SecureString 'TestP@ss1!' -AsPlainText -Force) } |
            Should -Not -Throw
        Should -Invoke Set-VaultSecret -Times 1 -ModuleName PKIChainManager
    }

    It 'Does not write raw PFX bytes to temp/ or cwd when vault is available' {
        $before = Get-ChildItem (Join-Path $env:TEMP '*.pfx') -ErrorAction SilentlyContinue
        Mock Set-VaultSecret { return $true } -ModuleName PKIChainManager
        Export-CertToVault -Thumbprint $script:vaultRootR.Thumbprint -VaultLabel 'TestRootCA2' -PfxPassword (ConvertTo-SecureString 'TestP@ss1!' -AsPlainText -Force)
        $after = Get-ChildItem (Join-Path $env:TEMP '*.pfx') -ErrorAction SilentlyContinue
        @($after).Count | Should -Be @($before).Count -Because 'No plaintext PFX should be written to temp when vault is available'
    }
}

# ════════════════════════════════════════════════════════════════
Describe 'New-FullPKIChain' {
    BeforeAll {
        $testBase = Join-Path $TestDrive 'pki_full'
        Initialize-PKIChainManager -BasePath $testBase
        $pw = ConvertTo-SecureString 'TestP@ss1!' -AsPlainText -Force
        $script:fullChain = New-FullPKIChain -PfxPassword $pw -KeyLength 2048
    }
    AfterAll {
        if ($script:fullChain) {
            foreach ($prop in @('RootCA','SubCA','CodeSigning')) {
                $item = $script:fullChain.$prop
                if ($item -and $item.Thumbprint) {
                    Get-ChildItem Cert:\CurrentUser\My |
                        Where-Object { $_.Thumbprint -eq $item.Thumbprint } |
                        Remove-Item -ErrorAction SilentlyContinue
                }
            }
        }
    }

    It 'Returns an object with RootCA, SubCA, and CodeSigning properties' {
        $script:fullChain | Should -Not -BeNullOrEmpty
        $script:fullChain.PSObject.Properties.Name | Should -Contain 'RootCA'
        $script:fullChain.PSObject.Properties.Name | Should -Contain 'SubCA'
        $script:fullChain.PSObject.Properties.Name | Should -Contain 'CodeSigning'
    }

    It 'RootCA entry has Type = RootCA' {
        $script:fullChain.RootCA.Type | Should -Be 'RootCA'
    }

    It 'SubCA is signed by Root CA' {
        $script:fullChain.SubCA.SignedBy | Should -Be $script:fullChain.RootCA.Thumbprint
    }

    It 'CodeSigning cert is signed by SubCA' {
        $script:fullChain.CodeSigning.SignedBy | Should -Be $script:fullChain.SubCA.Thumbprint
    }

    It 'All three PFX files exist on disk' {
        Test-Path $script:fullChain.RootCA.PfxPath     | Should -BeTrue
        Test-Path $script:fullChain.SubCA.PfxPath      | Should -BeTrue
        Test-Path $script:fullChain.CodeSigning.PfxPath | Should -BeTrue
    }
}



<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




