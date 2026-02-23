# VersionTag: 2604.B2.V31.0
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 9 entries)
<#
.SYNOPSIS
Script-CCC - User Management

.DESCRIPTION
This script performs user management tasks.
#>

Write-Information "================================" -InformationAction Continue
Write-Information "Script-CCC: CCC EXAMPLE SCRIPT" -InformationAction Continue
Write-Information "================================" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "Execution Details:" -InformationAction Continue
Write-Information "  Computer: $env:COMPUTERNAME" -InformationAction Continue
Write-Information "  User: $env:USERNAME" -InformationAction Continue
Write-Information "  PowerShell Version: $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" -InformationAction Continue
Write-Information "  Execution Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "Managing user accounts and permissions..." -InformationAction Continue

Write-Information "  [OK] TASK 1 - CCC EXAMPLE SCRIPT" -InformationAction Continue

Write-Information "  [OK] TASK 2 - CCC EXAMPLE SCRIPT" -InformationAction Continue

Write-Information "  [OK] TASK 3 - CCC EXAMPLE SCRIPT" -InformationAction Continue

Write-Information "  [OK] TASK 4 - CCC EXAMPLE SCRIPT" -InformationAction Continue

Write-Information "  [OK] TASK 5 - CCC EXAMPLE SCRIPT" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "User management completed successfully!" -InformationAction Continue
Write-Information "" -InformationAction Continue
# A
# Write-Host "Press any key to proceed... or you can just wait 5 seconds."
# $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
###
#B
# Write-Host "Press any key to proceed... or you can just wait 5 seconds."
#timeout /t 10
###
#C
# https://www.sharepointdiary.com/2023/03/pause-powershell-with-press-any-key-to-continue.html
function Wait-KeyOrTimeout {
    param([int]$Seconds = 5)
     
    $endTime = (Get-Date).AddSeconds($Seconds)
    Write-Information "Press any key to continue or wait $Seconds seconds..." -InformationAction Continue
     
    while ((Get-Date) -lt $endTime) {
        if ([Console]::KeyAvailable) {
            [Console]::ReadKey($true) | Out-Null
            return
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Information "Timeout reached, continuing..." -InformationAction Continue
}
 
Write-Information "CCC completed." -InformationAction Continue
Wait-KeyOrTimeout -Seconds 5
Write-Information "Script-C execution finished." -InformationAction Continue



















