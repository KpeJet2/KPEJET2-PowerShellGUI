# VersionTag: 2605.B2.V31.7
# Module: PwShGUI-CheckpointPrune
# Purpose: Apply a retention policy to checkpoints/ to bound disk usage.

function Invoke-CheckpointPrune {
    <#
    .SYNOPSIS
    Prune the checkpoints/ folder to a configurable retention policy.
    .DESCRIPTION
    Keeps the newest -KeepLast N items (files or first-level folders),
    plus anything newer than -KeepDays days. Older items move to a
    .pruned/ subfolder unless -Delete is specified. Use -WhatIf to preview.
    .EXAMPLE
    Invoke-CheckpointPrune -KeepLast 30 -KeepDays 14 -WhatIf
    #>
    [OutputType([System.Object[]])]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Path = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'checkpoints'),
        [int]$KeepLast = 30,
        [int]$KeepDays = 14,
        [switch]$Delete
    )
    if (-not (Test-Path $Path)) { Write-Verbose "No checkpoints folder at $Path"; return @() }
    $items = @(Get-ChildItem -Path $Path -Force | Where-Object { $_.Name -ne '.pruned' } |
        Sort-Object LastWriteTime -Descending)
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    $keep = New-Object System.Collections.Generic.HashSet[string]
    for ($i = 0; $i -lt [Math]::Min($KeepLast, $items.Count); $i++) { [void]$keep.Add($items[$i].FullName) }
    foreach ($it in $items) { if ($it.LastWriteTime -gt $cutoff) { [void]$keep.Add($it.FullName) } }
    $pruneDir = Join-Path $Path '.pruned'
    if (-not $Delete -and -not (Test-Path $pruneDir)) {
        if ($PSCmdlet.ShouldProcess($pruneDir, 'mkdir')) { New-Item -ItemType Directory -Path $pruneDir -Force | Out-Null }
    }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($it in $items) {
        if ($keep.Contains($it.FullName)) { continue }
        $action = if ($Delete) { 'DELETE' } else { 'MOVE' }
        if ($PSCmdlet.ShouldProcess($it.FullName, $action)) {
            try {
                if ($Delete) {
                    Remove-Item -Path $it.FullName -Recurse -Force -ErrorAction Stop
                } else {
                    Move-Item -Path $it.FullName -Destination (Join-Path $pruneDir $it.Name) -Force -ErrorAction Stop
                }
                $results.Add([PSCustomObject]@{ Item = $it.Name; Action = $action; Modified = $it.LastWriteTime })
            } catch {
                Write-Warning "Prune failed on $($it.Name): $_"
            }
        } else {
            $results.Add([PSCustomObject]@{ Item = $it.Name; Action = "WHATIF:$action"; Modified = $it.LastWriteTime })
        }
    }
    $results.ToArray()
}

Export-ModuleMember -Function Invoke-CheckpointPrune

