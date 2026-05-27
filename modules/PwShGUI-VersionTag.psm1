# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-28
# SupportsPS7.6TestedDate: 2026-04-28
# FileRole: Module

function Get-VersionTag {
    <#
    .SYNOPSIS  Extracts the VersionTag from a file or returns a canonical tag.
    .PARAMETER Path  Path to the file to scan for VersionTag (optional).
    .PARAMETER Default  Default VersionTag to return if not found (optional).
    .EXAMPLE
        Get-VersionTag -Path 'modules/PwShGUICore.psm1'
        Get-VersionTag -Default '2604.B2.V31.0'
        .DESCRIPTION
      Detailed behaviour: Get version tag.
    #>
    [OutputType([System.String])]
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Default = '0000.B0.V0.0'
    )
    if ($Path -and (Test-Path $Path)) {
        $head = Get-Content -Path $Path -TotalCount 5
        foreach ($line in $head) {
            if ($line -match '#\s*VersionTag:\s*([\d]+\.B\d+\.[Vv][\d\.]+)') {
                return $Matches[1].Trim()
            }
        }
    }
    return $Default
}


<# Outline:
    Single-function module that parses the canonical `# VersionTag: YYMM.B<build>.V<major>.<minor>`
    header from .ps1/.psm1/.psd1 files (scanning the first 5 lines) and returns the matched
    string, or a caller-supplied default when no header is present. Used by the build/version
    pipeline (Sync-VersionStandards, Show-VersionTagBanner) to track per-file revisions.
#>

<# Problems:
    None outstanding. Regex tolerates lower/upper-case `V` and multi-segment minor (`V31.0.2`)
    but does not yet validate that segments are numerically monotonic across builds.
#>

<# ToDo:
    None — Get-VersionTag is feature-complete for current pipeline needs. Future enhancements
    (cross-file monotonicity validation) are tracked separately under FEATURE-REQUEST entries.
#>
Export-ModuleMember -Function Get-VersionTag



