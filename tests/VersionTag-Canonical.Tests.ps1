# VersionTag: 2605.B2.V31.7
# SupportPS5.1: yes
# SupportsPS7.6: yes
<#
.SYNOPSIS  Regression guard for the canonical VersionTag format.
.DESCRIPTION
    Asserts that:
      1. config/system-variables.xml exposes all five Version sub-elements.
      2. The composed VersionTag matches the canonical regex
         ^\d{4}\.B\d+\.V\d+\.\d+$  (e.g. 2604.B2.V31.6).
      3. Main-GUI.ps1 Get-VersionString still emits an uppercase 'V' literal,
         catching accidental lowercase regressions.
    Reference: user memory P007 / DOC-ICON-STANDARD.md.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot
    $script:ConfigPath    = Join-Path $script:WorkspaceRoot 'config\system-variables.xml'
    $script:MainGuiPath   = Join-Path $script:WorkspaceRoot 'Main-GUI.ps1'
    $script:CanonicalRegex = '^\d{4}\.B\d+\.V\d+\.\d+$'
}

Describe 'VersionTag canonical format' {
    It 'config/system-variables.xml exists' {
        Test-Path -LiteralPath $script:ConfigPath | Should -BeTrue
    }

    It 'Version element has Major, Minor, Build, VMajor, VMinor' {
        [xml]$xml = Get-Content -LiteralPath $script:ConfigPath -Raw
        $v = $xml.SystemVariables.Version
        $v                        | Should -Not -BeNullOrEmpty
        $v.Major                  | Should -Match '^\d{4}$'
        $v.Minor                  | Should -Match '^B\d+$'
        $v.Build                  | Should -Match '^\d+$'
        $v.VMajor                 | Should -Match '^\d+$'
        $v.VMinor                 | Should -Match '^\d+$'
    }

    It 'Composed VersionTag matches canonical regex' {
        [xml]$xml = Get-Content -LiteralPath $script:ConfigPath -Raw
        $v = $xml.SystemVariables.Version
        $tag = "{0}.{1}.V{2}.{3}" -f $v.Major, $v.Minor, $v.VMajor, $v.VMinor
        $tag | Should -Match $script:CanonicalRegex
    }

    It 'Main-GUI.ps1 Get-VersionString uses uppercase V literal' {
        Test-Path -LiteralPath $script:MainGuiPath | Should -BeTrue
        $content = Get-Content -LiteralPath $script:MainGuiPath -Raw
        # Grab the Get-VersionString function body (small).
        $match = [regex]::Match($content, 'function\s+Get-VersionString\s*\{[\s\S]*?\n\}')
        $match.Success | Should -BeTrue -Because 'Get-VersionString must exist in Main-GUI.ps1'
        # Case-sensitive checks (Should -Match is case-insensitive in Pester 5).
        ($match.Value -cmatch '\.V\$\(') | Should -BeTrue  -Because 'Format must keep uppercase V before VMajor'
        ($match.Value -cmatch '\.v\$\(') | Should -BeFalse -Because 'Lowercase v in version string is a P007 regression'
    }
}

