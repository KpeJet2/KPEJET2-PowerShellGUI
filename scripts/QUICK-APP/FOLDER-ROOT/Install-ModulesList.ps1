# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-29 00:00  audit-007 added VersionTag

<#
.SYNOPSIS
    Update your PowerShell modules in bulk by specifiying an explicit list to install & keep up to date
    Requires 'PowerShellGet'
.DESCRIPTION
    Add this module to your $profile to run when required:
    Import-Module "path/to/module/updateMods"
.NOTES
    Author: Sadik Tekin
.PARAMETER clean
    Removes old versions keeping only the latest
.EXAMPLE
    updateMods -clean
#>

function updateMods {
    [CmdletBinding()]
    Param( [switch][Parameter(Mandatory = $false)] $clean )

    if ($PSVersionTable.PSVersion.Major -lt 7) { throw "Please use PowerShell >= 7.0" }

    Import-Module PowerShellGet

    # Add/Remove required modules from this list
    @(
        "Az"
        "Az.*"
        "AzureAD"
        "Microsoft.Graph"
        "AzAPICall"
        "SQLServer"
        "GuestConfiguration"
        "PSDscResources"
        "PSDesiredStateConfiguration"
        "AuditPolicyDsc"
        "SecurityPolicyDsc"
        "xWebAdministration"
        "nx"
        "Certificate-LifecycleMonitor"					
        "Admin-MorningBrief"					
        "Admin-UserLookup"					
        "AsBuiltReport.System.Resources"					
        "AdminTools"					
        "AD-UserLifecycle"					
        "AD-SecurityAudit"								
        "Claude"		
        "Create-Cert"					
        "CertMigrator"				
        "EC2Remote"					
        "EnvVarManager"					
        "FS255.BitWarden"								
        "Infra-LivingDoc"					
        "Infra-ChangeTracker"					
        "Infra-HealthDashboard"					
        "ITSM-Insights"					
        "InformationTechnologyOperations"				
        "InstallAppOnRemoteComputer"					
        "InstallMSIPackageOnRemoteServer"		
        "InstallPSModules"							
        "LocalRepoManager"					
        "LatencyDiag"					
        "MSP365 Authentication"					
        "NetAccounts"				
        "PowershellFunctions007"
        "PSRemoteOperations"					
        "PetName"					
        "PSScriptModule"					
        "PSUnplugged"					
        "PSWatchdog"					
        "PsBundler"					
        "Portal"					
        "PSModulePublisher"					
        "PSSYSAdm"					
        "PS-SysInfo"					
        "PsSysPassAPI"					
        "PSSystemDiagnostics"					
        "Powershell-QrCodeGenerator"					
		"Quser.Crescendo"					
        "RelativeWorkspaceManager-Advanced"						
        "spec.envvar.management"					
        "spec.function.setup"					
        "spec.microsoft.authentication"					
        "spec.module.creator"					
        "spec.module.setup"					
        "SolarWinds.ServiceDesk"					
        "SmartLogAnalyzer"					
		"ScriptWhitelistGuard"					
        "SetDefaultEnv"					
        "Template-PSModule"					
        "Toolchain"					
        "TLSleuth"										
        "Update-DellComputersRemotely"					
        "WinPath-Clean"					
        "Win11ToWin10UI"					
        "WinPath-Clean"					
        "WinPower"					
        "WinProfileOps"				
        "YaugerAIO"				
    ).ForEach({
            try {
                Find-Module -Name $_ -Verbose | ForEach-Object {
                    $installedVersion = (Get-InstalledModule -Name $_.Name -ErrorAction SilentlyContinue).Version
                    if (!($installedVersion)) {
                        Write-Host '🟢 Installing New Module' $_.Name $_.Version -ForegroundColor Green
                    }
                    elseif ($installedVersion -lt $_.Version) {
                        Write-Host '🔷 Updating' $_.Name $installedVersion '->' $_.Version -ForegroundColor Blue
                    }
                    $command = @{
                        Name            = $_.Name
                        RequiredVersion = $_.Version
                        Scope           = 'AllUsers'
                        Force           = $true
                        AcceptLicense   = $true
                        Confirm         = $false
                        Verbose         = $true
                    }
                    Install-Module @command

                    if ($clean) {
                        $modpath = "$(($env:PSModulePath).Split(';')[0])/$($_.Name)"
                        $latest = (Get-ChildItem -Path $modpath | Sort-Object LastWriteTime | Select-Object -Last 1)
                        Get-ChildItem -Path $modpath -Exclude $latest.BaseName | ForEach-Object {
                            Write-Host "🔴 Removing Older Version $($_.FullName)..." -ForegroundColor DarkRed
                            Remove-Item $_.FullName -Recurse -Force
                        }
                    }
                }
            }
            catch { Write-Host "🥵 Could not install module: $_" -ForegroundColor Red }
        })
}

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





