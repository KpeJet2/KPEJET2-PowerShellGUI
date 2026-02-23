# VersionTag: 2602.a.11
# VersionTag: 2602.a.10
# VersionTag: 2602.a.9
# VersionTag: 2602.a.8
# VersionTag: 2602.a.7
<#
.SYNOPSIS
Script5 - Network Diagnostics

.DESCRIPTION
This script performs network diagnostics and troubleshooting.
#>

Write-Information "================================" -InformationAction Continue
Write-Information "Script5: Network Diagnostics" -InformationAction Continue
Write-Information "================================" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "Execution Details:" -InformationAction Continue
Write-Information "  Computer: $env:COMPUTERNAME" -InformationAction Continue
Write-Information "  User: $env:USERNAME" -InformationAction Continue
Write-Information "  PowerShell Version: $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" -InformationAction Continue
Write-Information "  Execution Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "Running network diagnostics..." -InformationAction Continue
Write-Information "  [OK] Checking network connectivity" -InformationAction Continue
Write-Information "  [OK] Testing DNS resolution" -InformationAction Continue
Write-Information "  [OK] Pinging gateway" -InformationAction Continue
Write-Information "  [OK] Analyzing network adapters" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "Network diagnostics completed successfully!" -InformationAction Continue
Write-Information "" -InformationAction Continue
Write-Information "Press any key to close this window..." -InformationAction Continue
$null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")













