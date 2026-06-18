# VersionTag: 2606.B5.V51.4
$targets = @(
    'C:\PowerShellGUI\modules\CronAiAthon-Scheduler.psm1',
    'C:\PowerShellGUI\modules\UserProfileManager.psd1'
)
foreach ($t in $targets) {
    $b = [System.IO.File]::ReadAllBytes($t)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        Write-Host "$t : already has BOM"
    } else {
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        [System.IO.File]::WriteAllBytes($t, $bom + $b)
        Write-Host "$t : BOM added"
    }
}



