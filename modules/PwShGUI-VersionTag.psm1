function Get-VersionTag {
    <#
    .SYNOPSIS  Extracts the VersionTag from a file or returns a canonical tag.
    .PARAMETER Path  Path to the file to scan for VersionTag (optional).
    .PARAMETER Default  Default VersionTag to return if not found (optional).
    .EXAMPLE
        Get-VersionTag -Path 'modules/PwShGUICore.psm1'
        Get-VersionTag -Default '2604.B2.V31.0'
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Default = '0000.B0.V0.0'
    )
    if ($Path -and (Test-Path $Path)) {
        $head = Get-Content -Path $Path -TotalCount 5
        foreach ($line in $head) {
            if ($line -match '#\s*VersionTag:\s*(.+)$') {
                return $Matches[1].Trim()
            }
        }
    }
    return $Default
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
Export-ModuleMember -Function Get-VersionTag

