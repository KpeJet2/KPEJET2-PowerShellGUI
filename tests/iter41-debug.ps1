# VersionTag: 2605.B2.V31.7
try {
    & 'C:\PowerShellGUI\tests\iter41-scoreboard-data-gen.ps1'
} catch {
    Write-Host "ERR: $($_.Exception.Message)"
    Write-Host "AT:  $($_.InvocationInfo.PositionMessage)"
    Write-Host "STK: $($_.ScriptStackTrace)"
}

