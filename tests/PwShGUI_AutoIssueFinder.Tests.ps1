# VersionTag: 2607.B6.V53.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS  PwShGUI_AutoIssueFinder module Pester tests.
.DESCRIPTION
    Tests for PwShGUI_AutoIssueFinder.psm1: automated issue detection,
    pattern scanning, and issue reporting.
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\PwShGUI_AutoIssueFinder.psm1'
    Import-Module $modulePath -Force
}

Describe 'PwShGUI_AutoIssueFinder Module' {
    It 'Imports successfully' {
        Get-Module 'PwShGUI_AutoIssueFinder' | Should -Not -BeNullOrEmpty
    }
    It 'Exports 1 function' {
        $exports = (Get-Module 'PwShGUI_AutoIssueFinder').ExportedFunctions.Keys
        $exports.Count | Should -Be 1
    }
}

Describe 'Invoke-PwShGUIAutoIssueFinder' {
    It 'Returns scan results without error' {
        $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ("AIF-" + [Guid]::NewGuid().ToString('N'))
        $tmpScan = Join-Path ([System.IO.Path]::GetTempPath()) ("AIFScan-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpScan -Force | Out-Null
        try {
            { Invoke-PwShGUIAutoIssueFinder -Paths @($tmpScan) -OutputRoot $tmpOut -IncludeSubfolders } | Should -Not -Throw
        } finally {
            Remove-Item -LiteralPath $tmpScan -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        }
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







