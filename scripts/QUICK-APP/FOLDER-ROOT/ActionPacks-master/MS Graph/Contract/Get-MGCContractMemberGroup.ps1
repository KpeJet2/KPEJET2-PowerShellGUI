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
#requires -Modules Microsoft.Graph.Identity.DirectoryManagement

<#
    .SYNOPSIS
        Returns groups of contract
    
    .DESCRIPTION          

    .NOTES
        This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
        The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
        The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
        the use and the consequences of the use of this freely available script.
        PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
        © ScriptRunner Software GmbH

    .COMPONENT
        Requires Library script MS Graph\_LIB_\MGLibrary
        Requires Modules Microsoft.Graph.Identity.DirectoryManagement

    .LINK
        https://github.com/scriptrunner/ActionPacks/tree/master/MS%20Graph/Contracts

    .Parameter ContractId
        [sr-en] Identifier of the contact
        [sr-de] Kontakt-ID

    .Parameter SecurityEnabledOnly
        [sr-en] Member must be a user or service principal
        [sr-de] Mitglied muss ein Benutzer oder Service principal sein
#>

param( 
    [Parameter(Mandatory = $true)]
    [string]$ContractId,
    [switch]$SecurityEnabledOnly
)          

Import-Module Microsoft.Graph.Identity.DirectoryManagement

try{
   [hashtable]$cmdArgs = @{ErrorAction = 'Stop'
                        'ContractId' = $ContactId
                        'SecurityEnabledOnly' = $SecurityEnabledOnly.IsPresent
    }
    $result = Get-MgContractMemberGroup @cmdArgs
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


