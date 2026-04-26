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
#Requires -Modules Az.Sql

<#
    .SYNOPSIS
        Generates a report with elastic databases in an elastic pool and their property values
    
    .DESCRIPTION  
        
    .NOTES
        This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
        The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
        The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
        the use and the consequences of the use of this freely available script.
        PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
        © ScriptRunner Software GmbH

    .COMPONENT
        Requires Module Az.Sql
        Requires Library script AzureAzLibrary.ps1

    .LINK
        https://github.com/scriptrunner/ActionPacks/blob/master/Azure/_REPORTS_   

    .Parameter ServerName
        [sr-en] Specifies the name of the server that contains the elastic pool
        [sr-de] Name des Servers auf dem sich der elastic pool befindet

    .Parameter ResourceGroupName
        [sr-en] Specifies the name of the resource group that contains the elastic pool 
        [sr-de] Name der resource group die dem elastic pool zugewiesen wurde

    .Parameter PoolName
        [sr-en] Specifies the name of the elastic pool
        [sr-de] Name des elastic pools

    .Parameter DBName
        [sr-en] Specifies the name of the SQL Database to retrieve
        [sr-de] Name der Datenbank
#>

param( 
    [Parameter(Mandatory = $true)]
    [string]$PoolName,
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory = $true)]
    [string]$ServerName,
    [string]$DBName
)

Import-Module Az.Sql

try{
    [hashtable]$cmdArgs = @{'ErrorAction' = 'Stop'
                            'Confirm' = $false
                            'ElasticPoolName' = $PoolName
                            'ServerName' = $ServerName
                            'ResourceGroupName' = $ResourceGroupName}
    
    if([System.String]::IsNullOrWhiteSpace($DBName) -eq $false){
        $cmdArgs.Add('DatabaseName',$DBName)
    }

    $ret = Get-AzSqlElasticPoolDatabase @cmdArgs

    if($SRXEnv) {
        ConvertTo-ResultHtml -Result $ret    
    }
    else{
        Write-Output $ret
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



