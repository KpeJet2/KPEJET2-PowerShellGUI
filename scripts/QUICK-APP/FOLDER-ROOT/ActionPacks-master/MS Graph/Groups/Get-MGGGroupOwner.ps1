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
#requires -Modules Microsoft.Graph.Groups 

<#
    .SYNOPSIS
        Get owners from a group
    
    .DESCRIPTION          

    .NOTES
        This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
        The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
        The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
        the use and the consequences of the use of this freely available script.
        PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
        © ScriptRunner Software GmbH

    .COMPONENT
        Requires Modules Microsoft.Graph.Groups 

    .LINK
        https://github.com/scriptrunner/ActionPacks/tree/master/MS%20Graph/Groups
        
    .Parameter GroupId
        [sr-en] Group identifier
        [sr-de] Gruppen ID

    .Parameter ResultType
        [sr-en] Type of the result
        [sr-de] Ergebnistyp
#>

param( 
    [Parameter(Mandatory = $true)]
    [string]$GroupId,
    [Validateset('AsApplication','AsDevice','AsGroup','AsOrgContact','AsServicePrincipal','AsUser')]
    [string]$ResultType
)

Import-Module Microsoft.Graph.Groups

try{
    $result = $null
    [hashtable]$cmdArgs = @{ErrorAction = 'Stop'    
                        'GroupId'= $GroupId
                        'All' = $null
    }

    switch($ResultType){
        'AsApplication'{
            $result = Get-MgGroupOwnerAsApplication @cmdArgs
        }
        'AsDevice'{            
            $result = Get-MgGroupOwnerAsDevice @cmdArgs
        }
        'AsGroup'{
            $result = Get-MgGroupOwnerAsGroup @cmdArgs
        }
        'AsOrgContact'{
            $result = Get-MgGroupOwnerAsOrgContact @cmdArgs
        }
        'AsServicePrincipal'{
            $result = Get-MgGroupOwnerAsServicePrincipal @cmdArgs
        }
        'AsUser'{
            $result = Get-MgGroupOwnerAsUser @cmdArgs
        }
        default{
            $result = Get-MgGroupOwner @cmdArgs
        }
    }

    if($null -ne $SRXEnv) {
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


