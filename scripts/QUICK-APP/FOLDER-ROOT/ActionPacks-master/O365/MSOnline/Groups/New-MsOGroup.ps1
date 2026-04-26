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
#Requires -Modules MSOnline

<#
    .SYNOPSIS
        Connect to MS Online and adds a new group to the Azure Active Directory

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
        https://github.com/scriptrunner/ActionPacks/tree/master/O365/MSOnline/Groups

    .Parameter GroupName
        [sr-en] Display name of the group

    .Parameter Description
        [sr-en] Description of the group
    
    .Parameter TenantId
        [sr-en] Unique ID of the tenant on which to perform the operation
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$GroupName,
    [string]$Description,
    [guid]$TenantId
)

try{
    $Script:Grp = New-MsolGroup -DisplayName $GroupName -Description $Description -TenantId $TenantId | Select-Object *
    if($null -ne $Script:Grp){
        $res=@("Group $($GroupName) created",$Script:Grp)
        if($SRXEnv) {
            $SRXEnv.ResultMessage = "Group $($GroupName) created"
        } 
        else{
            Write-Output $res
        }
    }
    else{
        if($SRXEnv) {
            $SRXEnv.ResultMessage = "Group not created"
        }    
        Throw "Group not created"
    }
}
catch{
    throw
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


