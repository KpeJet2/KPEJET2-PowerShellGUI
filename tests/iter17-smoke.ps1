# VersionTag: 2605.B5.V46.0
# iter17 smoke: import every module on both engines, count successes/failures
$root = 'C:\PowerShellGUI\modules'
$mods = Get-ChildItem -Path $root -Filter '*.psm1' -File
$ok = 0; $fail = 0; $failures = @()
foreach ($m in $mods) {
    try {
        Import-Module $m.FullName -Force -DisableNameChecking -ErrorAction Stop
        $ok++
    } catch {
        $fail++
        $failures += [PSCustomObject]@{ Module = $m.Name; Error = $_.Exception.Message }
    }
}
Write-Host ("Engine: " + $PSVersionTable.PSVersion)
Write-Host ("Imports OK: " + $ok)
Write-Host ("Imports FAIL: " + $fail)
if ($fail -gt 0) { $failures | Format-Table -AutoSize }

