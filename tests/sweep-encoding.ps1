# VersionTag: 2605.B2.V31.7
Import-Module C:\PowerShellGUI\modules\PwShGUI-LegacyEncoding.psm1 -Force -DisableNameChecking
$tgts = @(
    'C:\PowerShellGUI\scripts',
    'C:\PowerShellGUI\sovereign-kernel',
    'C:\PowerShellGUI\agents',
    'C:\PowerShellGUI\tools',
    'C:\PowerShellGUI\UPM'
)
foreach ($t in $tgts) {
    if (-not (Test-Path $t)) { continue }
    $bad = @(Get-ChildItem -Path $t -Recurse -File -Include *.ps1, *.psm1, *.psd1 -ErrorAction SilentlyContinue |
        ForEach-Object { Test-FileEncoding -Path $_.FullName } |
        Where-Object { $_.NeedsFix })
    "$t : $($bad.Count) needs-fix"
    $bad | Select-Object -First 5 | ForEach-Object { "  - $(Split-Path -Leaf $_.Path)" }
}

