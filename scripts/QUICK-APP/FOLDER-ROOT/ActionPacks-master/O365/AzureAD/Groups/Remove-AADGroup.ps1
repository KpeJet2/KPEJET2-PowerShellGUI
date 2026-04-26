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
        Connect to Azure Active Directory and removes the group

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

    .LINK
        https://github.com/scriptrunner/ActionPacks/tree/master/O365/AzureAD/Groups

    .Parameter GroupObjectId
        [sr-en] Unique ID of the group to remove

    .Parameter GroupName
        [sr-en] Display name of the group to remove
#>

param(
    [Parameter(Mandatory = $true,ParameterSetName = "Group object id")]
    [guid]$GroupObjectId,
    [Parameter(Mandatory = $true,ParameterSetName = "Group name")]
    [string]$GroupName
)

try{ 
    if($PSCmdlet.ParameterSetName  -eq "Group object id"){
        $Script:Grp = Get-AzureADGroup -ObjectId $GroupObjectId
    }
    else{
        $Script:Grp = Get-AzureADGroup -All $true | Where-Object {$_.Displayname -eq $GroupName} 
    }
    if($null -ne $Script:Grp){
        $null = Remove-AzureADGroup -ObjectId $Script:Grp.ObjectId 
        if($SRXEnv) {
            $SRXEnv.ResultMessage = "Group $($Script:Grp.DisplayName) removed"
        } 
        else{
            Write-Output "Group $($Script:Grp.DisplayName) removed"
        }
    }
    else {
        if($SRXEnv) {
            $SRXEnv.ResultMessage = "Group not found"
        } 
        Throw "Group not found"
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


