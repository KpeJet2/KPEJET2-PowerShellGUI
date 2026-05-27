# VersionTag: 2605.B5.V46.0
# Module: PwShGUI-SinFixBranch
# Purpose: Auto-create a checkpoint and mark a SIN as IN_PROGRESS when starting a fix.

function New-SinFixBranch {
    <#
    .SYNOPSIS
    Open a fix workflow for a SIN: snapshot affected files + flip status to IN_PROGRESS.
    .DESCRIPTION
    Copies the SIN's referenced files to checkpoints/<sin-id>-<timestamp>/,
    and updates the SIN registry JSON status to IN_PROGRESS with a started_at
    timestamp. Use -WhatIf to preview.
    .EXAMPLE
    New-SinFixBranch -PatternId P027 -Files .\modules\PwShGUI-Foo.psm1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$PatternId,
        [string[]]$Files = @(),
        [string]$RegistryPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'sin_registry'),
        [string]$CheckpointsPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'checkpoints')
    )
    $registryFile = Get-ChildItem -Path $RegistryPath -Filter "SIN-PATTERN-$PatternId*.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $registryFile) { throw "No SIN registry file matches pattern '$PatternId' under $RegistryPath" }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $branchDir = Join-Path $CheckpointsPath ("$PatternId-$stamp")
    if ($PSCmdlet.ShouldProcess($branchDir, 'create checkpoint dir')) {
        New-Item -ItemType Directory -Path $branchDir -Force | Out-Null
    }
    foreach ($f in $Files) {
        if (-not (Test-Path $f)) { continue }
        $dest = Join-Path $branchDir (Split-Path -Leaf $f)
        if ($PSCmdlet.ShouldProcess($f, "copy -> $dest")) {
            Copy-Item -Path $f -Destination $dest -Force
        }
    }
    if ($PSCmdlet.ShouldProcess($registryFile.FullName, 'mark IN_PROGRESS')) {
        $j = Get-Content -Raw -Encoding UTF8 -Path $registryFile.FullName | ConvertFrom-Json
        if (-not ($j.PSObject.Properties.Name -contains 'status')) {
            $j | Add-Member -NotePropertyName status -NotePropertyValue 'IN_PROGRESS'
        } else { $j.status = 'IN_PROGRESS' }
        if (-not ($j.PSObject.Properties.Name -contains 'started_at')) {
            $j | Add-Member -NotePropertyName started_at -NotePropertyValue (Get-Date).ToString('s')
        } else { $j.started_at = (Get-Date).ToString('s') }
        $json = $j | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($registryFile.FullName, $json, (New-Object System.Text.UTF8Encoding($true)))
    }
    [PSCustomObject]@{ PatternId = $PatternId; Branch = $branchDir; Registry = $registryFile.FullName; Status = 'IN_PROGRESS' }
}

Export-ModuleMember -Function New-SinFixBranch

