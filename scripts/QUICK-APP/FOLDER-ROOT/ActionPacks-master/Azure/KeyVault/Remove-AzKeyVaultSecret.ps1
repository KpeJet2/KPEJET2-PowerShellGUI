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
#Requires -Modules Az.KeyVault

<#
    .SYNOPSIS
        Deletes a secret in a key vault
    
    .DESCRIPTION  
        
    .NOTES
        This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
        The customer or user is authorized to copy the script# VersionTag: 2602.a.11
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
#Requires -Modules Az.KeyVault

<#
    .SYNOPSIS
        Deletes a secret in a key vault
    
    .DESCRIPTION  
        
    .NOTES
        This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
        The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
        The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
        the use and the consequences of the use of this freely available script.
        PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
        © ScriptRunner Software GmbH

    .COMPONENT
        Requires Module Az.KeyVault

    .LINK
        https://github.com/scriptrunner/ActionPacks/blob/master/Azure/KeyVault

    .Parameter VaultName
        [sr-en] Name of the key vault   
        [sr-de] Namen des Key Vaults

    .Parameter SecretName
        [sr-en] Name of the secret
        [sr-de] Namen des Secrets
        
    .Parameter InRemovedState
        [sr-en] Remove the previously deleted secret permanently
        [sr-de] Gelöschtes Secret endgültig entfernen
#>

param( 
    [Parameter(Mandatory = $true)]
    [string]$VaultName,
    [Parameter(Mandatory = $true)]
    [string]$SecretName,
    [switch]$InRemovedState
)

Import-Module Az.KeyVault

try{

    [hashtable]$cmdArgs = @{'ErrorAction' = 'Stop'
                'VaultName' = $VaultName
                'Name' = $SecretName
                'Confirm' = $false
                'PassThru' = $null
                'Force' = $null
    }
    
    if($InRemovedState.IsPresent -eq $true){
        $cmdArgs.Add('InRemovedState',$InRemovedState)
    }
    $ret = Remove-AzKeyVaultSecret @cmdArgs | Select-Object *

    if($null -ne $SRXEnv) {
        $SRXEnv.ResultMessage = $ret 
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



