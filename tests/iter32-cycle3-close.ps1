# VersionTag: 2605.B5.V46.0
# cycle 3 close: smoke import all modules + PSSA tally
$ws = 'C:\PowerShellGUI'
$modules = Get-ChildItem -Path "$ws\modules" -Filter '*.psm1' | Where-Object {
    $_.FullName -notmatch '\\ActionPacks-master\\|\\QUICK-APP\\'
}
$ok = 0; $bad = 0; $errs = @()
foreach ($m in $modules) {
    try {
        Import-Module $m.FullName -Force -DisableNameChecking -ErrorAction Stop
        $ok++
    } catch { $bad++; $errs += "$($m.Name): $($_.Exception.Message)" }
}
Write-Host ("Smoke ($((Get-Host).Version)): " + $ok + '/' + ($ok+$bad) + ' OK')
if ($bad -gt 0) { $errs | ForEach-Object { Write-Host "  $_" } }

$pssa = Invoke-ScriptAnalyzer -Path "$ws\modules" -Recurse
$total = @($pssa).Count
Write-Host "PSSA total (modules): $total"
$pssa | Group-Object RuleName | Sort-Object Count -Descending | Select-Object -First 12 | Format-Table Count, Name -AutoSize

