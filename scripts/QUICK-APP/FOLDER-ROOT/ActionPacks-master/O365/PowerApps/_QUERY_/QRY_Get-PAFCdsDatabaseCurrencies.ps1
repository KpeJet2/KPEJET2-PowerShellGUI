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
#Requires -Modules Microsoft.PowerApps.Administration.PowerShell

<#
.SYNOPSIS
    Returns all currencies

.DESCRIPTION

.NOTES
    This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
    The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
    The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
    the use and the consequences of the use of this freely available script.
    PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
    © ScriptRunner Software GmbH

.COMPONENT
    Requires Module Microsoft.PowerApps.Administration.PowerShell
    Requires Library script PAFLibrary.ps1

.LINK
    https://github.com/scriptrunner/ActionPacks/tree/master/O365/PowerApps/_QUERY_
 
.Parameter PACredential
    Provides the user ID and password for PowerApps credentials

.Parameter LocationName
    The location of the current environment
#>

[CmdLetBinding()]
Param(
    [Parameter(Mandatory = $true)]   
    [pscredential]$PACredential,
    [Parameter(Mandatory = $true)]   
    [string]$LocationName
)

Import-Module Microsoft.PowerApps.Administration.PowerShell

$VerbosePreference = "SilentlyContinue"
try{
    ConnectPowerApps -PAFCredential $PACredential    

    [hashtable]$getArgs = @{'ErrorAction' = 'Stop'
                            'LocationName' = $LocationName
                            } 

    $result = Get-AdminPowerAppCdsDatabaseCurrencies @getArgs | Select-Object CurrencyCode,CurrencyName
    foreach($itm in  ($result | Sort-Object CurrencyName)){
        if($SRXEnv) {            
            $null = $SRXEnv.ResultList.Add($itm.CurrencyCode) # Value
            $null = $SRXEnv.ResultList2.Add($itm.CurrencyName) # DisplayValue            
        }
        else{
            Write-Output $itm.CurrencyName 
        }
    }
}
catch{
    throw
}
finally{
    DisconnectPowerApps
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


