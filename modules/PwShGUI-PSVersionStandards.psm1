# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
# VersionBuildHistory:
# TODO: HelpMenu | Show-VersionStandardsHelp | Actions: Check|Enforce|Report|Help | Spec: config/help-menu-registry.json
#   2603.B0.v27.0  2026-03-29 (initial creation)
#Requires -Version 5.1
<#
.SYNOPSIS
    PowerShell Version Standards Module -- defines optimal/minimum PS versions,
    PS5 compatibility flag workflow, and bootstrap environment logging.
.DESCRIPTION
    Centralizes PS version policy for the PwShGUI application:
      - Optimal version : 7.6+   (favoured; full feature set)
      - Minimum version : 5.1    (Windows PowerShell; limited feature set)
    Exports functions for version detection, compatibility-flag management,
    upgrade prompting, and bootstrap environment variable logging.
.NOTES
    Author  : The Establishment
    Version : 2604.B2.V31.0
    Module  : PwShGUI-PSVersionStandards
#>

# ======================== VERSION CONSTANTS ========================
[string] $script:OptimalPSVersion   = '7.6'
[string] $script:MinimumPSVersion   = '5.1'
[string] $script:OptimalPSEdition   = 'Core'
[string] $script:MinimumPSEdition   = 'Desktop'

# PS5 Compatibility Flag States (workflow progression)
# State 1: Optional-PendingSmokeTesting           (initial default)
# State 2a: Yes-NativeBackwardsCompatibility       (smoke test passed natively)
# State 2b: Optional-PendingPipelineItem2ADD       (needs code forks for v5)
# State 3a: Yes-CustomCodeForksImplemented         (approved + tests pass)
# State 3b: No-v5Compat-REVIEW-case-DENIED        (denied -- disabled until PS7.6)
$script:CompatFlagStates = @(
    'Optional-PendingSmokeTesting'
    'Yes-NativeBackwardsCompatibility'
    'Optional-PendingPipelineItem2ADD'
    'Yes-CustomCodeForksImplemented'
    'No-v5Compat-REVIEW-case-DENIED-FunctionalRelationsDisabledUntilPS76Detected'
)

# ======================== VERSION DETECTION ========================

function Get-PSVersionStandard {
    <#
    .SYNOPSIS Returns the version policy constants.
    #>
    [CmdletBinding()]
    param()
    [PSCustomObject]@{
        OptimalVersion  = [version]$script:OptimalPSVersion
        MinimumVersion  = [version]$script:MinimumPSVersion
        OptimalEdition  = $script:OptimalPSEdition
        MinimumEdition  = $script:MinimumPSEdition
        CurrentVersion  = $PSVersionTable.PSVersion
        CurrentEdition  = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
        IsOptimal       = ($PSVersionTable.PSVersion -ge [version]$script:OptimalPSVersion)
        IsMinimum       = ($PSVersionTable.PSVersion -ge [version]$script:MinimumPSVersion)
        CompatFlagStates = $script:CompatFlagStates
    }
}

function Test-PSVersionOptimal {
    <#
    .SYNOPSIS Returns $true if running PS 7.6+.
    #>
    [CmdletBinding()]
    param()
    $PSVersionTable.PSVersion -ge [version]$script:OptimalPSVersion
}

function Test-PSVersionMinimum {
    <#
    .SYNOPSIS Returns $true if running PS 5.1+.
    #>
    [CmdletBinding()]
    param()
    $PSVersionTable.PSVersion -ge [version]$script:MinimumPSVersion
}

function Get-PSVersionTier {
    <#
    .SYNOPSIS Returns 'Optimal', 'Supported', or 'Unsupported' based on current PS version.
    #>
    [OutputType([System.String])]
    [CmdletBinding()]
    param()
    $ver = $PSVersionTable.PSVersion
    if ($ver -ge [version]$script:OptimalPSVersion) { return 'Optimal' }
    if ($ver -ge [version]$script:MinimumPSVersion) { return 'Supported' }
    return 'Unsupported'
}

# ======================== COMPATIBILITY FLAG ========================

function Get-PS5CompatibilityFlag {
    <#
    .SYNOPSIS
        Reads the PS5 compatibility flag from config/ps5-compat-flags.json.
        Returns the flag state for a given script/module, or defaults to
        'Optional-PendingSmokeTesting'.
    .PARAMETER ScriptName
        Name of the script or module to query (e.g. 'Main-GUI.ps1').
    .PARAMETER ConfigDir
        Path to the config directory. Defaults to config/ relative to module location.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptName,
        [string]$ConfigDir
    )
    if (-not $ConfigDir) {
        $ConfigDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent)) 'config'
    }
    $flagFile = Join-Path $ConfigDir 'ps5-compat-flags.json'
    if (-not (Test-Path $flagFile)) {
        return [PSCustomObject]@{
            ScriptName = $ScriptName
            Flag       = 'Optional-PendingSmokeTesting'
            Updated    = $null
            Notes      = 'No flag file found -- default state'
        }
    }
    $flags = Get-Content $flagFile -Raw | ConvertFrom-Json
    $entry = $flags.flags | Where-Object { $_.scriptName -eq $ScriptName }
    if ($entry) {
        [PSCustomObject]@{
            ScriptName = $entry.scriptName
            Flag       = $entry.flag
            Updated    = $entry.updated
            Notes      = $entry.notes
        }
    } else {
        [PSCustomObject]@{
            ScriptName = $ScriptName
            Flag       = 'Optional-PendingSmokeTesting'
            Updated    = $null
            Notes      = 'No entry found -- default state'
        }
    }
}

function Set-PS5CompatibilityFlag {
    <#
    .SYNOPSIS
        Sets the PS5 compatibility flag for a script/module.
    .PARAMETER ScriptName
        Script or module filename.
    .PARAMETER Flag
        One of the defined flag states.
    .PARAMETER Notes
        Optional description of why the flag was set.
    .PARAMETER ConfigDir
        Path to config directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptName,
        [Parameter(Mandatory)]
        [ValidateSet(
            'Optional-PendingSmokeTesting',
            'Yes-NativeBackwardsCompatibility',
            'Optional-PendingPipelineItem2ADD',
            'Yes-CustomCodeForksImplemented',
            'No-v5Compat-REVIEW-case-DENIED-FunctionalRelationsDisabledUntilPS76Detected'
        )]
        [string]$Flag,
        [string]$Notes = '',
        [string]$ConfigDir
    )
    if (-not $ConfigDir) {
        $ConfigDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent)) 'config'
    }
    $flagFile = Join-Path $ConfigDir 'ps5-compat-flags.json'
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    if (Test-Path $flagFile) {
        $flags = Get-Content $flagFile -Raw | ConvertFrom-Json
    } else {
        $flags = [PSCustomObject]@{
            description = 'PS5 compatibility flags per script/module'
            optimalVersion = $script:OptimalPSVersion
            minimumVersion = $script:MinimumPSVersion
            flags = @()
        }
    }

    # Convert to mutable list
    $flagList = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $flags.flags) { $flagList.Add($f) }

    $existing = $flagList | Where-Object { $_.scriptName -eq $ScriptName }
    if ($existing) {
        $existing.flag    = $Flag
        $existing.updated = $timestamp
        $existing.notes   = $Notes
    } else {
        $flagList.Add([PSCustomObject]@{
            scriptName = $ScriptName
            flag       = $Flag
            updated    = $timestamp
            notes      = $Notes
        })
    }
    $flags.flags = @($flagList)

    $flags | ConvertTo-Json -Depth 5 | Set-Content $flagFile -Encoding UTF8
    Write-Verbose "Set PS5 compat flag: $ScriptName = $Flag"
    [PSCustomObject]@{ ScriptName = $ScriptName; Flag = $Flag; Updated = $timestamp }
}

# ======================== UPGRADE PROMPT ========================

function Show-PSUpgradePrompt {
    <#
    .SYNOPSIS
        Checks the current PS version against optimal and prompts for upgrade.
        Returns an object indicating whether upgrade is recommended.
    .PARAMETER Silent
        If set, returns the result without displaying GUI prompts.
    #>
    [CmdletBinding()]
    param(
        [switch]$Silent
    )
    $ver    = $PSVersionTable.PSVersion
    $tier   = Get-PSVersionTier
    $result = [PSCustomObject]@{
        CurrentVersion  = $ver
        Tier            = $tier
        UpgradeNeeded   = ($tier -ne 'Optimal')
        Message         = ''
    }

    switch ($tier) {
        'Optimal' {
            $result.Message = "PowerShell $ver is at or above optimal ($($script:OptimalPSVersion)+). No upgrade needed."
        }
        'Supported' {
            $result.Message = "PowerShell $ver meets minimum ($($script:MinimumPSVersion)) but is below optimal ($($script:OptimalPSVersion)+). Upgrade recommended: winget install --id Microsoft.PowerShell --source winget"
        }
        'Unsupported' {
            $result.Message = "PowerShell $ver is below minimum ($($script:MinimumPSVersion)). Upgrade REQUIRED: winget install --id Microsoft.PowerShell --source winget"
        }
    }

    if (-not $Silent -and $tier -ne 'Optimal') {
        # Log the upgrade suggestion
        if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
            $logLevel = if ($tier -eq 'Unsupported') { 'Error' } else { 'Warning' }
            Write-AppLog $result.Message $logLevel
        }
        # GUI prompt if WinForms is available
        if ([System.Windows.Forms.MessageBox] -and -not $Silent) {
            $icon = if ($tier -eq 'Unsupported') {
                [System.Windows.Forms.MessageBoxIcon]::Error
            } else {
                [System.Windows.Forms.MessageBoxIcon]::Warning
            }
            $response = [System.Windows.Forms.MessageBox]::Show(
                "$($result.Message)`n`nWould you like to open the PowerShell download page?",
                "PowerShell Version Check",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                $icon
            )
            if ($response -eq [System.Windows.Forms.DialogResult]::Yes) {
                Start-Process 'https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows'
            }
        }
    }
    $result
}

# ======================== BOOTSTRAP ENV LOGGING ========================

function Write-PSBootstrapLog {
    <#
    .SYNOPSIS
        Logs comprehensive PS environment details at application bootstrap.
        Captures version, edition, paths, environment variables, and host info.
    .PARAMETER LogFunction
        Name of the logging function to use (default: Write-AppLog).
    #>
    [CmdletBinding()]
    param(
        [string]$LogFunction = 'Write-AppLog'
    )

    $logCmd = Get-Command $LogFunction -ErrorAction SilentlyContinue
    # Fallback to Write-Verbose if log function unavailable
    $doLog = {
        param([string]$Msg, [string]$Level)
        if ($logCmd) {
            & $LogFunction $Msg $Level
        } else {
            Write-Verbose "[$Level] $Msg"
        }
    }

    & $doLog '===== PS Environment Bootstrap Log =====' 'Audit'
    & $doLog "PS Version       : $($PSVersionTable.PSVersion)" 'Info'
    & $doLog "PS Edition       : $(if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' })" 'Info'

    $tier = Get-PSVersionTier
    & $doLog "PS Version Tier  : $tier (Optimal=$($script:OptimalPSVersion)+ Min=$($script:MinimumPSVersion)+)" 'Info'

    & $doLog "PS Host          : $($Host.Name) v$($Host.Version)" 'Info'
    & $doLog "OS               : $([System.Environment]::OSVersion.VersionString)" 'Info'
    & $doLog "Computer         : $env:COMPUTERNAME" 'Info'
    & $doLog "User             : $env:USERNAME" 'Info'
    & $doLog "Culture          : $([System.Globalization.CultureInfo]::CurrentCulture.Name)" 'Info'

    # PS-related environment variables
    & $doLog "PSModulePath     : $env:PSModulePath" 'Debug'
    if ($env:PSExecutionPolicyPreference) {
        & $doLog "PSExecPolicy ENV : $env:PSExecutionPolicyPreference" 'Debug'
    }
    $execPolicy = Get-ExecutionPolicy -ErrorAction SilentlyContinue
    & $doLog "Execution Policy : $execPolicy" 'Info'

    # Detect installed PS versions via typical paths
    $psInstalls = @()
    $winPS = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $winPS) {
        $psInstalls += "WindowsPS 5.1: $winPS"
    }
    $pwshPaths = @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe"
        "$env:ProgramFiles\PowerShell\7-preview\pwsh.exe"
        (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    foreach ($p in $pwshPaths) {
        $psInstalls += "pwsh: $p"
    }
    & $doLog "Installed PS     : $($psInstalls -join ' | ')" 'Info'

    # .NET CLR version
    $clr = if ($PSVersionTable.CLRVersion) { $PSVersionTable.CLRVersion.ToString() } else { 'N/A (Core)' }
    & $doLog "CLR Version      : $clr" 'Debug'

    & $doLog "===== End PS Environment Bootstrap =====" 'Event'
}

# ======================== EXPORTS ========================

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember -Function @(
    'Get-PSVersionStandard'
    'Test-PSVersionOptimal'
    'Test-PSVersionMinimum'
    'Get-PSVersionTier'
    'Get-PS5CompatibilityFlag'
    'Set-PS5CompatibilityFlag'
    'Show-PSUpgradePrompt'
    'Write-PSBootstrapLog'
)






