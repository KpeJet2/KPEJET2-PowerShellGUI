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

<#
.SYNOPSIS
    Set Credential Security Support Provider (CredSSP) authentication

.DESCRIPTION

.NOTES
    This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
    The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
    The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
    the use and the consequences of the use of this freely available script.
    PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
    © ScriptRunner Software GmbH

.COMPONENT

.LINK
    https://github.com/scriptrunner/ActionPacks/tree/master/WinSystemManagement/System

.Parameter EnableCredSSP
    [sr-en] Enable or disable Credential Security Support Provider (CredSSP) authentication 

.Parameter Role
    [sr-en] Disable CredSSP as a client or as a server

.Parameter DelegateComputer 
    [sr-en] Servers to which client credentials are delegated
#>

[CmdLetBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Server','Client')]
    [string]$Role,
    [bool]$EnableCredSSP,
    [string]$DelegateComputer
)

try{
    if($EnableCredSSP -eq $true){
        [hashtable]$cmdArgs = @{'ErrorAction' = 'Stop'
                                'Role' = $Role
                                'Force' = $true
                                }  
        if([System.String]::IsNullOrWhiteSpace($DelegateComputer) -eq $false){
            $cmdArgs.Add('DelegateComputer',$DelegateComputer)
        }
        $null = Enable-WSManCredSSP @cmdArgs
    }
    else{
        $null = Disable-WSManCredSSP -Role $Role -ErrorAction Stop
    }
    
    if($SRXEnv) {
        $SRXEnv.ResultMessage = "CredSSP enabled is $($EnableCredSSP.ToString())"
    }
    else{
        Write-Output "CredSSP enabled is $($EnableCredSSP.ToString())"
    }
}
catch{
    throw
}
finally{
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


