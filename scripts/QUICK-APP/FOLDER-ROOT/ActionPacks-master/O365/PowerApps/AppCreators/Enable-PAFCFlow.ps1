# VersionTag: 2602.a.11
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionTag: 2602.a.10
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionTag: 2602.a.9
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionTag: 2602.a.8
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionTag: 2602.a.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.0
#Requires -Modules Microsoft.PowerApps.PowerShell

<#
.SYNOPSIS
    Enable/disable the specific flow

.DESCRIPTION

.NOTES
    This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
    The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
    The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
    the use and the consequences of the use of this freely available script.
    PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
    © ScriptRunner Software GmbH

.COMPONENT
    Requires Module Microsoft.PowerApps.PowerShell
    Requires Library script PAFLibrary.ps1

.LINK
    https://github.com/scriptrunner/ActionPacks/tree/master/O365/PowerApps/AppCreators
 
.Parameter PACredential
    Provides the user ID and password for PowerApps credentials

.Parameter FlowName
    FlowName identifier (not display name)

.Parameter EnvironmentName
    Used to specify the environment of the Flow

.Parameter Enable
    Enable or disable the specific flow

.Parameter ApiVersion
    The api version to call with
#>

[CmdLetBinding()]
Param(
    [Parameter(Mandatory = $true)]   
    [pscredential]$PACredential,
    [Parameter(Mandatory = $true)]
    [string]$FlowName,
    [Parameter(Mandatory = $true)]
    [bool]$Enable,
    [string]$EnvironmentName,
    [string]$ApiVersion
)

Import-Module Microsoft.PowerApps.PowerShell

try{
    ConnectPowerApps4Creators -PAFCredential $PACredential
    
    [string[]]$Properties = @('DisplayName','FlowName','Enabled','EnvironmentName','LastModifiedTime') 
    [hashtable]$cmdArgs = @{'ErrorAction' = 'Stop'
                            'FlowName' = $FlowName 
                            }  
                            
    if($PSBoundParameters.ContainsKey('EnvironmentName')){
        $cmdArgs.Add('EnvironmentName',$EnvironmentName)
    }
    if($PSBoundParameters.ContainsKey('ApiVersion')){
        $cmdArgs.Add('ApiVersion',$ApiVersion)
    }

    if($Enable -eq $true){
        Enable-Flow @cmdArgs
    }
    else{
        Disable-Flow @cmdArgs
    }   

    $result = Get-Flow @cmdArgs | Select-Object $Properties
    
    if($SRXEnv) {
        $SRXEnv.ResultMessage = $result
    }
    else{
        Write-Output $result
    }
}
catch{
    throw
}
finally{
    DisconnectPowerApps4Creators
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


