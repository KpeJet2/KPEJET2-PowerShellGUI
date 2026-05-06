<#
# VersionTag: 2605.B2.V31.7
# SupportPS5.1: YES(As of: 2026-04-30)
# SupportsPS7.6: YES(As of: 2026-04-30)
.SYNOPSIS
    PwShGUI-BreakingChange - Detect API breaks between two module snapshots.
.DESCRIPTION
    Compares exported function names and parameter signatures between
    two paths (e.g. checkpoint folders) and emits a JSON diff plus
    severity tag (BREAKING / ADDITIVE / NONE).
#>
#Requires -Version 5.1

$script:ModuleVersion = '2604.B3.V28.0'

function Get-ModuleSurface {
    param([string]$Path)
    $modules = @(Get-ChildItem -Path $Path -Recurse -Filter *.psm1 -File -ErrorAction SilentlyContinue)
    $surface = @{}
    foreach ($m in $modules) {
        try {
            $tokens = $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($m.FullName, [ref]$tokens, [ref]$errors)
            $funcs = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
            foreach ($fn in $funcs) {
                $params = @()
                if ($fn.Body -and $fn.Body.ParamBlock -and $fn.Body.ParamBlock.Parameters) {
                    foreach ($p in $fn.Body.ParamBlock.Parameters) {
                        $params += [PSCustomObject]@{
                            Name = $p.Name.VariablePath.UserPath
                            Type = if ($p.StaticType) { $p.StaticType.Name } else { 'object' }
                            Mandatory = ($p.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } |
                                ForEach-Object { $_.NamedArguments } |
                                Where-Object { $_.ArgumentName -eq 'Mandatory' }).Count -gt 0
                        }
                    }
                }
                $key = "$($m.BaseName)::$($fn.Name)"
                $surface[$key] = [PSCustomObject]@{
                    Module = $m.BaseName
                    Function = $fn.Name
                    Parameters = @($params)
                }
            }
        } catch {
            Write-Verbose "Parse failed: $($m.FullName) -- $_"
        }
    }
    return $surface
}

function Invoke-BreakingChangeDetector {
    <#
    .SYNOPSIS  Compare two module trees and report API drift.
    .PARAMETER BaselinePath  Older snapshot
    .PARAMETER CurrentPath   Newer snapshot
        .DESCRIPTION
      Detailed behaviour: Invoke breaking change detector.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$BaselinePath,
        [Parameter(Mandatory)][string]$CurrentPath,
        [string]$OutputDir
    )
    if (-not $OutputDir) { $OutputDir = Join-Path (Get-Location).Path '~REPORTS' }
    if (-not (Test-Path $OutputDir)) {
        if ($PSCmdlet.ShouldProcess($OutputDir, 'Create')) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
    }

    $base = Get-ModuleSurface -Path $BaselinePath
    $curr = Get-ModuleSurface -Path $CurrentPath

    $removed = @($base.Keys | Where-Object { -not $curr.ContainsKey($_) })
    $added   = @($curr.Keys | Where-Object { -not $base.ContainsKey($_) })
    $changed = New-Object System.Collections.Generic.List[object]

    foreach ($k in @($base.Keys | Where-Object { $curr.ContainsKey($_) })) {
        $b = $base[$k]; $c = $curr[$k]
        $bParams = @($b.Parameters) | ForEach-Object { "$($_.Name):$($_.Type):$($_.Mandatory)" }
        $cParams = @($c.Parameters) | ForEach-Object { "$($_.Name):$($_.Type):$($_.Mandatory)" }
        $diff = @(Compare-Object -ReferenceObject $bParams -DifferenceObject $cParams -ErrorAction SilentlyContinue)
        if ($diff.Count -gt 0) {
            $changed.Add([PSCustomObject]@{
                Function = $k
                Removed  = @($diff | Where-Object { $_.SideIndicator -eq '<=' } | ForEach-Object { $_.InputObject })
                Added    = @($diff | Where-Object { $_.SideIndicator -eq '=>' } | ForEach-Object { $_.InputObject })
            }) | Out-Null
        }
    }

    $verdict = if (@($removed).Count -gt 0 -or @($changed).Count -gt 0) { 'BREAKING' }
               elseif (@($added).Count -gt 0) { 'ADDITIVE' }
               else { 'NONE' }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
    $out = Join-Path $OutputDir ("breaking-change-{0}.json" -f $stamp)
    $report = [ordered]@{
        generated = (Get-Date).ToUniversalTime().ToString('o')
        baseline  = $BaselinePath
        current   = $CurrentPath
        verdict   = $verdict
        removed   = $removed
        added     = $added
        changed   = @($changed)
    }
    if ($PSCmdlet.ShouldProcess($out, 'Write report')) {
        $report | ConvertTo-Json -Depth 6 | Set-Content -Path $out -Encoding UTF8
    }
    [PSCustomObject]@{
        OutputPath = $out
        Verdict    = $verdict
        Removed    = @($removed).Count
        Added      = @($added).Count
        Changed    = @($changed).Count
    }
}

Export-ModuleMember -Function Invoke-BreakingChangeDetector, Get-ModuleSurface

