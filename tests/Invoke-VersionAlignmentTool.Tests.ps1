# VersionTag: 2608.B1.V54.1
# SupportPS5.1: YES
# SupportsPS7.6: YES
#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:Tool = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Invoke-VersionAlignmentTool.ps1'
    $script:Source = Get-Content -LiteralPath $script:Tool -Raw -Encoding UTF8
}

Describe 'release letter and zero rules' {
    It 'accepts alpha/beta and human single-zero forms' {
        $script:Source | Should -Match '\(\[A-Za-z\]\)\(\\d\+\)'
        $script:Source | Should -Match "return \"\$letter`0\""
        $script:Source | Should -Match 'releaseLetter'
        $script:Source | Should -Match 'releaseNumber'
    }

    It 'reserves triple zero for C/D security tokens' {
        $script:Source | Should -Match "\$letter -notin @\('C','D'\)"
        $script:Source | Should -Match 'reservedZeroClass'
        $script:Source | Should -Match 'A00'
    }

    It 'orders release letter before release number' {
        $script:Source | Should -Match 'Parsed.releaseLetter'
        $script:Source | Should -Match 'Parsed.releaseNumber'
    }
}