# VersionTag: 2604.B2.V31.0
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 9 entries)
#Requires -Version 5.1

# ── DPAPI credential helpers ────────────────────────────────────────────────
$script:_DpapiPrefix = 'DPAPI:'

function Protect-AVPNCredential {
    param([string]$PlainText)
    if ([string]::IsNullOrEmpty($PlainText)) { return '' }
    try {
        $secure = ConvertTo-SecureString $PlainText -AsPlainText -Force
        return $script:_DpapiPrefix + ($secure | ConvertFrom-SecureString)
    } catch { <# Intentional: non-fatal #> return $PlainText }
}

function Unprotect-AVPNCredential {
    param([string]$Stored)
    if ([string]::IsNullOrEmpty($Stored)) { return '' }
    if (-not $Stored.StartsWith($script:_DpapiPrefix)) { return $Stored }
    try {
        $encrypted = $Stored.Substring($script:_DpapiPrefix.Length)
        $secure = ConvertTo-SecureString $encrypted
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { <# Intentional: non-fatal #> return '' }
}

function Invoke-AVPNLog {
    param(
        [scriptblock]$LogCallback,
        [string]$Message,
        [string]$Level = "Info"
    )
    if ($LogCallback) {
        & $LogCallback $Message $Level
    } else {
        # Use Write-Warning for all non-info levels so errors surface to caller
        # (Write-Error -ErrorAction Continue silently bypasses callers' -ErrorAction Stop)
        if ($Level -eq "Error") {
            Write-AppLog -Message "[AVPN][ERROR] $Message" -Level Warning
        } elseif ($Level -eq "Warning") {
            Write-AppLog -Message "[AVPN][$Level] $Message" -Level Warning
        } else {
            Write-Verbose "[AVPN][$Level] $Message"
        }
    }
}

function Get-AVPNDefaultTemplateList {
    return @(
        @{ id = 1;  type = "Switch";                    model = "Generic L2/L3 Switch";      name = "Network Switch";      avInputs = 0; avOutputs = 0; powerInputs = 1; powerOutputs = 0; networkInterfaces = 6; usbInputs = 0; usbPlugs = 0; interfaceLabels = @("RJ45 1G","RJ45 10G","SFP","SFP+","QSFP+","QSFP28") },
        @{ id = 2;  type = "Router";                    model = "Generic Router";            name = "Network Router";      avInputs = 0; avOutputs = 0; powerInputs = 1; powerOutputs = 0; networkInterfaces = 5; usbInputs = 0; usbPlugs = 0; interfaceLabels = @("RJ45 WAN","RJ45 LAN","SFP","SFP+","Wi-Fi 2.4/5/6 GHz") },
        @{ id = 3;  type = "Firewall";                  model = "Generic Firewall";          name = "Network Firewall";    avInputs = 0; avOutputs = 0; powerInputs = 1; powerOutputs = 0; networkInterfaces = 5; usbInputs = 0; usbPlugs = 0; interfaceLabels = @("RJ45","SFP","SFP+","QSFP","Wi-Fi (optional)") },
        @{ id = 4;  type = "Wireless Access Point";     model = "Enterprise AP";             name = "Wireless AP";         avInputs = 0; avOutputs = 0; powerInputs = 1; powerOutputs = 0; networkInterfaces = 2; usbInputs = 0; usbPlugs = 0; interfaceLabels = @("RJ45 PoE","Wi-Fi 2.4/5/6 GHz") },
        @{ id = 5;  type = "Desktop PC";                model = "Workstation/Desktop";       name = "Desktop PC";          avInputs = 0; avOutputs = 3; powerInputs = 1; powerOutputs = 0; networkInterfaces = 3; usbInputs = 2; usbPlugs = 0; interfaceLabels = @("USB-A","USB-C","HDMI","DisplayPort","RJ45","Wi-Fi","Bluetooth","3.5mm Audio") },
        @{ id = 6;  type = "Laptop";                    model = "Generic Laptop";            name = "Laptop";              avInputs = 0; avOutputs = 3; powerInputs = 1; powerOutputs = 0; networkInterfaces = 3; usbInputs = 2; usbPlugs = 0; interfaceLabels = @("USB-A","USB-C/Thunderbolt","HDMI","DisplayPort Alt Mode","RJ45 (optional)","Wi-Fi","Bluetooth","3.5mm Audio") },
        @{ id = 7;  type = "Server";                    model = "Rack Server";               name = "Rack Server";         avInputs = 0; avOutputs = 1; powerInputs = 1; powerOutputs = 0; networkInterfaces = 5; usbInputs = 1; usbPlugs = 0; interfaceLabels = @("RJ45 1G","RJ45 10G","SFP+","iDRAC/iLO","USB","VGA","Serial") },
        @{ id = 8;  type = "Thin Client";               model = "Enterprise Thin Client";    name = "Thin Client";         avInputs = 0; avOutputs = 2; powerInputs = 1; powerOutputs = 0; networkInterfaces = 2; usbInputs = 2; usbPlugs = 0; interfaceLabels = @("USB-A","USB-C","DisplayPort","RJ45","Wi-Fi","3.5mm Audio") },
        @{ id = 9;  type = "Crestron Control Processor"; model = "CP4 / CP4-R";             name = "Control Processor";   avInputs = 0; avOutputs = 1; powerInputs = 1; powerOutputs = 1; networkInterfaces = 3; usbInputs = 1; usbPlugs = 0; interfaceLabels = @("Ethernet","RS-232","IR","Relay","IO","USB") },
        @{ id = 10; type = "Crestron Touch Panel";      model = "TSW/TS-1070 Series";        name = "Touch Panel";         avInputs = 0; avOutputs = 0; powerInputs = 1; powerOutputs = 0; networkInterfaces = 2; usbInputs = 1; usbPlugs = 0; interfaceLabels = @("Ethernet","PoE","Wi-Fi (some models)","USB") },
        @{ id = 11; type = "Crestron DM NVX Encoder";   model = "DM-NVX-350/360";           name = "DM NVX Encoder";      avInputs = 1; avOutputs = 2; powerInputs = 1; powerOutputs = 0; networkInterfaces = 1; usbInputs = 1; usbPlugs = 0; interfaceLabels = @("HDMI In","HDMI Out","RJ45 1G/10G","USB","AES67 Audio") },
        @{ id = 12; type = "Crestron DM Switcher";      model = "DM-MD Series";              name = "DM Switcher";         avInputs = 8; avOutputs = 8; powerInputs = 1; powerOutputs = 0; networkInterfaces = 1; usbInputs = 1; usbPlugs = 0; interfaceLabels = @("DM 8G+ In","DM 8G+ Out","HDMI In","HDMI Out","Ethernet","USB") },
        @{ id = 13; type = "Power Distribution";        model = "Furman M-8LX";              name = "Power Conditioner";   avInputs = 0; avOutputs = 0; powerInputs = 1; powerOutputs = 8; networkInterfaces = 0; usbInputs = 0; usbPlugs = 0; interfaceLabels = @("AC Input","AC Output x8") },
        @{ id = 14; type = "UPS";                       model = "APC Back-UPS Pro 1500VA";   name = "Backup Power";        avInputs = 0; avOutputs = 0; powerInputs = 1; powerOutputs = 12; networkInterfaces = 1; usbInputs = 0; usbPlugs = 0; interfaceLabels = @("AC Input","AC Output x12","Network") },
        @{ id = 15; type = "Other";                     model = "Generic Device";            name = "Custom Device";       avInputs = 0; avOutputs = 0; powerInputs = 0; powerOutputs = 0; networkInterfaces = 0; usbInputs = 0; usbPlugs = 0; interfaceLabels = @() }
    )
}

function Initialize-AVPNConfigFile {
    param([string]$ConfigPath)
    if (-not $ConfigPath) { return }
    if (Test-Path $ConfigPath) { return }

    $configDir = Split-Path $ConfigPath -Parent
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

    $config = [ordered]@{
        avpnDevices = Get-AVPNDefaultTemplateList
        inventory = @()
        lastModified = (Get-Date).ToUniversalTime().ToString("s") + "Z"
        version = "2603.B0.v19"
    }

    $json = $config | ConvertTo-Json -Depth 6
    Set-Content -Path $ConfigPath -Value $json -Encoding ascii
}

function Get-AVPNDeviceTypesPath {
    param([string]$ConfigPath)
    if (-not $ConfigPath) { return $null }
    $configDir = Split-Path $ConfigPath -Parent
    return (Join-Path $configDir "AVPN_device-types.json")
}

function Initialize-AVPNDeviceTypesFile {
    param(
        [string]$DeviceTypesPath,
        $Templates
    )
    if (-not $DeviceTypesPath) { return }
    if (Test-Path $DeviceTypesPath) { return }

    $configDir = Split-Path $DeviceTypesPath -Parent
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

    $seed = if ($Templates) { @($Templates) } else { @(Get-AVPNDefaultTemplateList) }
    $config = [ordered]@{
        deviceTypes = $seed
        lastModified = (Get-Date).ToUniversalTime().ToString("s") + "Z"
        version = "2603.B0.v19"
    }

    $json = $config | ConvertTo-Json -Depth 6
    Set-Content -Path $DeviceTypesPath -Value $json -Encoding ascii
}

function Get-AVPNDeviceTypeList {
    param([string]$DeviceTypesPath)
    if (-not $DeviceTypesPath) { return @() }
    if (-not (Test-Path $DeviceTypesPath)) { Initialize-AVPNDeviceTypesFile -DeviceTypesPath $DeviceTypesPath }
    try {
        $raw = Get-Content -Path $DeviceTypesPath -Raw
        $data = $raw | ConvertFrom-Json
        if (-not $data.deviceTypes) { $data | Add-Member -NotePropertyName deviceTypes -NotePropertyValue (Get-AVPNDefaultTemplateList) }
        return @($data.deviceTypes)
    } catch {
        Initialize-AVPNDeviceTypesFile -DeviceTypesPath $DeviceTypesPath
        $raw = Get-Content -Path $DeviceTypesPath -Raw
        $data = $raw | ConvertFrom-Json
        return @($data.deviceTypes)
    }
}

function Save-AVPNDeviceTypeList {
    param(
        [Parameter(Mandatory = $true)]$Templates,
        [Parameter(Mandatory = $true)][string]$DeviceTypesPath
    )
    $timestamp = (Get-Date).ToUniversalTime().ToString("s") + "Z"
    $config = [ordered]@{
        deviceTypes = @($Templates)
        lastModified = $timestamp
        version = "2603.B0.v19"
    }
    $json = $config | ConvertTo-Json -Depth 6
    Set-Content -Path $DeviceTypesPath -Value $json -Encoding ascii
}

function Get-AVPNConfig {
    param([string]$ConfigPath)
    if (-not $ConfigPath) { return $null }
    if (-not (Test-Path $ConfigPath)) { Initialize-AVPNConfigFile -ConfigPath $ConfigPath }
    try {
        $raw = Get-Content -Path $ConfigPath -Raw
        $data = $raw | ConvertFrom-Json
        if (-not $data.avpnDevices) { $data | Add-Member -NotePropertyName avpnDevices -NotePropertyValue (Get-AVPNDefaultTemplateList) }
        if (-not $data.inventory) { $data | Add-Member -NotePropertyName inventory -NotePropertyValue @() }
        # Decrypt DPAPI-protected credentials on load
        foreach ($dev in $data.inventory) {
            if ($dev.PSObject.Properties['loginPassword'] -and $dev.loginPassword) {
                $dev.loginPassword = Unprotect-AVPNCredential $dev.loginPassword
            }
        }
        return $data
    } catch {
        Initialize-AVPNConfigFile -ConfigPath $ConfigPath
        return (Get-Content -Path $ConfigPath -Raw) | ConvertFrom-Json
    }
}

function Save-AVPNConfig {
    param(
        [Parameter(Mandatory = $true)]$ConfigData,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )
    # Safely set metadata properties
    $timestamp = (Get-Date).ToUniversalTime().ToString("s") + "Z"
    $versionStr = "2603.B0.v19"
    
    if ($ConfigData.PSObject.Properties['lastModified']) {
        $ConfigData.lastModified = $timestamp
    } else {
        $ConfigData | Add-Member -NotePropertyName 'lastModified' -NotePropertyValue $timestamp -Force
    }
    
    if ($ConfigData.PSObject.Properties['version']) {
        $ConfigData.version = $versionStr
    } else {
        $ConfigData | Add-Member -NotePropertyName 'version' -NotePropertyValue $versionStr -Force
    }
    
    # Encrypt credentials before writing to disk
    foreach ($dev in $ConfigData.inventory) {
        if ($dev.PSObject.Properties['loginPassword'] -and $dev.loginPassword) {
            $dev.loginPassword = Protect-AVPNCredential $dev.loginPassword
        }
    }
    
    $json = $ConfigData | ConvertTo-Json -Depth 6
    Set-Content -Path $ConfigPath -Value $json -Encoding ascii

    # Restore plaintext in memory so callers remain unaffected
    foreach ($dev in $ConfigData.inventory) {
        if ($dev.PSObject.Properties['loginPassword'] -and $dev.loginPassword) {
            $dev.loginPassword = Unprotect-AVPNCredential $dev.loginPassword
        }
    }
}

function Get-AVPNConnectorCount {
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)][string]$ConnectorType
    )
    switch ($ConnectorType) {
        "AV Input" { return [int]$Device.avInputs }
        "AV Output" { return [int]$Device.avOutputs }
        "Power Input" { return [int]$Device.powerInputs }
        "Power Output" { return [int]$Device.powerOutputs }
        "Network" { return [int]$Device.networkInterfaces }
        "USB Input" { return [int]$Device.usbInputs }
        "USB Plug" { return [int]$Device.usbPlugs }
        default { return 0 }
    }
}

function Test-AVPNConnectionValid {
    param(
        [Parameter(Mandatory = $true)][string]$SourceType,
        [Parameter(Mandatory = $true)][string]$DestType
    )
    if ($SourceType -eq "Network" -and $DestType -eq "Network") { return $true }
    if ($SourceType -eq "AV Output" -and $DestType -eq "AV Input") { return $true }
    if ($SourceType -eq "Power Output" -and $DestType -eq "Power Input") { return $true }
    if ($SourceType -eq "USB Plug" -and $DestType -eq "USB Input") { return $true }
    return $false
}

function Export-AVPNCsv {
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)]$Connections,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rows = @()
    foreach ($device in $Inventory) {
        $rows += [pscustomobject]@{
            RecordType = "Device"
            DeviceId = $device.deviceId
            InstanceId = $device.instanceId
            TemplateId = $device.templateId
            Type = $device.type
            Model = $device.model
            Name = $device.name
            Location = $device.location
            AvInputs = $device.avInputs
            AvOutputs = $device.avOutputs
            PowerInputs = $device.powerInputs
            PowerOutputs = $device.powerOutputs
            NetworkInterfaces = $device.networkInterfaces
            UsbInputs = $device.usbInputs
            UsbPlugs = $device.usbPlugs
            UrlLink = $device.urlLink
            LoginUser = $device.loginUser
            LoginPassword = $device.loginPassword
            SourceInstance = ""
            SourceConnector = ""
            DestInstance = ""
            DestConnector = ""
        }
    }
    foreach ($conn in $Connections) {
        $rows += [pscustomobject]@{
            RecordType = "Connection"
            DeviceId = ""
            InstanceId = ""
            TemplateId = ""
            Type = ""
            Model = ""
            Name = ""
            Location = ""
            AvInputs = ""
            AvOutputs = ""
            PowerInputs = ""
            PowerOutputs = ""
            NetworkInterfaces = ""
            UsbInputs = ""
            UsbPlugs = ""
            UrlLink = ""
            LoginUser = ""
            LoginPassword = ""
            SourceInstance = $conn.SourceInstance
            SourceConnector = $conn.SourceConnector
            DestInstance = $conn.DestInstance
            DestConnector = $conn.DestConnector
        }
    }

    $rows | Export-Csv -Path $Path -NoTypeInformation -Force
}

function Import-AVPNCsv {
    param([Parameter(Mandatory = $true)][string]$Path)
    # Strip comment lines (e.g. # VersionTag) before passing to Import-Csv
    $rawLines = Get-Content -Path $Path | Where-Object { $_ -notmatch '^\s*#' }
    $rows = $rawLines | ConvertFrom-Csv
    $inventory = New-Object System.Collections.ArrayList
    $connections = New-Object System.Collections.ArrayList

    foreach ($row in $rows) {
        if ($row.RecordType -eq "Device") {
            $deviceIdValue = ""
            if ($row.PSObject.Properties['DeviceId']) { $deviceIdValue = $row.DeviceId }
            $urlLinkValue = ""
            if ($row.PSObject.Properties['UrlLink']) { $urlLinkValue = $row.UrlLink }
            $loginUserValue = ""
            if ($row.PSObject.Properties['LoginUser']) { $loginUserValue = $row.LoginUser }
            $loginPasswordValue = ""
            if ($row.PSObject.Properties['LoginPassword']) { $loginPasswordValue = $row.LoginPassword }

            $device = [ordered]@{
                deviceId = $deviceIdValue
                instanceId = $row.InstanceId
                templateId = [int]$row.TemplateId
                type = $row.Type
                model = $row.Model
                name = $row.Name
                quantity = 1
                location = $row.Location
                avInputs = [int]$row.AvInputs
                avOutputs = [int]$row.AvOutputs
                powerInputs = [int]$row.PowerInputs
                powerOutputs = [int]$row.PowerOutputs
                networkInterfaces = [int]$row.NetworkInterfaces
                usbInputs = [int]$row.UsbInputs
                usbPlugs = [int]$row.UsbPlugs
                urlLink = $urlLinkValue
                loginUser = $loginUserValue
                loginPassword = $loginPasswordValue
                connections = @()
            }
            [void]$inventory.Add($device)
        } elseif ($row.RecordType -eq "Connection") {
            $conn = [pscustomobject]@{
                SourceInstance = $row.SourceInstance
                SourceConnector = $row.SourceConnector
                DestInstance = $row.DestInstance
                DestConnector = $row.DestConnector
            }
            [void]$connections.Add($conn)
        }
    }

    return @{ Inventory = $inventory; Connections = $connections }
}

function Show-AVPNDeviceTypeDialog {
    param(
        $Template,
        [int]$NextId
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = if ($Template) { "Edit Device Type" } else { "Add Device Type" }
    $dialog.Size = New-Object System.Drawing.Size(380, 420)
    $dialog.StartPosition = "CenterParent"

    $labels = @("Type","Model","Name","AV Inputs","AV Outputs","Power Inputs","Power Outputs","Network Interfaces","USB Inputs","USB Plugs")
    $controls = @{}

    for ($i = 0; $i -lt $labels.Count; $i++) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $labels[$i]
        $label.Location = New-Object System.Drawing.Point(12, 14 + ($i * 32))
        $label.Size = New-Object System.Drawing.Size(140, 20)
        $dialog.Controls.Add($label)

        if ($i -lt 3) {
            $box = New-Object System.Windows.Forms.TextBox
            $box.Location = New-Object System.Drawing.Point(160, 12 + ($i * 32))
            $box.Size = New-Object System.Drawing.Size(190, 22)
            $controls[$labels[$i]] = $box
            $dialog.Controls.Add($box)
        } else {
            $num = New-Object System.Windows.Forms.NumericUpDown
            $num.Location = New-Object System.Drawing.Point(160, 12 + ($i * 32))
            $num.Size = New-Object System.Drawing.Size(90, 22)
            $num.Minimum = 0
            $num.Maximum = 99
            $controls[$labels[$i]] = $num
            $dialog.Controls.Add($num)
        }
    }

    if ($Template) {
        $controls["Type"].Text = $Template.type
        $controls["Model"].Text = $Template.model
        $controls["Name"].Text = $Template.name
        $controls["AV Inputs"].Value = $Template.avInputs
        $controls["AV Outputs"].Value = $Template.avOutputs
        $controls["Power Inputs"].Value = $Template.powerInputs
        $controls["Power Outputs"].Value = $Template.powerOutputs
        $controls["Network Interfaces"].Value = $Template.networkInterfaces
        $controls["USB Inputs"].Value = $Template.usbInputs
        $controls["USB Plugs"].Value = $Template.usbPlugs
    }

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "Save"
    $okBtn.Location = New-Object System.Drawing.Point(160, 340)
    $okBtn.Add_Click({ $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dialog.Close() })
    $dialog.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(250, 340)
    $cancelBtn.Add_Click({ $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dialog.Close() })
    $dialog.Controls.Add($cancelBtn)

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $dialog.Dispose(); return $null }

    $result = [ordered]@{
        id = if ($Template) { $Template.id } else { $NextId }
        type = $controls["Type"].Text.Trim()
        model = $controls["Model"].Text.Trim()
        name = $controls["Name"].Text.Trim()
        avInputs = [int]$controls["AV Inputs"].Value
        avOutputs = [int]$controls["AV Outputs"].Value
        powerInputs = [int]$controls["Power Inputs"].Value
        powerOutputs = [int]$controls["Power Outputs"].Value
        networkInterfaces = [int]$controls["Network Interfaces"].Value
        usbInputs = [int]$controls["USB Inputs"].Value
        usbPlugs = [int]$controls["USB Plugs"].Value
    }
    $dialog.Dispose()
    return $result
}

function Show-AVPNDeviceTypeEditor {
    param(
        [Parameter(Mandatory = $true)]$Templates,
        [scriptblock]$LogCallback
    )

    $deviceTypeLogCallback = $LogCallback

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Manage Device Types"
    $form.Size = New-Object System.Drawing.Size(720, 420)
    $form.StartPosition = "CenterParent"

    $list = New-Object System.Windows.Forms.ListView
    $list.View = "Details"
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.Dock = "Top"
    $list.Height = 300
    [void]$list.Columns.Add("Id", 40)
    [void]$list.Columns.Add("Type", 140)
    [void]$list.Columns.Add("Model", 160)
    [void]$list.Columns.Add("Name", 160)
    [void]$list.Columns.Add("AV In", 50)
    [void]$list.Columns.Add("AV Out", 60)
    [void]$list.Columns.Add("Pwr In", 60)
    [void]$list.Columns.Add("Pwr Out", 60)
    [void]$list.Columns.Add("Net", 50)
    [void]$list.Columns.Add("USB In", 60)
    [void]$list.Columns.Add("USB Plug", 70)
    $form.Controls.Add($list)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = "Bottom"
    $panel.Height = 60
    $form.Controls.Add($panel)

    $addBtn = New-Object System.Windows.Forms.Button
    $addBtn.Text = "Add"
    $addBtn.Location = New-Object System.Drawing.Point(8, 12)
    $panel.Controls.Add($addBtn)

    $editBtn = New-Object System.Windows.Forms.Button
    $editBtn.Text = "Edit"
    $editBtn.Location = New-Object System.Drawing.Point(88, 12)
    $panel.Controls.Add($editBtn)

    $removeBtn = New-Object System.Windows.Forms.Button
    $removeBtn.Text = "Remove"
    $removeBtn.Location = New-Object System.Drawing.Point(168, 12)
    $panel.Controls.Add($removeBtn)

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = "Close"
    $closeBtn.Location = New-Object System.Drawing.Point(248, 12)
    $panel.Controls.Add($closeBtn)

    $refresh = {
        $list.Items.Clear()
        foreach ($t in $Templates) {
            $item = New-Object System.Windows.Forms.ListViewItem($t.id)
            [void]$item.SubItems.Add($t.type)
            [void]$item.SubItems.Add($t.model)
            [void]$item.SubItems.Add($t.name)
            [void]$item.SubItems.Add($t.avInputs)
            [void]$item.SubItems.Add($t.avOutputs)
            [void]$item.SubItems.Add($t.powerInputs)
            [void]$item.SubItems.Add($t.powerOutputs)
            [void]$item.SubItems.Add($t.networkInterfaces)
            [void]$item.SubItems.Add($t.usbInputs)
            [void]$item.SubItems.Add($t.usbPlugs)
            $list.Items.Add($item) | Out-Null
        }
    }

    $addBtn.Add_Click({
        $nextId = if ($Templates.Count -gt 0) { ($Templates | Measure-Object -Property id -Maximum).Maximum + 1 } else { 1 }
        $newTemplate = Show-AVPNDeviceTypeDialog -NextId $nextId
        if ($newTemplate) {
            $Templates += $newTemplate
            Invoke-AVPNLog -LogCallback $deviceTypeLogCallback -Message "Added device template: $($newTemplate.type)" -Level "Info"
            & $refresh
        }
    })

    $editBtn.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $id = [int]$list.SelectedItems[0].Text
        $template = $Templates | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $template) { return }
        $updated = Show-AVPNDeviceTypeDialog -Template $template -NextId $template.id
        if ($updated) {
            $Templates = @($Templates | Where-Object { $_.id -ne $id }) + $updated
            Invoke-AVPNLog -LogCallback $deviceTypeLogCallback -Message "Updated device template: $($updated.type)" -Level "Info"
            & $refresh
        }
    })

    $removeBtn.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $id = [int]$list.SelectedItems[0].Text
        $Templates = @($Templates | Where-Object { $_.id -ne $id })
        Invoke-AVPNLog -LogCallback $deviceTypeLogCallback -Message "Removed device template id $id" -Level "Warning"
        & $refresh
    })

    $closeBtn.Add_Click({ $form.Close() })

    & $refresh
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    return $Templates
}

function Show-AVPNConnectionTracker {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [scriptblock]$LogCallback,
        [System.Windows.Forms.IWin32Window]$Owner
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    Invoke-AVPNLog -LogCallback $LogCallback -Message "Launching AVPN Connection Tracker" -Level "Event"

    $config = Get-AVPNConfig -ConfigPath $ConfigPath
    $deviceTypesPath = Get-AVPNDeviceTypesPath -ConfigPath $ConfigPath
    if ($deviceTypesPath -and -not (Test-Path $deviceTypesPath)) {
        $seedTemplates = if ($config.avpnDevices) { @($config.avpnDevices) } else { @(Get-AVPNDefaultTemplateList) }
        Initialize-AVPNDeviceTypesFile -DeviceTypesPath $deviceTypesPath -Templates $seedTemplates
    }
    $templates = @(Get-AVPNDeviceTypeList -DeviceTypesPath $deviceTypesPath)
    if (-not $templates -or $templates.Count -eq 0) {
        $templates = if ($config.avpnDevices) { @($config.avpnDevices) } else { @(Get-AVPNDefaultTemplateList) }
    }
    $filteredTemplates = New-Object System.Collections.ArrayList
    $inventory = New-Object System.Collections.ArrayList
    if ($config.inventory) { foreach ($item in $config.inventory) { [void]$inventory.Add($item) } }

    $connections = New-Object System.Collections.ArrayList
    foreach ($item in $inventory) {
        if ($item.connections) {
            foreach ($conn in $item.connections) {
                [void]$connections.Add([pscustomobject]@{
                    SourceInstance = $conn.sourceInstance
                    SourceConnector = $conn.sourceConnector
                    DestInstance = $conn.destInstance
                    DestConnector = $conn.destConnector
                })
            }
        }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "AVPN Connection Tracker"
    $form.Size = New-Object System.Drawing.Size(1200, 720)
    $form.StartPosition = "CenterParent"

    $mainSplit = New-Object System.Windows.Forms.SplitContainer
    $mainSplit.Dock = "Fill"
    $mainSplit.SplitterDistance = 280
    $form.Controls.Add($mainSplit)

    $libraryLabel = New-Object System.Windows.Forms.Label
    $libraryLabel.Text = "Device Library"
    $libraryLabel.Location = New-Object System.Drawing.Point(8, 8)
    $libraryLabel.AutoSize = $true
    $mainSplit.Panel1.Controls.Add($libraryLabel)

    $typeLabel = New-Object System.Windows.Forms.Label
    $typeLabel.Text = "Device Type"
    $typeLabel.Location = New-Object System.Drawing.Point(8, 30)
    $typeLabel.AutoSize = $true
    $mainSplit.Panel1.Controls.Add($typeLabel)

    $typeCombo = New-Object System.Windows.Forms.ComboBox
    $typeCombo.Location = New-Object System.Drawing.Point(8, 50)
    $typeCombo.Size = New-Object System.Drawing.Size(250, 22)
    $typeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $mainSplit.Panel1.Controls.Add($typeCombo)

    $templateList = New-Object System.Windows.Forms.ListBox
    $templateList.Location = New-Object System.Drawing.Point(8, 80)
    $templateList.Size = New-Object System.Drawing.Size(250, 280)
    $mainSplit.Panel1.Controls.Add($templateList)

    $manageTypesBtn = New-Object System.Windows.Forms.Button
    $manageTypesBtn.Text = "Manage Device Types"
    $manageTypesBtn.Location = New-Object System.Drawing.Point(8, 370)
    $manageTypesBtn.Size = New-Object System.Drawing.Size(250, 28)
    $mainSplit.Panel1.Controls.Add($manageTypesBtn)

    $refreshTypeCombo = {
        $typeCombo.Items.Clear()
        [void]$typeCombo.Items.Add("All Types")
        $types = @($templates | Select-Object -ExpandProperty type -Unique | Sort-Object)
        foreach ($t in $types) { [void]$typeCombo.Items.Add($t) }
        if ($typeCombo.Items.Count -gt 0) { $typeCombo.SelectedIndex = 0 }
    }

    $refreshTemplateList = {
        $templateList.Items.Clear()
        $filteredTemplates.Clear()
        $src = @($templates)
        if ($typeCombo.SelectedIndex -gt 0) {
            $selectedType = $typeCombo.SelectedItem
            $src = @($templates | Where-Object { $_.type -eq $selectedType })
        }
        foreach ($t in $src) {
            [void]$filteredTemplates.Add($t)
            [void]$templateList.Items.Add("$($t.id) - $($t.type) ($($t.model))")
        }
    }

    $typeCombo.Add_SelectedIndexChanged({ & $refreshTemplateList })
    & $refreshTypeCombo
    & $refreshTemplateList

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = "Custom Name"
    $nameLabel.Location = New-Object System.Drawing.Point(8, 410)
    $nameLabel.AutoSize = $true
    $mainSplit.Panel1.Controls.Add($nameLabel)

    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.Location = New-Object System.Drawing.Point(8, 430)
    $nameBox.Size = New-Object System.Drawing.Size(250, 22)
    $mainSplit.Panel1.Controls.Add($nameBox)

    $qtyLabel = New-Object System.Windows.Forms.Label
    $qtyLabel.Text = "Quantity"
    $qtyLabel.Location = New-Object System.Drawing.Point(8, 460)
    $qtyLabel.AutoSize = $true
    $mainSplit.Panel1.Controls.Add($qtyLabel)

    $qtyUpDown = New-Object System.Windows.Forms.NumericUpDown
    $qtyUpDown.Location = New-Object System.Drawing.Point(8, 480)
    $qtyUpDown.Minimum = 1
    $qtyUpDown.Maximum = 20
    $qtyUpDown.Value = 1
    $mainSplit.Panel1.Controls.Add($qtyUpDown)

    $addBtn = New-Object System.Windows.Forms.Button
    $addBtn.Text = "Add to Inventory"
    $addBtn.Location = New-Object System.Drawing.Point(8, 512)
    $addBtn.Size = New-Object System.Drawing.Size(250, 32)
    $mainSplit.Panel1.Controls.Add($addBtn)

    $rightSplit = New-Object System.Windows.Forms.SplitContainer
    $rightSplit.Dock = "Fill"
    $rightSplit.Orientation = "Horizontal"
    $rightSplit.SplitterDistance = 440
    $mainSplit.Panel2.Padding = New-Object System.Windows.Forms.Padding(0)
    $mainSplit.Panel2.Controls.Add($rightSplit)

    $canvas = New-Object System.Windows.Forms.Panel
    $canvas.Dock = "Fill"
    $canvas.BackColor = [System.Drawing.Color]::WhiteSmoke
    $canvas.AutoScroll = $true
    $canvas.Padding = New-Object System.Windows.Forms.Padding(0)
    $rightSplit.Panel1.Padding = New-Object System.Windows.Forms.Padding(0)
    $rightSplit.Panel1.Controls.Add($canvas)

    $gridPanel = New-Object System.Windows.Forms.Panel
    $gridPanel.Dock = "Bottom"
    $gridPanel.Height = 36
    $rightSplit.Panel1.Controls.Add($gridPanel)

    $showGridCheck = New-Object System.Windows.Forms.CheckBox
    $showGridCheck.Text = "Show grid"
    $showGridCheck.Location = New-Object System.Drawing.Point(8, 8)
    $showGridCheck.Checked = $true
    $gridPanel.Controls.Add($showGridCheck)

    $snapGridCheck = New-Object System.Windows.Forms.CheckBox
    $snapGridCheck.Text = "Snap to grid"
    $snapGridCheck.Location = New-Object System.Drawing.Point(110, 8)
    $snapGridCheck.Checked = $true
    $gridPanel.Controls.Add($snapGridCheck)

    $gridSizeLabel = New-Object System.Windows.Forms.Label
    $gridSizeLabel.Text = "Grid size"
    $gridSizeLabel.Location = New-Object System.Drawing.Point(230, 10)
    $gridSizeLabel.AutoSize = $true
    $gridPanel.Controls.Add($gridSizeLabel)

    $gridSizeUpDown = New-Object System.Windows.Forms.NumericUpDown
    $gridSizeUpDown.Location = New-Object System.Drawing.Point(290, 8)
    $gridSizeUpDown.Minimum = 10
    $gridSizeUpDown.Maximum = 80
    $gridSizeUpDown.Value = 20
    $gridPanel.Controls.Add($gridSizeUpDown)

    $alignBtn = New-Object System.Windows.Forms.Button
    $alignBtn.Text = "Align to Grid"
    $alignBtn.Location = New-Object System.Drawing.Point(390, 6)
    $alignBtn.Size = New-Object System.Drawing.Size(120, 24)
    $gridPanel.Controls.Add($alignBtn)

    $autoPlugBtn = New-Object System.Windows.Forms.Button
    $autoPlugBtn.Text = "Auto Plug All"
    $autoPlugBtn.Location = New-Object System.Drawing.Point(520, 6)
    $autoPlugBtn.Size = New-Object System.Drawing.Size(120, 24)
    $autoPlugBtn.BackColor = [System.Drawing.Color]::MistyRose
    $gridPanel.Controls.Add($autoPlugBtn)

    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = "Fill"
    $rightSplit.Panel2.Controls.Add($tabControl)

    $inventoryTab = New-Object System.Windows.Forms.TabPage
    $inventoryTab.Text = "Inventory"
    $tabControl.TabPages.Add($inventoryTab) | Out-Null

    $connectionsTab = New-Object System.Windows.Forms.TabPage
    $connectionsTab.Text = "Connections"
    $tabControl.TabPages.Add($connectionsTab) | Out-Null

    $inventoryList = New-Object System.Windows.Forms.ListView
    $inventoryList.View = "Details"
    $inventoryList.FullRowSelect = $true
    $inventoryList.GridLines = $true
    $inventoryList.Dock = "Top"
    $inventoryList.Height = 180
    [void]$inventoryList.Columns.Add("Dev ID", 50)
    [void]$inventoryList.Columns.Add("Name", 120)
    [void]$inventoryList.Columns.Add("Type", 100)
    [void]$inventoryList.Columns.Add("Model", 120)
    [void]$inventoryList.Columns.Add("AV In", 40)
    [void]$inventoryList.Columns.Add("AV Out", 45)
    [void]$inventoryList.Columns.Add("Pwr In", 50)
    [void]$inventoryList.Columns.Add("Pwr Out", 55)
    [void]$inventoryList.Columns.Add("Network", 50)
    [void]$inventoryList.Columns.Add("USB In", 45)
    [void]$inventoryList.Columns.Add("USB Plug", 55)
    [void]$inventoryList.Columns.Add("URL", 200)
    [void]$inventoryList.Columns.Add("Login User", 100)
    [void]$inventoryList.Columns.Add("Login Pass", 100)
    [void]$inventoryList.Columns.Add("InstanceId", 200)
    $inventoryTab.Controls.Add($inventoryList)

    $invButtonPanel = New-Object System.Windows.Forms.Panel
    $invButtonPanel.Dock = "Bottom"
    $invButtonPanel.Height = 60
    $inventoryTab.Controls.Add($invButtonPanel)

    $removeBtn = New-Object System.Windows.Forms.Button
    $removeBtn.Text = "Remove"
    $removeBtn.Location = New-Object System.Drawing.Point(8, 12)
    $removeBtn.Size = New-Object System.Drawing.Size(80, 32)
    $invButtonPanel.Controls.Add($removeBtn)

    $editBtn = New-Object System.Windows.Forms.Button
    $editBtn.Text = "Edit Info"
    $editBtn.Location = New-Object System.Drawing.Point(96, 12)
    $editBtn.Size = New-Object System.Drawing.Size(80, 32)
    $invButtonPanel.Controls.Add($editBtn)

    $saveBtn = New-Object System.Windows.Forms.Button
    $saveBtn.Text = "Export CSV"
    $saveBtn.Location = New-Object System.Drawing.Point(184, 12)
    $saveBtn.Size = New-Object System.Drawing.Size(90, 32)
    $invButtonPanel.Controls.Add($saveBtn)

    $loadBtn = New-Object System.Windows.Forms.Button
    $loadBtn.Text = "Import CSV"
    $loadBtn.Location = New-Object System.Drawing.Point(282, 12)
    $loadBtn.Size = New-Object System.Drawing.Size(90, 32)
    $invButtonPanel.Controls.Add($loadBtn)

    $saveAsBtn = New-Object System.Windows.Forms.Button
    $saveAsBtn.Text = "Export CSV As"
    $saveAsBtn.Location = New-Object System.Drawing.Point(380, 12)
    $saveAsBtn.Size = New-Object System.Drawing.Size(110, 32)
    $invButtonPanel.Controls.Add($saveAsBtn)

    $resetBtn = New-Object System.Windows.Forms.Button
    $resetBtn.Text = "Reset Layout"
    $resetBtn.Location = New-Object System.Drawing.Point(498, 12)
    $resetBtn.Size = New-Object System.Drawing.Size(110, 32)
    $invButtonPanel.Controls.Add($resetBtn)

    $connPanel = New-Object System.Windows.Forms.Panel
    $connPanel.Dock = "Top"
    $connPanel.Height = 80
    $connectionsTab.Controls.Add($connPanel)

    $srcDeviceLabel = New-Object System.Windows.Forms.Label
    $srcDeviceLabel.Text = "Source Device"
    $srcDeviceLabel.Location = New-Object System.Drawing.Point(8, 8)
    $srcDeviceLabel.AutoSize = $true
    $connPanel.Controls.Add($srcDeviceLabel)

    $srcDeviceCombo = New-Object System.Windows.Forms.ComboBox
    $srcDeviceCombo.Location = New-Object System.Drawing.Point(8, 28)
    $srcDeviceCombo.Width = 170
    $srcDeviceCombo.DropDownStyle = "DropDownList"
    $connPanel.Controls.Add($srcDeviceCombo)

    $srcTypeCombo = New-Object System.Windows.Forms.ComboBox
    $srcTypeCombo.Location = New-Object System.Drawing.Point(186, 28)
    $srcTypeCombo.Width = 110
    $srcTypeCombo.DropDownStyle = "DropDownList"
    $srcTypeCombo.Items.AddRange(@("AV Output", "Power Output", "Network", "USB Plug", "AV Input", "Power Input", "USB Input"))
    $connPanel.Controls.Add($srcTypeCombo)

    $srcIndexUpDown = New-Object System.Windows.Forms.NumericUpDown
    $srcIndexUpDown.Location = New-Object System.Drawing.Point(302, 28)
    $srcIndexUpDown.Width = 60
    $connPanel.Controls.Add($srcIndexUpDown)

    $destDeviceLabel = New-Object System.Windows.Forms.Label
    $destDeviceLabel.Text = "Destination Device"
    $destDeviceLabel.Location = New-Object System.Drawing.Point(380, 8)
    $destDeviceLabel.AutoSize = $true
    $connPanel.Controls.Add($destDeviceLabel)

    $destDeviceCombo = New-Object System.Windows.Forms.ComboBox
    $destDeviceCombo.Location = New-Object System.Drawing.Point(380, 28)
    $destDeviceCombo.Width = 170
    $destDeviceCombo.DropDownStyle = "DropDownList"
    $connPanel.Controls.Add($destDeviceCombo)

    $destTypeCombo = New-Object System.Windows.Forms.ComboBox
    $destTypeCombo.Location = New-Object System.Drawing.Point(558, 28)
    $destTypeCombo.Width = 110
    $destTypeCombo.DropDownStyle = "DropDownList"
    $destTypeCombo.Items.AddRange(@("AV Input", "Power Input", "Network", "USB Input", "AV Output", "Power Output", "USB Plug"))
    $connPanel.Controls.Add($destTypeCombo)

    $destIndexUpDown = New-Object System.Windows.Forms.NumericUpDown
    $destIndexUpDown.Location = New-Object System.Drawing.Point(674, 28)
    $destIndexUpDown.Width = 60
    $connPanel.Controls.Add($destIndexUpDown)

    $addConnBtn = New-Object System.Windows.Forms.Button
    $addConnBtn.Text = "Add Connection"
    $addConnBtn.Location = New-Object System.Drawing.Point(744, 24)
    $addConnBtn.Size = New-Object System.Drawing.Size(120, 30)
    $connPanel.Controls.Add($addConnBtn)

    $connList = New-Object System.Windows.Forms.ListView
    $connList.View = "Details"
    $connList.FullRowSelect = $true
    $connList.GridLines = $true
    $connList.Dock = "Fill"
    [void]$connList.Columns.Add("Source", 220)
    [void]$connList.Columns.Add("Destination", 220)
    [void]$connList.Columns.Add("Type", 180)
    $connectionsTab.Controls.Add($connList)

    $connRemoveBtn = New-Object System.Windows.Forms.Button
    $connRemoveBtn.Text = "Remove Selected"
    $connRemoveBtn.Dock = "Bottom"
    $connRemoveBtn.Height = 30
    $connectionsTab.Controls.Add($connRemoveBtn)

    $dragState = @{ Active = $false; Offset = $null; Control = $null }
    $connectorDragState = @{ Active = $false; SourceDevice = $null; SourceType = $null; SourceIndex = $null; MousePos = $null }
    $deviceControls = @{}
    $script:placementIndex = 0

    # Connector type colors
    $connectorColors = @{
        'AV Input' = [System.Drawing.Color]::DodgerBlue
        'AV Output' = [System.Drawing.Color]::DodgerBlue
        'Power Input' = [System.Drawing.Color]::Crimson
        'Power Output' = [System.Drawing.Color]::Crimson
        'Network' = [System.Drawing.Color]::ForestGreen
        'USB Input' = [System.Drawing.Color]::Orange
        'USB Plug' = [System.Drawing.Color]::Orange
    }

    # Connector shape identifiers (unique per interface type)
    # AV = circle, Power = rectangle (plug/socket), Network = diamond (RJ45), USB = rounded-rect
    $connectorShapes = @{
        'AV Input'     = 'circle'
        'AV Output'    = 'circle'
        'Power Input'  = 'rect'
        'Power Output' = 'rect'
        'Network'      = 'diamond'
        'USB Input'    = 'roundrect'
        'USB Plug'     = 'roundrect'
    }

    $getConnectorColor = {
        param([string]$Type)
        if ($connectorColors.ContainsKey($Type)) { return $connectorColors[$Type] }
        return [System.Drawing.Color]::Gray
    }

    $getConnectorPositions = {
        param($device, $box)
        $positions = @()
        $boxWidth = $box.Width
        $boxHeight = $box.Height
        $boxLeft = $box.Left
        $boxTop = $box.Top
        $centerX = $boxLeft + ($boxWidth / 2)
        $centerY = $boxTop + ($boxHeight / 2)
        
        # Calculate positions for each connector type
        $allConnectors = @()
        
        # Outputs (white triangles pointing away) - placed on edges
        for ($i = 0; $i -lt $device.avOutputs; $i++) {
            $allConnectors += @{ Type = 'AV Output'; Index = $i; IsInput = $false }
        }
        for ($i = 0; $i -lt $device.powerOutputs; $i++) {
            $allConnectors += @{ Type = 'Power Output'; Index = $i; IsInput = $false }
        }
        for ($i = 0; $i -lt $device.usbPlugs; $i++) {
            $allConnectors += @{ Type = 'USB Plug'; Index = $i; IsInput = $false }
        }
        
        # Inputs (black triangles pointing inward)
        for ($i = 0; $i -lt $device.avInputs; $i++) {
            $allConnectors += @{ Type = 'AV Input'; Index = $i; IsInput = $true }
        }
        for ($i = 0; $i -lt $device.powerInputs; $i++) {
            $allConnectors += @{ Type = 'Power Input'; Index = $i; IsInput = $true }
        }
        for ($i = 0; $i -lt $device.usbInputs; $i++) {
            $allConnectors += @{ Type = 'USB Input'; Index = $i; IsInput = $true }
        }
        for ($i = 0; $i -lt $device.networkInterfaces; $i++) {
            $allConnectors += @{ Type = 'Network'; Index = $i; IsInput = $true }
        }
        
        # Distribute connectors around the perimeter
        $count = $allConnectors.Count
        if ($count -eq 0) { return $positions }
        
        $perimeter = 2 * ($boxWidth + $boxHeight)
        $spacing = $perimeter / [Math]::Max(1, $count)
        
        for ($idx = 0; $idx -lt $count; $idx++) {
            $conn = $allConnectors[$idx]
            $distance = $idx * $spacing
            
            # Determine which edge and position
            if ($distance -lt $boxWidth) {
                # Top edge
                $x = $boxLeft + $distance
                $y = $boxTop
                $angle = if ($conn.IsInput) { 90 } else { -90 }
            } elseif ($distance -lt ($boxWidth + $boxHeight)) {
                # Right edge
                $x = $boxLeft + $boxWidth
                $y = $boxTop + ($distance - $boxWidth)
                $angle = if ($conn.IsInput) { 180 } else { 0 }
            } elseif ($distance -lt (2 * $boxWidth + $boxHeight)) {
                # Bottom edge
                $x = $boxLeft + $boxWidth - ($distance - $boxWidth - $boxHeight)
                $y = $boxTop + $boxHeight
                $angle = if ($conn.IsInput) { -90 } else { 90 }
            } else {
                # Left edge
                $x = $boxLeft
                $y = $boxTop + $boxHeight - ($distance - 2 * $boxWidth - $boxHeight)
                $angle = if ($conn.IsInput) { 0 } else { 180 }
            }
            
            $positions += @{
                Type = $conn.Type
                Index = $conn.Index
                IsInput = $conn.IsInput
                X = [int]$x
                Y = [int]$y
                Angle = $angle
                CenterX = [int]$centerX
                CenterY = [int]$centerY
            }
        }
        
        return $positions
    }

    $updateConnectorBounds = {
        param($device, $typeCombo, $indexUpDown)
        if (-not $device -or -not $typeCombo.SelectedItem) {
            $indexUpDown.Minimum = 0
            $indexUpDown.Maximum = 0
            $indexUpDown.Value = 0
            return
        }
        $count = Get-AVPNConnectorCount -Device $device -ConnectorType $typeCombo.SelectedItem
        if ($count -le 0) {
            $indexUpDown.Minimum = 0
            $indexUpDown.Maximum = 0
            $indexUpDown.Value = 0
        } else {
            $indexUpDown.Minimum = 0
            $indexUpDown.Maximum = $count - 1
            if ($indexUpDown.Value -gt ($count - 1)) { $indexUpDown.Value = 0 }
        }
    }

    $getNextPosition = {
        $grid = [math]::Max(1, [int]$gridSizeUpDown.Value)
        $cols = [int][Math]::Max(1, [Math]::Floor(($canvas.DisplayRectangle.Width - 10) / 200))
        $row = [math]::Floor($script:placementIndex / $cols)
        $col = $script:placementIndex % $cols
        $script:placementIndex++
        $x = 4 + ($col * 200)
        $y = 4 + ($row * 120)
        $x = [math]::Round($x / $grid) * $grid
        $y = [math]::Round($y / $grid) * $grid
        return [System.Drawing.Point]::new($x, $y)
    }

    $snapToGrid = {
        param($control)
        $grid = [int]$gridSizeUpDown.Value
        if ($grid -le 0) { return }
        $alignedX = [math]::Round($control.Left / $grid) * $grid
        $alignedY = [math]::Round($control.Top / $grid) * $grid
        $control.Location = New-Object System.Drawing.Point($alignedX, $alignedY)
    }

    $refreshInventoryUI = {
        $inventoryList.Items.Clear()
        $srcDeviceCombo.Items.Clear()
        $destDeviceCombo.Items.Clear()
        $canvas.Controls.Clear()
        $deviceControls.Clear()

        # Ensure all inventory items have user-defined fields
        $invIndex = 0
        foreach ($device in $inventory) {
            $invIndex++
            
            # Ensure device has all required properties
            if (-not $device.PSObject.Properties['deviceId']) {
                $device | Add-Member -NotePropertyName 'deviceId' -NotePropertyValue $invIndex -Force
            }
            if (-not $device.PSObject.Properties['urlLink']) {
                $device | Add-Member -NotePropertyName 'urlLink' -NotePropertyValue '' -Force
            }
            if (-not $device.PSObject.Properties['loginUser']) {
                $device | Add-Member -NotePropertyName 'loginUser' -NotePropertyValue '' -Force
            }
            if (-not $device.PSObject.Properties['loginPassword']) {
                $device | Add-Member -NotePropertyName 'loginPassword' -NotePropertyValue '' -Force
            }
            
            # Create inventory list item with all fields
            $item = New-Object System.Windows.Forms.ListViewItem($device.deviceId.ToString())
            [void]$item.SubItems.Add($device.name)
            [void]$item.SubItems.Add($device.type)
            [void]$item.SubItems.Add($device.model)
            [void]$item.SubItems.Add([string]$device.avInputs)
            [void]$item.SubItems.Add([string]$device.avOutputs)
            [void]$item.SubItems.Add([string]$device.powerInputs)
            [void]$item.SubItems.Add([string]$device.powerOutputs)
            [void]$item.SubItems.Add([string]$device.networkInterfaces)
            [void]$item.SubItems.Add([string]$device.usbInputs)
            [void]$item.SubItems.Add([string]$device.usbPlugs)
            $urlDisplay = if ($device.PSObject.Properties['urlLink'] -and $device.urlLink) { $device.urlLink } else { "" }
            [void]$item.SubItems.Add([string]$urlDisplay)
            $userDisplay = if ($device.PSObject.Properties['loginUser'] -and $device.loginUser) { $device.loginUser } else { "" }
            [void]$item.SubItems.Add([string]$userDisplay)
            $passDisplay = if ($device.PSObject.Properties['loginPassword'] -and $device.loginPassword) { "***" } else { "" }
            [void]$item.SubItems.Add([string]$passDisplay)
            [void]$item.SubItems.Add($device.instanceId)
            $item.Tag = $device.instanceId
            $inventoryList.Items.Add($item) | Out-Null

            $srcDeviceCombo.Items.Add("$invIndex - $($device.name)") | Out-Null
            $destDeviceCombo.Items.Add("$invIndex - $($device.name)") | Out-Null

            $box = New-Object System.Windows.Forms.GroupBox
            $box.Size = New-Object System.Drawing.Size(180, 100)
            $box.Text = "$invIndex - $($device.name)"
            $box.Tag = $device.instanceId

            # Highlight unpowered devices in yellow
            $needsPower = ([int]$device.powerInputs -gt 0)
            $hasPower = $false
            if ($needsPower) {
                for ($pi = 0; $pi -lt [int]$device.powerInputs; $pi++) {
                    $pwrConn = $connections | Where-Object {
                        $_.DestInstance -eq $device.instanceId -and $_.DestConnector -eq "Power Input:$pi"
                    }
                    if ($pwrConn) { $hasPower = $true; break }
                }
            }
            if ($needsPower -and -not $hasPower) {
                $box.BackColor = [System.Drawing.Color]::LightYellow
            } else {
                $box.BackColor = [System.Drawing.Color]::White
            }

            $label = New-Object System.Windows.Forms.Label
            $label.AutoSize = $false
            $label.Size = New-Object System.Drawing.Size(170, 60)
            $label.Location = New-Object System.Drawing.Point(6, 30)
            $label.Text = "AV: $($device.avInputs) in / $($device.avOutputs) out`r`nPWR: $($device.powerInputs) in / $($device.powerOutputs) out`r`nNET: $($device.networkInterfaces) USB: $($device.usbInputs) in / $($device.usbPlugs) plug"
            $box.Controls.Add($label)

            if ($device.location) {
                $parts = $device.location -split ","
                if ($parts.Count -eq 2) {
                    $box.Location = New-Object System.Drawing.Point([int]$parts[0], [int]$parts[1])
                }
            } else {
                $pos = & $getNextPosition
                $box.Location = $pos
                # Safely set location property
                $locValue = "$($pos.X),$($pos.Y)"
                if ($device.PSObject.Properties['location']) {
                    $device.location = $locValue
                } else {
                    $device | Add-Member -NotePropertyName 'location' -NotePropertyValue $locValue -Force
                }
            }

            $box.Add_MouseDown({
                $dragState.Active = $true
                $dragState.Control = $this
                $dragState.Offset = [System.Drawing.Point]::new($args[1].X, $args[1].Y)
            })
            $box.Add_MouseMove({
                if (-not $dragState.Active) { return }
                $newX = $this.Left + ($args[1].X - $dragState.Offset.X)
                $newY = $this.Top + ($args[1].Y - $dragState.Offset.Y)
                $this.Location = New-Object System.Drawing.Point($newX, $newY)
                $canvas.Invalidate()
            })
            $box.Add_MouseUp({
                $dragState.Active = $false
                $dragState.Control = $null
                $dragState.Offset = $null
                if ($snapGridCheck.Checked) { & $snapToGrid $this }
                
                # Find device by instanceId and update location safely
                $instanceId = $this.Tag
                $targetDevice = $inventory | Where-Object { $_.instanceId -eq $instanceId } | Select-Object -First 1
                if ($targetDevice) {
                    $newLocation = "$($this.Left),$($this.Top)"
                    if ($targetDevice.PSObject.Properties['location']) {
                        $targetDevice.location = $newLocation
                    } else {
                        $targetDevice | Add-Member -NotePropertyName 'location' -NotePropertyValue $newLocation -Force
                    }
                }
            })

            $canvas.Controls.Add($box)
            $deviceControls[$device.instanceId] = $box
        }

        $connList.Items.Clear()
        foreach ($conn in $connections) {
            $srcDevice = $inventory | Where-Object { $_.instanceId -eq $conn.SourceInstance }
            $destDevice = $inventory | Where-Object { $_.instanceId -eq $conn.DestInstance }
            $srcLabel = if ($srcDevice) { "$($srcDevice.name)" } else { $conn.SourceInstance }
            $destLabel = if ($destDevice) { "$($destDevice.name)" } else { $conn.DestInstance }
            $listItem = New-Object System.Windows.Forms.ListViewItem($srcLabel)
            [void]$listItem.SubItems.Add($destLabel)
            [void]$listItem.SubItems.Add("$($conn.SourceConnector) -> $($conn.DestConnector)")
            $connList.Items.Add($listItem) | Out-Null
        }
    }

    $canvas.Add_Paint({
        $g = $args[1].Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        
        # Draw grid if enabled
        $grid = [int]$gridSizeUpDown.Value
        if ($showGridCheck.Checked -and $grid -gt 0) {
            $rect = $canvas.DisplayRectangle
            $penGrid = New-Object System.Drawing.Pen([System.Drawing.Color]::Gainsboro, 1)
            for ($x = 0; $x -lt $rect.Width; $x += $grid) { $g.DrawLine($penGrid, $x, 0, $x, $rect.Height) }
            for ($y = 0; $y -lt $rect.Height; $y += $grid) { $g.DrawLine($penGrid, 0, $y, $rect.Width, $y) }
            $penGrid.Dispose()
        }
        
        # Draw connection lines with colors
        foreach ($conn in $connections) {
            if (-not $deviceControls.ContainsKey($conn.SourceInstance)) { continue }
            if (-not $deviceControls.ContainsKey($conn.DestInstance)) { continue }
            
            $srcBox = $deviceControls[$conn.SourceInstance]
            $destBox = $deviceControls[$conn.DestInstance]
            $srcDevice = $inventory | Where-Object { $_.instanceId -eq $conn.SourceInstance } | Select-Object -First 1
            $destDevice = $inventory | Where-Object { $_.instanceId -eq $conn.DestInstance } | Select-Object -First 1
            
            if (-not $srcDevice -or -not $destDevice) { continue }
            
            # Parse connector type from connector string (e.g., "AV Output:0")
            $srcType = ($conn.SourceConnector -split ':')[0]
            $destType = ($conn.DestConnector -split ':')[0]
            
            # Get color for this connection type
            $color = & $getConnectorColor $srcType
            
            # Get connector positions
            $srcPositions = & $getConnectorPositions $srcDevice $srcBox
            $destPositions = & $getConnectorPositions $destDevice $destBox
            
            # Find specific connector endpoints
            $srcConnIdx = [int](($conn.SourceConnector -split ':')[1])
            $destConnIdx = [int](($conn.DestConnector -split ':')[1])
            
            $srcPos = $srcPositions | Where-Object { $_.Type -eq $srcType -and $_.Index -eq $srcConnIdx } | Select-Object -First 1
            $destPos = $destPositions | Where-Object { $_.Type -eq $destType -and $_.Index -eq $destConnIdx } | Select-Object -First 1
            
            if ($srcPos -and $destPos) {
                $pen = New-Object System.Drawing.Pen($color, 3)
                $g.DrawLine($pen, $srcPos.X, $srcPos.Y, $destPos.X, $destPos.Y)
                $pen.Dispose()
            }
        }
        
        # Draw connector shapes on each device (unique per interface type)
        foreach ($device in $inventory) {
            if (-not $deviceControls.ContainsKey($device.instanceId)) { continue }
            $box = $deviceControls[$device.instanceId]
            $positions = & $getConnectorPositions $device $box
            
            foreach ($pos in $positions) {
                $color = & $getConnectorColor $pos.Type
                $fillBrush = if ($pos.IsInput) { 
                    New-Object System.Drawing.SolidBrush($color) 
                } else { 
                    New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
                }
                $pen = New-Object System.Drawing.Pen($color, 2)
                $shapeName = if ($connectorShapes.ContainsKey($pos.Type)) { $connectorShapes[$pos.Type] } else { 'circle' }
                $sz = 7

                switch ($shapeName) {
                    'circle' {
                        # AV connectors -- filled/hollow circle
                        $g.FillEllipse($fillBrush, ($pos.X - $sz), ($pos.Y - $sz), ($sz * 2), ($sz * 2))
                        $g.DrawEllipse($pen, ($pos.X - $sz), ($pos.Y - $sz), ($sz * 2), ($sz * 2))
                    }
                    'rect' {
                        # Power connectors -- filled/hollow rectangle (plug shape)
                        $g.FillRectangle($fillBrush, ($pos.X - $sz), ($pos.Y - $sz), ($sz * 2), ($sz * 2))
                        $g.DrawRectangle($pen, ($pos.X - $sz), ($pos.Y - $sz), ($sz * 2), ($sz * 2))
                    }
                    'diamond' {
                        # Network connectors -- rotated square (diamond)
                        $dpts = New-Object 'System.Drawing.Point[]' 4
                        $dpts[0] = [System.Drawing.Point]::new($pos.X, $pos.Y - $sz)
                        $dpts[1] = [System.Drawing.Point]::new($pos.X + $sz, $pos.Y)
                        $dpts[2] = [System.Drawing.Point]::new($pos.X, $pos.Y + $sz)
                        $dpts[3] = [System.Drawing.Point]::new($pos.X - $sz, $pos.Y)
                        $g.FillPolygon($fillBrush, $dpts)
                        $g.DrawPolygon($pen, $dpts)
                    }
                    'roundrect' {
                        # USB connectors -- rounded rectangle
                        $rr = $sz * 2
                        $radius = 4
                        $rrRect = [System.Drawing.Rectangle]::new(($pos.X - $sz), ($pos.Y - [int]($sz * 0.7)), $rr, [int]($sz * 1.4))
                        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
                        $path.AddArc($rrRect.X, $rrRect.Y, $radius, $radius, 180, 90)
                        $path.AddArc($rrRect.Right - $radius, $rrRect.Y, $radius, $radius, 270, 90)
                        $path.AddArc($rrRect.Right - $radius, $rrRect.Bottom - $radius, $radius, $radius, 0, 90)
                        $path.AddArc($rrRect.X, $rrRect.Bottom - $radius, $radius, $radius, 90, 90)
                        $path.CloseFigure()
                        $g.FillPath($fillBrush, $path)
                        $g.DrawPath($pen, $path)
                        $path.Dispose()
                    }
                }
                
                # Draw index number near connector
                $font = New-Object System.Drawing.Font('Arial', 7, [System.Drawing.FontStyle]::Bold)
                $textBrush = New-Object System.Drawing.SolidBrush($color)
                $text = "$($pos.Index)"
                $textSize = $g.MeasureString($text, $font)
                $textX = $pos.X - ($textSize.Width / 2)
                $textY = $pos.Y - ($textSize.Height / 2)
                $g.DrawString($text, $font, $textBrush, $textX, $textY)
                
                if ($fillBrush -is [System.Drawing.SolidBrush]) { $fillBrush.Dispose() }
                $pen.Dispose()
                $font.Dispose()
                $textBrush.Dispose()
            }
        }
        
        # Draw drag preview line if dragging a connector
        if ($connectorDragState.Active -and $connectorDragState.MousePos) {
            $srcDevice = $inventory | Where-Object { $_.instanceId -eq $connectorDragState.SourceDevice } | Select-Object -First 1
            if ($srcDevice -and $deviceControls.ContainsKey($srcDevice.instanceId)) {
                $box = $deviceControls[$srcDevice.instanceId]
                $positions = & $getConnectorPositions $srcDevice $box
                $srcPos = $positions | Where-Object { 
                    $_.Type -eq $connectorDragState.SourceType -and $_.Index -eq $connectorDragState.SourceIndex 
                } | Select-Object -First 1
                
                if ($srcPos) {
                    $color = & $getConnectorColor $connectorDragState.SourceType
                    $pen = New-Object System.Drawing.Pen($color, 2)
                    $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
                    $g.DrawLine($pen, $srcPos.X, $srcPos.Y, $connectorDragState.MousePos.X, $connectorDragState.MousePos.Y)
                    $pen.Dispose()
                }
            }
        }
    })

    # ── Helper: find all matching available input connectors for a given output ──
    $getMatchingInputs = {
        param([string]$srcInstanceId, [string]$srcType, [int]$srcIndex)
        # Determine the matching input type
        $inputType = switch ($srcType) {
            'AV Output'    { 'AV Input' }
            'Power Output' { 'Power Input' }
            'USB Plug'     { 'USB Input' }
            'Network'      { 'Network' }
            default        { $null }
        }
        if (-not $inputType) { return @() }

        $matches = @()
        foreach ($dev in $inventory) {
            if ($dev.instanceId -eq $srcInstanceId -and $inputType -ne 'Network') { continue }
            $count = Get-AVPNConnectorCount -Device $dev -ConnectorType $inputType
            for ($i = 0; $i -lt $count; $i++) {
                # Check if this input port is already connected
                $alreadyUsed = $connections | Where-Object {
                    $_.DestInstance -eq $dev.instanceId -and $_.DestConnector -eq "${inputType}:$i"
                }
                if (-not $alreadyUsed) {
                    $matches += @{ Device = $dev; Type = $inputType; Index = $i }
                }
            }
        }
        return $matches
    }

    # ── Helper: check whether a Power Input port is already connected ──
    $isPowerInputUsed = {
        param([string]$instanceId, [int]$portIndex)
        $used = $connections | Where-Object {
            $_.DestInstance -eq $instanceId -and $_.DestConnector -eq "Power Input:$portIndex"
        }
        return [bool]$used
    }

    # Canvas mouse handlers for connector drag-and-drop
    $canvas.Add_MouseDown({
        $mouseX = $args[1].X
        $mouseY = $args[1].Y
        $btn    = $args[1].Button

        # ── RIGHT-CLICK on output connector → quick-connect context menu ──
        if ($btn -eq [System.Windows.Forms.MouseButtons]::Right) {
            foreach ($device in $inventory) {
                if (-not $deviceControls.ContainsKey($device.instanceId)) { continue }
                $box = $deviceControls[$device.instanceId]
                $positions = & $getConnectorPositions $device $box

                foreach ($pos in $positions) {
                    $dx = $mouseX - $pos.X
                    $dy = $mouseY - $pos.Y
                    if ([Math]::Sqrt($dx * $dx + $dy * $dy) -ge 14) { continue }

                    # Only show menu for output-type connectors (or Network as bidirectional)
                    if ($pos.IsInput -and $pos.Type -ne 'Network') { continue }

                    $matchList = & $getMatchingInputs $device.instanceId $pos.Type $pos.Index
                    if ($matchList.Count -eq 0) { continue }

                    $ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip
                    foreach ($m in $matchList) {
                        $label = "$($m.Device.name) -- $($m.Type):$($m.Index)"
                        $mi = New-Object System.Windows.Forms.ToolStripMenuItem($label)
                        # Capture closure variables
                        $mi.Tag = @{
                            SrcInst = $device.instanceId
                            SrcConn = "$($pos.Type):$($pos.Index)"
                            DstInst = $m.Device.instanceId
                            DstConn = "$($m.Type):$($m.Index)"
                        }
                        $mi.Add_Click({
                            $t = $this.Tag
                            $newConn = [pscustomobject]@{
                                SourceInstance  = $t.SrcInst
                                SourceConnector = $t.SrcConn
                                DestInstance    = $t.DstInst
                                DestConnector   = $t.DstConn
                            }
                            $dup = $connections | Where-Object {
                                $_.SourceInstance  -eq $newConn.SourceInstance -and
                                $_.SourceConnector -eq $newConn.SourceConnector -and
                                $_.DestInstance    -eq $newConn.DestInstance -and
                                $_.DestConnector   -eq $newConn.DestConnector
                            }
                            if (-not $dup) {
                                [void]$connections.Add($newConn)
                                & $refreshInventoryUI
                                $canvas.Invalidate()
                            }
                        })
                        [void]$ctxMenu.Items.Add($mi)
                    }
                    $ctxMenu.Show($canvas, $mouseX, $mouseY)
                    return   # handled
                }
            }
            return   # right-click but not on a connector -- do nothing
        }
        
        # ── LEFT-CLICK: existing drag logic ──
        # Check if clicking near any connector
        foreach ($device in $inventory) {
            if (-not $deviceControls.ContainsKey($device.instanceId)) { continue }
            $box = $deviceControls[$device.instanceId]
            $positions = & $getConnectorPositions $device $box
            
            foreach ($pos in $positions) {
                $dx = $mouseX - $pos.X
                $dy = $mouseY - $pos.Y
                $distance = [Math]::Sqrt($dx * $dx + $dy * $dy)
                
                if ($distance -lt 12) {
                    # Start connector drag
                    $connectorDragState.Active = $true
                    $connectorDragState.SourceDevice = $device.instanceId
                    $connectorDragState.SourceType = $pos.Type
                    $connectorDragState.SourceIndex = $pos.Index
                    $connectorDragState.SourceIsInput = $pos.IsInput
                    $connectorDragState.MousePos = [System.Drawing.Point]::new($mouseX, $mouseY)
                    return
                }
            }
        }
    })

    $canvas.Add_MouseMove({
        if ($connectorDragState.Active) {
            $connectorDragState.MousePos = [System.Drawing.Point]::new($args[1].X, $args[1].Y)
            $canvas.Invalidate()
        }
    })

    $canvas.Add_MouseUp({
        if (-not $connectorDragState.Active) { return }
        
        $mouseX = $args[1].X
        $mouseY = $args[1].Y
        
        # Check if released near a compatible connector
        foreach ($device in $inventory) {
            if ($device.instanceId -eq $connectorDragState.SourceDevice) { continue }
            if (-not $deviceControls.ContainsKey($device.instanceId)) { continue }
            
            $box = $deviceControls[$device.instanceId]
            $positions = & $getConnectorPositions $device $box
            
            foreach ($pos in $positions) {
                $dx = $mouseX - $pos.X
                $dy = $mouseY - $pos.Y
                $distance = [Math]::Sqrt($dx * $dx + $dy * $dy)
                
                if ($distance -lt 12) {
                    # Check compatibility
                    $srcType = $connectorDragState.SourceType
                    $destType = $pos.Type
                    $srcIsInput = $connectorDragState.SourceIsInput
                    $destIsInput = $pos.IsInput
                    
                    # Must be opposite types (input to output or output to input) and same base type
                    $srcBase = $srcType -replace ' (Input|Output|Plug)$', ''
                    $destBase = $destType -replace ' (Input|Output|Plug)$', ''
                    
                    if ($srcIsInput -ne $destIsInput -and $srcBase -eq $destBase) {
                        # Valid connection - determine source and dest based on input/output
                        if ($srcIsInput) {
                            # Source is input, so connection is from dest (output) to source (input)
                            $connSourceInst = $device.instanceId
                            $connSourceType = $destType
                            $connSourceIdx = $pos.Index
                            $connDestInst = $connectorDragState.SourceDevice
                            $connDestType = $srcType
                            $connDestIdx = $connectorDragState.SourceIndex
                        } else {
                            # Source is output, so connection is from source (output) to dest (input)
                            $connSourceInst = $connectorDragState.SourceDevice
                            $connSourceType = $srcType
                            $connSourceIdx = $connectorDragState.SourceIndex
                            $connDestInst = $device.instanceId
                            $connDestType = $destType
                            $connDestIdx = $pos.Index
                        }
                        
                        # Create connection
                        $newConn = [pscustomobject]@{
                            SourceInstance = $connSourceInst
                            SourceConnector = "${connSourceType}:$connSourceIdx"
                            DestInstance = $connDestInst
                            DestConnector = "${connDestType}:$connDestIdx"
                        }
                        
                        # Check if connection already exists
                        $exists = $connections | Where-Object {
                            $_.SourceInstance -eq $newConn.SourceInstance -and
                            $_.SourceConnector -eq $newConn.SourceConnector -and
                            $_.DestInstance -eq $newConn.DestInstance -and
                            $_.DestConnector -eq $newConn.DestConnector
                        }
                        
                        if (-not $exists) {
                            [void]$connections.Add($newConn)
                            & $refreshInventoryUI
                        }
                        
                        break
                    }
                }
            }
        }
        
        # Reset drag state
        $connectorDragState.Active = $false
        $connectorDragState.SourceDevice = $null
        $connectorDragState.SourceType = $null
        $connectorDragState.SourceIndex = $null
        $connectorDragState.SourceIsInput = $null
        $connectorDragState.MousePos = $null
        $canvas.Invalidate()
    })

    $manageTypesBtn.Add_Click({
        $templates = Show-AVPNDeviceTypeEditor -Templates $templates -LogCallback $LogCallback
        & $refreshTypeCombo
        & $refreshTemplateList
        
        if ($config.PSObject.Properties['avpnDevices']) {
            $config.avpnDevices = $templates
        } else {
            $config | Add-Member -NotePropertyName 'avpnDevices' -NotePropertyValue $templates -Force
        }
        if ($deviceTypesPath) {
            Save-AVPNDeviceTypeList -Templates $templates -DeviceTypesPath $deviceTypesPath
        }
        Save-AVPNConfig -ConfigData $config -ConfigPath $ConfigPath
    })

    $addBtn.Add_Click({
        if ($templateList.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show("Select a device template.", "AVPN") | Out-Null
            return
        }
        if ($filteredTemplates.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No templates available for the selected type.", "AVPN") | Out-Null
            return
        }
        $template = $filteredTemplates[$templateList.SelectedIndex]
        $quantity = [int]$qtyUpDown.Value
        for ($i = 0; $i -lt $quantity; $i++) {
            $instanceId = [guid]::NewGuid().ToString()
            $deviceName = if ($nameBox.Text.Trim()) { $nameBox.Text.Trim() } else { $template.name }
            $device = [ordered]@{
                instanceId = $instanceId
                deviceId = ($inventory.Count + 1)
                templateId = $template.id
                type = $template.type
                model = $template.model
                name = $deviceName
                quantity = 1
                location = ""
                avInputs = $template.avInputs
                avOutputs = $template.avOutputs
                powerInputs = $template.powerInputs
                powerOutputs = $template.powerOutputs
                networkInterfaces = $template.networkInterfaces
                usbInputs = $template.usbInputs
                usbPlugs = $template.usbPlugs
                connections = @()
                urlLink = ""
                loginUser = ""
                loginPassword = ""
            }
            [void]$inventory.Add($device)
        }
        $nameBox.Clear()
        $qtyUpDown.Value = 1
        & $refreshInventoryUI
        $canvas.Invalidate()
    })

    $removeBtn.Add_Click({
        if ($inventoryList.SelectedItems.Count -eq 0) { return }
        $selectedItemTag = $inventoryList.SelectedItems[0].Tag
        $device = $inventory | Where-Object { $_.instanceId -eq $selectedItemTag } | Select-Object -First 1
        if (-not $device) { return }
        [void]$inventory.Remove($device)
        # Remove connections referencing the deleted device from the shared ArrayList
        $toRemove = @($connections | Where-Object {
            $_.SourceInstance -eq $selectedItemTag -or $_.DestInstance -eq $selectedItemTag
        })
        foreach ($c in $toRemove) { [void]$connections.Remove($c) }
        & $refreshInventoryUI
        $canvas.Invalidate()
    })

    $editBtn.Add_Click({
        if ($inventoryList.SelectedItems.Count -eq 0) { return }
        $selectedItemTag = $inventoryList.SelectedItems[0].Tag
        $device = $inventory | Where-Object { $_.instanceId -eq $selectedItemTag } | Select-Object -First 1
        if (-not $device) { return }
        
        # Create device properties dialog
        $propForm = New-Object System.Windows.Forms.Form
        $propForm.Text = "Edit Device Info - $($device.name)"
        $propForm.Size = New-Object System.Drawing.Size(400, 280)
        $propForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $propForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $propForm.MaximizeBox = $false
        $propForm.MinimizeBox = $false
        $propForm.BackColor = [System.Drawing.Color]::White
        
        # Device name label and display
        $nameLabel = New-Object System.Windows.Forms.Label
        $nameLabel.Text = "Device Name:"
        $nameLabel.Location = New-Object System.Drawing.Point(10, 15)
        $nameLabel.Size = New-Object System.Drawing.Size(100, 20)
        $propForm.Controls.Add($nameLabel)
        
        $nameValue = New-Object System.Windows.Forms.Label
        $nameValue.Text = $device.name
        $nameValue.Location = New-Object System.Drawing.Point(120, 15)
        $nameValue.Size = New-Object System.Drawing.Size(260, 20)
        $propForm.Controls.Add($nameValue)
        
        # URL field
        $urlLabel = New-Object System.Windows.Forms.Label
        $urlLabel.Text = "Device URL:"
        $urlLabel.Location = New-Object System.Drawing.Point(10, 45)
        $urlLabel.Size = New-Object System.Drawing.Size(100, 20)
        $propForm.Controls.Add($urlLabel)
        
        $urlTextBox = New-Object System.Windows.Forms.TextBox
        $urlValue = if ($device.PSObject.Properties['urlLink']) { $device.urlLink } else { "" }
        $urlTextBox.Text = $urlValue
        $urlTextBox.Location = New-Object System.Drawing.Point(120, 45)
        $urlTextBox.Size = New-Object System.Drawing.Size(260, 20)
        $propForm.Controls.Add($urlTextBox)
        
        # Login user field
        $userLabel = New-Object System.Windows.Forms.Label
        $userLabel.Text = "Login User:"
        $userLabel.Location = New-Object System.Drawing.Point(10, 75)
        $userLabel.Size = New-Object System.Drawing.Size(100, 20)
        $propForm.Controls.Add($userLabel)
        
        $userTextBox = New-Object System.Windows.Forms.TextBox
        $userValue = if ($device.PSObject.Properties['loginUser']) { $device.loginUser } else { "" }
        $userTextBox.Text = $userValue
        $userTextBox.Location = New-Object System.Drawing.Point(120, 75)
        $userTextBox.Size = New-Object System.Drawing.Size(260, 20)
        $propForm.Controls.Add($userTextBox)
        
        # Login password field
        $passLabel = New-Object System.Windows.Forms.Label
        $passLabel.Text = "Login Password:"
        $passLabel.Location = New-Object System.Drawing.Point(10, 105)
        $passLabel.Size = New-Object System.Drawing.Size(100, 20)
        $propForm.Controls.Add($passLabel)
        
        $passTextBox = New-Object System.Windows.Forms.TextBox
        $passValue = if ($device.PSObject.Properties['loginPassword']) { $device.loginPassword } else { "" }
        $passTextBox.Text = $passValue
        $passTextBox.UseSystemPasswordChar = $true
        $passTextBox.Location = New-Object System.Drawing.Point(120, 105)
        $passTextBox.Size = New-Object System.Drawing.Size(260, 20)
        $propForm.Controls.Add($passTextBox)

        $showPassCheck = New-Object System.Windows.Forms.CheckBox
        $showPassCheck.Text = "Show Password"
        $showPassCheck.Location = New-Object System.Drawing.Point(120, 130)
        $showPassCheck.Size = New-Object System.Drawing.Size(140, 20)
        $showPassCheck.Add_CheckedChanged({
            $passTextBox.UseSystemPasswordChar = -not $showPassCheck.Checked
        })
        $propForm.Controls.Add($showPassCheck)
        
        # Save button
        $propSaveBtn = New-Object System.Windows.Forms.Button
        $propSaveBtn.Text = "Save"
        $propSaveBtn.Location = New-Object System.Drawing.Point(160, 210)
        $propSaveBtn.Size = New-Object System.Drawing.Size(90, 32)
        $propSaveBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $propForm.AcceptButton = $propSaveBtn
        $propForm.Controls.Add($propSaveBtn)
        
        # Cancel button
        $propCancelBtn = New-Object System.Windows.Forms.Button
        $propCancelBtn.Text = "Cancel"
        $propCancelBtn.Location = New-Object System.Drawing.Point(260, 210)
        $propCancelBtn.Size = New-Object System.Drawing.Size(90, 32)
        $propCancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $propForm.CancelButton = $propCancelBtn
        $propForm.Controls.Add($propCancelBtn)
        
        $result = $propForm.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            # Update device properties
            if ($device.PSObject.Properties['urlLink']) {
                $device.urlLink = $urlTextBox.Text
            } else {
                $device | Add-Member -NotePropertyName 'urlLink' -NotePropertyValue $urlTextBox.Text -Force
            }
            
            if ($device.PSObject.Properties['loginUser']) {
                $device.loginUser = $userTextBox.Text
            } else {
                $device | Add-Member -NotePropertyName 'loginUser' -NotePropertyValue $userTextBox.Text -Force
            }
            
            if ($device.PSObject.Properties['loginPassword']) {
                $device.loginPassword = $passTextBox.Text
            } else {
                $device | Add-Member -NotePropertyName 'loginPassword' -NotePropertyValue $passTextBox.Text -Force
            }
            
            # Refresh inventory UI to show updated values
            & $refreshInventoryUI
        }
        
        $propForm.Dispose()
    })

    $resetBtn.Add_Click({
        $script:placementIndex = 0
        foreach ($device in $inventory) {
            $pos = & $getNextPosition
            $locValue = "$($pos.X),$($pos.Y)"
            if ($device.PSObject.Properties['location']) {
                $device.location = $locValue
            } else {
                $device | Add-Member -NotePropertyName 'location' -NotePropertyValue $locValue -Force
            }
        }
        & $refreshInventoryUI
    })

    $alignBtn.Add_Click({
        foreach ($ctrl in $canvas.Controls) {
            & $snapToGrid $ctrl
        }
        foreach ($device in $inventory) {
            if ($deviceControls.ContainsKey($device.instanceId)) {
                $ctrl = $deviceControls[$device.instanceId]
                $locValue = "$($ctrl.Left),$($ctrl.Top)"
                if ($device.PSObject.Properties['location']) {
                    $device.location = $locValue
                } else {
                    $device | Add-Member -NotePropertyName 'location' -NotePropertyValue $locValue -Force
                }
            }
        }
        $canvas.Invalidate()
    })

    # ── Auto Plug All: connect every unconnected Power Input to an unused Power Output socket ──
    $autoPlugBtn.Add_Click({
        # Build list of available Power Output ports
        $availOutputs = New-Object System.Collections.ArrayList
        foreach ($dev in $inventory) {
            for ($p = 0; $p -lt [int]$dev.powerOutputs; $p++) {
                $used = $connections | Where-Object {
                    $_.SourceInstance -eq $dev.instanceId -and $_.SourceConnector -eq "Power Output:$p"
                }
                if (-not $used) {
                    [void]$availOutputs.Add(@{ Device = $dev; Index = $p })
                }
            }
        }

        # Build list of devices needing power
        $needPower = New-Object System.Collections.ArrayList
        foreach ($dev in $inventory) {
            for ($p = 0; $p -lt [int]$dev.powerInputs; $p++) {
                $used = $connections | Where-Object {
                    $_.DestInstance -eq $dev.instanceId -and $_.DestConnector -eq "Power Input:$p"
                }
                if (-not $used) {
                    [void]$needPower.Add(@{ Device = $dev; Index = $p })
                }
            }
        }

        $plugged = 0
        $unpowered = @()
        foreach ($need in $needPower) {
            if ($availOutputs.Count -eq 0) {
                $unpowered += $need.Device.name
                continue
            }
            $src = $availOutputs[0]
            $availOutputs.RemoveAt(0)
            $newConn = [pscustomobject]@{
                SourceInstance  = $src.Device.instanceId
                SourceConnector = "Power Output:$($src.Index)"
                DestInstance    = $need.Device.instanceId
                DestConnector   = "Power Input:$($need.Index)"
            }
            [void]$connections.Add($newConn)
            $plugged++
        }

        & $refreshInventoryUI
        $canvas.Invalidate()

        $msg = "Auto Plug: $plugged power connections made."
        if ($unpowered.Count -gt 0) {
            $uniqueNames = $unpowered | Select-Object -Unique
            $msg += "`r`n`r`nNo available power sockets for:`r`n- " + ($uniqueNames -join "`r`n- ")
            $msg += "`r`n`r`nThese devices are highlighted in yellow on the canvas."
        }
        [System.Windows.Forms.MessageBox]::Show($msg, "AVPN Auto Plug", [System.Windows.Forms.MessageBoxButtons]::OK,
            $(if ($unpowered.Count -gt 0) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information })) | Out-Null
    })

    $saveBtn.Add_Click({
        $defaultPath = Join-Path (Split-Path $ConfigPath -Parent) "AVPN-inventory.csv"
        Export-AVPNCsv -Inventory $inventory -Connections $connections -Path $defaultPath
        Invoke-AVPNLog -LogCallback $LogCallback -Message "Exported AVPN CSV to $defaultPath" -Level "Info"
        [System.Windows.Forms.MessageBox]::Show("Exported CSV to $defaultPath", "AVPN") | Out-Null
    })

    $saveAsBtn.Add_Click({
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = "CSV files (*.csv)|*.csv"
        $dialog.FileName = "AVPN-inventory.csv"
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Export-AVPNCsv -Inventory $inventory -Connections $connections -Path $dialog.FileName
            Invoke-AVPNLog -LogCallback $LogCallback -Message "Exported AVPN CSV to $($dialog.FileName)" -Level "Info"
        }
    })

    $loadBtn.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = "CSV files (*.csv)|*.csv"
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $result = Import-AVPNCsv -Path $dialog.FileName
                $inventory.Clear()
                if ($result.Inventory) { foreach ($item in $result.Inventory) { [void]$inventory.Add($item) } }
                $connections.Clear()
                if ($result.Connections) { foreach ($item in $result.Connections) { [void]$connections.Add($item) } }
                & $refreshInventoryUI
                $canvas.Invalidate()
                Invoke-AVPNLog -LogCallback $LogCallback -Message "Imported AVPN CSV from $($dialog.FileName)" -Level "Info"
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Failed to load AVPN CSV: $($_.Exception.Message)", "AVPN") | Out-Null
            }
        }
    })

    $srcDeviceCombo.Add_SelectedIndexChanged({
        if ($srcDeviceCombo.SelectedIndex -ge 0) {
            $device = $inventory[$srcDeviceCombo.SelectedIndex]
            & $updateConnectorBounds $device $srcTypeCombo $srcIndexUpDown
        }
    })

    $destDeviceCombo.Add_SelectedIndexChanged({
        if ($destDeviceCombo.SelectedIndex -ge 0) {
            $device = $inventory[$destDeviceCombo.SelectedIndex]
            & $updateConnectorBounds $device $destTypeCombo $destIndexUpDown
        }
    })

    $srcTypeCombo.Add_SelectedIndexChanged({
        if ($srcDeviceCombo.SelectedIndex -ge 0) {
            $device = $inventory[$srcDeviceCombo.SelectedIndex]
            & $updateConnectorBounds $device $srcTypeCombo $srcIndexUpDown
        }
    })

    $destTypeCombo.Add_SelectedIndexChanged({
        if ($destDeviceCombo.SelectedIndex -ge 0) {
            $device = $inventory[$destDeviceCombo.SelectedIndex]
            & $updateConnectorBounds $device $destTypeCombo $destIndexUpDown
        }
    })

    $addConnBtn.Add_Click({
        if ($srcDeviceCombo.SelectedIndex -lt 0 -or $destDeviceCombo.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show("Select source and destination devices.", "AVPN") | Out-Null
            return
        }
        if (-not $srcTypeCombo.SelectedItem -or -not $destTypeCombo.SelectedItem) {
            [System.Windows.Forms.MessageBox]::Show("Select connector types.", "AVPN") | Out-Null
            return
        }
        if ($srcDeviceCombo.SelectedIndex -eq $destDeviceCombo.SelectedIndex) {
            [System.Windows.Forms.MessageBox]::Show("Source and destination must be different devices.", "AVPN") | Out-Null
            return
        }
        $sourceDevice = $inventory[$srcDeviceCombo.SelectedIndex]
        $destDevice = $inventory[$destDeviceCombo.SelectedIndex]

        $srcType = $srcTypeCombo.SelectedItem
        $destType = $destTypeCombo.SelectedItem
        if (-not (Test-AVPNConnectionValid -SourceType $srcType -DestType $destType)) {
            [System.Windows.Forms.MessageBox]::Show("Invalid connection: $srcType -> $destType", "AVPN") | Out-Null
            return
        }
        if ((Get-AVPNConnectorCount -Device $sourceDevice -ConnectorType $srcType) -le 0) {
            [System.Windows.Forms.MessageBox]::Show("Source device has no $srcType connectors.", "AVPN") | Out-Null
            return
        }
        if ((Get-AVPNConnectorCount -Device $destDevice -ConnectorType $destType) -le 0) {
            [System.Windows.Forms.MessageBox]::Show("Destination device has no $destType connectors.", "AVPN") | Out-Null
            return
        }

        $srcIndex = [int]$srcIndexUpDown.Value
        $destIndex = [int]$destIndexUpDown.Value

        $conn = [pscustomobject]@{
            SourceInstance = $sourceDevice.instanceId
            SourceConnector = "${srcType}:$srcIndex"
            DestInstance = $destDevice.instanceId
            DestConnector = "${destType}:$destIndex"
        }
        [void]$connections.Add($conn)
        & $refreshInventoryUI
        $canvas.Invalidate()
    })

    $connRemoveBtn.Add_Click({
        if ($connList.SelectedItems.Count -eq 0) { return }
        $index = $connList.SelectedItems[0].Index
        if ($index -ge 0 -and $index -lt $connections.Count) {
            $connections.RemoveAt($index)
            & $refreshInventoryUI
            $canvas.Invalidate()
        }
    })

    $form.Add_FormClosing({
        foreach ($device in $inventory) {
            if ($device.PSObject.Properties['connections']) {
                $device.connections = @()
            } else {
                $device | Add-Member -NotePropertyName 'connections' -NotePropertyValue @() -Force
            }
        }
        foreach ($conn in $connections) {
            $srcDevice = $inventory | Where-Object { $_.instanceId -eq $conn.SourceInstance }
            if ($srcDevice) {
                if (-not $srcDevice.connections) {
                    if ($srcDevice.PSObject.Properties['connections']) {
                        $srcDevice.connections = @()
                    } else {
                        $srcDevice | Add-Member -NotePropertyName 'connections' -NotePropertyValue @() -Force
                    }
                }
                $srcDevice.connections += @{
                    sourceInstance = $conn.SourceInstance
                    sourceConnector = $conn.SourceConnector
                    destInstance = $conn.DestInstance
                    destConnector = $conn.DestConnector
                }
            }
        }
        if ($config.PSObject.Properties['inventory']) {
            $config.inventory = @($inventory)
        } else {
            $config | Add-Member -NotePropertyName 'inventory' -NotePropertyValue @($inventory) -Force
        }
        
        if ($config.PSObject.Properties['avpnDevices']) {
            $config.avpnDevices = @($templates)
        } else {
            $config | Add-Member -NotePropertyName 'avpnDevices' -NotePropertyValue @($templates) -Force
        }

        if ($deviceTypesPath) {
            Save-AVPNDeviceTypeList -Templates $templates -DeviceTypesPath $deviceTypesPath
        }
        
        Save-AVPNConfig -ConfigData $config -ConfigPath $ConfigPath
    })

    & $refreshInventoryUI
    if ($Owner) {
        $form.ShowDialog($Owner) | Out-Null
    } else {
        $form.ShowDialog() | Out-Null
    }
    $form.Dispose()
}

Export-ModuleMember -Function Show-AVPNConnectionTracker, Initialize-AVPNConfigFile, Get-AVPNConfig, Save-AVPNConfig











