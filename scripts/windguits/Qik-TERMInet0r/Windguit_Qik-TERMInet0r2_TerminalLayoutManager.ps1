<# 
    TerminalLayoutManager.ps1
    Single-file WPF, dark mode, tabbed UI, on-demand elevation (simplified but functional core).
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.IO.Compression.FileSystem

# -------------------- Globals --------------------
$ScriptPath     = $MyInvocation.MyCommand.Path
$ScriptDir      = Split-Path $ScriptPath
$ScriptBaseName = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
$HostName       = $env:COMPUTERNAME

$LayoutMemoryFile = Join-Path $ScriptDir ("{0}_layoutmemories.json" -f $ScriptBaseName)
$HostConfigZip    = Join-Path $ScriptDir ("{0}_terminalconfig_{1}.zip" -f $ScriptBaseName, $HostName)

# Layout options
$LayoutOptions = @(
    "OnePane",
    "TwoRows",
    "TwoColumns",
    "TwoSplits",
    "Quad"
)

# In-memory layout memory
$LayoutMemory = @{}

# -------------------- Layout Memory --------------------
function Load-LayoutMemory {
    if (Test-Path $LayoutMemoryFile) {
        try {
            $json = Get-Content $LayoutMemoryFile -Raw
            if ($json.Trim()) {
                $global:LayoutMemory = $json | ConvertFrom-Json
            }
        } catch {
            $global:LayoutMemory = @{}
        }
    } else {
        $global:LayoutMemory = @{}
    }
}

function Save-LayoutMemory {
    $LayoutMemory | ConvertTo-Json -Depth 5 | Set-Content -Path $LayoutMemoryFile -Encoding UTF8
}

function Get-ProfileLayoutSelection {
    param([string]$ProfileName)
    if ($LayoutMemory.ContainsKey($ProfileName)) {
        return $LayoutMemory[$ProfileName]
    } else {
        return "OnePane"
    }
}

function Set-ProfileLayoutSelection {
    param(
        [string]$ProfileName,
        [string]$LayoutKey
    )
    $LayoutMemory[$ProfileName] = $LayoutKey
}

# -------------------- Windows Terminal Profiles --------------------
function Get-WTSettingsPath {
    $base = Join-Path $env:LOCALAPPDATA "Packages"
    $wtPackage = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like "Microsoft.WindowsTerminal*" } |
                 Select-Object -First 1
    if (-not $wtPackage) { return $null }

    $settingsPath = Join-Path $wtPackage.FullName "LocalState\settings.json"
    if (Test-Path $settingsPath) { return $settingsPath }

    $profilesPath = Join-Path $wtPackage.FullName "LocalState\profiles.json"
    if (Test-Path $profilesPath) { return $profilesPath }

    return $null
}

function Get-WTProfiles {
    $settingsPath = Get-WTSettingsPath
    if (-not $settingsPath) { return @() }

    try {
        $json = Get-Content $settingsPath -Raw | ConvertFrom-Json
    } catch {
        return @()
    }

    $profiles = @()
    if ($json.profiles.list) {
        $profiles = $json.profiles.list
    } elseif ($json.profiles) {
        $profiles = $json.profiles
    }

    $profiles | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.name
            Commandline = $_.commandline
            Guid        = $_.guid
        }
    }
}

# -------------------- Layout → wt.exe args --------------------
function Get-WTLayoutArgs {
    param(
        [string]$ProfileName,
        [string]$LayoutKey
    )

    $base = "new-tab -p `"$ProfileName`""

    switch ($LayoutKey) {
        "OnePane"   { return $base }
        "TwoRows"   { return "$base ; split-pane -V -p `"$ProfileName`"" }
        "TwoColumns"{ return "$base ; split-pane -H -p `"$ProfileName`"" }
        "TwoSplits" { return "$base ; split-pane -H -p `"$ProfileName`" ; split-pane -V -p `"$ProfileName`"" }
        "Quad"      { return "$base ; split-pane -H -p `"$ProfileName`" ; split-pane -V -p `"$ProfileName`" ; split-pane -V -p `"$ProfileName`"" }
        default     { return $base }
    }
}

# -------------------- Ping Layout --------------------
function Start-PingLayout {
    param($PingGrid)

    $targets = @()
    foreach ($row in $PingGrid.Items) {
        if ($row -and $row.Host) {
            $val = $row.Host.ToString().Trim()
            if ($val) { $targets += $val }
        }
    }

    if (-not $targets) {
        [System.Windows.MessageBox]::Show("No ping targets specified.")
        return
    }

    $cmd = "wt.exe"
    $first = $true
    $cmdArgs = ""

    foreach ($t in $targets) {
        if ($first) {
            $cmdArgs += " new-tab powershell -NoLogo -NoExit -Command `"ping -t $t`""
            $first = $false
        } else {
            $cmdArgs += " ; split-pane -H powershell -NoLogo -NoExit -Command `"ping -t $t`""
        }
    }

    Start-Process $cmd -ArgumentList $cmdArgs
}

# -------------------- ARP (on-demand elevation) --------------------
function Invoke-ElevatedArp {
    param([string]$OutputPath)

    $helper = @"
param([string]`$OutPath)
`$arp = arp -a 2>`$null
`$arp | Set-Content -Path `$OutPath -Encoding UTF8
"@

    $tempHelper = Join-Path $env:TEMP ("ArpHelper_{0}.ps1" -f ([guid]::NewGuid()))
    $helper | Set-Content -Path $tempHelper -Encoding UTF8

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$tempHelper`" -OutPath `"$OutputPath`""
    $psi.Verb = "runas"
    $psi.UseShellExecute = $true

    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
    } catch {
        [System.Windows.MessageBox]::Show("ARP elevation cancelled or failed.")
    } finally {
        Remove-Item $tempHelper -ErrorAction SilentlyContinue
    }
}

function Run-ArpScan {
    param($ArpGrid)

    $tempOut = Join-Path $env:TEMP ("ArpOut_{0}.txt" -f ([guid]::NewGuid()))
    Invoke-ElevatedArp -OutputPath $tempOut

    if (-not (Test-Path $tempOut)) { return }

    $ArpGrid.Items.Clear()

    $arp = Get-Content $tempOut
    Remove-Item $tempOut -ErrorAction SilentlyContinue

    foreach ($line in $arp) {
        if ($line -match "^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F\-]+)\s+(\w+)") {
            $ip  = $matches[1]
            $mac = $matches[2]
            $typ = $matches[3]
            $obj = [PSCustomObject]@{
                IP   = $ip
                MAC  = $mac
                Type = $typ
            }
            $ArpGrid.Items.Add($obj) | Out-Null
        }
    }
}

function Export-ArpToHtml {
    param($ArpGrid)

    $rows = @()
    foreach ($row in $ArpGrid.Items) {
        if ($row) {
            $rows += [PSCustomObject]@{
                IPAddress = $row.IP
                MAC       = $row.MAC
                Type      = $row.Type
            }
        }
    }

    if (-not $rows) {
        [System.Windows.MessageBox]::Show("No ARP data to export.")
        return
    }

    $html = $rows | ConvertTo-Html -Title "ARP Table" -PreContent "<h1>ARP Table</h1>"
    $htmlPath = Join-Path $ScriptDir "ARPTable.html"
    $html | Set-Content -Path $htmlPath -Encoding UTF8
    Start-Process $htmlPath
}

# -------------------- Backup / Restore (on-demand elevation for restore) --------------------
function Get-WTConfigFiles {
    $settingsPath = Get-WTSettingsPath
    if (-not $settingsPath) { return @() }
    $dir = Split-Path $settingsPath
    Get-ChildItem $dir -File
}

function Save-TerminalConfig {
    [System.Windows.MessageBox]::Show("Saving terminal config to `n$HostConfigZip")

    if (Test-Path $HostConfigZip) {
        Remove-Item $HostConfigZip -Force
    }

    $tempDir = Join-Path $env:TEMP ("WTConfig_{0}_{1}" -f $HostName, (Get-Random))
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    try {
        $cfgFiles = Get-WTConfigFiles
        foreach ($f in $cfgFiles) {
            Copy-Item $f.FullName -Destination (Join-Path $tempDir $f.Name)
        }

        Copy-Item $ScriptPath -Destination (Join-Path $tempDir (Split-Path $ScriptPath -Leaf))

        $layoutFiles = Get-ChildItem $ScriptDir -Filter "*_layoutmemories*" -File -ErrorAction SilentlyContinue
        foreach ($lf in $layoutFiles) {
            Copy-Item $lf.FullName -Destination (Join-Path $tempDir $lf.Name)
        }

        [IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $HostConfigZip)
        [System.Windows.MessageBox]::Show("Saved terminal config to `n$HostConfigZip")
    } finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ElevatedRestore {
    param([string]$ZipPath)

    $helper = @"
param([string]`$ZipPath)
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-WTSettingsPath {
    `$base = Join-Path `$env:LOCALAPPDATA "Packages"
    `$wtPackage = Get-ChildItem `$base -Directory -ErrorAction SilentlyContinue |
                 Where-Object { `$_.Name -like "Microsoft.WindowsTerminal*" } |
                 Select-Object -First 1
    if (-not `$wtPackage) { return `$null }
    `$settingsPath = Join-Path `$wtPackage.FullName "LocalState\settings.json"
    if (Test-Path `$settingsPath) { return `$settingsPath }
    `$profilesPath = Join-Path `$wtPackage.FullName "LocalState\profiles.json"
    if (Test-Path `$profilesPath) { return `$profilesPath }
    return `$null
}
`$tempDir = Join-Path `$env:TEMP ("WTConfigRestore_{0}_{1}" -f `$env:COMPUTERNAME, (Get-Random))
New-Item -ItemType Directory -Path `$tempDir | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory(`$ZipPath, `$tempDir)
`$settingsPath = Get-WTSettingsPath
if (`$settingsPath) {
    `$cfgDir = Split-Path `$settingsPath
    `$extractedCfg = Get-ChildItem `$tempDir -File | Where-Object {
        `$_.Name -like "settings.json" -or `$_.Name -like "profiles.json"
    }
    foreach (`$f in `$extractedCfg) {
        Copy-Item `$f.FullName -Destination (Join-Path `$cfgDir `$f.Name) -Force
    }
}
`$extractedLayouts = Get-ChildItem `$tempDir -Filter "*_layoutmemories*" -File -ErrorAction SilentlyContinue
foreach (`$lf in `$extractedLayouts) {
    Copy-Item `$lf.FullName -Destination (Join-Path (Split-Path `$MyInvocation.MyCommand.Path) `$lf.Name) -Force
}
Remove-Item `$tempDir -Recurse -Force -ErrorAction SilentlyContinue
"@

    $tempHelper = Join-Path $env:TEMP ("WTConfigRestore_{0}.ps1" -f ([guid]::NewGuid()))
    $helper | Set-Content -Path $tempHelper -Encoding UTF8

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$tempHelper`" -ZipPath `"$ZipPath`""
    $psi.Verb = "runas"
    $psi.UseShellExecute = $true

    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        [System.Windows.MessageBox]::Show("Restore complete. You may need to restart Windows Terminal.")
    } catch {
        [System.Windows.MessageBox]::Show("Restore cancelled or failed.")
    } finally {
        Remove-Item $tempHelper -ErrorAction SilentlyContinue
    }
}

function Show-TerminalConfigInfo {
    $settingsPath = Get-WTSettingsPath
    if (-not $settingsPath) {
        [System.Windows.MessageBox]::Show("Windows Terminal settings not found.")
        return
    }
    $cfgDir = Split-Path $settingsPath
    $files  = Get-ChildItem $cfgDir -File
    $msg = "Settings path: $settingsPath`n`nFiles:`n"
    foreach ($f in $files) {
        $msg += " - {0} ({1} bytes)`n" -f $f.Name, $f.Length
    }
    [System.Windows.MessageBox]::Show($msg, "Terminal Config Info")
}

function Ensure-HostBaselineConfig {
    if (Test-Path $HostConfigZip) { return }
    $result = [System.Windows.MessageBox]::Show(
        "No terminal config zip found for host '$HostName'.`n`nCreate a baseline now?",
        "Baseline Config",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
        Save-TerminalConfig
    }
}

# -------------------- XAML (Dark Mode, Tabbed) --------------------
$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Terminal Layout & Profile Manager" Height="700" Width="1100"
        Background="#FF1E1E1E" Foreground="#FFE0E0E0" WindowStartupLocation="CenterScreen">
    <Window.Resources>
        <Style TargetType="TabControl">
            <Setter Property="Background" Value="#FF1E1E1E"/>
            <Setter Property="Foreground" Value="#FFE0E0E0"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Background" Value="#FF2A2A2A"/>
            <Setter Property="Foreground" Value="#FFE0E0E0"/>
            <Setter Property="BorderBrush" Value="#FF3A3A3A"/>
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#FF1E1E1E"/>
            <Setter Property="Foreground" Value="#FFE0E0E0"/>
            <Setter Property="GridLinesVisibility" Value="All"/>
            <Setter Property="BorderBrush" Value="#FF3A3A3A"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#FF3A3A3A"/>
            <Setter Property="Foreground" Value="#FFE0E0E0"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Padding" Value="5,2"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#FFE0E0E0"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#FFE0E0E0"/>
        </Style>
    </Window.Resources>
    <Grid>
        <TabControl Margin="5">
            <!-- Profiles Tab -->
            <TabItem Header="Profiles">
                <Grid Margin="5">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <DataGrid x:Name="ProfilesGrid" Grid.Row="0" AutoGenerateColumns="False" CanUserAddRows="False">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Profile Name" Binding="{Binding Name}" IsReadOnly="True" Width="*"/>
                            <DataGridComboBoxColumn Header="Layout" SelectedItemBinding="{Binding Layout}" Width="200">
                                <DataGridComboBoxColumn.ElementStyle>
                                    <Style TargetType="ComboBox">
                                        <Setter Property="ItemsSource" Value="{Binding RelativeSource={RelativeSource AncestorType=Window}, Path=Tag}"/>
                                    </Style>
                                </DataGridComboBoxColumn.ElementStyle>
                                <DataGridComboBoxColumn.EditingElementStyle>
                                    <Style TargetType="ComboBox">
                                        <Setter Property="ItemsSource" Value="{Binding RelativeSource={RelativeSource AncestorType=Window}, Path=Tag}"/>
                                    </Style>
                                </DataGridComboBoxColumn.EditingElementStyle>
                            </DataGridComboBoxColumn>
                        </DataGrid.Columns>
                    </DataGrid>
                    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,5,0,0">
                        <Button x:Name="BtnOpenLayouts" Content="Open Selected Layouts" Width="180"/>
                        <Button x:Name="BtnReloadProfiles" Content="Reload Profiles" Width="140"/>
                    </StackPanel>
                </Grid>
            </TabItem>

            <!-- Ping Tab -->
            <TabItem Header="Ping">
                <Grid Margin="5">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Text="Ping Targets (one per row):" Margin="0,0,0,5"/>
                    <DataGrid x:Name="PingGrid" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="True">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Host/IP" Binding="{Binding Host}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,5,0,0">
                        <Button x:Name="BtnOpenPingLayout" Content="Open Ping Layout" Width="150"/>
                    </StackPanel>
                </Grid>
            </TabItem>

            <!-- ARP Tab -->
            <TabItem Header="ARP">
                <Grid Margin="5">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <StackPanel Orientation="Horizontal" Grid.Row="0">
                        <CheckBox x:Name="ChkArp" Content="ARP local subnet" Margin="0,0,10,0"/>
                        <Button x:Name="BtnRunArp" Content="Run ARP" Width="100"/>
                        <Button x:Name="BtnArpHtml" Content="Export ARP to HTML" Width="160"/>
                    </StackPanel>
                    <DataGrid x:Name="ArpGrid" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" Margin="0,5,0,5">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="IP Address" Binding="{Binding IP}" Width="*"/>
                            <DataGridTextColumn Header="MAC Address" Binding="{Binding MAC}" Width="*"/>
                            <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Grid>
            </TabItem>

            <!-- Backup / Restore Tab -->
            <TabItem Header="Backup / Restore">
                <Grid Margin="5">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <StackPanel Orientation="Horizontal" Grid.Row="0">
                        <Button x:Name="BtnShowConfig" Content="Check & Show Config" Width="170"/>
                        <Button x:Name="BtnSaveConfig" Content="Save Config" Width="120"/>
                        <Button x:Name="BtnRestoreConfig" Content="Restore Config" Width="130"/>
                    </StackPanel>
                    <StackPanel Grid.Row="1" Margin="0,10,0,0">
                        <TextBlock Text="Script Path:"/>
                        <TextBlock x:Name="TxtScriptPath" Margin="0,0,0,5"/>
                        <TextBlock Text="Host Name:"/>
                        <TextBlock x:Name="TxtHostName" Margin="0,0,0,5"/>
                        <TextBlock Text="WT Settings Path:"/>
                        <TextBlock x:Name="TxtWTPath" Margin="0,0,0,5"/>
                    </StackPanel>
                </Grid>
            </TabItem>
        </TabControl>
    </Grid>
</Window>
"@

# -------------------- Build WPF Window --------------------
[xml]$xamlXml = $Xaml
$reader = New-Object System.Xml.XmlNodeReader $xamlXml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Expose layout options via Window.Tag
$window.Tag = $LayoutOptions

# Find controls
$ProfilesGrid    = $window.FindName("ProfilesGrid")
$BtnOpenLayouts  = $window.FindName("BtnOpenLayouts")
$BtnReloadProfiles = $window.FindName("BtnReloadProfiles")

$PingGrid        = $window.FindName("PingGrid")
$BtnOpenPingLayout = $window.FindName("BtnOpenPingLayout")

$ChkArp          = $window.FindName("ChkArp")
$BtnRunArp       = $window.FindName("BtnRunArp")
$BtnArpHtml      = $window.FindName("BtnArpHtml")
$ArpGrid         = $window.FindName("ArpGrid")

$BtnShowConfig   = $window.FindName("BtnShowConfig")
$BtnSaveConfig   = $window.FindName("BtnSaveConfig")
$BtnRestoreConfig= $window.FindName("BtnRestoreConfig")
$TxtScriptPath   = $window.FindName("TxtScriptPath")
$TxtHostName     = $window.FindName("TxtHostName")
$TxtWTPath       = $window.FindName("TxtWTPath")

# -------------------- Data Models --------------------
class ProfileLayoutRow {
    [string]$Name
    [string]$Layout
}

class PingRow {
    [string]$Host
}

class ArpRow {
    [string]$IP
    [string]$MAC
    [string]$Type
}

# -------------------- Populate Profiles Grid --------------------
function Load-ProfilesGrid {
    $ProfilesGrid.Items.Clear()
    $profiles = Get-WTProfiles
    foreach ($p in $profiles) {
        $row = [ProfileLayoutRow]::new()
        $row.Name   = $p.Name
        $row.Layout = Get-ProfileLayoutSelection -ProfileName $p.Name
        $ProfilesGrid.Items.Add($row) | Out-Null
    }
}

# -------------------- Wire Events --------------------
Load-LayoutMemory
Load-ProfilesGrid

$TxtScriptPath.Text = $ScriptPath
$TxtHostName.Text   = $HostName
$wtPath = Get-WTSettingsPath
$TxtWTPath.Text     = $wtPath

$BtnReloadProfiles.Add_Click({
    Load-ProfilesGrid
})

$BtnOpenLayouts.Add_Click({
    foreach ($row in $ProfilesGrid.Items) {
        if ($row.Name -and $row.Layout) {
            Set-ProfileLayoutSelection -ProfileName $row.Name -LayoutKey $row.Layout
        }
    }
    Save-LayoutMemory

    $cmd = "wt.exe"
    $args = ""
    $first = $true

    foreach ($row in $ProfilesGrid.Items) {
        if (-not $row.Name -or -not $row.Layout) { continue }
        $layoutArgs = Get-WTLayoutArgs -ProfileName $row.Name -LayoutKey $row.Layout
        if ($first) {
            $args += " $layoutArgs"
            $first = $false
        } else {
            $args += " ; $layoutArgs"
        }
    }

    if (-not $args.Trim()) {
        [System.Windows.MessageBox]::Show("No profiles/layouts selected.")
        return
    }

    Start-Process $cmd -ArgumentList $args
})

$BtnOpenPingLayout.Add_Click({
    Start-PingLayout -PingGrid $PingGrid
})

$BtnRunArp.Add_Click({
    if ($ChkArp.IsChecked -ne $true) {
        [System.Windows.MessageBox]::Show("ARP checkbox is not ticked.")
        return
    }
    Run-ArpScan -ArpGrid $ArpGrid
})

$BtnArpHtml.Add_Click({
    if ($ChkArp.IsChecked -ne $true) {
        [System.Windows.MessageBox]::Show("Enable ARP local subnet first.")
        return
    }
    Export-ArpToHtml -ArpGrid $ArpGrid
})

$BtnShowConfig.Add_Click({
    Show-TerminalConfigInfo
})

$BtnSaveConfig.Add_Click({
    Save-TerminalConfig
})

$BtnRestoreConfig.Add_Click({
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.InitialDirectory = $ScriptDir
    $ofd.Filter = "Zip files (*.zip)|*.zip|All files (*.*)|*.*"
    $ofd.Title  = "Select Terminal Config Zip"
    if ($ofd.ShowDialog() -eq $true) {
        Invoke-ElevatedRestore -ZipPath $ofd.FileName
    }
})

$window.Add_Closing({
    Ensure-HostBaselineConfig
})

# -------------------- Run --------------------
$window.ShowDialog() | Out-Null