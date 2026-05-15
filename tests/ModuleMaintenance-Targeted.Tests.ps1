# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-28
# SupportsPS7.6TestedDate: 2026-04-28
# FileRole: Test
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Set-StrictMode -Version Latest
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:TargetTag = '2604.B3.V33.0'

    $script:Targets = @(
        'scripts/Validate-ModuleImports.ps1',
        'scripts/Publish-WorkspaceModules.ps1',
        'scripts/Build-AgenticManifest.ps1',
        'modules/PwShGUI-VersionTag.psm1',
        'modules/PwShGUI-HistoryZip.psm1',
        'modules/Import-WorkspaceModule.psm1',
        'scripts/Script-F - LinkToConfigJson.ps1',
        'scripts/Set-WorkspaceModulePath.ps1',
        'scripts/Setup-ModuleEnvironment.ps1'
    )

    function Get-VersionFromLine {
        param([string]$line)
        if ($line -match '(?:VersionTag:\s*)?(\d{4})\.B(\d+)\.V(\d+)\.(\d+)') {
            return [PSCustomObject]@{
                Raw   = $Matches[0]
                YYMM  = [int]$Matches[1]
                Build = [int]$Matches[2]
                Major = [int]$Matches[3]
                Minor = [int]$Matches[4]
            }
        }
        return $null
    }

    function Compare-VersionTag {
        param([string]$a, [string]$b)
        $va = Get-VersionFromLine -line $a
        $vb = Get-VersionFromLine -line $b
        if ($null -eq $va -or $null -eq $vb) { return -2 }
        foreach ($k in @('YYMM','Build','Major','Minor')) {
            if ($va.$k -gt $vb.$k) { return 1 }
            if ($va.$k -lt $vb.$k) { return -1 }
        }
        return 0
    }
}

Describe 'Targeted Maintenance - Tag and Parse' {
    It 'All target files exist' {
        $missing = @()
        foreach ($rel in $script:Targets) {
            $path = Join-Path $script:Root $rel
            if (-not (Test-Path $path)) { $missing += $rel }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'All target files have VersionTag at or above 2604.B3.V33.0' {
        $bad = @()
        foreach ($rel in $script:Targets) {
            $path = Join-Path $script:Root $rel
            $head = Get-Content -Path $path -TotalCount 20
            $tagLine = $head | Where-Object { $_ -match 'VersionTag:\s*\d{4}\.B\d+\.V\d+\.\d+' } | Select-Object -First 1
            if (-not $tagLine) {
                $bad += "$rel missing VersionTag"
                continue
            }
            if ((Compare-VersionTag -a $tagLine -b $script:TargetTag) -lt 0) {
                $bad += "$rel has lower tag: $tagLine"
            }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'All target scripts/modules parse cleanly' {
        $errs = @()
        foreach ($rel in $script:Targets) {
            $path = Join-Path $script:Root $rel
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
            if (@($parseErrors).Count -gt 0) {
                $errs += "$rel parse errors: $(@($parseErrors).Count)"
            }
        }
        $errs | Should -BeNullOrEmpty
    }
}

Describe 'Targeted Maintenance - Packaging' {
    It 'Target modules have module manifests' {
        $mods = @(
            'modules/PwShGUI-VersionTag.psd1',
            'modules/PwShGUI-HistoryZip.psd1',
            'modules/Import-WorkspaceModule.psd1'
        )
        $missing = @()
        foreach ($m in $mods) {
            if (-not (Test-Path (Join-Path $script:Root $m))) { $missing += $m }
        }
        $missing | Should -BeNullOrEmpty
    }
}

<# Outline:
    Targeted maintenance compliance tests for requested scripts/modules.
#>

<# Problems:
    None.
#>

<# ToDo:
    Extend to assert explicit pipeline step registration map.
#>


