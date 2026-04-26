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
#Requires -Modules Az.Resources

<#
    .SYNOPSIS
        Gets storage resource groups
    
    .DESCRIPTION  
        
    .NOTES
        This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
        The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
        The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
        the use and the consequences of the use of this freely available script.
        PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
        © ScriptRunner Software GmbH

    .COMPONENT
        Requires Module Az.Resources

    .LINK
        https://github.com/scriptrunner/ActionPacks/blob/master/Azure/_QUERY_ 
#>

param( 
    [bool]$GetIDs
)

Import-Module Az.Resources

try{
    $result = Get-AzResourceGroup -ErrorAction Stop | Sort-Object ResourceGroupName

    foreach($grp in $result){
        if($SRXEnv) {
            $key
            if($GetIDs -eq $true){
                $null = $SRXEnv.ResultList.Add($grp.ResourceId)
            }
            else{
                $null = $SRXEnv.ResultList.Add($grp.ResourceGroupName)
            }
            $null = $SRXEnv.ResultList2.Add($grp.ResourceGroupName) # Display
        }
        else{
            Write-Output $grp.ResourceGroupName
        }
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



