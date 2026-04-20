# VersionTag: 2604.B0.V1.0
# FileRole: Module
# Module: PwShGUI-NetworkTools
# Purpose: Network connectivity testing and diagnostic utilities for PwShGUI
# Requires: PowerShell 5.1+
Set-StrictMode -Version Latest
# TODO: HelpMenu | Show-NetworkToolsHelp | Actions: Ping|Trace|Resolve|Scan|Help | Spec: config/help-menu-registry.json

function Test-NetworkConnectivity {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Target = '8.8.8.8',

        [Parameter()]
        [int]$Count = 1,

        [Parameter()]
        [int]$TimeoutMs = 3000
    )

    try {
        $result = Test-Connection -ComputerName $Target -Count $Count -Quiet -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            Target    = $Target
            Reachable = [bool]$result
            Timestamp = Get-Date -Format 'o'
        }
    }
    catch {
        Write-Verbose "Test-NetworkConnectivity failed for ${Target}: $($_.Exception.Message)"
        return [PSCustomObject]@{
            Target    = $Target
            Reachable = $false
            Timestamp = Get-Date -Format 'o'
        }
    }
}

function Test-PortOpen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [int]$Port,

        [Parameter()]
        [int]$TimeoutMs = 2000
    )

    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $connect = $tcp.BeginConnect($ComputerName, $Port, $null, $null)
        $waited = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($waited -and $tcp.Connected) {
            $tcp.EndConnect($connect)
            return [PSCustomObject]@{
                Host = $ComputerName; Port = $Port; Open = $true; Timestamp = Get-Date -Format 'o'
            }
        }
        return [PSCustomObject]@{
            Host = $ComputerName; Port = $Port; Open = $false; Timestamp = Get-Date -Format 'o'
        }
    }
    catch {
        Write-Verbose "Test-PortOpen ${ComputerName}:${Port} error: $($_.Exception.Message)"
        return [PSCustomObject]@{
            Host = $ComputerName; Port = $Port; Open = $false; Timestamp = Get-Date -Format 'o'
        }
    }
    finally {
        if ($null -ne $tcp) { $tcp.Dispose() }
    }
}

function Get-PublicIPAddress {
    [CmdletBinding()]
    param()

    $endpoints = @(
        'https://api.ipify.org?format=json',
        'https://ifconfig.me/ip'
    )

    foreach ($ep in $endpoints) {
        try {
            $response = Invoke-RestMethod -Uri $ep -TimeoutSec 5 -ErrorAction Stop
            if ($response -is [PSCustomObject] -and $response.PSObject.Properties.Name -contains 'ip') {
                return $response.ip
            }
            # plain text response
            $ip = ($response -split "`n")[0].Trim()
            if ($ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                return $ip
            }
        }
        catch {
            Write-Verbose "Get-PublicIPAddress failed for ${ep}: $($_.Exception.Message)"
        }
    }
    return $null
}

function Test-DnsResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostName
    )

    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($HostName)
        return [PSCustomObject]@{
            HostName  = $HostName
            Resolved  = $true
            Addresses = @($resolved | ForEach-Object { $_.IPAddressToString })
            Timestamp = Get-Date -Format 'o'
        }
    }
    catch {
        Write-Verbose "DNS resolution failed for ${HostName}: $($_.Exception.Message)"
        return [PSCustomObject]@{
            HostName  = $HostName
            Resolved  = $false
            Addresses = @()
            Timestamp = Get-Date -Format 'o'
        }
    }
}

function Get-NetworkSummary {
    [CmdletBinding()]
    param()

    $internet = Test-NetworkConnectivity -Target '8.8.8.8'
    $dns = Test-DnsResolution -HostName 'google.com'

    return [PSCustomObject]@{
        InternetReachable = $internet.Reachable
        DnsWorking        = $dns.Resolved
        PublicIP          = if ($internet.Reachable) { Get-PublicIPAddress } else { $null }
        Timestamp         = Get-Date -Format 'o'
    }
}

Export-ModuleMember -Function @(
    'Test-NetworkConnectivity',
    'Test-PortOpen',
    'Get-PublicIPAddress',
    'Test-DnsResolution',
    'Get-NetworkSummary'
)
