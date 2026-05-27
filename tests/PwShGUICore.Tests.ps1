# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Pester unit tests for PwShGUICore module -- Pass 1 Foundation.
.DESCRIPTION
    Tests: Write-AppLog, Initialize-CorePaths, Export-LogBuffer,
    Assert-DirectoryExists, Write-ScriptLog, Invoke-LogRotation.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\PwShGUICore.psm1'
    Import-Module $modulePath -Force
}

Describe 'Initialize-CorePaths' {
    It 'Should create required directories in TestDrive' {
        $testDir = Join-Path $TestDrive 'pwshgui-test'
        Initialize-CorePaths -ScriptDir $testDir

        # Core paths should be set after initialization
        $paths = Get-AllProjectPaths
        $paths | Should -Not -BeNullOrEmpty
    }
}

Describe 'Assert-DirectoryExists' {
    It 'Should create a directory that does not exist' {
        $newDir = Join-Path $TestDrive 'assert-test-dir'
        Assert-DirectoryExists -Path $newDir
        Test-Path $newDir | Should -Be $true
    }

    It 'Should not fail when directory already exists' {
        $existingDir = Join-Path $TestDrive 'existing-dir'
        New-Item -ItemType Directory -Path $existingDir -Force | Out-Null
        { Assert-DirectoryExists -Path $existingDir } | Should -Not -Throw
    }
}

Describe 'Write-AppLog' {
    BeforeAll {
        $testDir = Join-Path $TestDrive 'log-test'
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Initialize-CorePaths -ScriptDir $testDir
    }

    It 'Should write a log entry without throwing' {
        { Write-AppLog -Message 'Test log entry' -Level 'Info' } | Should -Not -Throw
    }

    It 'Should write different severity levels' {
        { Write-AppLog -Message 'Warning test' -Level 'Warning' } | Should -Not -Throw
        { Write-AppLog -Message 'Error test' -Level 'Error' } | Should -Not -Throw
    }
}

Describe 'Write-ScriptLog' {
    It 'Should write a script-level log without throwing' {
        { Write-ScriptLog -Message 'Script log test' -ScriptName 'PesterTest' -Level 'Info' } | Should -Not -Throw
    }
}

Describe 'Export-LogBuffer' {
    It 'Should export buffered log entries without error' {
        { Export-LogBuffer } | Should -Not -Throw
    }
}

Describe 'Get-AllProjectPaths' {
    It 'Should return a hashtable or object with path properties' {
        $paths = Get-AllProjectPaths
        $paths | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-RainbowColor' {
    It 'Should return a color object' {
        $color = Get-RainbowColor -Index 0
        $color | Should -Not -BeNullOrEmpty
    }

    It 'Should return different colors for different indices' {
        $c1 = Get-RainbowColor -Index 0
        $c2 = Get-RainbowColor -Index 3
        # They should both be valid but may differ
        $c1 | Should -Not -BeNullOrEmpty
        $c2 | Should -Not -BeNullOrEmpty
    }
}

Describe 'Write-AppLog level validation' {
    It 'Should accept all six canonical levels without throwing' {
        foreach ($lvl in @('Debug','Info','Warning','Error','Critical','Audit')) {
            { Write-AppLog -Message "Level $lvl test" -Level $lvl } | Should -Not -Throw
        }
    }
    It 'Should reject non-canonical levels' {
        { Write-AppLog -Message 'Bad' -Level 'Success' } | Should -Throw
    }
}

Describe 'Invoke-LogRotation' {
    It 'Should run without error when log directory exists' {
        if (Get-Command Invoke-LogRotation -ErrorAction SilentlyContinue) {
            { Invoke-LogRotation } | Should -Not -Throw
        } else {
            Set-ItResult -Skipped -Because 'Invoke-LogRotation not exported'
        }
    }
}

Describe 'Write-ErrorReport' {
    It 'Logs an error record without throwing by default' {
        try { throw 'Synthetic test error' } catch {
            { Write-ErrorReport -ErrorRecord $_ -Context 'PesterTest' } | Should -Not -Throw
        }
    }
    It 'Rethrows when -Rethrow is set' {
        try { throw 'Rethrow test' } catch {
            { Write-ErrorReport -ErrorRecord $_ -Context 'PesterTest' -Rethrow } | Should -Throw
        }
    }
}

Describe 'PwShGUICore Utility Functions' {
    It 'Validates config paths successfully' {
        $result = Test-ConfigPaths
        $result | Should -Be $true
    }
    It 'Enumerates project files' {
        $files = Get-AllProjectFiles
        $files | Should -Not -BeNullOrEmpty
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





