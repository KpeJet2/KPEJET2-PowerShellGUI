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
#Requires -Modules AzureAD

<#
    .SYNOPSIS
        Connect to Azure Active Directory and gets a list of users
    
    .DESCRIPTION  

    .NOTES
        This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
        The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
        The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
        the use and the consequences of the use of this freely available script.
        PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
        © ScriptRunner Software GmbH

    .COMPONENT       
        Azure Active Directory Powershell Module
        Azure Target

    .LINK
        https://github.com/scriptrunner/ActionPacks/tree/master/O365/AzureAD/Query
#>

param(    
)
 
try{
    $result = Get-AzureADUser -All $true  | `
        Select-Object DisplayName, ObjectId -Unique | `
        Sort-Object -Property Displayname
    
    foreach($itm in  ($result | Sort-Object CurrencyName)){
        if($SRXEnv) {            
            $null = $SRXEnv.ResultList.Add($itm.ObjectID) # Value
            $null = $SRXEnv.ResultList2.Add($itm.Displayname) # DisplayValue            
        }
        else{
            Write-Output $itm.DisplayName 
        }
    }
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


