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
    Generates a report with task definition object of a scheduled task that is registered on the computer

.DESCRIPTION

.NOTES
    This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
    The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
    The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
    the use and the consequences of the use of this freely available script.
    PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
    © ScriptRunner Software GmbH

.COMPONENT
    Requires Library Script ReportLibrary from the Action Pack Reporting\_LIB_

.LINK
    https://github.com/scriptrunner/ActionPacks/tree/master/WinSystemManagement/_REPORTS_ 

.Parameter TaskName
    [sr-en] Name of a scheduled task. Use * for all tasks    

.Parameter TaskPath 
    [sr-en] Path for scheduled task in Task Scheduler namespace. Use * for all paths

.Parameter ComputerName
    [sr-en] Name of the computer from which to retrieve the schedule tasks.
    
.Parameter AccessAccount
    [sr-en] User account that has permission to perform this action. If Credential is not specified, the current user account is used.
#>

[CmdLetBinding()]
Param(
    [string]$TaskName = "*",
    [string]$TaskPath = "*",
    [string]$ComputerName,
    [PSCredential]$AccessAccount
)

$Script:Cim=$null
try{
    [string[]]$Properties = @('TaskName','TaskPath','Description','URI','State','Author')

    if([System.String]::IsNullOrWhiteSpace($TaskName)){
        $TaskName= "*"
    }
    if([System.String]::IsNullOrWhiteSpace($TaskPath)){
        $TaskPath= "*"
    }

    if([System.String]::IsNullOrWhiteSpace($ComputerName)){
        $ComputerName = [System.Net.DNS]::GetHostByName('').HostName
    }          
    if($null -eq $AccessAccount){
        $Script:Cim = New-CimSession -ComputerName $ComputerName -ErrorAction Stop
    }
    else {
        $Script:Cim = New-CimSession -ComputerName $ComputerName -Credential $AccessAccount -ErrorAction Stop
    }

    $tasks = @()
    $null = Get-ScheduledTask -CimSession $Script:Cim -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop  `
                    | Select-Object $Properties | Sort-Object TaskName | ForEach-Object{
                            $tasks += [PSCustomObject]@{
                                TaskName = $_.TaskName;
                                TaskPath = $_.TaskPath;
                                Description = $_.Description;
                                URI = $_.URI;
                                State = $_.State;
                                Author = $_.Author
                            }
                    }
    
    ConvertTo-ResultHtml -Result $tasks
}
catch{
    throw
}
finally{
    if($null -ne $Script:Cim){
        Remove-CimSession $Script:Cim 
    }
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


