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
#Requires -Modules SkypeOnlineConnector

function ConnectS4B(){
    <#
        .SYNOPSIS
            Open a Skype for Business online session

        .DESCRIPTION

        .NOTES
            This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
            The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
            The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
            the use and the consequences of the use of this freely available script.
            PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
            © ScriptRunner Software GmbH

        .COMPONENT
            Requires Module SkypeOnlineConnector

        .LINK
            https://github.com/scriptrunner/ActionPacks/tree/master/O365/Skype4Business/_LIB_

        .Parameter S4BCredential
            Credential object containing the Skype for Business user/password
        #>

        [CmdLetBinding()]
        Param(
            [Parameter(Mandatory = $true)]  
            [PSCredential]$S4BCredential
        )

        try{
            [hashtable]$cmdArgs = @{'ErrorAction' = 'Stop'
                        'Credential' = $S4BCredential
                        }
            $Global:session = New-CsOnlineSession @cmdArgs
            Import-PSSession -Session $Global:session -ErrorAction Stop         
        }
        catch{
            throw
        }
        finally{
        }
}

function DisconnectS4B(){
    <#
        .SYNOPSIS
            Closes the online session to Skype for Business 

        .DESCRIPTION

        .NOTES
            This PowerShell script was developed and optimized for ScriptRunner. The use of the scripts requires ScriptRunner. 
            The customer or user is authorized to copy the script from the repository and use them in ScriptRunner. 
            The terms of use for ScriptRunner do not apply to this script. In particular, ScriptRunner Software GmbH assumes no liability for the function, 
            the use and the consequences of the use of this freely available script.
            PowerShell is a product of Microsoft Corporation. ScriptRunner is a product of ScriptRunner Software GmbH.
            © ScriptRunner Software GmbH

        .COMPONENT
            Requires Module SkypeOnlineConnector

        .LINK
            https://github.com/scriptrunner/ActionPacks/tree/master/O365/Skype4Business/_LIB_

        #>

        [CmdLetBinding()]
        Param(
        )

        try{
            Remove-PSSession -Session $Global:session
        }
        catch{
            throw
        }
        finally{
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


