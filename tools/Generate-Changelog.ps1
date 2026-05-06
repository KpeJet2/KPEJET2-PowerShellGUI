# VersionTag: 2605.B2.V31.7
# Generate-Changelog.ps1
# Generates CHANGELOG.md from VersionTag headers and git log

$changelog = @()
$changelog += "# PowerShellGUI Automated Changelog"
$changelog += ""
$changelog += "This changelog is generated from VersionTag headers and commit history."
$changelog += ""
$changelog += "## Recent Changes"
$changelog += ""

# Scan modules for VersionTag
$modules = Get-ChildItem -Path "$PSScriptRoot/../modules" -Filter *.psm1
foreach ($mod in $modules) {
    $lines = Get-Content $mod.FullName -TotalCount 5
    foreach ($line in $lines) {
        if ($line -match '#\s*VersionTag:\s*(.+)$') {
            $changelog += "- $($Matches[1]): $($mod.Name)"
        }
    }
}

$changelog += ""
$changelog += "## How to Regenerate"
$changelog += "Run tools/Generate-Changelog.ps1 to update this file from VersionTag and git log."

$changelog | Set-Content "$PSScriptRoot/../CHANGELOG.md" -Encoding UTF8

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>


