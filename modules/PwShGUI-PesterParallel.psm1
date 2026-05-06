# VersionTag: 2605.B2.V31.7
# Module: PwShGUI-PesterParallel
# Purpose: Run Pester suites in parallel under PS7+ with per-module isolation.

function Invoke-PesterParallel {
    <#
    .SYNOPSIS
    Run Pester test files in parallel (PS7+) and return aggregated results.
    .DESCRIPTION
    On PS7+ uses ForEach-Object -Parallel; on PS5.1 falls back to a serial run.
    Each test file runs in its own session so module state is isolated.
    Requires Pester 5.x to be installed.
    .EXAMPLE
    Invoke-PesterParallel -Path .\tests -ThrottleLimit 4
    #>
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'tests'),
        [int]$ThrottleLimit = 4,
        [string]$OutputPath
    )
    $files = @(Get-ChildItem -Path $Path -Recurse -File -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue)
    if (@($files).Count -eq 0) { Write-Warning "No *.Tests.ps1 found under $Path"; return @() }
    $isPS7 = ($PSVersionTable.PSVersion.Major -ge 7)
    $results = $null
    if ($isPS7) {
        $results = $files | ForEach-Object -Parallel {
            try {
                Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
                $cfg = New-PesterConfiguration
                $cfg.Run.Path = $_.FullName
                $cfg.Run.PassThru = $true
                $cfg.Output.Verbosity = 'None'
                $r = Invoke-Pester -Configuration $cfg
                [PSCustomObject]@{
                    File = $_.FullName
                    Passed = $r.PassedCount
                    Failed = $r.FailedCount
                    Skipped = $r.SkippedCount
                    Duration = $r.Duration.TotalSeconds
                }
            } catch {
                [PSCustomObject]@{ File = $_.FullName; Passed = 0; Failed = -1; Skipped = 0; Duration = 0; Error = "$_" }
            }
        } -ThrottleLimit $ThrottleLimit
    } else {
        $results = foreach ($f in $files) {
            try {
                Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
                $cfg = New-PesterConfiguration
                $cfg.Run.Path = $f.FullName
                $cfg.Run.PassThru = $true
                $cfg.Output.Verbosity = 'None'
                $r = Invoke-Pester -Configuration $cfg
                [PSCustomObject]@{ File = $f.FullName; Passed = $r.PassedCount; Failed = $r.FailedCount; Skipped = $r.SkippedCount; Duration = $r.Duration.TotalSeconds }
            } catch {
                [PSCustomObject]@{ File = $f.FullName; Passed = 0; Failed = -1; Skipped = 0; Duration = 0; Error = "$_" }
            }
        }
    }
    $arr = @($results)
    if ($OutputPath) {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $arr | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputPath -Encoding UTF8
    }
    $arr
}

Export-ModuleMember -Function Invoke-PesterParallel

