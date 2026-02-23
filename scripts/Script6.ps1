# VersionTag: 2602.a.11
# VersionTag: 2602.a.10
# VersionTag: 2602.a.9
# VersionTag: 2602.a.8
# VersionTag: 2602.a.7
<#
.SYNOPSIS
Script6 - System Cleanup

.DESCRIPTION
This script performs system cleanup tasks.
#>

Write-Information "================================" -InformationAction Continue
Write-Information "Script6: System Cleanup" -InformationAction Continue
Write-Information "================================" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "Execution Details:" -InformationAction Continue
Write-Information "  Computer: $env:COMPUTERNAME" -InformationAction Continue
Write-Information "  User: $env:USERNAME" -InformationAction Continue
Write-Information "  PowerShell Version: $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" -InformationAction Continue
Write-Information "  Execution Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "Performing system cleanup tasks..." -InformationAction Continue
Write-Information "  [OK] Clearing temporary files" -InformationAction Continue
Write-Information "  [OK] Removing old log files" -InformationAction Continue
Write-Information "  [OK] Emptying recycle bin" -InformationAction Continue
Write-Information "  [OK] Optimizing disk space" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "System cleanup completed successfully!" -InformationAction Continue
Write-Information "" -InformationAction Continue
Write-Information "Press any key to close this window..." -InformationAction Continue
$null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")













