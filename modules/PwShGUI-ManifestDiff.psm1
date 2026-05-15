# VersionTag: 2605.B5.V46.0
# Module: PwShGUI-ManifestDiff
# Purpose: Detect silent metadata drift between .psd1 manifest snapshots.

<#
.SYNOPSIS
  Get manifest snapshot.
#>
function Get-ManifestSnapshot {
    [CmdletBinding()]
    param([string]$ModulesPath = (Join-Path $PSScriptRoot '..'))
    $snap = @{}
    Get-ChildItem -Path $ModulesPath -Recurse -Filter '*.psd1' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $data = $null
        try { $data = Import-PowerShellDataFile -Path $_.FullName -ErrorAction Stop } catch { return }
        if (-not $data) { return }
        $snap[$_.BaseName] = [PSCustomObject]@{
            File           = $_.FullName
            ModuleVersion  = $data['ModuleVersion']
            Guid           = $data['GUID']
            Author         = $data['Author']
            FunctionsToExport = @($data['FunctionsToExport'])
            CmdletsToExport   = @($data['CmdletsToExport'])
            RequiredModules   = @($data['RequiredModules'])
        }
    }
    [PSCustomObject]@{ TakenAt = (Get-Date).ToString('s'); Modules = $snap }
}

function Compare-ModuleManifest {
    <#
    .SYNOPSIS
    Diff two manifest snapshots and surface drift.
    .DESCRIPTION
    Compares ModuleVersion, GUID, Author, exported functions/cmdlets, and
    required modules across two snapshot objects (or two snapshot file paths).
    .EXAMPLE
    Compare-ModuleManifest -Old .\snap-old.json -New .\snap-new.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Old,
        [Parameter(Mandatory)] $New
    )
    if ($Old -is [string]) { $Old = Get-Content -Raw -Encoding UTF8 $Old | ConvertFrom-Json }
    if ($New -is [string]) { $New = Get-Content -Raw -Encoding UTF8 $New | ConvertFrom-Json }
    $oldNames = @($Old.Modules.PSObject.Properties.Name)
    $newNames = @($New.Modules.PSObject.Properties.Name)
    $diffs = New-Object System.Collections.Generic.List[object]
    foreach ($n in ($oldNames + $newNames | Select-Object -Unique)) {
        $o = $Old.Modules.$n
        $w = $New.Modules.$n
        if (-not $o) { $diffs.Add([PSCustomObject]@{ Module = $n; Change = 'ADDED' }); continue }
        if (-not $w) { $diffs.Add([PSCustomObject]@{ Module = $n; Change = 'REMOVED' }); continue }
        foreach ($prop in 'ModuleVersion', 'Guid', 'Author') {
            if (("$($o.$prop)") -ne ("$($w.$prop)")) {
                $diffs.Add([PSCustomObject]@{ Module = $n; Change = "PROP:$prop"; Old = $o.$prop; New = $w.$prop })
            }
        }
        foreach ($listProp in 'FunctionsToExport', 'CmdletsToExport', 'RequiredModules') {
            $oldSet = @($o.$listProp) | Where-Object { $_ }
            $newSet = @($w.$listProp) | Where-Object { $_ }
            $added   = @($newSet | Where-Object { $oldSet -notcontains $_ })
            $removed = @($oldSet | Where-Object { $newSet -notcontains $_ })
            if (@($added).Count -gt 0)   { $diffs.Add([PSCustomObject]@{ Module = $n; Change = "$listProp+"; Items = $added }) }
            if (@($removed).Count -gt 0) { $diffs.Add([PSCustomObject]@{ Module = $n; Change = "$listProp-"; Items = $removed }) }
        }
    }
    $diffs.ToArray()
}

Export-ModuleMember -Function Get-ManifestSnapshot, Compare-ModuleManifest

