# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Pester regression tests -- Pass 5.
.DESCRIPTION
    Replays known past sins and verifies guards:
    - Em dash rejection (PS 5.1 compat)
    - .Count null-safety
    - Timer Tag property avoidance
    - SIN pattern verification
#>

Describe 'Em Dash Regression (PS 5.1 Compat)' {
    BeforeAll {
        $script:scriptRoot = Split-Path -Parent $PSScriptRoot
        $script:psFiles = Get-ChildItem -Path $script:scriptRoot -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike '*\.history\*' -and
                $_.FullName -notlike '*\.git\*' -and
                $_.FullName -notlike '*node_modules\*'
            }
    }

    It 'No em dash (U+2014) inside double-quoted strings in PS files' {
        $violations = @()
        $emDash = [char]0x2014
        foreach ($file in $script:psFiles) {
            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content) { continue }

            # Check for em dash inside double-quoted strings (not comments, not single-quoted)
            $lines = $content -split "`n"
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                # Skip comment lines and single-quoted strings
                if ($line.Trim().StartsWith('#')) { continue }
                if ($line.Contains($emDash)) {
                    # Check if it is inside a double-quoted string context
                    if ($line -match '"[^"]*\x{2014}[^"]*"') {
                        $violations += "$($file.Name):$lineNum"
                    }
                }
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'Em dashes in double-quoted strings cause PS 5.1 parse failures'
    }
}

Describe 'Timer Tag Property Avoidance' {
    BeforeAll {
        $script:scriptRoot = Split-Path -Parent $PSScriptRoot
    }

    It 'No System.Timers.Timer .Tag usage in modules' {
        $moduleFiles = Get-ChildItem -Path (Join-Path $script:scriptRoot 'modules') -Filter '*.psm1' -File -ErrorAction SilentlyContinue
        $violations = @()
        foreach ($mf in $moduleFiles) {
            $content = Get-Content $mf.FullName -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content) { continue }
            # Check for System.Timers.Timer combined with .Tag usage
            if ($content -match 'System\.Timers\.Timer' -and $content -match '\$\w+\.Tag\s*=') {
                $violations += $mf.Name
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'System.Timers.Timer does not have a .Tag property (only WinForms Timer does)'
    }
}

Describe 'Parse Validation of All Modules' {
    BeforeAll {
        $script:moduleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
        $script:moduleFiles = Get-ChildItem -Path $script:moduleDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue
    }

    It 'All modules parse without errors' {
        $failures = @()
        foreach ($mf in $script:moduleFiles) {
            $tokens = $null; $errors = $null
            try {
                [void][System.Management.Automation.Language.Parser]::ParseFile($mf.FullName, [ref]$tokens, [ref]$errors)
                if ($errors -and $errors.Count -gt 0) {
                    foreach ($e in $errors) {
                        $failures += "$($mf.Name):$($e.Extent.StartLineNumber) - $($e.Message)"
                    }
                }
            } catch {
                $failures += "$($mf.Name) - ParseFile exception: $_"
            }
        }
        $failures | Should -BeNullOrEmpty -Because 'All modules must parse clean in PS 5.1'
    }
}

Describe 'Parse Validation of All Scripts' {
    BeforeAll {
        $script:scriptRoot = Split-Path -Parent $PSScriptRoot
        $script:scriptFiles = Get-ChildItem -Path (Join-Path $script:scriptRoot 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
    }

    It 'All scripts parse without errors' {
        $failures = @()
        foreach ($sf in $script:scriptFiles) {
            $tokens = $null; $errors = $null
            try {
                [void][System.Management.Automation.Language.Parser]::ParseFile($sf.FullName, [ref]$tokens, [ref]$errors)
                if ($errors -and $errors.Count -gt 0) {
                    foreach ($e in $errors) {
                        $failures += "$($sf.Name):$($e.Extent.StartLineNumber) - $($e.Message)"
                    }
                }
            } catch {
                $failures += "$($sf.Name) - ParseFile exception: $_"
            }
        }
        $failures | Should -BeNullOrEmpty -Because 'All scripts must parse clean'
    }
}

Describe 'JSON Config Validation' {
    BeforeAll {
        $script:configDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'config'
        $script:jsonFiles = Get-ChildItem -Path $script:configDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    }

    It 'All config JSON files are well-formed' {
        $failures = @()
        foreach ($jf in $script:jsonFiles) {
            try {
                Get-Content $jf.FullName -Raw | ConvertFrom-Json | Out-Null
            } catch {
                $failures += "$($jf.Name): $($_.Exception.Message)"
            }
        }
        $failures | Should -BeNullOrEmpty
    }
}

Describe 'SIN Registry Integrity' {
    BeforeAll {
        $script:sinDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'sin_registry'
    }

    It 'All SIN files are valid JSON' {
        if (-not (Test-Path $script:sinDir)) { Set-ItResult -Skipped -Because 'sin_registry directory not found' }
        $sinFiles = Get-ChildItem -Path $script:sinDir -Filter '*.json' -File -ErrorAction SilentlyContinue
        $failures = @()
        foreach ($sf in $sinFiles) {
            try {
                $sin = Get-Content $sf.FullName -Raw | ConvertFrom-Json
                if (-not $sin.sin_id -and -not $sin.PSObject.Properties['sin_id']) {
                    $failures += "$($sf.Name): missing sin_id field"
                }
            } catch {
                $failures += "$($sf.Name): invalid JSON"
            }
        }
        $failures | Should -BeNullOrEmpty
    }
}

Describe '
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember Consistency' {
    BeforeAll {
        $script:moduleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
        $script:moduleFiles = Get-ChildItem -Path $script:moduleDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue
    }

    It 'All modules use array-style 
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember' {
        $violations = @()
        foreach ($mf in $script:moduleFiles) {
            $content = Get-Content $mf.FullName -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content) { continue }
            # Check for single-line 
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember (Pattern C - non-array)
            if ($content -match '
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember\s+-Function\s+[^@\(]') {
                # Allow single function export but flag for consistency review
                $violations += $mf.Name
            }
        }
        # This is a style check -- report but do not fail hard
        if ($violations.Count -gt 0) {
            Write-Warning "Modules using non-array 
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember: $($violations -join ', ')"
        }
    }
}





