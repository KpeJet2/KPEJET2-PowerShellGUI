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

<#
    .SYNOPSIS
        Connect to Microsoft Exchange Server and gets the resource properties
    
    .DESCRIPTION  

    .NOTES
        This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
        The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
        The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
        the use and the consequences of the use of this freely available script.
        PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
        © ScriptRunner Software GmbH 

    .COMPONENT       

    .LINK
        https://github.com/scriptrunner/ActionPacks/tree/master/Exchange/Resources

    .Parameter MailboxId
        [sr-en] Alias, Display name, Distinguished name, SamAccountName, Guid or user principal name of the resource from which to get properties

    .Parameter Properties
        [sr-en] Properties to expand. Use * for all properties
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$MailboxId,
    [Validateset('*','DisplayName','WindowsEmailAddress','ResourceCapacity','AccountDisabled','IsMailboxEnabled','DistinguishedName','Alias','Guid','SamAccountName')]
    [string[]]$Properties=@('DisplayName','WindowsEmailAddress','ResourceCapacity','AccountDisabled','IsMailboxEnabled','DistinguishedName','Alias','Guid','SamAccountName')
)

try{
    if($Properties -contains '*'){
        $Properties = @('*')
    }
    $res = Get-Mailbox -Identity $MailboxId | Select-Object $Properties 

    if($null -ne $res){
        $resultMessage = @()
        $resultMessage += $res
        $res = Get-CalendarProcessing -Identity $MailboxId | `
            Select-Object AllBookInPolicy,AllowRecurringMeetings,BookingWindowInDays,EnforceSchedulingHorizon,MaximumDurationInMinutes,ScheduleOnlyDuringWorkHours
        if($null -ne $res){        
            $resultMessage +=$res
        }
        if($SRXEnv) {
            $SRXEnv.ResultMessage = $resultMessage  
        }
        else{
            Write-Output $resultMessage
        }
    }
    else{
        if($SRXEnv) {
            $SRXEnv.ResultMessage = "Resource $($MailboxId) not found"
        } 
        Throw  "Resource $($MailboxId) not found"
    }
}
catch{
    throw
}
Finally{
    
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


