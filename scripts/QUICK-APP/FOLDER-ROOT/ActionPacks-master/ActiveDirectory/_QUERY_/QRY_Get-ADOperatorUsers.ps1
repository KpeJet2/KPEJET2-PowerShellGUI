# VersionTag: 2602.a.11
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2602.a.10
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2602.a.9
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2602.a.8
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2602.a.7
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
#Requires -Version 5.0
#Requires -Modules ActiveDirectory

<#
    .SYNOPSIS
        Returns all users of the users ou or below
    
    .DESCRIPTION  

    .NOTES
        This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
        The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
        The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
        the use and the consequences of the use of this freely available script.
        PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
        © ScriptRunner Software GmbH

    .COMPONENT
        Requires Module ActiveDirectory

    .LINK        
#>

param(                
)

Import-Module ActiveDirectory

try{
    [string]$usr = $SRXEnv.SRXStartedBy.Split('\')[1]
    [string]$strFilter = "(&(objectCategory=User)(samAccountName=$($usr)))"
    $objSearcher = New-Object System.DirectoryServices.DirectorySearcher
    $objSearcher.Filter = $strFilter
    $objPath = $objSearcher.FindOne()
    $objUser = $objPath.GetDirectoryEntry()
    [string]$DN = $objUser.distinguishedName
    $ADVal = [ADSI]"LDAP://$DN"
    [string]$WorkOU = $ADVal.Parent.Replace('LDAP://','')
    
    $result = Get-ADUser -Filter * -SearchBase $WorkOU -SearchScope Subtree -Properties SamAccountName,DistinguishedName -ErrorAction Stop | Sort-Object SamAccountName
    foreach($itm in $result){
        if($SRXEnv){
            $null = $SRXEnv.ResultList.Add($itm.DistinguishedName)
            $null = $SRXEnv.ResultList2.Add($itm.SamAccountName)
        }
        else{
            Write-Output $itm.SamAccountName
        }
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



