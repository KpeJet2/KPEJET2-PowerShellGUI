# VersionTag: 2605.B5.V51.1
# PwShGUI-TrayServiceRoutes.psm1 — HTTP API routes for tray service config and seeding

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Register HTTP API routes for tray service configuration, folder shortcuts, and workspace seeding.

.DESCRIPTION
This module provides route handler functions for the Start-LocalWebEngine.ps1 HTTP listener.
It handles tray config CRUD, folder/document shortcuts discovery, and seeding operations.

Import this module before starting the web engine:
    Import-Module (Join-Path $modulesDir 'PwShGUI-TrayServiceRoutes.psm1') -Force

Then call Register-TrayServiceRoutes to hook the handlers into your route dispatcher.
#>

$script:TrayConfigPath = $null
$script:WorkspacePath  = $null
$script:Port           = 8042

function Initialize-TrayServiceRoutes {
    <#
    .SYNOPSIS
    Initialize route module state (paths, port).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [int]$Port = 8042
    )

    $script:WorkspacePath   = $WorkspacePath
    $script:TrayConfigPath  = Join-Path $WorkspacePath 'config' 'tray-service-config.json'
    $script:Port            = $Port

    Write-Verbose "TrayServiceRoutes initialized: WorkspacePath=$WorkspacePath, Port=$Port"
}

function Get-TrayServiceConfigRoute {
    <#
    .SYNOPSIS
    Handler for GET /api/config/tray-service
    Returns current tray configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context
    )

    $config = $null
    if (Test-Path -LiteralPath $script:TrayConfigPath) {
        try {
            $content = Get-Content -LiteralPath $script:TrayConfigPath -Raw -ErrorAction Stop
            $config = ConvertFrom-Json -InputObject $content -ErrorAction Stop
        } catch {
            return Send-JsonResponse -Context $Context -StatusCode 500 -Message "Tray config exists but could not be read or parsed. Check config/tray-service-config.json for valid JSON and file permissions. Details: $($_.Exception.Message)"
        }
    } else {
        return Send-JsonResponse -Context $Context -StatusCode 404 -Message "Tray config file not found at config/tray-service-config.json. Save settings from the Tray Configuration page to create it."
    }

    Send-JsonResponse -Context $Context -StatusCode 200 -Data $config
}

function Set-TrayServiceConfigRoute {
    <#
    .SYNOPSIS
    Handler for POST /api/config/tray-service
    Updates and persists tray configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context
    )

    try {
        $body = $null
        if ($Context.Request.ContentLength64 -gt 0) {
            $reader = New-Object System.IO.StreamReader($Context.Request.InputStream)
            $body = $reader.ReadToEnd()
            $reader.Close()
        }

        if ([string]::IsNullOrEmpty($body)) {
            return Send-JsonResponse -Context $Context -StatusCode 400 -Message "Tray configuration payload is empty. Refresh the page, change a setting, and retry save."
        }

        $config = ConvertFrom-Json -InputObject $body -ErrorAction Stop

        # Ensure _versionTag is present
        if (-not $config.PSObject.Properties.Name -contains '_versionTag') {
            $config | Add-Member -NotePropertyName '_versionTag' -NotePropertyValue '2605.B5.V51.1'
        }

        # P012: explicit -Encoding on Set-Content
        $configJson = $config | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $script:TrayConfigPath -Value $configJson -Encoding UTF8 -Force

        Send-JsonResponse -Context $Context -StatusCode 200 -Message "Configuration saved successfully to config/tray-service-config.json." -Data @{ success = $true }
    } catch {
        Send-JsonResponse -Context $Context -StatusCode 500 -Message "Tray configuration could not be saved. Verify write access to config/tray-service-config.json and ensure the file is not locked. Details: $($_.Exception.Message)"
    }
}

function Get-FolderShortcutsRoute {
    <#
    .SYNOPSIS
    Handler for GET /api/config/shortcuts?type=RUN|INVOKE|LAUNCH|START
    Returns matching verb-based script shortcuts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context
    )

    try {
        $queryType = $Context.Request.QueryString['type']
        if ([string]::IsNullOrEmpty($queryType)) {
            $queryType = 'RUN'
        }

        # Import PwShGUI-TrayHost to use Get-VerbFolderShortcuts
        $trayHostModule = Join-Path $script:WorkspacePath 'modules' 'PwShGUI-TrayHost.psm1'
        if (Test-Path -LiteralPath $trayHostModule) {
            Import-Module -Name $trayHostModule -Force -ErrorAction SilentlyContinue
        }

        $shortcuts = @()
        try {
            $shortcuts = @(Get-VerbFolderShortcuts -FolderType $queryType -ScriptsRoot (Join-Path $script:WorkspacePath 'scripts'))
        } catch {
            Write-Verbose "Error getting verb shortcuts: $_"
        }

        Send-JsonResponse -Context $Context -StatusCode 200 -Data @{
            type = $queryType
            count = @($shortcuts).Count
            items = @($shortcuts | Select-Object -Property Name, Relative, Modified)
        }
    } catch {
        Send-JsonResponse -Context $Context -StatusCode 500 -Message "Failed to retrieve folder shortcuts from scripts path. Verify modules/PwShGUI-TrayHost.psm1 loads correctly and scripts folder exists. Details: $($_.Exception.Message)"
    }
}

function Get-DocumentShortcutsRoute {
    <#
    .SYNOPSIS
    Handler for GET /api/config/documents?type=XHTML|Markdown
    Returns matching document file shortcuts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context
    )

    try {
        $queryType = $Context.Request.QueryString['type']
        if ([string]::IsNullOrEmpty($queryType)) {
            $queryType = 'XHTML'
        }

        # Import PwShGUI-TrayHost to use Get-DocumentShortcuts
        $trayHostModule = Join-Path $script:WorkspacePath 'modules' 'PwShGUI-TrayHost.psm1'
        if (Test-Path -LiteralPath $trayHostModule) {
            Import-Module -Name $trayHostModule -Force -ErrorAction SilentlyContinue
        }

        $documents = @()
        try {
            $documents = @(Get-DocumentShortcuts -DocumentType $queryType -WorkspacePath $script:WorkspacePath)
        } catch {
            Write-Verbose "Error getting document shortcuts: $_"
        }

        Send-JsonResponse -Context $Context -StatusCode 200 -Data @{
            type = $queryType
            count = @($documents).Count
            items = @($documents | Select-Object -Property Name, Relative, Modified)
        }
    } catch {
        Send-JsonResponse -Context $Context -StatusCode 500 -Message "Failed to retrieve document shortcuts. Verify document roots exist and modules/PwShGUI-TrayHost.psm1 is available. Details: $($_.Exception.Message)"
    }
}

function Get-SeedingCandidatesRoute {
    <#
    .SYNOPSIS
    Handler for GET /api/seeding/candidates
    Returns list of available seed packages from fallback paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context
    )

    try {
        # Import PwShGUI-WorkspaceSeed module
        $seedModule = Join-Path $script:WorkspacePath 'modules' 'PwShGUI-WorkspaceSeed.psm1'
        if (Test-Path -LiteralPath $seedModule) {
            Import-Module -Name $seedModule -Force -ErrorAction SilentlyContinue
        }

        $candidates = @()
        try {
            $candidates = @(Find-SeedPath -WorkspacePath $script:WorkspacePath)
        } catch {
            Write-Verbose "Error finding seed paths: $_"
        }

        Send-JsonResponse -Context $Context -StatusCode 200 -Data @{
            count = @($candidates).Count
            items = @($candidates | Select-Object -Property Path, Type, Modified, SizeGB, FileName)
        }
    } catch {
        Send-JsonResponse -Context $Context -StatusCode 500 -Message "Failed to enumerate seed candidates. Verify modules/PwShGUI-WorkspaceSeed.psm1 is present and accessible. Details: $($_.Exception.Message)"
    }
}

function Invoke-SeedingRoute {
    <#
    .SYNOPSIS
    Handler for POST /api/seeding/execute
    Performs the workspace seeding operation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context
    )

    try {
        $body = $null
        if ($Context.Request.ContentLength64 -gt 0) {
            $reader = New-Object System.IO.StreamReader($Context.Request.InputStream)
            $body = $reader.ReadToEnd()
            $reader.Close()
        }

        if ([string]::IsNullOrEmpty($body)) {
            return Send-JsonResponse -Context $Context -StatusCode 400 -Message "Seeding request payload is empty. Select a seed source in the UI and retry."
        }

        $seedRequest = ConvertFrom-Json -InputObject $body -ErrorAction Stop
        $seedPath = $seedRequest.seedPath
        $autoStart = if ($seedRequest.autoStart -is [bool]) { $seedRequest.autoStart } else { $false }
        $autoStartMethod = if (-not [string]::IsNullOrEmpty($seedRequest.autoStartMethod)) { $seedRequest.autoStartMethod } else { 'ScheduledTask' }

        if ([string]::IsNullOrEmpty($seedPath)) {
            return Send-JsonResponse -Context $Context -StatusCode 400 -Message "Seeding request is missing seedPath. Choose a seed package path before executing seeding."
        }

        # Import PwShGUI-WorkspaceSeed module
        $seedModule = Join-Path $script:WorkspacePath 'modules' 'PwShGUI-WorkspaceSeed.psm1'
        if (-not (Test-Path -LiteralPath $seedModule)) {
            return Send-JsonResponse -Context $Context -StatusCode 500 -Message "Required seed module was not found at modules/PwShGUI-WorkspaceSeed.psm1. Restore the module and retry."
        }

        Import-Module -Name $seedModule -Force -ErrorAction Stop

        # Load preserve patterns from config
        $config = $null
        $preservePatterns = @(
            'config/*.json', 'config/*.xml', 'config/*.yaml',
            'logs/*', 'temp/*', 'pki/*', '~REPORTS/*'
        )
        if (Test-Path -LiteralPath $script:TrayConfigPath) {
            try {
                $configContent = Get-Content -LiteralPath $script:TrayConfigPath -Raw -ErrorAction SilentlyContinue
                $config = ConvertFrom-Json -InputObject $configContent -ErrorAction SilentlyContinue
                if ($config.PSObject.Properties.Name -contains 'seeding' -and $config.seeding.PSObject.Properties.Name -contains 'preserveOnMerge') {
                    $preservePatterns = @($config.seeding.preserveOnMerge)
                }
            } catch { }
        }

        # Perform seeding
        $result = Expand-SeedPackage -SeedPath $seedPath -TargetPath $script:WorkspacePath -PreservePatterns $preservePatterns

        if ($result.Success) {
            # Register auto-start if requested
            if ($autoStart) {
                $autoStartResult = Register-TrayAutoStart -Method $autoStartMethod -TrayScriptPath (Join-Path $script:WorkspacePath 'scripts' 'Start-LocalWebEngineService.ps1') -Port $script:Port
                if ($autoStartResult.Success) {
                    $result | Add-Member -NotePropertyName 'autoStartRegistered' -NotePropertyValue $true
                }
            }

            Send-JsonResponse -Context $Context -StatusCode 200 -Data $result
        } else {
            Send-JsonResponse -Context $Context -StatusCode 500 -Data $result
        }
    } catch {
        Send-JsonResponse -Context $Context -StatusCode 500 -Message "Seeding failed before completion. Check seed path access, preserve patterns, and module dependencies. Details: $($_.Exception.Message)"
    }
}

function Send-JsonResponse {
    <#
    .SYNOPSIS
    Helper to send JSON responses with standard formatting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [int]$StatusCode = 200,
        [string]$Message = '',
        [object]$Data = $null
    )

    $response = @{}

    if ($StatusCode -ge 400) {
        $response['success'] = $false
        if (-not [string]::IsNullOrEmpty($Message)) {
            $response['error'] = $Message
        }
    } else {
        $response['success'] = $true
        if (-not [string]::IsNullOrEmpty($Message)) {
            $response['message'] = $Message
        }
    }

    if ($null -ne $Data) {
        $response['data'] = $Data
    }

    $json = $response | ConvertTo-Json -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $ctx = $Context.Response
    $ctx.StatusCode = $StatusCode
    $ctx.ContentType = 'application/json; charset=utf-8'
    $ctx.ContentLength64 = $bytes.Length
    $ctx.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.OutputStream.Close()
}

Export-ModuleMember -Function @(
    'Initialize-TrayServiceRoutes',
    'Get-TrayServiceConfigRoute',
    'Set-TrayServiceConfigRoute',
    'Get-FolderShortcutsRoute',
    'Get-DocumentShortcutsRoute',
    'Get-SeedingCandidatesRoute',
    'Invoke-SeedingRoute',
    'Send-JsonResponse'
)
