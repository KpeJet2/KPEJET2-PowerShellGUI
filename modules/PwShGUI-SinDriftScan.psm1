# VersionTag: 2605.B5.V46.0
# Module: PwShGUI-SinDriftScan
# Purpose: Detect SINs that re-appear in code after their registry status was set to RESOLVED.
# Author: Plan4Me autopilot, iteration 2
# SIN-Notes: ASCII-only to avoid P006/P023; uses @() for Count (P004).

<#
.SYNOPSIS
  Get resolved sin patterns.
#>
function Get-ResolvedSinPatterns {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param([string]$RegistryPath = (Join-Path $PSScriptRoot '..\sin_registry'))
    $resolved = @()
    if (-not (Test-Path $RegistryPath)) { return $resolved }
    Get-ChildItem -Path $RegistryPath -Filter 'SIN-PATTERN-*.json' -File | ForEach-Object {
        try {
            $j = Get-Content -Raw -Encoding UTF8 -Path $_.FullName | ConvertFrom-Json
            $status = $null
            if ($j.PSObject.Properties.Name -contains 'status') { $status = $j.status }
            if ($status -and $status -match 'RESOLVED') {
                $resolved += [PSCustomObject]@{
                    File    = $_.Name
                    Pattern = if ($j.PSObject.Properties.Name -contains 'pattern_id') { $j.pattern_id } else { $_.BaseName }
                    Regex   = if ($j.PSObject.Properties.Name -contains 'detection_regex') { $j.detection_regex } else { $null }
                    Status  = $status
                }
            }
        } catch {
            Write-Verbose "Skip $($_.Name): $_"
        }
    }
    $resolved
}

function Invoke-SinDriftScan {
    <#
    .SYNOPSIS
    Re-scans the workspace for any RESOLVED SIN pattern that has reappeared.
    .DESCRIPTION
    Loads every SIN-PATTERN-*.json with status=RESOLVED, runs its detection_regex
    across a target tree, and returns drift findings (file/line/pattern).
    .EXAMPLE
    Invoke-SinDriftScan -Root C:\PowerShellGUI -OutputPath .\reports\drift.json
    #>
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param(
        [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
        [string]$OutputPath,
        [string[]]$Include = @('*.ps1', '*.psm1'),
        [string[]]$ExcludeDir = @('.git', 'node_modules', '.venv', 'temp')
    )
    $patterns = @(Get-ResolvedSinPatterns)
    if ($patterns.Count -eq 0) {
        Write-Verbose 'No RESOLVED patterns found; nothing to drift-scan.'
        return @()
    }
    $files = Get-ChildItem -Path $Root -Recurse -File -Include $Include -ErrorAction SilentlyContinue |
        Where-Object {
            $full = $_.FullName
            -not ($ExcludeDir | Where-Object { $full -like "*\$_\*" })
        }
    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $content = $null
        try { $content = Get-Content -Raw -Encoding UTF8 -Path $f.FullName } catch { continue }
        if (-not $content) { continue }
        foreach ($p in $patterns) {
            if (-not $p.Regex) { continue }
            try {
                $rx = [regex]::new($p.Regex, 'IgnoreCase,Multiline')
                foreach ($m in $rx.Matches($content)) {
                    $line = ([regex]::Matches($content.Substring(0, $m.Index), "`n")).Count + 1
                    $findings.Add([PSCustomObject]@{
                        Pattern = $p.Pattern
                        File    = $f.FullName
                        Line    = $line
                        Match   = ($m.Value -replace '\s+', ' ').Substring(0, [Math]::Min(120, $m.Length))
                    })
                }
            } catch {
                Write-Verbose "Bad regex for $($p.Pattern): $_"
            }
        }
    }
    $result = $findings.ToArray()
    if ($OutputPath) {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $result | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputPath -Encoding UTF8
    }
    $result
}

Export-ModuleMember -Function Get-ResolvedSinPatterns, Invoke-SinDriftScan

