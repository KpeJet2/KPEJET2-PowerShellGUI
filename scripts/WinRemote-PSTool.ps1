# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Utility
#Requires -Version 5.1
<#
.SYNOPSIS
    WinRemote PS Tool - Remote PowerShell Management GUI for the agent pipeline.
.DESCRIPTION
    Multi-tab WinForms GUI providing:
      Tab 1 - Discovery & Hosts: ARP/subnet scan, manual connect box, save/restore host list
      Tab 2 - WinRM Configuration: Enable/secure WinRM, TrustedHosts allow-list, firewall rules
      Tab 3 - Remoting Checklist: Pre-flight validation for PS remoting readiness
      Tab 4 - Secure Baseline: Device-type-aware hardening (Server/Laptop/ThinClient/UPS)

    Designed for local administrator accounts in a watchdog-supervised environment.
    Integrates with PwShGUI workspace via Tools menu.
.NOTES
    Security: All WinRM changes require elevation confirmation.
    Config:   Hosts persisted to config/winremote-hosts.json.
    Baseline: HTTPS preferred, Kerberos/NTLMv2, restricted endpoints.
#>

# ── Module import ─────────────────────────────────────────────────────────────
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\PwShGUICore.psm1'
if (Test-Path $modulePath) { try { Import-Module $modulePath -Force -ErrorAction Stop } catch { Write-Warning "Failed to import core module: $_" } }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Paths ─────────────────────────────────────────────────────────────────────
$script:ProjectRoot = Split-Path $PSScriptRoot -Parent
$script:ConfigDir   = Join-Path $script:ProjectRoot 'config'
$script:HostsFile   = Join-Path $script:ConfigDir 'winremote-hosts.json'
$script:VaultFile   = Join-Path $script:ConfigDir 'winremote-vault.json'
$script:LogDir      = Join-Path $script:ProjectRoot 'logs'

# ── DPAPI credential helpers (scoped to this script) ─────────────────────────
$script:_VaultDpapiPrefix = 'DPAPI:'

function Protect-WRCredential {
    param([string]$PlainText)
    if ([string]::IsNullOrEmpty($PlainText)) { return '' }
    try {
        $secure = ConvertTo-SecureString $PlainText -AsPlainText -Force
        return $script:_VaultDpapiPrefix + ($secure | ConvertFrom-SecureString)
    } catch { return $PlainText }
}

function Unprotect-WRCredential {
    param([string]$Stored)
    if ([string]::IsNullOrEmpty($Stored)) { return '' }
    if (-not $Stored.StartsWith($script:_VaultDpapiPrefix)) { return $Stored }
    try {
        $encrypted = $Stored.Substring($script:_VaultDpapiPrefix.Length)
        $secure = ConvertTo-SecureString $encrypted
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return '' }
}

function Load-WRVault {
    if (Test-Path $script:VaultFile) {
        try {
            $raw = Get-Content -Path $script:VaultFile -Raw -Encoding UTF8 -ErrorAction Stop
            return @($raw | ConvertFrom-Json)
        } catch { return @() }
    }
    return @()
}

function Save-WRVault {
    param([array]$Entries)
    if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
    $Entries | ConvertTo-Json -Depth 4 | Set-Content -Path $script:VaultFile -Encoding UTF8 -Force
}

# ── Host Config Persistence ──────────────────────────────────────────────────

function Load-RemoteHosts {
    if (Test-Path $script:HostsFile) {
        try {
            $json = Get-Content -Path $script:HostsFile -Raw -ErrorAction Stop | ConvertFrom-Json
            return @($json)
        } catch {
            return @()
        }
    }
    return @()
}

function Save-RemoteHosts {
    param([array]$Hosts)
    if (-not (Test-Path $script:ConfigDir)) {
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
    }
    $Hosts | ConvertTo-Json -Depth 4 | Set-Content -Path $script:HostsFile -Encoding UTF8 -Force
}

function New-HostEntry {
    param(
        [string]$Hostname,
        [string]$IPAddress,
        [string]$DeviceType = 'Unknown',
        [string]$Source     = 'Manual',
        [string]$Status     = 'Untested',
        [int]$WinRMPort     = 5985,
        [bool]$UseSSL       = $false,
        [string]$Notes      = ''
    )
    [pscustomobject]@{
        Hostname   = $Hostname
        IPAddress  = $IPAddress
        DeviceType = $DeviceType
        Source     = $Source
        Status     = $Status
        WinRMPort  = $WinRMPort
        UseSSL     = $UseSSL
        LastSeen   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Notes      = $Notes
    }
}

# ── Network Discovery ────────────────────────────────────────────────────────

function Get-LocalSubnet {
    <# Returns the primary IPv4 subnet in CIDR notation #>
    try {
        $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.InterfaceAlias -notmatch 'Loopback' } |
            Sort-Object { $_.InterfaceMetric } |
            Select-Object -First 1
        if ($adapters) {
            $ip = $adapters.IPAddress
            $prefix = $adapters.PrefixLength
            return @{ IP = $ip; Prefix = $prefix; Subnet = "$ip/$prefix" }
        }
    } catch { Write-Warning "[WinRemote] Get-LocalSubnet error: $_" }
    return $null
}

function Invoke-ARPDiscovery {
    <#
    .SYNOPSIS
        Active ARP discovery: pings the local /24 subnet to populate the ARP cache,
        then reads the cache so remote hosts that have never communicated with this
        machine are also returned.
    #>
    param([string]$BaseIP = '')

    # Resolve subnet to scan
    if (-not $BaseIP) {
        $subnetInfo = Get-LocalSubnet
        if ($subnetInfo) { $BaseIP = $subnetInfo.IP }
    }

    # Active ping sweep to populate ARP cache (fire-and-forget, short timeout)
    if ($BaseIP -and $BaseIP -match '^\d+\.\d+\.\d+\.\d+$') {
        $parts = $BaseIP -split '\.'
        if (@($parts).Count -ge 3) {
            $subnetPrefix = "$($parts[0]).$($parts[1]).$($parts[2])"
            $pool = [RunspaceFactory]::CreateRunspacePool(1, 64)
            $pool.Open()
            $sweepJobs = @()
            for ($i = 1; $i -le 254; $i++) {
                $target = "$subnetPrefix.$i"
                $ps = [PowerShell]::Create().AddScript({
                    param($ip)
                    try {
                        $p = New-Object System.Net.NetworkInformation.Ping
                        [void]$p.Send($ip, 150)
                    } catch { <# Intentional: non-fatal #> }
                }).AddArgument($target)
                $ps.RunspacePool = $pool
                $sweepJobs += @{ PS = $ps; Handle = $ps.BeginInvoke() }
            }
            foreach ($j in $sweepJobs) {
                try { [void]$j.PS.EndInvoke($j.Handle) } catch { <# Intentional: non-fatal #> }
                $j.PS.Dispose()
            }
            $pool.Close(); $pool.Dispose()
        }
    }

    # Read ARP cache (now populated by the sweep above)
    $hosts = @()
    try {
        $arpLines = & arp.exe -a 2>&1 | Where-Object { $_ -is [string] }
        foreach ($line in $arpLines) {
            # Windows arp.exe output: "  192.168.1.1           aa-bb-cc-dd-ee-ff     dynamic"
            if ($line -match '^\s{2,}(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2})\s+(\w+)') {
                $ipAddr = $Matches[1]
                $mac    = $Matches[2] -replace ':','-'
                $type   = $Matches[3].Trim()
                if ($type -eq 'dynamic' -and $ipAddr -ne '255.255.255.255' -and $ipAddr -notmatch '\.255$') {
                    $hosts += [pscustomobject]@{ IP = $ipAddr; MAC = $mac; Type = $type }
                }
            }
        }
    } catch { Write-Warning "[WinRemote] ARP cache read error: $_" }
    return $hosts
}

function Invoke-SubnetPingScan {
    <# Pings a /24 subnet range for live hosts. Returns array of responding IPs. #>
    param([string]$BaseIP)
    $parts = $BaseIP -split '\.'
    if ($parts.Count -lt 4) { return @() }
    $subnet = "$($parts[0]).$($parts[1]).$($parts[2])"
    $live = @()

    # Parallel ping using runspaces for speed
    $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, 50)
    $runspacePool.Open()
    $jobs = @()

    for ($i = 1; $i -le 254; $i++) {
        $target = "$subnet.$i"
        $ps = [PowerShell]::Create().AddScript({
            param($ip)
            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                $reply = $ping.Send($ip, 200)
                if ($reply.Status -eq 'Success') { return $ip }
            } catch { <# Intentional: non-fatal #> }
            return $null
        }).AddArgument($target)
        $ps.RunspacePool = $runspacePool
        $jobs += @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    foreach ($job in $jobs) {
        $result = $job.PS.EndInvoke($job.Handle)
        if ($result) { $live += $result }
        $job.PS.Dispose()
    }
    $runspacePool.Close()
    $runspacePool.Dispose()

    return $live
}

function Test-WinRMPort {
    <# Tests TCP connectivity to WinRM port #>
    param([string]$HostOrIP, [int]$Port = 5985, [int]$Timeout = 2000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $result = $tcp.BeginConnect($HostOrIP, $Port, $null, $null)
        $waited = $result.AsyncWaitHandle.WaitOne($Timeout, $false)
        if ($waited -and $tcp.Connected) {
            $tcp.Close()
            return $true
        }
        $tcp.Close()
    } catch { <# Intentional: non-fatal #> }
    return $false
}

function Resolve-HostnameFromIP {
    param([string]$IP)
    try {
        $entry = [System.Net.Dns]::GetHostEntry($IP)
        if ($entry.HostName) { return $entry.HostName }
    } catch { <# Intentional: non-fatal #> }
    return ''
}

function Detect-DeviceType {
    <# Heuristic device type detection based on hostname, MAC OUI, and services #>
    param([string]$Hostname, [string]$MAC, [string]$IP)

    $hn = ($Hostname).ToLowerInvariant()

    # UPS controllers (common OUI prefixes and hostname patterns)
    $upsOUIs = @('00:20:85','00:c0:b7','00:06:23','00:80:a3')
    $macNorm = ($MAC -replace '-',':').ToLowerInvariant()
    foreach ($oui in $upsOUIs) {
        if ($macNorm.StartsWith($oui)) { return 'UPS-Controller' }
    }
    if ($hn -match 'ups|apc|eaton|liebert|tripplite|cyberpower|powerware') { return 'UPS-Controller' }

    # Thin clients
    if ($hn -match 'thin|wyse|igel|hp\s*t[0-9]|tera|zeroClient|10zig') { return 'ThinClient' }

    # Servers
    if ($hn -match 'srv|server|dc\d|ad\d|sql|iis|exchange|hyper-v|hv\d|esxi|vcenter|nas|san') { return 'Server' }

    # Check if WinRM HTTPS (5986) is open - likely a server
    if (Test-WinRMPort -HostOrIP $IP -Port 5986 -Timeout 1000) { return 'Server' }

    return 'Laptop/Workstation'
}

# ── WinRM Configuration Helpers ──────────────────────────────────────────────

function Get-WinRMStatus {
    <# Returns a checklist-style status object for the local WinRM configuration #>
    $status = [ordered]@{}

    # Service state
    try {
        $svc = Get-Service WinRM -ErrorAction Stop
        $status['WinRM Service'] = @{ State = $svc.Status.ToString(); OK = ($svc.Status -eq 'Running') }
    } catch {
        $status['WinRM Service'] = @{ State = 'Not Found'; OK = $false }
    }

    # Listener
    try {
        $listeners = Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop
        $httpListener  = $listeners | Where-Object { $_.Keys -contains 'Transport=HTTP' }
        $httpsListener = $listeners | Where-Object { $_.Keys -contains 'Transport=HTTPS' }
        $status['HTTP Listener']  = @{ State = if ($httpListener) { 'Present' } else { 'Missing' }; OK = [bool]$httpListener }
        $status['HTTPS Listener'] = @{ State = if ($httpsListener) { 'Present (Preferred)' } else { 'Not configured' }; OK = [bool]$httpsListener }
    } catch {
        $status['WinRM Listeners'] = @{ State = 'Cannot query'; OK = $false }
    }

    # TrustedHosts
    try {
        $th = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
        $status['TrustedHosts'] = @{ State = if ($th) { $th } else { '(empty - Kerberos only)' }; OK = $true }
    } catch {
        $status['TrustedHosts'] = @{ State = 'Cannot query'; OK = $false }
    }

    # Authentication methods
    try {
        $authPath = 'WSMan:\localhost\Service\Auth'
        $kerberos = (Get-Item "$authPath\Kerberos" -ErrorAction SilentlyContinue).Value
        $negotiate = (Get-Item "$authPath\Negotiate" -ErrorAction SilentlyContinue).Value
        $basic     = (Get-Item "$authPath\Basic" -ErrorAction SilentlyContinue).Value
        $credSSP   = (Get-Item "$authPath\CredSSP" -ErrorAction SilentlyContinue).Value
        $status['Auth: Kerberos']  = @{ State = $kerberos;  OK = ($kerberos -eq 'true') }
        $status['Auth: Negotiate'] = @{ State = $negotiate; OK = ($negotiate -eq 'true') }
        $status['Auth: Basic']     = @{ State = $basic;     OK = ($basic -eq 'false') } # Basic should be OFF
        $status['Auth: CredSSP']   = @{ State = $credSSP;   OK = ($credSSP -eq 'false') } # CredSSP should be OFF
    } catch {
        $status['Authentication'] = @{ State = 'Cannot query'; OK = $false }
    }

    # Firewall rules
    try {
        $fwRules = Get-NetFirewallRule -Name 'WINRM*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -eq 'True' }
        $status['Firewall Rules'] = @{
            State = if ($fwRules) { "$($fwRules.Count) rule(s) enabled" } else { 'No WinRM rules' }
            OK = [bool]$fwRules
        }
    } catch {
        $status['Firewall Rules'] = @{ State = 'Cannot query'; OK = $false }
    }

    # Execution policy
    $ep = Get-ExecutionPolicy
    $status['Execution Policy'] = @{
        State = $ep.ToString()
        OK = ($ep -ne 'Restricted')
    }

    # PS Remoting test
    try {
        $session = New-PSSession -ComputerName localhost -ErrorAction Stop
        Remove-PSSession $session
        $status['Local PS Remoting'] = @{ State = 'Working'; OK = $true }
    } catch {
        $status['Local PS Remoting'] = @{ State = "Failed: $($_.Exception.Message)"; OK = $false }
    }

    return $status
}

function Get-RemotingChecklist {
    <# Returns an ordered array of checklist items for PS remoting readiness #>
    $items = @()

    # 1. WinRM service
    $svc = Get-Service WinRM -ErrorAction SilentlyContinue
    $items += [pscustomobject]@{
        Category = 'Service'
        Check    = 'WinRM service is running'
        Status   = if ($svc -and $svc.Status -eq 'Running') { 'PASS' } else { 'FAIL' }
        Detail   = if ($svc) { $svc.Status.ToString() } else { 'Service not found' }
        Fix      = 'Enable-PSRemoting -Force'
    }

    # 2. WinRM service startup
    $items += [pscustomobject]@{
        Category = 'Service'
        Check    = 'WinRM startup type is Automatic'
        Status   = if ($svc -and $svc.StartType -eq 'Automatic') { 'PASS' } else { 'WARN' }
        Detail   = if ($svc) { $svc.StartType.ToString() } else { 'N/A' }
        Fix      = 'Set-Service WinRM -StartupType Automatic'
    }

    # 3. Listeners
    $hasHTTP = $false; $hasHTTPS = $false
    try {
        $listeners = Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop
        $hasHTTP  = [bool]($listeners | Where-Object { $_.Keys -contains 'Transport=HTTP' })
        $hasHTTPS = [bool]($listeners | Where-Object { $_.Keys -contains 'Transport=HTTPS' })
    } catch { Write-Warning "[WinRemote] WSMan listener check error: $_" }

    $items += [pscustomobject]@{
        Category = 'Listener'
        Check    = 'HTTP listener exists (5985)'
        Status   = if ($hasHTTP) { 'PASS' } else { 'FAIL' }
        Detail   = if ($hasHTTP) { 'Present' } else { 'Missing' }
        Fix      = 'Enable-PSRemoting -Force'
    }
    $items += [pscustomobject]@{
        Category = 'Listener'
        Check    = 'HTTPS listener exists (5986)'
        Status   = if ($hasHTTPS) { 'PASS' } else { 'INFO' }
        Detail   = if ($hasHTTPS) { 'Present (recommended)' } else { 'Not configured (optional but recommended for security)' }
        Fix      = 'New-SelfSignedCertificate + New-Item WSMan:\localhost\Listener -Transport HTTPS'
    }

    # 4. Authentication
    try {
        $authPath = 'WSMan:\localhost\Service\Auth'
        $kerberos  = (Get-Item "$authPath\Kerberos" -ErrorAction SilentlyContinue).Value
        $negotiate = (Get-Item "$authPath\Negotiate" -ErrorAction SilentlyContinue).Value
        $basic     = (Get-Item "$authPath\Basic" -ErrorAction SilentlyContinue).Value
        $credSSP   = (Get-Item "$authPath\CredSSP" -ErrorAction SilentlyContinue).Value

        $items += [pscustomobject]@{
            Category = 'Auth'; Check = 'Kerberos enabled'
            Status   = if ($kerberos -eq 'true') { 'PASS' } else { 'WARN' }
            Detail   = $kerberos; Fix = 'Set-Item WSMan:\localhost\Service\Auth\Kerberos -Value $true'
        }
        $items += [pscustomobject]@{
            Category = 'Auth'; Check = 'Negotiate enabled'
            Status   = if ($negotiate -eq 'true') { 'PASS' } else { 'WARN' }
            Detail   = $negotiate; Fix = 'Set-Item WSMan:\localhost\Service\Auth\Negotiate -Value $true'
        }
        $items += [pscustomobject]@{
            Category = 'Auth'; Check = 'Basic auth DISABLED (security)'
            Status   = if ($basic -eq 'false') { 'PASS' } else { 'FAIL' }
            Detail   = "Basic=$basic"; Fix = 'Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false'
        }
        $items += [pscustomobject]@{
            Category = 'Auth'; Check = 'CredSSP DISABLED (security)'
            Status   = if ($credSSP -eq 'false') { 'PASS' } else { 'FAIL' }
            Detail   = "CredSSP=$credSSP"; Fix = 'Disable-WSManCredSSP -Role Server'
        }
    } catch {
        $items += [pscustomobject]@{
            Category = 'Auth'; Check = 'Authentication configuration'
            Status   = 'FAIL'; Detail = 'Cannot query WSMan auth settings'
            Fix      = 'Ensure WinRM is enabled first'
        }
    }

    # 5. Firewall
    try {
        $fwRules = Get-NetFirewallRule -Name 'WINRM*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -eq 'True' }
        $items += [pscustomobject]@{
            Category = 'Firewall'; Check = 'WinRM firewall rules exist'
            Status   = if ($fwRules) { 'PASS' } else { 'FAIL' }
            Detail   = if ($fwRules) { "$($fwRules.Count) rule(s)" } else { 'No rules' }
            Fix      = 'Enable-PSRemoting -Force (or New-NetFirewallRule for WinRM)'
        }
    } catch {
        $items += [pscustomobject]@{
            Category = 'Firewall'; Check = 'Firewall rule check'
            Status   = 'WARN'; Detail = 'Cannot query firewall'; Fix = 'Run as admin'
        }
    }

    # 6. TrustedHosts
    try {
        $th = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
        $items += [pscustomobject]@{
            Category = 'Trust'; Check = 'TrustedHosts configured'
            Status   = if ($th -and $th -ne '*') { 'PASS' } elseif ($th -eq '*') { 'WARN' } else { 'INFO' }
            Detail   = if ($th) { $th } else { 'Empty (Kerberos-only)' }
            Fix      = 'Set-Item WSMan:\localhost\Client\TrustedHosts -Value "host1,host2"'
        }
    } catch {
        $items += [pscustomobject]@{
            Category = 'Trust'; Check = 'TrustedHosts'; Status = 'FAIL'
            Detail   = 'Cannot query'; Fix = 'Enable WinRM first'
        }
    }

    # 7. Elevation
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    $items += [pscustomobject]@{
        Category = 'Elevation'; Check = 'Running as Administrator'
        Status   = if ($elevated) { 'PASS' } else { 'WARN' }
        Detail   = if ($elevated) { 'Elevated' } else { 'Standard user - some operations need elevation' }
        Fix      = 'Restart PowerShellGUI as Administrator'
    }

    # 8. Execution Policy
    $ep = Get-ExecutionPolicy
    $items += [pscustomobject]@{
        Category = 'Policy'; Check = 'ExecutionPolicy not Restricted'
        Status   = if ($ep -ne 'Restricted') { 'PASS' } else { 'FAIL' }
        Detail   = $ep.ToString()
        Fix      = 'Set-ExecutionPolicy RemoteSigned -Scope CurrentUser'
    }

    # 9. Network Profile
    try {
        $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
        $public = $profiles | Where-Object { $_.NetworkCategory -eq 'Public' }
        $items += [pscustomobject]@{
            Category = 'Network'; Check = 'Network profile is not Public'
            Status   = if ($public) { 'WARN' } else { 'PASS' }
            Detail   = ($profiles | ForEach-Object { "$($_.Name): $($_.NetworkCategory)" }) -join '; '
            Fix      = 'Set-NetConnectionProfile -InterfaceIndex <idx> -NetworkCategory Private'
        }
    } catch { Write-Warning "[WinRemote] Network profile check error: $_" }

    return $items
}

# ── Secure Baseline Definitions ──────────────────────────────────────────────

function Get-SecureBaseline {
    param([string]$DeviceType)

    $baselines = @{
        'Server' = @{
            Description     = 'Production server hardening'
            WinRMPort       = 5986
            UseSSL          = $true
            AllowedAuth     = @('Kerberos', 'Negotiate')
            DisabledAuth    = @('Basic', 'CredSSP')
            MaxConcurrent   = 25
            MaxMemoryMB     = 2048
            IdleTimeout     = 7200000
            TLSMinVersion   = '1.2'
            CertRequired    = $true
            ConstrainedMode = $false
            JEAEndpoint     = $true
            AuditLogon      = $true
            FirewallScope   = 'Domain,Private'
            Notes           = 'HTTPS-only; Kerberos preferred; JEA endpoints for least-privilege'
        }
        'Laptop/Workstation' = @{
            Description     = 'Managed workstation baseline'
            WinRMPort       = 5985
            UseSSL          = $false
            AllowedAuth     = @('Kerberos', 'Negotiate')
            DisabledAuth    = @('Basic', 'CredSSP')
            MaxConcurrent   = 5
            MaxMemoryMB     = 512
            IdleTimeout     = 3600000
            TLSMinVersion   = '1.2'
            CertRequired    = $false
            ConstrainedMode = $false
            JEAEndpoint     = $false
            AuditLogon      = $true
            FirewallScope   = 'Domain,Private'
            Notes           = 'HTTP acceptable on domain; restrict to Domain/Private profiles'
        }
        'ThinClient' = @{
            Description     = 'Thin client / kiosk hardening'
            WinRMPort       = 5985
            UseSSL          = $false
            AllowedAuth     = @('Kerberos')
            DisabledAuth    = @('Basic', 'CredSSP', 'Negotiate')
            MaxConcurrent   = 2
            MaxMemoryMB     = 128
            IdleTimeout     = 1800000
            TLSMinVersion   = '1.2'
            CertRequired    = $false
            ConstrainedMode = $true
            JEAEndpoint     = $true
            AuditLogon      = $true
            FirewallScope   = 'Domain'
            Notes           = 'Kerberos only; Constrained Language Mode; JEA for maintenance'
        }
        'UPS-Controller' = @{
            Description     = 'UPS / Network PDU management'
            WinRMPort       = 5985
            UseSSL          = $false
            AllowedAuth     = @('Negotiate')
            DisabledAuth    = @('Basic', 'CredSSP', 'Kerberos')
            MaxConcurrent   = 1
            MaxMemoryMB     = 64
            IdleTimeout     = 900000
            TLSMinVersion   = '1.2'
            CertRequired    = $false
            ConstrainedMode = $true
            JEAEndpoint     = $true
            AuditLogon      = $true
            FirewallScope   = 'Domain'
            Notes           = 'Minimal sessions; read-only JEA endpoint; 15min idle timeout'
        }
    }

    if ($baselines.ContainsKey($DeviceType)) {
        return $baselines[$DeviceType]
    }
    return $baselines['Laptop/Workstation']
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN GUI
# ══════════════════════════════════════════════════════════════════════════════

function Show-WinRemotePSTool {
    [CmdletBinding()]
    param()

    $script:hosts = @(Load-RemoteHosts)

    # ── Form ──────────────────────────────────────────────────────────────────
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'WinRemote PS Tool - Remote Management Console'
    $form.Size            = New-Object System.Drawing.Size(1100, 780)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.MinimumSize     = New-Object System.Drawing.Size(950, 650)
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White

    $statusBar = New-Object System.Windows.Forms.StatusStrip
    $statusBar.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = 'Ready'
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 220, 255)
    $statusBar.Items.Add($statusLabel) | Out-Null
    $form.Controls.Add($statusBar)

    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = 'Fill'
    $tabControl.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)

    # ══════════════════════════════════════════════════════════════════════════
    #  TAB 1 - DISCOVERY & HOSTS
    # ══════════════════════════════════════════════════════════════════════════
    $tabDiscovery = New-Object System.Windows.Forms.TabPage
    $tabDiscovery.Text = 'Discovery && Hosts'
    $tabDiscovery.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)

    # Top panel with buttons
    $pnlDiscTop = New-Object System.Windows.Forms.Panel
    $pnlDiscTop.Dock = 'Top'
    $pnlDiscTop.Height = 116
    $pnlDiscTop.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)

    $btnARPScan = New-Object System.Windows.Forms.Button
    $btnARPScan.Text = 'ARP Scan'; $btnARPScan.Location = [System.Drawing.Point]::new(8, 8)
    $btnARPScan.Size = [System.Drawing.Size]::new(100, 28)
    $btnARPScan.FlatStyle = 'Flat'; $btnARPScan.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnARPScan.ForeColor = [System.Drawing.Color]::White

    $btnPingScan = New-Object System.Windows.Forms.Button
    $btnPingScan.Text = 'Ping Scan /24'; $btnPingScan.Location = [System.Drawing.Point]::new(116, 8)
    $btnPingScan.Size = [System.Drawing.Size]::new(110, 28)
    $btnPingScan.FlatStyle = 'Flat'; $btnPingScan.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnPingScan.ForeColor = [System.Drawing.Color]::White

    $btnTestWinRM = New-Object System.Windows.Forms.Button
    $btnTestWinRM.Text = 'Test WinRM'; $btnTestWinRM.Location = [System.Drawing.Point]::new(234, 8)
    $btnTestWinRM.Size = [System.Drawing.Size]::new(100, 28)
    $btnTestWinRM.FlatStyle = 'Flat'; $btnTestWinRM.BackColor = [System.Drawing.Color]::FromArgb(60, 150, 60)
    $btnTestWinRM.ForeColor = [System.Drawing.Color]::White

    $btnConnect = New-Object System.Windows.Forms.Button
    $btnConnect.Text = 'Connect'; $btnConnect.Location = [System.Drawing.Point]::new(342, 8)
    $btnConnect.Size = [System.Drawing.Size]::new(90, 28)
    $btnConnect.FlatStyle = 'Flat'; $btnConnect.BackColor = [System.Drawing.Color]::FromArgb(180, 120, 0)
    $btnConnect.ForeColor = [System.Drawing.Color]::White

    $btnSaveHosts = New-Object System.Windows.Forms.Button
    $btnSaveHosts.Text = 'Save Hosts'; $btnSaveHosts.Location = [System.Drawing.Point]::new(440, 8)
    $btnSaveHosts.Size = [System.Drawing.Size]::new(95, 28)
    $btnSaveHosts.FlatStyle = 'Flat'; $btnSaveHosts.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $btnSaveHosts.ForeColor = [System.Drawing.Color]::White

    $btnRestoreHosts = New-Object System.Windows.Forms.Button
    $btnRestoreHosts.Text = 'Restore Hosts'; $btnRestoreHosts.Location = [System.Drawing.Point]::new(543, 8)
    $btnRestoreHosts.Size = [System.Drawing.Size]::new(105, 28)
    $btnRestoreHosts.FlatStyle = 'Flat'; $btnRestoreHosts.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $btnRestoreHosts.ForeColor = [System.Drawing.Color]::White

    $btnRemoveHost = New-Object System.Windows.Forms.Button
    $btnRemoveHost.Text = 'Remove Selected'; $btnRemoveHost.Location = [System.Drawing.Point]::new(656, 8)
    $btnRemoveHost.Size = [System.Drawing.Size]::new(120, 28)
    $btnRemoveHost.FlatStyle = 'Flat'; $btnRemoveHost.BackColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
    $btnRemoveHost.ForeColor = [System.Drawing.Color]::White

    # Manual connect row
    $lblManual = New-Object System.Windows.Forms.Label
    $lblManual.Text = 'Manual Host/IP:'; $lblManual.Location = [System.Drawing.Point]::new(8, 46)
    $lblManual.Size = [System.Drawing.Size]::new(100, 22); $lblManual.ForeColor = [System.Drawing.Color]::White

    $txtManualHost = New-Object System.Windows.Forms.TextBox
    $txtManualHost.Location = [System.Drawing.Point]::new(112, 44)
    $txtManualHost.Size = [System.Drawing.Size]::new(200, 22)
    $txtManualHost.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtManualHost.ForeColor = [System.Drawing.Color]::White

    $cboDeviceType = New-Object System.Windows.Forms.ComboBox
    $cboDeviceType.Location = [System.Drawing.Point]::new(320, 44)
    $cboDeviceType.Size = [System.Drawing.Size]::new(140, 22)
    $cboDeviceType.DropDownStyle = 'DropDownList'
    $cboDeviceType.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $cboDeviceType.ForeColor = [System.Drawing.Color]::White
    @('Auto-Detect','Server','Laptop/Workstation','ThinClient','UPS-Controller') | ForEach-Object {
        $cboDeviceType.Items.Add($_) | Out-Null
    }
    $cboDeviceType.SelectedIndex = 0

    $btnAddManual = New-Object System.Windows.Forms.Button
    $btnAddManual.Text = 'Add Host'; $btnAddManual.Location = [System.Drawing.Point]::new(468, 42)
    $btnAddManual.Size = [System.Drawing.Size]::new(90, 28)
    $btnAddManual.FlatStyle = 'Flat'; $btnAddManual.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnAddManual.ForeColor = [System.Drawing.Color]::White

    $chkSSL = New-Object System.Windows.Forms.CheckBox
    $chkSSL.Text = 'Use HTTPS (5986)'; $chkSSL.Location = [System.Drawing.Point]::new(566, 46)
    $chkSSL.Size = [System.Drawing.Size]::new(145, 22); $chkSSL.ForeColor = [System.Drawing.Color]::White

    # ── Row 3: Subnet / Port / WinRM Status LED ───────────────────────────────
    $lblSubnetScan = New-Object System.Windows.Forms.Label
    $lblSubnetScan.Text = 'Subnet:'; $lblSubnetScan.Location = [System.Drawing.Point]::new(8, 88)
    $lblSubnetScan.Size = [System.Drawing.Size]::new(52, 22); $lblSubnetScan.ForeColor = [System.Drawing.Color]::White

    $txtSubnet = New-Object System.Windows.Forms.TextBox
    $txtSubnet.Location = [System.Drawing.Point]::new(62, 86)
    $txtSubnet.Size = [System.Drawing.Size]::new(150, 22)
    $txtSubnet.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtSubnet.ForeColor = [System.Drawing.Color]::White
    $txtSubnet.PlaceholderText = 'e.g. 192.168.1.0'
    # Auto-detect local subnet
    $detectedSubnet = Get-LocalSubnet
    if ($detectedSubnet) { $txtSubnet.Text = "$($detectedSubnet.IP.Substring(0, $detectedSubnet.IP.LastIndexOf('.'))).0" }

    $btnDetectSubnet = New-Object System.Windows.Forms.Button
    $btnDetectSubnet.Text = 'Auto'; $btnDetectSubnet.Location = [System.Drawing.Point]::new(220, 84)
    $btnDetectSubnet.Size = [System.Drawing.Size]::new(56, 24)
    $btnDetectSubnet.FlatStyle = 'Flat'; $btnDetectSubnet.BackColor = [System.Drawing.Color]::FromArgb(60, 80, 60)
    $btnDetectSubnet.ForeColor = [System.Drawing.Color]::White

    $lblPortSelect = New-Object System.Windows.Forms.Label
    $lblPortSelect.Text = 'WinRM Port:'; $lblPortSelect.Location = [System.Drawing.Point]::new(284, 88)
    $lblPortSelect.Size = [System.Drawing.Size]::new(78, 22); $lblPortSelect.ForeColor = [System.Drawing.Color]::White

    $cboPort = New-Object System.Windows.Forms.ComboBox
    $cboPort.Location = [System.Drawing.Point]::new(364, 84)
    $cboPort.Size = [System.Drawing.Size]::new(140, 22)
    $cboPort.DropDownStyle = 'DropDownList'
    $cboPort.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $cboPort.ForeColor = [System.Drawing.Color]::White
    @('HTTP - 5985', 'HTTPS - 5986', 'Custom...') | ForEach-Object { $cboPort.Items.Add($_) | Out-Null }
    $cboPort.SelectedIndex = 0

    $txtCustomPort = New-Object System.Windows.Forms.TextBox
    $txtCustomPort.Location = [System.Drawing.Point]::new(512, 84)
    $txtCustomPort.Size = [System.Drawing.Size]::new(55, 22)
    $txtCustomPort.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtCustomPort.ForeColor = [System.Drawing.Color]::White
    $txtCustomPort.Text = '5985'; $txtCustomPort.Visible = $false
    $txtCustomPort.MaxLength = 5

    $lblWinRMLED = New-Object System.Windows.Forms.Label
    $lblWinRMLED.Text = 'WinRM: Checking...'; $lblWinRMLED.Location = [System.Drawing.Point]::new(576, 84)
    $lblWinRMLED.Size = [System.Drawing.Size]::new(160, 24)
    $lblWinRMLED.TextAlign = 'MiddleCenter'
    $lblWinRMLED.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblWinRMLED.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $lblWinRMLED.ForeColor = [System.Drawing.Color]::White

    $pnlDiscTop.Controls.AddRange(@(
        $btnARPScan, $btnPingScan, $btnTestWinRM, $btnConnect,
        $btnSaveHosts, $btnRestoreHosts, $btnRemoveHost,
        $lblManual, $txtManualHost, $cboDeviceType, $btnAddManual, $chkSSL,
        $lblSubnetScan, $txtSubnet, $btnDetectSubnet,
        $lblPortSelect, $cboPort, $txtCustomPort, $lblWinRMLED
    ))

    # Hosts DataGridView
    $dgvHosts = New-Object System.Windows.Forms.DataGridView
    $dgvHosts.Dock = 'Fill'
    $dgvHosts.ReadOnly = $true
    $dgvHosts.AllowUserToAddRows = $false
    $dgvHosts.AutoSizeColumnsMode = 'Fill'
    $dgvHosts.SelectionMode = 'FullRowSelect'
    $dgvHosts.RowHeadersVisible = $false
    $dgvHosts.BackgroundColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $dgvHosts.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $dgvHosts.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgvHosts.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $dgvHosts.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $dgvHosts.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgvHosts.EnableHeadersVisualStyles = $false
    $dgvHosts.GridColor = [System.Drawing.Color]::FromArgb(60, 60, 60)

    @(
        @{ Name='Hostname';   Width=160 },
        @{ Name='IPAddress';  Width=120 },
        @{ Name='DeviceType'; Width=120 },
        @{ Name='Source';     Width=80  },
        @{ Name='Status';     Width=90  },
        @{ Name='WinRMPort';  Width=70  },
        @{ Name='UseSSL';     Width=55  },
        @{ Name='LastSeen';   Width=140 },
        @{ Name='Notes';      Width=180 }
    ) | ForEach-Object {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $_.Name; $col.Name = $_.Name
        $col.MinimumWidth = [Math]::Min($_.Width, 50)
        $dgvHosts.Columns.Add($col) | Out-Null
    }

    $tabDiscovery.Controls.Add($dgvHosts)
    $tabDiscovery.Controls.Add($pnlDiscTop)

    # ── Populate grid helper ──────────────────────────────────────────────────
    $refreshHostGrid = {
        $dgvHosts.Rows.Clear()
        foreach ($h in $script:hosts) {
            $dgvHosts.Rows.Add(
                $h.Hostname, $h.IPAddress, $h.DeviceType, $h.Source,
                $h.Status, $h.WinRMPort, $h.UseSSL, $h.LastSeen, $h.Notes
            ) | Out-Null
        }
        $statusLabel.Text = "$($script:hosts.Count) host(s) loaded"
    }

    # Color-code status cells
    $dgvHosts.Add_CellFormatting({
        param($s, $e)
        if ($e.ColumnIndex -eq 4 -and $null -ne $e.Value) {
            switch ($e.Value.ToString()) {
                'WinRM-OK'  { $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(100, 255, 100) }
                'Reachable' { $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(180, 220, 100) }
                'Offline'   { $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 80) }
                'Untested'  { $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180) }
            }
        }
    })

    # Initial populate
    & $refreshHostGrid

    # ── WinRM Status LED updater ──────────────────────────────────────────────
    $updateWinRMLED = {
        try {
            $svc = Get-Service WinRM -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                $lblWinRMLED.BackColor = [System.Drawing.Color]::FromArgb(40, 160, 40)
                $lblWinRMLED.Text = 'WinRM: Running'
            } else {
                $lblWinRMLED.BackColor = [System.Drawing.Color]::FromArgb(180, 30, 30)
                $lblWinRMLED.Text = 'WinRM: Stopped'
            }
        } catch {
            $lblWinRMLED.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
            $lblWinRMLED.Text = 'WinRM: Unknown'
        }
    }

    # ── Port/SSL sync ─────────────────────────────────────────────────────────
    $cboPort.Add_SelectedIndexChanged({
        switch ($cboPort.SelectedIndex) {
            0 { $chkSSL.Checked = $false; $txtCustomPort.Visible = $false }
            1 { $chkSSL.Checked = $true;  $txtCustomPort.Visible = $false }
            2 { $txtCustomPort.Visible = $true }
        }
        & $updateWinRMLED
    })

    $chkSSL.Add_CheckedChanged({
        if ($chkSSL.Checked -and $cboPort.SelectedIndex -ne 1) {
            $cboPort.SelectedIndex = 1
        } elseif (-not $chkSSL.Checked -and $cboPort.SelectedIndex -eq 1) {
            $cboPort.SelectedIndex = 0
        }
    })

    $btnDetectSubnet.Add_Click({
        $det = Get-LocalSubnet
        if ($det) {
            $octets = $det.IP -split '\.'
            $txtSubnet.Text = "$($octets[0]).$($octets[1]).$($octets[2]).0"  # SIN-EXEMPT: P027 - split result guarded by if/truthy check on same line
            $statusLabel.Text = "Detected subnet: $($txtSubnet.Text)/$($det.Prefix)"
        } else {
            [System.Windows.Forms.MessageBox]::Show('Cannot detect local subnet.', 'Auto-Detect',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })

    # ── ARP Scan ──────────────────────────────────────────────────────────────
    $btnARPScan.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $statusLabel.Text = 'ARP scan: pinging subnet to populate cache, please wait...'
        $form.Refresh()
        try {
            $baseIP = if ($txtSubnet.Text.Trim()) { $txtSubnet.Text.Trim() } else { $null }
            $arpHosts = Invoke-ARPDiscovery -BaseIP $baseIP
            $added = 0
            foreach ($ah in $arpHosts) {
                $exists = $script:hosts | Where-Object { $_.IPAddress -eq $ah.IP }
                if (-not $exists) {
                    $hn = Resolve-HostnameFromIP -IP $ah.IP
                    $dtype = Detect-DeviceType -Hostname $hn -MAC $ah.MAC -IP $ah.IP
                    $script:hosts += New-HostEntry -Hostname (if ($hn) { $hn } else { $ah.IP }) `
                        -IPAddress $ah.IP -DeviceType $dtype -Source 'ARP-Scan'
                    $added++
                }
            }
            & $refreshHostGrid
            $statusLabel.Text = "ARP scan complete: $($arpHosts.Count) found, $added new"
        } catch {
            $statusLabel.Text = "ARP scan error: $($_.Exception.Message)"
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    # ── Ping Scan ─────────────────────────────────────────────────────────────
    $btnPingScan.Add_Click({
        $subnetBase = $txtSubnet.Text.Trim()
        if (-not $subnetBase) {
            $subnet = Get-LocalSubnet
            if (-not $subnet) {
                [System.Windows.Forms.MessageBox]::Show('Cannot determine local subnet. Enter it in the Subnet field.', 'Error',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            $subnetBase = $subnet.IP
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $statusLabel.Text = "Ping scanning $subnetBase /24..."
        $form.Refresh()
        try {
            $liveIPs = Invoke-SubnetPingScan -BaseIP $subnetBase
            $added = 0
            foreach ($ip in $liveIPs) {
                $exists = $script:hosts | Where-Object { $_.IPAddress -eq $ip }
                if (-not $exists) {
                    $hn = Resolve-HostnameFromIP -IP $ip
                    $dtype = Detect-DeviceType -Hostname $hn -MAC '' -IP $ip
                    $script:hosts += New-HostEntry -Hostname (if ($hn) { $hn } else { $ip }) `
                        -IPAddress $ip -DeviceType $dtype -Source 'Ping-Scan'
                    $added++
                }
            }
            & $refreshHostGrid
            $statusLabel.Text = "Ping scan complete: $(@($liveIPs).Count) alive, $added new"
        } catch {
            $statusLabel.Text = "Ping scan error: $($_.Exception.Message)"
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    # ── Test WinRM on selected hosts ──────────────────────────────────────────
    $btnTestWinRM.Add_Click({
        if ($dgvHosts.SelectedRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select one or more hosts to test.', 'WinRM Test',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $statusLabel.Text = 'Testing WinRM connectivity...'
        $form.Refresh()
        foreach ($row in $dgvHosts.SelectedRows) {
            $idx = $row.Index
            if ($idx -ge $script:hosts.Count) { continue }
            $h = $script:hosts[$idx]
            # Prefer port from row's stored value; fall back to UI combobox selection
            $port = if ($h.WinRMPort -and $h.WinRMPort -gt 0) { [int]$h.WinRMPort } else {
                switch ($cboPort.SelectedIndex) {
                    0 { 5985 }; 1 { 5986 }
                    default { if ($txtCustomPort.Text -match '^\d+$') { [int]$txtCustomPort.Text } else { 5985 } }
                }
            }
            $ip = if ($h.IPAddress) { $h.IPAddress } else { $h.Hostname }
            $ok = Test-WinRMPort -HostOrIP $ip -Port $port
            $script:hosts[$idx].Status = if ($ok) { 'WinRM-OK' } else { 'Offline' }
            $script:hosts[$idx].LastSeen = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        }
        & $refreshHostGrid
        & $updateWinRMLED
        $statusLabel.Text = 'WinRM test complete'
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    # ── Connect (PS Session) ──────────────────────────────────────────────────
    $btnConnect.Add_Click({
        if ($dgvHosts.SelectedRows.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one host to connect.', 'Connect',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $idx = $dgvHosts.SelectedRows[0].Index
        if ($idx -ge $script:hosts.Count) { return }
        $h = $script:hosts[$idx]
        $target = if ($h.IPAddress) { $h.IPAddress } else { $h.Hostname }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Open interactive PS remoting session to:`n`n  $($h.Hostname) ($target)`n  Port: $($h.WinRMPort)  SSL: $($h.UseSSL)`n`nThis will open a new PowerShell window.",
            'Connect to Remote Host',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne 'Yes') { return }

        $shellExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        $sslFlag = if ($h.UseSSL) { ' -UseSSL' } else { '' }
        $portFlag = if ($h.WinRMPort -and $h.WinRMPort -ne 5985) { " -Port $($h.WinRMPort)" } else { '' }
        $cmd = "Enter-PSSession -ComputerName '$target'$sslFlag$portFlag"
        Start-Process $shellExe -ArgumentList "-NoProfile -NoExit -Command `"$cmd`""
        $statusLabel.Text = "Session opened to $target"
    })

    # ── Add Manual Host ───────────────────────────────────────────────────────
    $btnAddManual.Add_Click({
        $hostInput = $txtManualHost.Text.Trim()
        if (-not $hostInput) {
            [System.Windows.Forms.MessageBox]::Show('Enter a hostname or IP address.', 'Add Host',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        # Resolve IP if hostname given
        $ip = ''; $hn = $hostInput
        if ($hostInput -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            $ip = $hostInput
            $hn = Resolve-HostnameFromIP -IP $ip
            if (-not $hn) { $hn = $ip }
        } else {
            try {
                $resolved = [System.Net.Dns]::GetHostAddresses($hostInput) |
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                    Select-Object -First 1
                if ($resolved) { $ip = $resolved.ToString() }
            } catch { <# Intentional: non-fatal #> }
        }

        $dtype = $cboDeviceType.SelectedItem.ToString()
        if ($dtype -eq 'Auto-Detect') {
            $dtype = Detect-DeviceType -Hostname $hn -MAC '' -IP $ip
        }

        $port = switch ($cboPort.SelectedIndex) {
            0 { 5985 }; 1 { 5986 }
            default { if ($txtCustomPort.Text -match '^\d+$') { [int]$txtCustomPort.Text } else { 5985 } }
        }
        $exists = $script:hosts | Where-Object { $_.IPAddress -eq $ip -or $_.Hostname -eq $hn }
        if ($exists) {
            [System.Windows.Forms.MessageBox]::Show("Host already in list: $hn ($ip)", 'Duplicate',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $script:hosts += New-HostEntry -Hostname $hn -IPAddress $ip -DeviceType $dtype `
            -Source 'Manual' -WinRMPort $port -UseSSL $chkSSL.Checked
        $txtManualHost.Text = ''
        & $refreshHostGrid
        $statusLabel.Text = "Added host: $hn"
    })

    # ── Save / Restore / Remove ───────────────────────────────────────────────
    $btnSaveHosts.Add_Click({
        Save-RemoteHosts -Hosts $script:hosts
        $statusLabel.Text = "Saved $($script:hosts.Count) host(s) to config"
        [System.Windows.Forms.MessageBox]::Show(
            "Saved $($script:hosts.Count) host(s) to:`n$($script:HostsFile)",
            'Hosts Saved', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information)
    })

    $btnRestoreHosts.Add_Click({
        $loaded = @(Load-RemoteHosts)
        if ($loaded.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No saved hosts found.', 'Restore',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $script:hosts = $loaded
        & $refreshHostGrid
        $statusLabel.Text = "Restored $($loaded.Count) host(s) from config"
    })

    $btnRemoveHost.Add_Click({
        if ($dgvHosts.SelectedRows.Count -eq 0) { return }
        $indices = @($dgvHosts.SelectedRows | ForEach-Object { $_.Index }) | Sort-Object -Descending
        foreach ($idx in $indices) {
            if ($idx -lt $script:hosts.Count) {
                $script:hosts = @($script:hosts | Where-Object { $_ -ne $script:hosts[$idx] })
            }
        }
        & $refreshHostGrid
    })

    # ══════════════════════════════════════════════════════════════════════════
    #  TAB 2 - WINRM CONFIGURATION
    # ══════════════════════════════════════════════════════════════════════════
    $tabWinRM = New-Object System.Windows.Forms.TabPage
    $tabWinRM.Text = 'WinRM Configuration'
    $tabWinRM.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)

    $pnlWinRMTop = New-Object System.Windows.Forms.Panel
    $pnlWinRMTop.Dock = 'Top'; $pnlWinRMTop.Height = 42
    $pnlWinRMTop.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)

    $btnRefreshWinRM = New-Object System.Windows.Forms.Button
    $btnRefreshWinRM.Text = 'Refresh Status'; $btnRefreshWinRM.Location = [System.Drawing.Point]::new(8, 8)
    $btnRefreshWinRM.Size = [System.Drawing.Size]::new(120, 28)
    $btnRefreshWinRM.FlatStyle = 'Flat'; $btnRefreshWinRM.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnRefreshWinRM.ForeColor = [System.Drawing.Color]::White

    $btnEnableRemoting = New-Object System.Windows.Forms.Button
    $btnEnableRemoting.Text = 'Enable PS Remoting'; $btnEnableRemoting.Location = [System.Drawing.Point]::new(136, 8)
    $btnEnableRemoting.Size = [System.Drawing.Size]::new(140, 28)
    $btnEnableRemoting.FlatStyle = 'Flat'; $btnEnableRemoting.BackColor = [System.Drawing.Color]::FromArgb(60, 150, 60)
    $btnEnableRemoting.ForeColor = [System.Drawing.Color]::White

    $btnSetTrusted = New-Object System.Windows.Forms.Button
    $btnSetTrusted.Text = 'Set TrustedHosts'; $btnSetTrusted.Location = [System.Drawing.Point]::new(284, 8)
    $btnSetTrusted.Size = [System.Drawing.Size]::new(130, 28)
    $btnSetTrusted.FlatStyle = 'Flat'; $btnSetTrusted.BackColor = [System.Drawing.Color]::FromArgb(180, 120, 0)
    $btnSetTrusted.ForeColor = [System.Drawing.Color]::White

    $btnHardenAuth = New-Object System.Windows.Forms.Button
    $btnHardenAuth.Text = 'Harden Auth'; $btnHardenAuth.Location = [System.Drawing.Point]::new(422, 8)
    $btnHardenAuth.Size = [System.Drawing.Size]::new(110, 28)
    $btnHardenAuth.FlatStyle = 'Flat'; $btnHardenAuth.BackColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
    $btnHardenAuth.ForeColor = [System.Drawing.Color]::White

    $btnStartWinRMSvc = New-Object System.Windows.Forms.Button
    $btnStartWinRMSvc.Text = 'Start Service (Admin)'; $btnStartWinRMSvc.Location = [System.Drawing.Point]::new(540, 8)
    $btnStartWinRMSvc.Size = [System.Drawing.Size]::new(145, 28)
    $btnStartWinRMSvc.FlatStyle = 'Flat'; $btnStartWinRMSvc.BackColor = [System.Drawing.Color]::FromArgb(100, 60, 160)
    $btnStartWinRMSvc.ForeColor = [System.Drawing.Color]::White
    $btnStartWinRMSvc.ToolTipText = 'Set WinRM to Automatic startup and start the service (requires elevation)'

    $pnlWinRMTop.Controls.AddRange(@($btnRefreshWinRM, $btnEnableRemoting, $btnSetTrusted, $btnHardenAuth, $btnStartWinRMSvc))

    $dgvWinRM = New-Object System.Windows.Forms.DataGridView
    $dgvWinRM.Dock = 'Fill'
    $dgvWinRM.ReadOnly = $true
    $dgvWinRM.AllowUserToAddRows = $false
    $dgvWinRM.AutoSizeColumnsMode = 'Fill'
    $dgvWinRM.RowHeadersVisible = $false
    $dgvWinRM.BackgroundColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $dgvWinRM.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $dgvWinRM.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgvWinRM.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $dgvWinRM.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $dgvWinRM.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgvWinRM.EnableHeadersVisualStyles = $false
    $dgvWinRM.GridColor = [System.Drawing.Color]::FromArgb(60, 60, 60)

    @('Setting','Value','Status') | ForEach-Object {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $_; $col.Name = $_
        $dgvWinRM.Columns.Add($col) | Out-Null
    }

    # Color code status column
    $dgvWinRM.Add_CellFormatting({
        param($s, $e)
        if ($e.ColumnIndex -eq 2 -and $null -ne $e.Value) {
            $val = $e.Value.ToString()
            if ($val -match 'OK|PASS|True|Running|Present|Elevated') {
                $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(100, 255, 100)
            } elseif ($val -match 'FAIL|Missing|Not Found|false') {
                $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 80)
            } else {
                $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 80)
            }
        }
    })

    $refreshWinRM = {
        $dgvWinRM.Rows.Clear()
        $status = Get-WinRMStatus
        foreach ($key in $status.Keys) {
            $s = $status[$key]
            $st = if ($s.OK) { 'OK' } else { 'ISSUE' }
            $dgvWinRM.Rows.Add($key, $s.State, $st) | Out-Null
        }
        $statusLabel.Text = 'WinRM status refreshed'
    }

    $tabWinRM.Controls.Add($dgvWinRM)
    $tabWinRM.Controls.Add($pnlWinRMTop)

    # ── WinRM Button Events ───────────────────────────────────────────────────
    $btnRefreshWinRM.Add_Click({ & $refreshWinRM })

    $btnEnableRemoting.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This will run Enable-PSRemoting -Force which:`n`n" +
            "  - Starts WinRM service (set to Automatic)`n  - Creates HTTP listener on 5985`n" +
            "  - Configures firewall exceptions`n  - Sets LocalAccountTokenFilterPolicy`n`n" +
            "Requires Administrator privileges. Proceed?",
            'Enable PS Remoting', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Shield)
        if ($confirm -ne 'Yes') { return }

        $shellExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        Start-Process $shellExe -Verb RunAs -ArgumentList "-NoProfile -Command `"Enable-PSRemoting -Force; Write-Host 'Done - press Enter'; Read-Host`""
        $statusLabel.Text = 'Enable-PSRemoting launched (elevated)'
    })

    $btnSetTrusted.Add_Click({
        $currentHosts = ($script:hosts | Where-Object { $_.Hostname -and $_.Hostname -ne '' } |
            ForEach-Object { $_.Hostname }) -join ','
        if (-not $currentHosts) { $currentHosts = '' }

        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'Set TrustedHosts Allow-List'; $dlg.Size = [System.Drawing.Size]::new(520, 220)
        $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
        $dlg.ForeColor = [System.Drawing.Color]::White

        $lblInfo = New-Object System.Windows.Forms.Label
        $lblInfo.Text = "Comma-separated list of trusted hosts for WinRM.`nUse hostnames or IPs. Avoid using * (wildcard)."
        $lblInfo.Location = [System.Drawing.Point]::new(12, 12); $lblInfo.Size = [System.Drawing.Size]::new(490, 40)

        $txtTrusted = New-Object System.Windows.Forms.TextBox
        $txtTrusted.Location = [System.Drawing.Point]::new(12, 58); $txtTrusted.Size = [System.Drawing.Size]::new(490, 24)
        $txtTrusted.Text = $currentHosts
        $txtTrusted.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
        $txtTrusted.ForeColor = [System.Drawing.Color]::White

        $chkFromList = New-Object System.Windows.Forms.CheckBox
        $chkFromList.Text = 'Populate from current host list'; $chkFromList.Location = [System.Drawing.Point]::new(12, 90)
        $chkFromList.Size = [System.Drawing.Size]::new(250, 22); $chkFromList.Checked = $true
        $chkFromList.ForeColor = [System.Drawing.Color]::White

        $btnOK = New-Object System.Windows.Forms.Button
        $btnOK.Text = 'Apply'; $btnOK.DialogResult = 'OK'
        $btnOK.Location = [System.Drawing.Point]::new(340, 140); $btnOK.Size = [System.Drawing.Size]::new(75, 28)
        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = 'Cancel'; $btnCancel.DialogResult = 'Cancel'
        $btnCancel.Location = [System.Drawing.Point]::new(425, 140); $btnCancel.Size = [System.Drawing.Size]::new(75, 28)

        $dlg.Controls.AddRange(@($lblInfo, $txtTrusted, $chkFromList, $btnOK, $btnCancel))
        $dlg.AcceptButton = $btnOK; $dlg.CancelButton = $btnCancel

        if ($dlg.ShowDialog() -eq 'OK') {
            $value = $txtTrusted.Text.Trim()
            if ($value -eq '*') {
                $warnResult = [System.Windows.Forms.MessageBox]::Show(
                    "Wildcard (*) trusts ALL hosts. This is a security risk.`nAre you sure?",
                    'Security Warning', [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($warnResult -ne 'Yes') { $dlg.Dispose(); return }
            }
            try {
                Set-Item WSMan:\localhost\Client\TrustedHosts -Value $value -Force
                $statusLabel.Text = "TrustedHosts set to: $value"
            } catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to set TrustedHosts (admin required):`n$($_.Exception.Message)",
                    'Error', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error)
            }
        }
        $dlg.Dispose()
    })

    $btnHardenAuth.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This will harden WinRM authentication:`n`n" +
            "  [+] Enable Kerberos`n  [+] Enable Negotiate`n" +
            "  [-] Disable Basic (plaintext)`n  [-] Disable CredSSP (delegation risk)`n`n" +
            "Requires Administrator. Proceed?",
            'Harden Authentication', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Shield)
        if ($confirm -ne 'Yes') { return }

        $cmds = @(
            "Set-Item WSMan:\localhost\Service\Auth\Kerberos -Value `$true",
            "Set-Item WSMan:\localhost\Service\Auth\Negotiate -Value `$true",
            "Set-Item WSMan:\localhost\Service\Auth\Basic -Value `$false",
            "Disable-WSManCredSSP -Role Server -ErrorAction SilentlyContinue"
        )
        $shellExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        $joinedCmds = $cmds -join '; '
        Start-Process $shellExe -Verb RunAs -ArgumentList "-NoProfile -Command `"$joinedCmds; Write-Host 'Auth hardened - press Enter'; Read-Host`""
        $statusLabel.Text = 'Auth hardening launched (elevated)'
    })

    $btnStartWinRMSvc.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This will (as Administrator):`n`n" +
            "  [1] Set WinRM service StartupType to Automatic`n" +
            "  [2] Start the WinRM service`n`n" +
            "This is a lower-level operation than Enable-PSRemoting.`n" +
            "Use it when WinRM is configured but the service is stopped/disabled.`n`n" +
            "Proceed?",
            'Start WinRM Service', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Shield)
        if ($confirm -ne 'Yes') { return }

        $shellExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        Start-Process $shellExe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-Command',
            "Set-Service WinRM -StartupType Automatic; Start-Service WinRM; Write-Host 'WinRM service started - press Enter'; Read-Host"
        )
        $statusLabel.Text = 'WinRM service start launched (elevated) — click Refresh Status to update'
    })

    # ══════════════════════════════════════════════════════════════════════════
    #  TAB 3 - REMOTING CHECKLIST
    # ══════════════════════════════════════════════════════════════════════════
    $tabChecklist = New-Object System.Windows.Forms.TabPage
    $tabChecklist.Text = 'Remoting Checklist'
    $tabChecklist.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)

    $pnlCheckTop = New-Object System.Windows.Forms.Panel
    $pnlCheckTop.Dock = 'Top'; $pnlCheckTop.Height = 42
    $pnlCheckTop.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)

    $btnRunChecklist = New-Object System.Windows.Forms.Button
    $btnRunChecklist.Text = 'Run Checklist'; $btnRunChecklist.Location = [System.Drawing.Point]::new(8, 8)
    $btnRunChecklist.Size = [System.Drawing.Size]::new(120, 28)
    $btnRunChecklist.FlatStyle = 'Flat'; $btnRunChecklist.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnRunChecklist.ForeColor = [System.Drawing.Color]::White

    $btnCopyFix = New-Object System.Windows.Forms.Button
    $btnCopyFix.Text = 'Copy Fix Command'; $btnCopyFix.Location = [System.Drawing.Point]::new(136, 8)
    $btnCopyFix.Size = [System.Drawing.Size]::new(130, 28)
    $btnCopyFix.FlatStyle = 'Flat'; $btnCopyFix.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $btnCopyFix.ForeColor = [System.Drawing.Color]::White

    $btnExportChecklist = New-Object System.Windows.Forms.Button
    $btnExportChecklist.Text = 'Export Report'; $btnExportChecklist.Location = [System.Drawing.Point]::new(274, 8)
    $btnExportChecklist.Size = [System.Drawing.Size]::new(110, 28)
    $btnExportChecklist.FlatStyle = 'Flat'; $btnExportChecklist.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $btnExportChecklist.ForeColor = [System.Drawing.Color]::White

    $pnlCheckTop.Controls.AddRange(@($btnRunChecklist, $btnCopyFix, $btnExportChecklist))

    $dgvChecklist = New-Object System.Windows.Forms.DataGridView
    $dgvChecklist.Dock = 'Fill'
    $dgvChecklist.ReadOnly = $true
    $dgvChecklist.AllowUserToAddRows = $false
    $dgvChecklist.AutoSizeColumnsMode = 'Fill'
    $dgvChecklist.SelectionMode = 'FullRowSelect'
    $dgvChecklist.RowHeadersVisible = $false
    $dgvChecklist.BackgroundColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $dgvChecklist.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $dgvChecklist.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgvChecklist.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $dgvChecklist.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $dgvChecklist.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgvChecklist.EnableHeadersVisualStyles = $false
    $dgvChecklist.GridColor = [System.Drawing.Color]::FromArgb(60, 60, 60)

    @('Category','Check','Status','Detail','Fix Command') | ForEach-Object {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $_; $col.Name = ($_ -replace ' ','')
        $dgvChecklist.Columns.Add($col) | Out-Null
    }

    $dgvChecklist.Add_CellFormatting({
        param($s, $e)
        if ($e.ColumnIndex -eq 2 -and $null -ne $e.Value) {
            switch ($e.Value.ToString()) {
                'PASS' { $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(100, 255, 100) }
                'FAIL' { $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 80) }
                'WARN' { $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 80) }
                'INFO' { $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(130, 180, 255) }
            }
        }
    })

    $tabChecklist.Controls.Add($dgvChecklist)
    $tabChecklist.Controls.Add($pnlCheckTop)

    $script:checklistItems = @()

    $btnRunChecklist.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $statusLabel.Text = 'Running remoting checklist...'
        $form.Refresh()
        $dgvChecklist.Rows.Clear()
        $script:checklistItems = @(Get-RemotingChecklist)
        foreach ($item in $script:checklistItems) {
            $dgvChecklist.Rows.Add($item.Category, $item.Check, $item.Status, $item.Detail, $item.Fix) | Out-Null
        }
        $pass = ($script:checklistItems | Where-Object { $_.Status -eq 'PASS' }).Count
        $total = $script:checklistItems.Count
        $statusLabel.Text = "Checklist complete: $pass/$total PASS"
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    $btnCopyFix.Add_Click({
        if ($dgvChecklist.SelectedRows.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select a checklist item to copy its fix command.', 'Copy Fix',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $idx = $dgvChecklist.SelectedRows[0].Index
        if ($idx -ge $script:checklistItems.Count) { return }
        $fix = $script:checklistItems[$idx].Fix
        [System.Windows.Forms.Clipboard]::SetText($fix)
        $statusLabel.Text = "Copied: $fix"
    })

    $btnExportChecklist.Add_Click({
        if ($script:checklistItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Run the checklist first.', 'Export',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $reportPath = Join-Path $script:LogDir "WinRemote-Checklist-$ts.json"
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        $script:checklistItems | ConvertTo-Json -Depth 3 | Set-Content -Path $reportPath -Encoding UTF8
        $statusLabel.Text = "Exported to $reportPath"
        [System.Windows.Forms.MessageBox]::Show("Report saved:`n$reportPath", 'Exported',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    })

    # ══════════════════════════════════════════════════════════════════════════
    #  TAB 4 - SECURE BASELINE
    # ══════════════════════════════════════════════════════════════════════════
    $tabBaseline = New-Object System.Windows.Forms.TabPage
    $tabBaseline.Text = 'Secure Baseline'
    $tabBaseline.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)

    $pnlBaseTop = New-Object System.Windows.Forms.Panel
    $pnlBaseTop.Dock = 'Top'; $pnlBaseTop.Height = 42
    $pnlBaseTop.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)

    $lblDevType = New-Object System.Windows.Forms.Label
    $lblDevType.Text = 'Device Type:'; $lblDevType.Location = [System.Drawing.Point]::new(8, 12)
    $lblDevType.Size = [System.Drawing.Size]::new(80, 20); $lblDevType.ForeColor = [System.Drawing.Color]::White

    $cboBaselineType = New-Object System.Windows.Forms.ComboBox
    $cboBaselineType.Location = [System.Drawing.Point]::new(92, 8)
    $cboBaselineType.Size = [System.Drawing.Size]::new(180, 24)
    $cboBaselineType.DropDownStyle = 'DropDownList'
    $cboBaselineType.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $cboBaselineType.ForeColor = [System.Drawing.Color]::White
    @('Server','Laptop/Workstation','ThinClient','UPS-Controller') | ForEach-Object {
        $cboBaselineType.Items.Add($_) | Out-Null
    }
    $cboBaselineType.SelectedIndex = 0

    $btnLoadBaseline = New-Object System.Windows.Forms.Button
    $btnLoadBaseline.Text = 'Load Baseline'; $btnLoadBaseline.Location = [System.Drawing.Point]::new(280, 8)
    $btnLoadBaseline.Size = [System.Drawing.Size]::new(110, 28)
    $btnLoadBaseline.FlatStyle = 'Flat'; $btnLoadBaseline.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnLoadBaseline.ForeColor = [System.Drawing.Color]::White

    $btnApplyBaseline = New-Object System.Windows.Forms.Button
    $btnApplyBaseline.Text = 'Apply to Selected Host'; $btnApplyBaseline.Location = [System.Drawing.Point]::new(398, 8)
    $btnApplyBaseline.Size = [System.Drawing.Size]::new(150, 28)
    $btnApplyBaseline.FlatStyle = 'Flat'; $btnApplyBaseline.BackColor = [System.Drawing.Color]::FromArgb(60, 150, 60)
    $btnApplyBaseline.ForeColor = [System.Drawing.Color]::White

    $btnExportBaseline = New-Object System.Windows.Forms.Button
    $btnExportBaseline.Text = 'Export as JSON'; $btnExportBaseline.Location = [System.Drawing.Point]::new(556, 8)
    $btnExportBaseline.Size = [System.Drawing.Size]::new(110, 28)
    $btnExportBaseline.FlatStyle = 'Flat'; $btnExportBaseline.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $btnExportBaseline.ForeColor = [System.Drawing.Color]::White

    $pnlBaseTop.Controls.AddRange(@($lblDevType, $cboBaselineType, $btnLoadBaseline, $btnApplyBaseline, $btnExportBaseline))

    $dgvBaseline = New-Object System.Windows.Forms.DataGridView
    $dgvBaseline.Dock = 'Fill'
    $dgvBaseline.ReadOnly = $true
    $dgvBaseline.AllowUserToAddRows = $false
    $dgvBaseline.AutoSizeColumnsMode = 'Fill'
    $dgvBaseline.RowHeadersVisible = $false
    $dgvBaseline.BackgroundColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $dgvBaseline.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $dgvBaseline.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgvBaseline.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $dgvBaseline.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $dgvBaseline.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgvBaseline.EnableHeadersVisualStyles = $false
    $dgvBaseline.GridColor = [System.Drawing.Color]::FromArgb(60, 60, 60)

    @('Setting','Recommended Value','Notes') | ForEach-Object {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $_; $col.Name = ($_ -replace ' ','')
        $dgvBaseline.Columns.Add($col) | Out-Null
    }

    $script:currentBaseline = $null

    $loadBaselineGrid = {
        $dgvBaseline.Rows.Clear()
        $dtype = $cboBaselineType.SelectedItem.ToString()
        $bl = Get-SecureBaseline -DeviceType $dtype
        $script:currentBaseline = $bl

        $dgvBaseline.Rows.Add('Description',     $bl.Description,     '') | Out-Null
        $dgvBaseline.Rows.Add('WinRM Port',       $bl.WinRMPort,       'HTTPS=5986, HTTP=5985') | Out-Null
        $dgvBaseline.Rows.Add('Use SSL/HTTPS',    $bl.UseSSL,          'Recommended for servers') | Out-Null
        $dgvBaseline.Rows.Add('Allowed Auth',     ($bl.AllowedAuth -join ', '), 'Kerberos preferred') | Out-Null
        $dgvBaseline.Rows.Add('Disabled Auth',    ($bl.DisabledAuth -join ', '), 'Basic & CredSSP should be off') | Out-Null
        $dgvBaseline.Rows.Add('Max Concurrent',   $bl.MaxConcurrent,   'WSMan shell limit') | Out-Null
        $dgvBaseline.Rows.Add('Max Memory (MB)',   $bl.MaxMemoryMB,     'Per-shell memory limit') | Out-Null
        $dgvBaseline.Rows.Add('Idle Timeout (ms)', $bl.IdleTimeout,     "$(([int]$bl.IdleTimeout) / 60000) minutes") | Out-Null
        $dgvBaseline.Rows.Add('Min TLS Version',  $bl.TLSMinVersion,   'TLS 1.2 minimum') | Out-Null
        $dgvBaseline.Rows.Add('Cert Required',    $bl.CertRequired,    'For HTTPS listener') | Out-Null
        $dgvBaseline.Rows.Add('Constrained Mode', $bl.ConstrainedMode, 'Language mode restriction') | Out-Null
        $dgvBaseline.Rows.Add('JEA Endpoint',     $bl.JEAEndpoint,     'Just Enough Administration') | Out-Null
        $dgvBaseline.Rows.Add('Audit Logon',      $bl.AuditLogon,      'Windows event logging') | Out-Null
        $dgvBaseline.Rows.Add('Firewall Scope',   $bl.FirewallScope,   'Network profile restriction') | Out-Null
        $dgvBaseline.Rows.Add('Notes',            $bl.Notes,           '') | Out-Null

        $statusLabel.Text = "Loaded $dtype baseline"
    }

    $tabBaseline.Controls.Add($dgvBaseline)
    $tabBaseline.Controls.Add($pnlBaseTop)

    $btnLoadBaseline.Add_Click({ & $loadBaselineGrid })

    $btnApplyBaseline.Add_Click({
        if (-not $script:currentBaseline) {
            [System.Windows.Forms.MessageBox]::Show('Load a baseline first.', 'Apply',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $bl = $script:currentBaseline
        $dtype = $cboBaselineType.SelectedItem.ToString()

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Apply $dtype baseline to LOCAL machine?`n`n" +
            "  - Port: $($bl.WinRMPort)  SSL: $($bl.UseSSL)`n" +
            "  - Auth: $($bl.AllowedAuth -join ', ')`n" +
            "  - Disable: $($bl.DisabledAuth -join ', ')`n" +
            "  - MaxShells: $($bl.MaxConcurrent)  MaxMem: $($bl.MaxMemoryMB)MB`n`n" +
            "Requires Administrator. Proceed?",
            "Apply $dtype Baseline",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Shield)
        if ($confirm -ne 'Yes') { return }

        $cmds = @()
        # Auth settings
        foreach ($a in $bl.AllowedAuth) {
            $cmds += "Set-Item WSMan:\localhost\Service\Auth\$a -Value `$true"
        }
        foreach ($d in $bl.DisabledAuth) {
            if ($d -eq 'CredSSP') {
                $cmds += "Disable-WSManCredSSP -Role Server -ErrorAction SilentlyContinue"
            } else {
                $cmds += "Set-Item WSMan:\localhost\Service\Auth\$d -Value `$false"
            }
        }
        # Shell limits
        $cmds += "Set-Item WSMan:\localhost\Shell\MaxShellsPerUser -Value $($bl.MaxConcurrent)"
        $cmds += "Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value $($bl.MaxMemoryMB)"
        $cmds += "Set-Item WSMan:\localhost\Shell\IdleTimeout -Value $($bl.IdleTimeout)"

        $shellExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        $joinedCmds = $cmds -join '; '
        Start-Process $shellExe -Verb RunAs -ArgumentList "-NoProfile -Command `"$joinedCmds; Write-Host 'Baseline applied - press Enter'; Read-Host`""
        $statusLabel.Text = "$dtype baseline applied (elevated)"
    })

    $btnExportBaseline.Add_Click({
        if (-not $script:currentBaseline) {
            [System.Windows.Forms.MessageBox]::Show('Load a baseline first.', 'Export',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $dtype = $cboBaselineType.SelectedItem.ToString() -replace '[/\\]','-'
        $exportPath = Join-Path $script:LogDir "WinRemote-Baseline-$dtype-$ts.json"
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        $script:currentBaseline | ConvertTo-Json -Depth 3 | Set-Content -Path $exportPath -Encoding UTF8
        $statusLabel.Text = "Exported to $exportPath"
        [System.Windows.Forms.MessageBox]::Show("Baseline saved:`n$exportPath", 'Exported',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    })

    # ══════════════════════════════════════════════════════════════════════════
    #  TAB 5 - PSREMOTING WORKSPACE / NODE
    # ══════════════════════════════════════════════════════════════════════════
    $tabWorkspace = New-Object System.Windows.Forms.TabPage
    $tabWorkspace.Text = 'Workspace / Node'
    $tabWorkspace.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)

    $script:vault = @(Load-WRVault)

    # ── Outer split: top = Source+Pull, bottom = Credential Vault ─────────────
    $splitWS = New-Object System.Windows.Forms.SplitContainer
    $splitWS.Dock = 'Fill'
    $splitWS.Orientation = 'Horizontal'
    $splitWS.SplitterDistance = 340
    $splitWS.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $splitWS.Panel1.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $splitWS.Panel2.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $tabWorkspace.Controls.Add($splitWS)

    # ── Inner split (top): left = Workspace Source, right = Client Pull ────────
    $splitWSTop = New-Object System.Windows.Forms.SplitContainer
    $splitWSTop.Dock = 'Fill'
    $splitWSTop.Orientation = 'Vertical'
    $splitWSTop.SplitterDistance = 460
    $splitWSTop.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $splitWSTop.Panel1.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $splitWSTop.Panel2.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $splitWS.Panel1.Controls.Add($splitWSTop)

    # ════════════ LEFT: WORKSPACE SOURCE CONFIG ═══════════════════════════════
    $grpSource = New-Object System.Windows.Forms.GroupBox
    $grpSource.Text = 'Workspace Source (Publish From)'; $grpSource.Dock = 'Fill'
    $grpSource.ForeColor = [System.Drawing.Color]::White
    $grpSource.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $splitWSTop.Panel1.Controls.Add($grpSource)

    $lblSrcLocal = New-Object System.Windows.Forms.Label
    $lblSrcLocal.Text = 'Local workspace path:'; $lblSrcLocal.Location = [System.Drawing.Point]::new(12, 26)
    $lblSrcLocal.Size = [System.Drawing.Size]::new(148, 20); $lblSrcLocal.ForeColor = [System.Drawing.Color]::White
    $txtSrcLocal = New-Object System.Windows.Forms.TextBox
    $txtSrcLocal.Location = [System.Drawing.Point]::new(12, 46); $txtSrcLocal.Size = [System.Drawing.Size]::new(340, 22)
    $txtSrcLocal.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $txtSrcLocal.ForeColor = [System.Drawing.Color]::White
    $txtSrcLocal.Text = $script:ProjectRoot
    $btnBrowseSrc = New-Object System.Windows.Forms.Button
    $btnBrowseSrc.Text = '...'; $btnBrowseSrc.Location = [System.Drawing.Point]::new(358, 44)
    $btnBrowseSrc.Size = [System.Drawing.Size]::new(32, 24); $btnBrowseSrc.FlatStyle = 'Flat'
    $btnBrowseSrc.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 70); $btnBrowseSrc.ForeColor = [System.Drawing.Color]::White

    $lblSrcRemote = New-Object System.Windows.Forms.Label
    $lblSrcRemote.Text = 'Remote publish path:'; $lblSrcRemote.Location = [System.Drawing.Point]::new(12, 76)
    $lblSrcRemote.Size = [System.Drawing.Size]::new(148, 20); $lblSrcRemote.ForeColor = [System.Drawing.Color]::White
    $txtSrcRemote = New-Object System.Windows.Forms.TextBox
    $txtSrcRemote.Location = [System.Drawing.Point]::new(12, 96); $txtSrcRemote.Size = [System.Drawing.Size]::new(378, 22)
    $txtSrcRemote.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $txtSrcRemote.ForeColor = [System.Drawing.Color]::White
    $txtSrcRemote.PlaceholderText = 'e.g. C:\Deploy\PowerShellGUI'

    $lblSrcCred = New-Object System.Windows.Forms.Label
    $lblSrcCred.Text = 'Use credential:'; $lblSrcCred.Location = [System.Drawing.Point]::new(12, 126)
    $lblSrcCred.Size = [System.Drawing.Size]::new(100, 20); $lblSrcCred.ForeColor = [System.Drawing.Color]::White
    $cboSrcCred = New-Object System.Windows.Forms.ComboBox
    $cboSrcCred.Location = [System.Drawing.Point]::new(120, 122); $cboSrcCred.Size = [System.Drawing.Size]::new(270, 22)
    $cboSrcCred.DropDownStyle = 'DropDownList'
    $cboSrcCred.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $cboSrcCred.ForeColor = [System.Drawing.Color]::White

    $lblSrcTarget = New-Object System.Windows.Forms.Label
    $lblSrcTarget.Text = 'Target host:'; $lblSrcTarget.Location = [System.Drawing.Point]::new(12, 152)
    $lblSrcTarget.Size = [System.Drawing.Size]::new(100, 20); $lblSrcTarget.ForeColor = [System.Drawing.Color]::White
    $cboSrcTarget = New-Object System.Windows.Forms.ComboBox
    $cboSrcTarget.Location = [System.Drawing.Point]::new(120, 148); $cboSrcTarget.Size = [System.Drawing.Size]::new(270, 22)
    $cboSrcTarget.DropDownStyle = 'DropDown'
    $cboSrcTarget.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $cboSrcTarget.ForeColor = [System.Drawing.Color]::White

    $btnTestSrcConn = New-Object System.Windows.Forms.Button
    $btnTestSrcConn.Text = 'Test Connection'; $btnTestSrcConn.Location = [System.Drawing.Point]::new(12, 182)
    $btnTestSrcConn.Size = [System.Drawing.Size]::new(120, 28); $btnTestSrcConn.FlatStyle = 'Flat'
    $btnTestSrcConn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btnTestSrcConn.ForeColor = [System.Drawing.Color]::White

    $btnPublishWS = New-Object System.Windows.Forms.Button
    $btnPublishWS.Text = 'Publish Workspace'; $btnPublishWS.Location = [System.Drawing.Point]::new(140, 182)
    $btnPublishWS.Size = [System.Drawing.Size]::new(140, 28); $btnPublishWS.FlatStyle = 'Flat'
    $btnPublishWS.BackColor = [System.Drawing.Color]::FromArgb(60, 150, 60); $btnPublishWS.ForeColor = [System.Drawing.Color]::White

    $txtSrcOutput = New-Object System.Windows.Forms.TextBox
    $txtSrcOutput.Location = [System.Drawing.Point]::new(12, 220); $txtSrcOutput.Size = [System.Drawing.Size]::new(378, 85)
    $txtSrcOutput.Multiline = $true; $txtSrcOutput.ReadOnly = $true; $txtSrcOutput.ScrollBars = 'Vertical'
    $txtSrcOutput.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25); $txtSrcOutput.ForeColor = [System.Drawing.Color]::FromArgb(180, 220, 180)
    $txtSrcOutput.Font = New-Object System.Drawing.Font('Consolas', 8)

    $grpSource.Controls.AddRange(@(
        $lblSrcLocal, $txtSrcLocal, $btnBrowseSrc,
        $lblSrcRemote, $txtSrcRemote,
        $lblSrcCred, $cboSrcCred,
        $lblSrcTarget, $cboSrcTarget,
        $btnTestSrcConn, $btnPublishWS, $txtSrcOutput
    ))

    # ════════════ RIGHT: CLIENT NODE PULL ═════════════════════════════════════
    $grpPull = New-Object System.Windows.Forms.GroupBox
    $grpPull.Text = 'Client Node Pull (Remote Install)'; $grpPull.Dock = 'Fill'
    $grpPull.ForeColor = [System.Drawing.Color]::White
    $grpPull.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $splitWSTop.Panel2.Controls.Add($grpPull)

    $lblPullTarget = New-Object System.Windows.Forms.Label
    $lblPullTarget.Text = 'Target host/IP:'; $lblPullTarget.Location = [System.Drawing.Point]::new(12, 26)
    $lblPullTarget.Size = [System.Drawing.Size]::new(108, 20); $lblPullTarget.ForeColor = [System.Drawing.Color]::White
    $cboPullTarget = New-Object System.Windows.Forms.ComboBox
    $cboPullTarget.Location = [System.Drawing.Point]::new(124, 22); $cboPullTarget.Size = [System.Drawing.Size]::new(240, 22)
    $cboPullTarget.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $cboPullTarget.ForeColor = [System.Drawing.Color]::White

    $lblPullCred = New-Object System.Windows.Forms.Label
    $lblPullCred.Text = 'Credential:'; $lblPullCred.Location = [System.Drawing.Point]::new(12, 52)
    $lblPullCred.Size = [System.Drawing.Size]::new(80, 20); $lblPullCred.ForeColor = [System.Drawing.Color]::White
    $cboPullCred = New-Object System.Windows.Forms.ComboBox
    $cboPullCred.Location = [System.Drawing.Point]::new(96, 48); $cboPullCred.Size = [System.Drawing.Size]::new(268, 22)
    $cboPullCred.DropDownStyle = 'DropDownList'
    $cboPullCred.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $cboPullCred.ForeColor = [System.Drawing.Color]::White

    $lblPullSrc = New-Object System.Windows.Forms.Label
    $lblPullSrc.Text = 'Source path:'; $lblPullSrc.Location = [System.Drawing.Point]::new(12, 78)
    $lblPullSrc.Size = [System.Drawing.Size]::new(88, 20); $lblPullSrc.ForeColor = [System.Drawing.Color]::White
    $txtPullSrc = New-Object System.Windows.Forms.TextBox
    $txtPullSrc.Location = [System.Drawing.Point]::new(104, 74); $txtPullSrc.Size = [System.Drawing.Size]::new(260, 22)
    $txtPullSrc.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $txtPullSrc.ForeColor = [System.Drawing.Color]::White
    $txtPullSrc.Text = $script:ProjectRoot

    $lblPullDest = New-Object System.Windows.Forms.Label
    $lblPullDest.Text = 'Destination:'; $lblPullDest.Location = [System.Drawing.Point]::new(12, 104)
    $lblPullDest.Size = [System.Drawing.Size]::new(88, 20); $lblPullDest.ForeColor = [System.Drawing.Color]::White
    $txtPullDest = New-Object System.Windows.Forms.TextBox
    $txtPullDest.Location = [System.Drawing.Point]::new(104, 100); $txtPullDest.Size = [System.Drawing.Size]::new(260, 22)
    $txtPullDest.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $txtPullDest.ForeColor = [System.Drawing.Color]::White
    $txtPullDest.PlaceholderText = 'e.g. C:\PowerShellGUI'

    $chkPullUseSSL = New-Object System.Windows.Forms.CheckBox
    $chkPullUseSSL.Text = 'Use HTTPS session'; $chkPullUseSSL.Location = [System.Drawing.Point]::new(12, 130)
    $chkPullUseSSL.Size = [System.Drawing.Size]::new(145, 22); $chkPullUseSSL.ForeColor = [System.Drawing.Color]::White

    $btnPullPreview = New-Object System.Windows.Forms.Button
    $btnPullPreview.Text = 'Preview Command'; $btnPullPreview.Location = [System.Drawing.Point]::new(12, 160)
    $btnPullPreview.Size = [System.Drawing.Size]::new(130, 28); $btnPullPreview.FlatStyle = 'Flat'
    $btnPullPreview.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80); $btnPullPreview.ForeColor = [System.Drawing.Color]::White

    $btnPullExecute = New-Object System.Windows.Forms.Button
    $btnPullExecute.Text = 'Execute Pull'; $btnPullExecute.Location = [System.Drawing.Point]::new(150, 160)
    $btnPullExecute.Size = [System.Drawing.Size]::new(110, 28); $btnPullExecute.FlatStyle = 'Flat'
    $btnPullExecute.BackColor = [System.Drawing.Color]::FromArgb(60, 150, 60); $btnPullExecute.ForeColor = [System.Drawing.Color]::White

    $txtPullOutput = New-Object System.Windows.Forms.TextBox
    $txtPullOutput.Location = [System.Drawing.Point]::new(12, 198); $txtPullOutput.Size = [System.Drawing.Size]::new(352, 110)
    $txtPullOutput.Multiline = $true; $txtPullOutput.ReadOnly = $true; $txtPullOutput.ScrollBars = 'Vertical'
    $txtPullOutput.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25); $txtPullOutput.ForeColor = [System.Drawing.Color]::FromArgb(180, 220, 180)
    $txtPullOutput.Font = New-Object System.Drawing.Font('Consolas', 8)

    $grpPull.Controls.AddRange(@(
        $lblPullTarget, $cboPullTarget,
        $lblPullCred, $cboPullCred,
        $lblPullSrc, $txtPullSrc,
        $lblPullDest, $txtPullDest,
        $chkPullUseSSL, $btnPullPreview, $btnPullExecute, $txtPullOutput
    ))

    # ════════════ BOTTOM: CREDENTIAL VAULT ═══════════════════════════════════
    $grpVault = New-Object System.Windows.Forms.GroupBox
    $grpVault.Text = 'Per-Host Credential Vault (DPAPI-encrypted)'; $grpVault.Dock = 'Fill'
    $grpVault.ForeColor = [System.Drawing.Color]::White
    $grpVault.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $splitWS.Panel2.Controls.Add($grpVault)

    # Input row
    $lblVaultHost = New-Object System.Windows.Forms.Label
    $lblVaultHost.Text = 'Host/IP:'; $lblVaultHost.Location = [System.Drawing.Point]::new(12, 24)
    $lblVaultHost.Size = [System.Drawing.Size]::new(55, 20); $lblVaultHost.ForeColor = [System.Drawing.Color]::White
    $txtVaultHost = New-Object System.Windows.Forms.TextBox
    $txtVaultHost.Location = [System.Drawing.Point]::new(70, 22); $txtVaultHost.Size = [System.Drawing.Size]::new(160, 22)
    $txtVaultHost.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $txtVaultHost.ForeColor = [System.Drawing.Color]::White
    $txtVaultHost.PlaceholderText = 'host or IP'

    $lblVaultUser = New-Object System.Windows.Forms.Label
    $lblVaultUser.Text = 'Username:'; $lblVaultUser.Location = [System.Drawing.Point]::new(242, 24)
    $lblVaultUser.Size = [System.Drawing.Size]::new(68, 20); $lblVaultUser.ForeColor = [System.Drawing.Color]::White
    $txtVaultUser = New-Object System.Windows.Forms.TextBox
    $txtVaultUser.Location = [System.Drawing.Point]::new(313, 22); $txtVaultUser.Size = [System.Drawing.Size]::new(160, 22)
    $txtVaultUser.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $txtVaultUser.ForeColor = [System.Drawing.Color]::White
    $txtVaultUser.PlaceholderText = 'DOMAIN\user or user'

    $lblVaultPass = New-Object System.Windows.Forms.Label
    $lblVaultPass.Text = 'Password:'; $lblVaultPass.Location = [System.Drawing.Point]::new(485, 24)
    $lblVaultPass.Size = [System.Drawing.Size]::new(65, 20); $lblVaultPass.ForeColor = [System.Drawing.Color]::White
    $txtVaultPass = New-Object System.Windows.Forms.TextBox
    $txtVaultPass.Location = [System.Drawing.Point]::new(552, 22); $txtVaultPass.Size = [System.Drawing.Size]::new(160, 22)
    $txtVaultPass.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $txtVaultPass.ForeColor = [System.Drawing.Color]::White
    $txtVaultPass.UseSystemPasswordChar = $true; $txtVaultPass.PlaceholderText = '(stored with DPAPI)'

    $btnVaultStore = New-Object System.Windows.Forms.Button
    $btnVaultStore.Text = 'Store'; $btnVaultStore.Location = [System.Drawing.Point]::new(724, 20)
    $btnVaultStore.Size = [System.Drawing.Size]::new(65, 26); $btnVaultStore.FlatStyle = 'Flat'
    $btnVaultStore.BackColor = [System.Drawing.Color]::FromArgb(60, 150, 60); $btnVaultStore.ForeColor = [System.Drawing.Color]::White

    $btnVaultRemove = New-Object System.Windows.Forms.Button
    $btnVaultRemove.Text = 'Remove'; $btnVaultRemove.Location = [System.Drawing.Point]::new(796, 20)
    $btnVaultRemove.Size = [System.Drawing.Size]::new(65, 26); $btnVaultRemove.FlatStyle = 'Flat'
    $btnVaultRemove.BackColor = [System.Drawing.Color]::FromArgb(180, 40, 40); $btnVaultRemove.ForeColor = [System.Drawing.Color]::White

    $dgvVault = New-Object System.Windows.Forms.DataGridView
    $dgvVault.Location = [System.Drawing.Point]::new(12, 54); $dgvVault.Size = [System.Drawing.Size]::new(851, 90)
    $dgvVault.Anchor = 'Top,Left,Right,Bottom'
    $dgvVault.ReadOnly = $true; $dgvVault.AllowUserToAddRows = $false
    $dgvVault.AutoSizeColumnsMode = 'Fill'; $dgvVault.SelectionMode = 'FullRowSelect'
    $dgvVault.RowHeadersVisible = $false
    $dgvVault.BackgroundColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $dgvVault.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $dgvVault.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgvVault.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $dgvVault.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $dgvVault.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgvVault.EnableHeadersVisualStyles = $false
    $dgvVault.GridColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    @('Host / IP', 'Username', 'Stored (DPAPI-encrypted)') | ForEach-Object {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $_; $col.Name = ($_ -replace '[^A-Za-z]',''); $dgvVault.Columns.Add($col) | Out-Null
    }

    $grpVault.Controls.AddRange(@(
        $lblVaultHost, $txtVaultHost, $lblVaultUser, $txtVaultUser,
        $lblVaultPass, $txtVaultPass, $btnVaultStore, $btnVaultRemove, $dgvVault
    ))

    # ── Helper: refresh vault credential combo boxes and grid ─────────────────
    $refreshVaultUI = {
        $dgvVault.Rows.Clear()
        $cboSrcCred.Items.Clear(); $cboSrcCred.Items.Add('(none)') | Out-Null
        $cboPullCred.Items.Clear(); $cboPullCred.Items.Add('(none)') | Out-Null
        foreach ($entry in $script:vault) {
            $display = "$($entry.Host) [$($entry.Username)]"
            $dgvVault.Rows.Add($entry.Host, $entry.Username, '(encrypted)') | Out-Null
            $cboSrcCred.Items.Add($display) | Out-Null
            $cboPullCred.Items.Add($display) | Out-Null
        }
        if ($cboSrcCred.Items.Count -gt 0) { $cboSrcCred.SelectedIndex = 0 }
        if ($cboPullCred.Items.Count -gt 0) { $cboPullCred.SelectedIndex = 0 }
    }

    # Populate host combos from discovery list
    $refreshWSHostCombos = {
        $cboSrcTarget.Items.Clear(); $cboPullTarget.Items.Clear()
        foreach ($h in $script:hosts) {
            $lbl = if ($h.Hostname -and $h.Hostname -ne $h.IPAddress) { "$($h.Hostname) ($($h.IPAddress))" } else { $h.IPAddress }
            $cboSrcTarget.Items.Add($lbl) | Out-Null
            $cboPullTarget.Items.Add($lbl) | Out-Null
        }
    }

    # ── Vault Store button ─────────────────────────────────────────────────────
    $btnVaultStore.Add_Click({
        $vh = $txtVaultHost.Text.Trim()
        $vu = $txtVaultUser.Text.Trim()
        $vp = $txtVaultPass.Text
        if (-not $vh -or -not $vu) {
            [System.Windows.Forms.MessageBox]::Show('Host and Username are required.', 'Vault',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        # Remove existing entry for this host+user
        $script:vault = @($script:vault | Where-Object { -not ($_.Host -eq $vh -and $_.Username -eq $vu) })
        $encPass = if ($vp) { Protect-WRCredential -PlainText $vp } else { '' }
        $script:vault += [pscustomobject]@{
            Host     = $vh
            Username = $vu
            Password = $encPass
            Stored   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
        Save-WRVault -Entries $script:vault
        $txtVaultHost.Text = ''; $txtVaultUser.Text = ''; $txtVaultPass.Text = ''
        & $refreshVaultUI
        $statusLabel.Text = "Stored credential for $vh [$vu]"
    })

    # ── Vault Remove button ────────────────────────────────────────────────────
    $btnVaultRemove.Add_Click({
        if ($dgvVault.SelectedRows.Count -ne 1) { return }
        $idx = $dgvVault.SelectedRows[0].Index
        if ($idx -lt @($script:vault).Count) {
            $removed = $script:vault[$idx]
            $script:vault = @($script:vault | Where-Object { $_ -ne $removed })
            Save-WRVault -Entries $script:vault
            & $refreshVaultUI
            $statusLabel.Text = "Removed credential for $($removed.Host)"
        }
    })

    # ── File browse ────────────────────────────────────────────────────────────
    $btnBrowseSrc.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select local workspace folder to publish'
        $dlg.SelectedPath = $txtSrcLocal.Text
        if ($dlg.ShowDialog() -eq 'OK') { $txtSrcLocal.Text = $dlg.SelectedPath }
        $dlg.Dispose()
    })

    # ── Retrieve selected credential as PSCredential ───────────────────────────
    $getSelectedCred = {
        param([System.Windows.Forms.ComboBox]$combo)
        $idx = $combo.SelectedIndex - 1  # offset by 1 for '(none)' item
        if ($idx -lt 0 -or $idx -ge @($script:vault).Count) { return $null }
        $entry = $script:vault[$idx]
        $plain = Unprotect-WRCredential -Stored $entry.Password
        if (-not $plain) { return $null }
        $secPass = ConvertTo-SecureString $plain -AsPlainText -Force
        return New-Object System.Management.Automation.PSCredential($entry.Username, $secPass)
    }

    # ── Test Connection (source) ───────────────────────────────────────────────
    $btnTestSrcConn.Add_Click({
        $tgt = $cboSrcTarget.Text.Trim()
        # Extract IP/hostname from "hostname (ip)" format
        if ($tgt -match '\((\d[\d.]+)\)$') { $tgt = $Matches[1] }
        if (-not $tgt) {
            [System.Windows.Forms.MessageBox]::Show('Enter or select a target host.', 'Test Connection',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $cred = & $getSelectedCred $cboSrcCred
        $txtSrcOutput.Text = "Testing PSSession to $tgt...`r`n"
        try {
            $sessionParams = @{ ComputerName = $tgt; ErrorAction = 'Stop' }
            if ($cred) { $sessionParams['Credential'] = $cred }
            $sess = New-PSSession @sessionParams
            $txtSrcOutput.AppendText("OK — session opened: $($sess.Name)`r`n")
            Remove-PSSession $sess -ErrorAction SilentlyContinue
        } catch {
            $txtSrcOutput.AppendText("FAILED: $($_.Exception.Message)`r`n")
        }
    })

    # ── Publish Workspace ──────────────────────────────────────────────────────
    $btnPublishWS.Add_Click({
        $srcPath = $txtSrcLocal.Text.Trim()
        $dstPath = $txtSrcRemote.Text.Trim()
        $tgt     = $cboSrcTarget.Text.Trim()
        if ($tgt -match '\((\d[\d.]+)\)$') { $tgt = $Matches[1] }

        if (-not (Test-Path $srcPath)) {
            [System.Windows.Forms.MessageBox]::Show("Local path not found:`n$srcPath", 'Publish',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if (-not $dstPath -or -not $tgt) {
            [System.Windows.Forms.MessageBox]::Show('Set Remote publish path and Target host.', 'Publish',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Publish workspace:`n  From: $srcPath`n  To:   \\$tgt\$dstPath`n`nProceed?",
            'Publish Workspace', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne 'Yes') { return }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $txtSrcOutput.Text = "Publishing to $tgt...`r`n"
        try {
            $cred = & $getSelectedCred $cboSrcCred
            $sessionParams = @{ ComputerName = $tgt; ErrorAction = 'Stop' }
            if ($cred) { $sessionParams['Credential'] = $cred }
            $sess = New-PSSession @sessionParams

            # Ensure destination exists
            Invoke-Command -Session $sess -ScriptBlock {
                param($path)
                if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
            } -ArgumentList $dstPath

            # Copy items
            Copy-Item -Path $srcPath -Destination $dstPath -ToSession $sess -Recurse -Force -ErrorAction Stop
            Remove-PSSession $sess -ErrorAction SilentlyContinue
            $txtSrcOutput.AppendText("Publish complete.`r`n")
            $statusLabel.Text = "Workspace published to $tgt"
        } catch {
            $txtSrcOutput.AppendText("ERROR: $($_.Exception.Message)`r`n")
            $statusLabel.Text = "Publish failed: $($_.Exception.Message)"
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    # ── Pull Preview ───────────────────────────────────────────────────────────
    $btnPullPreview.Add_Click({
        $tgt  = $cboPullTarget.Text.Trim()
        if ($tgt -match '\((\d[\d.]+)\)$') { $tgt = $Matches[1] }
        $src  = $txtPullSrc.Text.Trim()
        $dst  = $txtPullDest.Text.Trim()
        $ssl  = if ($chkPullUseSSL.Checked) { ' -UseSSL' } else { '' }
        $credIdx = $cboPullCred.SelectedIndex - 1
        $credStr = if ($credIdx -ge 0 -and $credIdx -lt @($script:vault).Count) {
            " -Credential (Get-Credential '$($script:vault[$credIdx].Username)')"
        } else { '' }
        $cmd = @"
`$sess = New-PSSession -ComputerName '$tgt'$ssl$credStr -ErrorAction Stop
Copy-Item -Path '$src' -Destination '$dst' -FromSession `$sess -Recurse -Force
Remove-PSSession `$sess
"@
        $txtPullOutput.Text = "-- PREVIEW COMMAND --`r`n$cmd"
    })

    # ── Pull Execute ───────────────────────────────────────────────────────────
    $btnPullExecute.Add_Click({
        $tgt = $cboPullTarget.Text.Trim()
        if ($tgt -match '\((\d[\d.]+)\)$') { $tgt = $Matches[1] }
        $src = $txtPullSrc.Text.Trim()
        $dst = $txtPullDest.Text.Trim()
        if (-not $tgt -or -not $src -or -not $dst) {
            [System.Windows.Forms.MessageBox]::Show('Set Target host, Source path, and Destination.', 'Pull',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Pull workspace:`n  From: $tgt`:$src`n  To:   $dst`n`nProceed?",
            'Pull Workspace', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne 'Yes') { return }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $txtPullOutput.Text = "Pulling from $tgt...`r`n"
        try {
            $cred = & $getSelectedCred $cboPullCred
            $sessionParams = @{ ComputerName = $tgt; ErrorAction = 'Stop' }
            if ($chkPullUseSSL.Checked) { $sessionParams['UseSSL'] = $true }
            if ($cred) { $sessionParams['Credential'] = $cred }
            $sess = New-PSSession @sessionParams

            if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
            Copy-Item -Path $src -Destination $dst -FromSession $sess -Recurse -Force -ErrorAction Stop
            Remove-PSSession $sess -ErrorAction SilentlyContinue
            $txtPullOutput.AppendText("Pull complete.`r`n")
            $statusLabel.Text = "Workspace pulled from $tgt to $dst"
        } catch {
            $txtPullOutput.AppendText("ERROR: $($_.Exception.Message)`r`n")
            $statusLabel.Text = "Pull failed: $($_.Exception.Message)"
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    # ── Initial populate ───────────────────────────────────────────────────────
    & $refreshVaultUI
    & $refreshWSHostCombos

    # ══════════════════════════════════════════════════════════════════════════
    #  ASSEMBLE TABS & SHOW
    # ══════════════════════════════════════════════════════════════════════════
    $tabControl.TabPages.AddRange(@($tabDiscovery, $tabWinRM, $tabChecklist, $tabBaseline, $tabWorkspace))
    $form.Controls.Add($tabControl)

    # Auto-load WinRM status when switching to Tab 2; refresh workspace host combos on Tab 5
    $tabControl.Add_SelectedIndexChanged({
        if ($tabControl.SelectedIndex -eq 1) { & $refreshWinRM }
        if ($tabControl.SelectedIndex -eq 4) { & $refreshWSHostCombos }
    })

    # On load: refresh host grid, update WinRM LED, auto-load baseline
    $form.Add_Shown({
        & $refreshHostGrid
        & $updateWinRMLED
    })

    [void]$form.ShowDialog()
    $form.Dispose()
}

# ── Entry point ───────────────────────────────────────────────────────────────
Show-WinRemotePSTool



<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




