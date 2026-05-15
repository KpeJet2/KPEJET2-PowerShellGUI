# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionBuildHistory:
#   2604.B1.V1.0  2026-04-10  Rebuilt from broken 2-B draft. SIN-compliant WPF rewrite of Qik-TERMInet0r.
# ============================================================
#  Windguit_Qik-TERMInet0r2-B_TerminalLayoutManager.ps1
#  Windows Terminal Layout & Profile Manager — WPF Edition (Dark)
#  Tabs: Profiles, Ping, ARP, Backup/Restore
#  Requires: Windows Terminal installed, PowerShell 5.1, .NET WPF
# ============================================================

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

$LayoutOptions = @("OnePane","TwoRows","TwoColumns","TwoSplits","Quad")
$LayoutMemory  = @{}

# -------------------- Layout Memory --------------------
function Load-LayoutMemory {
    [CmdletBinding()]
    param()
    if (Test-Path -LiteralPath $LayoutMemoryFile) {
        try {
            $json = Get-Content -LiteralPath $LayoutMemoryFile -Raw
            if ($json.Trim()) {
                $global:LayoutMemory = $json | ConvertFrom-Json
            }
        } catch {
            <# Intentional: non-fatal — reset to empty on corrupt JSON #>
            $global:LayoutMemory = @{}
        }
    } else {
        $global:LayoutMemory = @{}
    }
}

function Save-LayoutMemory {
    [CmdletBinding()]
    param()
    $LayoutMemory | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $LayoutMemoryFile -Encoding UTF8
}

function Get-ProfileLayoutSelection {
    [CmdletBinding()]
    param([string]$ProfileName)
    if ($LayoutMemory.ContainsKey($ProfileName)) {
        return $LayoutMemory[$ProfileName]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    return "OnePane"
}

function Set-ProfileLayoutSelection {
    [CmdletBinding()]
    param([string]$ProfileName, [string]$LayoutKey)
    $LayoutMemory[$ProfileName] = $LayoutKey  # SIN-EXEMPT:P027 -- index access, context-verified safe
}

# -------------------- Windows Terminal Helpers --------------------
function Get-WTSettingsPath {
    [CmdletBinding()]
    param()
    $base = Join-Path $env:LOCALAPPDATA "Packages"
    $wtPackage = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like "Microsoft.WindowsTerminal*" } |
                 Select-Object -First 1
    if (-not $wtPackage) { return $null }

    $settingsPath = Join-Path $wtPackage.FullName "LocalState\settings.json"
    if (Test-Path -LiteralPath $settingsPath) { return $settingsPath }

    $profilesPath = Join-Path $wtPackage.FullName "LocalState\profiles.json"
    if (Test-Path -LiteralPath $profilesPath) { return $profilesPath }

    return $null
}

function Get-WTProfiles {
    [CmdletBinding()]
    param()
    $settingsPath = Get-WTSettingsPath
    if (-not $settingsPath) { return @() }

    try {
        $json = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    } catch {
        <# Intentional: non-fatal — return empty list if settings unreadable #>
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

function Get-WTLayoutArgs {
    [CmdletBinding()]
    param([string]$ProfileName, [string]$LayoutKey)
    $base = "new-tab -p `"$ProfileName`""
    switch ($LayoutKey) {
        "OnePane"    { return $base }
        "TwoRows"    { return "$base ; split-pane -V -p `"$ProfileName`"" }
        "TwoColumns" { return "$base ; split-pane -H -p `"$ProfileName`"" }
        "TwoSplits"  { return "$base ; split-pane -H -p `"$ProfileName`" ; split-pane -V -p `"$ProfileName`"" }
        "Quad"       { return "$base ; split-pane -H -p `"$ProfileName`" ; split-pane -V -p `"$ProfileName`" ; split-pane -V -p `"$ProfileName`"" }
        default      { return $base }
    }
}

# -------------------- Ping Layout --------------------
function Start-PingLayout {
    [CmdletBinding()]
    param($PingGrid)

    $targets = @()
    foreach ($row in $PingGrid.Items) {
        if ($null -ne $row -and $row.Host) {
            $val = $row.Host.ToString().Trim()
            if ($val) { $targets += $val }
        }
    }

    if (@($targets).Count -eq 0) {
        [System.Windows.MessageBox]::Show("No ping targets specified.")
        return
    }

    $wtArgs = ""
    $first  = $true
    foreach ($t in $targets) {
        if ($first) {
            $wtArgs += " new-tab powershell -NoLogo -NoExit -Command `"ping -t $t`""
            $first = $false
        } else {
            $wtArgs += " ; split-pane -H powershell -NoLogo -NoExit -Command `"ping -t $t`""
        }
    }
    Start-Process "wt.exe" -ArgumentList $wtArgs
}

# -------------------- ARP (on-demand elevation) --------------------
function Invoke-ElevatedArp {
    [CmdletBinding()]
    param([string]$OutputPath)

    $helperCode = @'
param([string]$OutPath)
$arp = arp -a 2>$null
$arp | Set-Content -LiteralPath $OutPath -Encoding UTF8
'@

    $tempHelper = Join-Path $env:TEMP ("ArpHelper_{0}.ps1" -f ([guid]::NewGuid()))
    Set-Content -LiteralPath $tempHelper -Value $helperCode -Encoding UTF8

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = "powershell.exe"
    $psi.Arguments       = "-ExecutionPolicy Bypass -File `"$tempHelper`" -OutPath `"$OutputPath`""
    $psi.Verb            = "runas"
    $psi.UseShellExecute = $true

    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
    } catch {
        [System.Windows.MessageBox]::Show("ARP elevation cancelled or failed: $_")
    } finally {
        Remove-Item -LiteralPath $tempHelper -ErrorAction SilentlyContinue
    }
}

function Run-ArpScan {
    [CmdletBinding()]
    param($ArpGrid)

    $tempOut = Join-Path $env:TEMP ("ArpOut_{0}.txt" -f ([guid]::NewGuid()))
    Invoke-ElevatedArp -OutputPath $tempOut

    if (-not (Test-Path -LiteralPath $tempOut)) { return }

    $ArpGrid.Items.Clear()
    $arp = Get-Content -LiteralPath $tempOut
    Remove-Item -LiteralPath $tempOut -ErrorAction SilentlyContinue

    foreach ($line in $arp) {
        if ($line -match "^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F\-]+)\s+(\w+)") {
            $ArpGrid.Items.Add([PSCustomObject]@{
                IP   = $Matches[1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
                MAC  = $Matches[2]  # SIN-EXEMPT:P027 -- index access, context-verified safe
                Type = $Matches[3]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            }) | Out-Null
        }
    }
}

function Export-ArpToHtml {
    [CmdletBinding()]
    param($ArpGrid)

    $rows = @()
    foreach ($row in $ArpGrid.Items) {
        if ($null -ne $row) {
            $rows += [PSCustomObject]@{ IPAddress = $row.IP; MAC = $row.MAC; Type = $row.Type }
        }
    }

    if (@($rows).Count -eq 0) {
        [System.Windows.MessageBox]::Show("No ARP data to export.")
        return
    }

    $html     = $rows | ConvertTo-Html -Title "ARP Table" -PreContent "<h1>ARP Table</h1>"
    $htmlPath = Join-Path $ScriptDir "ARPTable.html"
    $html | Set-Content -LiteralPath $htmlPath -Encoding UTF8
    Start-Process $htmlPath
}

# -------------------- Backup / Restore --------------------
function Get-WTConfigFiles {
    [CmdletBinding()]
    param()
    $settingsPath = Get-WTSettingsPath
    if (-not $settingsPath) { return @() }
    Get-ChildItem (Split-Path $settingsPath) -File
}

function Show-TerminalConfigInfo {
    [CmdletBinding()]
    param()
    $settingsPath = Get-WTSettingsPath
    if (-not $settingsPath) {
        [System.Windows.MessageBox]::Show("Windows Terminal settings not found.")
        return
    }
    $files = Get-ChildItem (Split-Path $settingsPath) -File
    $msg   = "Settings path: $settingsPath`n`nFiles:`n"
    foreach ($f in $files) {
        $msg += " - {0} ({1} bytes)`n" -f $f.Name, $f.Length
    }
    [System.Windows.MessageBox]::Show($msg, "Terminal Config Info")
}

function Save-TerminalConfig {
    [CmdletBinding()]
    param()
    [System.Windows.MessageBox]::Show("Saving terminal config to:`n$HostConfigZip")

    if (Test-Path -LiteralPath $HostConfigZip) { Remove-Item -LiteralPath $HostConfigZip -Force }

    $tempDir = Join-Path $env:TEMP ("WTConfig_{0}_{1}" -f $HostName, (Get-Random))
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    try {
        foreach ($f in (Get-WTConfigFiles)) {
            Copy-Item $f.FullName -Destination (Join-Path $tempDir $f.Name)
        }
        Copy-Item $ScriptPath -Destination (Join-Path $tempDir (Split-Path $ScriptPath -Leaf))
        foreach ($lf in (Get-ChildItem $ScriptDir -Filter "*_layoutmemories*" -File -ErrorAction SilentlyContinue)) {
            Copy-Item $lf.FullName -Destination (Join-Path $tempDir $lf.Name)
        }
        [IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $HostConfigZip)
        [System.Windows.MessageBox]::Show("Saved terminal config to:`n$HostConfigZip")
    } catch {
        [System.Windows.MessageBox]::Show("Save failed: $_")
    } finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ElevatedRestore {
    [CmdletBinding()]
    param([string]$ZipPath)

    $helperCode = @'
param([string]$ZipPath)
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-WTSettingsPath {
    $base = Join-Path $env:LOCALAPPDATA "Packages"
    $wtPackage = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like "Microsoft.WindowsTerminal*" } |
                 Select-Object -First 1
    if (-not $wtPackage) { return $null }
    $sp = Join-Path $wtPackage.FullName "LocalState\settings.json"
    if (Test-Path -LiteralPath $sp) { return $sp }
    $pp = Join-Path $wtPackage.FullName "LocalState\profiles.json"
    if (Test-Path -LiteralPath $pp) { return $pp }
    return $null
}
$tempDir = Join-Path $env:TEMP ("WTConfigRestore_{0}_{1}" -f $env:COMPUTERNAME, (Get-Random))
New-Item -ItemType Directory -Path $tempDir | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $tempDir)
$settingsPath = Get-WTSettingsPath
if ($settingsPath) {
    $cfgDir = Split-Path $settingsPath
    foreach ($f in (Get-ChildItem $tempDir -File | Where-Object { $_.Name -like "settings.json" -or $_.Name -like "profiles.json" })) {
        Copy-Item $f.FullName -Destination (Join-Path $cfgDir $f.Name) -Force
    }
}
foreach ($lf in (Get-ChildItem $tempDir -Filter "*_layoutmemories*" -File -ErrorAction SilentlyContinue)) {
    Copy-Item $lf.FullName -Destination (Join-Path (Split-Path $MyInvocation.MyCommand.Path) $lf.Name) -Force
}
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
'@

    $tempHelper = Join-Path $env:TEMP ("WTConfigRestore_{0}.ps1" -f ([guid]::NewGuid()))
    Set-Content -LiteralPath $tempHelper -Value $helperCode -Encoding UTF8

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = "powershell.exe"
    $psi.Arguments       = "-ExecutionPolicy Bypass -File `"$tempHelper`" -ZipPath `"$ZipPath`""
    $psi.Verb            = "runas"
    $psi.UseShellExecute = $true

    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        [System.Windows.MessageBox]::Show("Restore complete. Restart Windows Terminal to apply.")
    } catch {
        [System.Windows.MessageBox]::Show("Restore cancelled or failed: $_")
    } finally {
        Remove-Item -LiteralPath $tempHelper -ErrorAction SilentlyContinue
    }
}

function Ensure-HostBaselineConfig {
    [CmdletBinding()]
    param()
    if (Test-Path -LiteralPath $HostConfigZip) { return }
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
        Title="Terminal Layout &amp; Profile Manager" Height="700" Width="1100"
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
                        <Button x:Name="BtnShowConfig" Content="Check &amp; Show Config" Width="170"/>
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

# Expose layout options via Window.Tag for DataGrid ComboBox bindings
$window.Tag = $LayoutOptions

# Find all named controls
$ProfilesGrid      = $window.FindName("ProfilesGrid")
$BtnOpenLayouts    = $window.FindName("BtnOpenLayouts")
$BtnReloadProfiles = $window.FindName("BtnReloadProfiles")
$PingGrid          = $window.FindName("PingGrid")
$BtnOpenPingLayout = $window.FindName("BtnOpenPingLayout")
$ChkArp            = $window.FindName("ChkArp")
$BtnRunArp         = $window.FindName("BtnRunArp")
$BtnArpHtml        = $window.FindName("BtnArpHtml")
$ArpGrid           = $window.FindName("ArpGrid")
$BtnShowConfig     = $window.FindName("BtnShowConfig")
$BtnSaveConfig     = $window.FindName("BtnSaveConfig")
$BtnRestoreConfig  = $window.FindName("BtnRestoreConfig")
$TxtScriptPath     = $window.FindName("TxtScriptPath")
$TxtHostName       = $window.FindName("TxtHostName")
$TxtWTPath         = $window.FindName("TxtWTPath")

# -------------------- Data-model classes --------------------
class ProfileLayoutRow {
    [string]$Name
    [string]$Layout
}

class PingRow {
    [string]$Host
}

# -------------------- Populate Profiles Grid --------------------
function Load-ProfilesGrid {
    [CmdletBinding()]
    param()
    $ProfilesGrid.Items.Clear()
    foreach ($p in (Get-WTProfiles)) {
        $row = [ProfileLayoutRow]::new()
        $row.Name   = $p.Name
        $row.Layout = Get-ProfileLayoutSelection -ProfileName $p.Name
        $ProfilesGrid.Items.Add($row) | Out-Null
    }
}

# -------------------- Initialise --------------------
Load-LayoutMemory
Load-ProfilesGrid

$TxtScriptPath.Text = $ScriptPath
$TxtHostName.Text   = $HostName
$TxtWTPath.Text     = (Get-WTSettingsPath)

# -------------------- Event Handlers --------------------
$BtnReloadProfiles.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    Load-ProfilesGrid
})

$BtnOpenLayouts.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    foreach ($row in $ProfilesGrid.Items) {
        if ($row.Name -and $row.Layout) {
            Set-ProfileLayoutSelection -ProfileName $row.Name -LayoutKey $row.Layout
        }
    }
    Save-LayoutMemory

    $wtArgs = ""
    $first  = $true
    foreach ($row in $ProfilesGrid.Items) {
        if (-not $row.Name -or -not $row.Layout) { continue }
        $layoutArgs = Get-WTLayoutArgs -ProfileName $row.Name -LayoutKey $row.Layout
        if ($first) { $wtArgs += " $layoutArgs"; $first = $false }
        else        { $wtArgs += " ; $layoutArgs" }
    }

    if (-not $wtArgs.Trim()) {
        [System.Windows.MessageBox]::Show("No profiles/layouts selected.")
        return
    }
    Start-Process "wt.exe" -ArgumentList $wtArgs
})

$BtnOpenPingLayout.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    Start-PingLayout -PingGrid $PingGrid
})

$BtnRunArp.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    if ($ChkArp.IsChecked -ne $true) {
        [System.Windows.MessageBox]::Show("Tick 'ARP local subnet' first.")
        return
    }
    Run-ArpScan -ArpGrid $ArpGrid
})

$BtnArpHtml.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    if ($ChkArp.IsChecked -ne $true) {
        [System.Windows.MessageBox]::Show("Enable ARP local subnet first.")
        return
    }
    Export-ArpToHtml -ArpGrid $ArpGrid
})

$BtnShowConfig.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    Show-TerminalConfigInfo
})

$BtnSaveConfig.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    Save-TerminalConfig
})

$BtnRestoreConfig.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.InitialDirectory = $ScriptDir
    $ofd.Filter           = "Zip files (*.zip)|*.zip|All files (*.*)|*.*"
    $ofd.Title            = "Select Terminal Config Zip"
    if ($ofd.ShowDialog() -eq $true) {
        Invoke-ElevatedRestore -ZipPath $ofd.FileName
    }
})

$window.Add_Closing({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    Ensure-HostBaselineConfig
})

# -------------------- Launch --------------------
$window.ShowDialog() | Out-Null

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





