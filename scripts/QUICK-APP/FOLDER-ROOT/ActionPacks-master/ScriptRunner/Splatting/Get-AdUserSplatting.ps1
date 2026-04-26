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
<#
.Synopsis
.Description
.Notes
.Component
.Parameter sAMAccountName
    Nimmt den sAMAccountName wenn zu Testzwecken nach einem bestimmten Benutzer gesucht werden soll
#>


param (
    #[Parameter(Mandatory = $true)]
    #[string]$sAMAccountName,    
    [string[]]$Properties = @("cn", "GivenName", "sn", "PostalCode", "sAMAccountName")
)

Import-Module ActiveDirectory

try {   
    $ADUsers = Get-ADUser -Filter '*' -Properties $Properties
    foreach ($user in $ADUsers) {
        [hashtable]$result = @{} #Hashtable zur Verwendung mit Splatting in der ScriptRunner Action
        foreach ($prop in $Properties) {
            $null = $result.Add($prop, $user.Item($prop).Value)            
        }
        if ($SRXEnv) {
            $null = $SRXEnv.ResultList.Add($result)
            $null = $SRXEnv.ResultList2.Add("$($user.cn)")        
        }
        else {
            Write-Host "$($result)"
        }   
    }
}
catch {
    throw
}

<#try {
    $ADUser = Get-ADUser -Identity $sAMAccountName -Properties $Properties
    [hashtable]$result = @{} #Hashtable zur Verwendung mit Splatting in der ScriptRunner Action
    foreach ($prop in $Properties) {
        $null = $result.Add($prop, $ADUser.Item($prop).Value)
    }
    if ($SRXEnv) {
        $null = $SRXEnv.ResultList.Add($result)
        $null = $SRXEnv.ResultList2.Add("$($ADUser.cn)")        
    }
}
catch {
    throw
    
}#>















<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>


