# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS  SyntaxGuard - Automated syntax validation for all project PowerShell files.
.DESCRIPTION
    Parses every .ps1 and .psm1 file in the project using the PowerShell AST parser.
    Detects parse errors, PS 5.1 incompatible operators, file size anomalies, and
    duplicate content patterns (e.g. VersionTag injection corruption).
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:ProjectRoot = Split-Path $PSScriptRoot -Parent
    $script:ExcludeDirs  = @('.history', 'node_modules', '~REPORTS', 'temp', '__pycache__', '.git')
    $script:ExcludeFiles = @('PS-CheatSheet-EXAMPLES-V2.ps1')
    $script:SelfName     = 'SyntaxGuard.Tests.ps1'

    function Get-ProjectPSFiles {
        Get-ChildItem $script:ProjectRoot -Include '*.ps1','*.psm1' -Recurse |
            Where-Object {
                $rel = $_.FullName.Substring($script:ProjectRoot.Length + 1)
                $skip = $false
                foreach ($d in $script:ExcludeDirs) { if ($rel.StartsWith("$d\") -or $rel.StartsWith("$d/")) { $skip = $true; break } }
                if ($_.Name -in $script:ExcludeFiles) { $skip = $true }
                -not $skip
            }
    }
}

Describe 'SyntaxGuard - Parse Validation' {
    It 'All .ps1/.psm1 files parse without errors' {
        $failures = @()
        foreach ($file in (Get-ProjectPSFiles)) {
            try {
                $errors = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile(
                    $file.FullName, [ref]$null, [ref]$errors
                )
                if ($errors.Count -gt 0) {
                    $failures += "$($file.Name) L$($errors[0].Extent.StartLineNumber): $($errors[0].Message)"
                }
            } catch {
                $failures += "$($file.Name): PARSER CRASH - $($_.Exception.Message)"
            }
        }
        $failures | Should -BeNullOrEmpty -Because "all project files must parse cleanly"
    }
}

Describe 'SyntaxGuard - PS 5.1 Compatibility' {
    It 'No null-coalescing operator in .ps1/.psm1 files' {
        $hits = @()
        foreach ($file in (Get-ProjectPSFiles)) {
            if ($file.Name -eq $script:SelfName) { continue }
            $lines = [System.IO.File]::ReadAllLines($file.FullName)
            for ($i = 0; $i -lt $lines.Length; $i++) {
                $line = $lines[$i]
                if ($line -match '^\s*#') { continue }
                # Match ?? not preceded by ? (ternary) and not in strings
                if ($line -match '(?<!\?)\?\?(?!\?)') {
                    $hits += "$($file.Name):$($i+1)"
                }
            }
        }
        $hits | Should -BeNullOrEmpty -Because "PS 5.1 does not support null-coalescing operator"
    }

    It 'No null-conditional operator in .ps1/.psm1 files' {
        $hits = @()
        foreach ($file in (Get-ProjectPSFiles)) {
            if ($file.Name -eq $script:SelfName) { continue }
            $lines = [System.IO.File]::ReadAllLines($file.FullName)
            for ($i = 0; $i -lt $lines.Length; $i++) {
                if ($lines[$i] -match '^\s*#') { continue }
                if ($lines[$i] -match '\?\.\w') {
                    $hits += "$($file.Name):$($i+1)"
                }
            }
        }
        $hits | Should -BeNullOrEmpty -Because "PS 5.1 does not support null-conditional operator"
    }
}

Describe 'SyntaxGuard - File Integrity' {
    It 'Main-GUI.ps1 does not exceed 500KB (corruption guard)' {
        $mainGui = Join-Path $script:ProjectRoot 'Main-GUI.ps1'
        if (Test-Path $mainGui) {
            $size = (Get-Item $mainGui).Length
            $size | Should -BeLessOrEqual 512000 -Because "Main-GUI.ps1 over 500KB indicates corruption (normal ~370KB)"
        }
    }

    It 'Main-GUI.ps1 has exactly one VersionTag header' {
        $mainGui = Join-Path $script:ProjectRoot 'Main-GUI.ps1'
        if (Test-Path $mainGui) {
            $lines = [System.IO.File]::ReadAllLines($mainGui)
            $tagCount = ($lines | Where-Object { $_ -match '^\s*#\s*VersionTag:\s*\d' }).Count
            $tagCount | Should -Be 1 -Because "duplicate VersionTag headers indicate file duplication"
        }
    }

    It 'Main-GUI.ps1 has no duplicate function definitions' {
        $mainGui = Join-Path $script:ProjectRoot 'Main-GUI.ps1'
        if (Test-Path $mainGui) {
            $lines = [System.IO.File]::ReadAllLines($mainGui)
            $funcs = @{}
            $dupes = @()
            for ($i = 0; $i -lt $lines.Length; $i++) {
                if ($lines[$i] -match '^function\s+(\S+)') {
                    $name = $Matches[1]
                    if ($funcs.ContainsKey($name)) {
                        $dupes += "'$name' at lines $($funcs[$name]+1) and $($i+1)"
                    } else { $funcs[$name] = $i }
                }
            }
            $dupes | Should -BeNullOrEmpty -Because "duplicate functions indicate content duplication"
        }
    }

    It 'Main-GUI.ps1 line count is under 10000' {
        $mainGui = Join-Path $script:ProjectRoot 'Main-GUI.ps1'
        if (Test-Path $mainGui) {
            $lc = [System.IO.File]::ReadAllLines($mainGui).Length
            $lc | Should -BeLessOrEqual 10000 -Because "line counts over 10K indicate file duplication"
        }
    }
}

Describe 'SyntaxGuard - Style Compliance' {
    It 'No empty catch blocks in module files' {
        $hits = @()
        foreach ($file in (Get-ProjectPSFiles | Where-Object Extension -eq '.psm1')) {
            $lines = [System.IO.File]::ReadAllLines($file.FullName)
            for ($i = 0; $i -lt $lines.Length; $i++) {
                if ($lines[$i] -match 'catch\s*\{\s*\}') {
                    $hits += "$($file.Name):$($i+1)"
                }
                elseif ($lines[$i] -match 'catch\s*\{\s*$' -and ($i + 1) -lt $lines.Length -and $lines[$i+1].Trim() -match '^\}$') {
                    $hits += "$($file.Name):$($i+1)"
                }
            }
        }
        # Threshold: track regression -- current baseline is known
        $hits.Count | Should -BeLessOrEqual 127 -Because "empty catch blocks should decrease over time, not increase"
    }

    It 'No SilentlyContinue on Import-Module in module files' {
        $hits = @()
        foreach ($file in (Get-ProjectPSFiles | Where-Object Extension -eq '.psm1')) {
            $lines = [System.IO.File]::ReadAllLines($file.FullName)
            for ($i = 0; $i -lt $lines.Length; $i++) {
                if ($lines[$i] -match '^\s*#') { continue }
                if ($lines[$i] -match 'Import-Module\s+.*-ErrorAction\s+SilentlyContinue') {
                    $hits += "$($file.Name):$($i+1)"
                }
            }
        }
        $hits.Count | Should -BeLessOrEqual 15 -Because "silent Import-Module should decrease over time, not increase"
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




