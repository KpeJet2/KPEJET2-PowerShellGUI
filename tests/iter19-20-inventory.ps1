# VersionTag: 2605.B2.V31.7
# iter19+20: drift scan + low-volume rule inventory
try { Import-Module 'C:\PowerShellGUI\modules\PwShGUI-SinDriftScan.psm1' -Force -ErrorAction Stop } catch { Write-Warning "iter19-20: SinDriftScan import failed: $_" }
$drift = Invoke-SinDriftScan -SinRegistry 'C:\PowerShellGUI\sin_registry' -ScanRoot 'C:\PowerShellGUI\modules' -ErrorAction SilentlyContinue
Write-Host ("Drift findings: " + @($drift).Count)
$drift | Select-Object -First 5 Pattern, Path, Line | Format-Table -AutoSize

Write-Host "`n=== Low-volume rule inventory ==="
$rules = @('PSReviewUnusedParameter','PSUseDeclaredVarsMoreThanAssignments','PSAvoidUsingPositionalParameters','PSUseToExportFieldsInManifest','PSUseSingularNouns')
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule $rules
$f | Group-Object RuleName | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize
$f | Select-Object RuleName, ScriptName, Line, Message | Sort-Object RuleName, ScriptName, Line | Format-Table -AutoSize | Out-File 'C:\PowerShellGUI\reports\iter17\iter20-low-volume.txt' -Encoding UTF8
Write-Host "Written: reports/iter17/iter20-low-volume.txt"

