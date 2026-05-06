<#
# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-29 00:00  audit-007 added VersionTag
.SYNOPSIS
    Bulk imports multiple PowerShell modules with validation.
.DESCRIPTION
    Reads a list of module names (hardcoded or from a file) and imports them.
    Skips modules that are already loaded and reports missing modules.
#>

# List of modules to import (you can also load from a file)
$ModulesToImport = @(
 'Az'
        'Az.*'
        'AzureAD'
        'Microsoft.Graph'
        'AzAPICall'
        'SQLServer'
        'GuestConfiguration'
        'PSDscResources'
        'PSDesiredStateConfiguration'
        'AuditPolicyDsc'
        'SecurityPolicyDsc'
        'xWebAdministration'
        'nx'
        'Certificate-LifecycleMonitor'					
        'Admin-MorningBrief'					
        'Admin-UserLookup'					
        'AsBuiltReport.System.Resources'					
        'AdminTools'					
        'AD-UserLifecycle'					
        'AD-SecurityAudit'								
        'Claude'		
        'Create-Cert'					
        'CertMigrator'				
        'EC2Remote'					
        'EnvVarManager'					
        'FS255.BitWarden'								
        'Infra-LivingDoc'					
        'Infra-ChangeTracker'					
        'Infra-HealthDashboard'					
        'ITSM-Insights'					
        'InformationTechnologyOperations'				
        'InstallAppOnRemoteComputer'					
        'InstallMSIPackageOnRemoteServer'		
        'InstallPSModules'							
        'LocalRepoManager'					
        'LatencyDiag'					
        'MSP365 Authentication'					
        'NetAccounts'				
        'PowershellFunctions007'
        'PSRemoteOperations'					
        'PetName'					
        'PSScriptModule'					
        'PSUnplugged'					
        'PSWatchdog'					
        'PsBundler'					
        'Portal'					
        'PSModulePublisher'					
        'PSSYSAdm'					
        'PS-SysInfo'					
        'PsSysPassAPI'					
        'PSSystemDiagnostics'					
        'Powershell-QrCodeGenerator'					
		'Quser.Crescendo'					
        'RelativeWorkspaceManager-Advanced'						
        'spec.envvar.management'					
        'spec.function.setup'					
        'spec.microsoft.authentication'					
        'spec.module.creator'					
        'spec.module.setup'					
        'SolarWinds.ServiceDesk'					
        'SmartLogAnalyzer'					
		'ScriptWhitelistGuard'					
        'SetDefaultEnv'					
        'Template-PSModule'					
        'Toolchain'					
        'TLSleuth'										
        'Update-DellComputersRemotely'					
        'WinPath-Clean'					
        'Win11ToWin10UI'					
        'WinPath-Clean'					
        'WinPower'					
        'WinProfileOps'				
        'YaugerAIO'
)

foreach ($Module in $ModulesToImport) {
    try {
        # Check if module is already loaded
        if (Get-Package -Name $Module -ListAvailable) {
            if (-not (Get-Module -Name $Module)) {
                Install-Module -Name $Module -ErrorAction Stop
                Write-Host "✅ Imported module: $Module" -ForegroundColor Green
            }
            else {
                Write-Host "ℹ Module already loaded: $Module" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "❌ Module not found: $Module" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "⚠ Failed to import module: $Module. Error: $_" -ForegroundColor Red
    }
}

$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$ModulesToImport = Get-Content -Path (Join-Path $WorkspaceRoot 'config\APP-INSTALL-TEMPLATES\modules2.txt')

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





