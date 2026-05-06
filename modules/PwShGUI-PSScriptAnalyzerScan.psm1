<#
# VersionTag: 2605.B2.V31.7
# SupportPS5.1: YES(As of: 2026-04-30)
# SupportsPS7.6: YES(As of: 2026-04-30)
.SYNOPSIS
    Invoke-PSScriptAnalyzerScan - Optional PSSA wrapper for SyntaxGuard.
.DESCRIPTION
    Runs PSScriptAnalyzer if available; produces JSON + SARIF-lite output
    that can be merged into SyntaxGuard reports. Soft-fails when PSSA is
    not installed (returns a stub object with Available=$false).
#>
#Requires -Version 5.1

$script:ModuleVersion = '2604.B3.V28.0'

function Invoke-PSScriptAnalyzerScan {
    <#
    .SYNOPSIS  Run PSScriptAnalyzer over a path and emit normalized JSON.
    .PARAMETER Path  File or directory.
    .PARAMETER Severity  Minimum severity to report (default Warning).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Severity = 'Warning',
        [string]$OutputDir,
        [string[]]$ExcludeRule
    )

    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        return [PSCustomObject]@{
            Available = $false
            Message   = 'PSScriptAnalyzer not installed. Install with: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force'
            Findings  = @()
        }
    }
    Import-Module PSScriptAnalyzer -ErrorAction Stop

    if (-not $OutputDir) { $OutputDir = Join-Path (Get-Location).Path '~REPORTS' }
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

    $params = @{
        Path     = $Path
        Severity = $Severity
        Recurse  = $true
    }
    if ($ExcludeRule) { $params['ExcludeRule'] = $ExcludeRule }

    $raw = @(Invoke-ScriptAnalyzer @params)

    $findings = foreach ($r in $raw) {
        [PSCustomObject]@{
            File     = $r.ScriptPath
            Line     = $r.Line
            Column   = $r.Column
            RuleName = $r.RuleName
            Severity = $r.Severity.ToString()
            Message  = $r.Message
        }
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
    $jsonPath = Join-Path $OutputDir ("pssa-{0}.json" -f $stamp)
    @{
        generated = (Get-Date).ToUniversalTime().ToString('o')
        path      = $Path
        count     = @($findings).Count
        findings  = @($findings)
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8

    [PSCustomObject]@{
        Available = $true
        OutputPath = $jsonPath
        Count     = @($findings).Count
        Findings  = @($findings)
    }
}

Export-ModuleMember -Function Invoke-PSScriptAnalyzerScan

