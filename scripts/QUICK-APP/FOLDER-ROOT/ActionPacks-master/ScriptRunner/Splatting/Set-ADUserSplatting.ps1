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
.Parameter UserIdentity
    Nimmt einen AD-Benutzer aus einer Query
.Parameter PostalCode
    zeigt die PLZ eines AD-Benutzers
.Parameter GivenName
    zeigt den Vornamen eines AD-Benutzers
.Parameter sn
    zeigt den Nachnamen eines AD-Benutzers
.Parameter streetAddress
    zeigt die Straße eines AD-Benutzers
#>


param (
    [Parameter(Mandatory = $true, HelpMessage = "ASRDisplay(Splatting)")] #Notwendig damit die Attribute der $UserIdentity im Script verwendet werden können 
    [hashtable]$UserIdentity,
    [string]$PostalCode,
    [string]$GivenName,
    [string]$sn,
    [pscredential]$cred    
)

Import-Module ActiveDirectory

try {
    [hashtable]$Properties = @{
        'Identity' = $UserIdentity.sAMAccountName #Hier wird mittels Splatting der sAMAccountName aus dem Parameter (Hashtable) $UserIdentity verwendet
        'PostalCode' = $PostalCode
        'GivenName' = $GivenName
        'sn' = $sn
    }

    Set-ADUser @Properties #Mittels Splatting werden die Attribute des AD Benutzers gesetzt
}
catch {
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


