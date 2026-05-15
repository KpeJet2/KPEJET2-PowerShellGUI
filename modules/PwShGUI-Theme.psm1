# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
#Requires -Version 5.1
<#
.SYNOPSIS
    PwShGUI Theme Module -- centralised modern styling, rainbow progress bars, spinners.
# TODO: HelpMenu | Show-ThemeHelp | Actions: Apply|Preview|Reset|List|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
    Provides a consistent dark-accent modern look for all PowerShellGUI forms.
    Exports helper functions to apply themes, create rainbow progress bars,
    and show preprocessing spinners.

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 24th March 2026
#>

# Ensure System.Drawing is available (required for Color/Font types in PS 5.1)
if (-not ([System.Management.Automation.PSTypeName]'System.Drawing.Color').Type) {
    Add-Type -AssemblyName System.Drawing
}

# ========================== THEME COLOUR PALETTE ==========================
$script:Theme = @{
    FormBack        = [System.Drawing.Color]::FromArgb(30, 30, 30)
    FormBackAlt     = [System.Drawing.Color]::FromArgb(45, 45, 48)
    PanelBack       = [System.Drawing.Color]::FromArgb(37, 37, 38)
    ControlBack     = [System.Drawing.Color]::FromArgb(51, 51, 55)
    ControlFore     = [System.Drawing.Color]::FromArgb(220, 220, 220)
    AccentBlue      = [System.Drawing.Color]::FromArgb(0, 122, 204)
    AccentGreen     = [System.Drawing.Color]::FromArgb(78, 201, 176)
    AccentOrange    = [System.Drawing.Color]::FromArgb(206, 145, 60)
    HeadingFore     = [System.Drawing.Color]::White
    SubtleFore      = [System.Drawing.Color]::FromArgb(150, 150, 150)
    BorderColor     = [System.Drawing.Color]::FromArgb(63, 63, 70)
    ButtonBack      = [System.Drawing.Color]::FromArgb(55, 55, 60)
    ButtonHover     = [System.Drawing.Color]::FromArgb(70, 70, 78)
    ButtonFore      = [System.Drawing.Color]::FromArgb(230, 230, 230)
    DgvBack         = [System.Drawing.Color]::FromArgb(37, 37, 38)
    DgvAltRow       = [System.Drawing.Color]::FromArgb(45, 45, 48)
    DgvHeaderBack   = [System.Drawing.Color]::FromArgb(51, 51, 55)
    DgvHeaderFore   = [System.Drawing.Color]::FromArgb(200, 200, 200)
    DgvGridLine     = [System.Drawing.Color]::FromArgb(63, 63, 70)
    MenuBack        = [System.Drawing.Color]::FromArgb(45, 45, 48)
    MenuFore        = [System.Drawing.Color]::FromArgb(220, 220, 220)
    StatusBack      = [System.Drawing.Color]::FromArgb(0, 122, 204)
    StatusFore      = [System.Drawing.Color]::White
    FontFamily      = 'Segoe UI'
    FontSize        = 9
    HeadingSize     = 12
    SmallSize       = 7.5
}

<#
.SYNOPSIS
  Get theme value.
#>
function Get-ThemeValue {
    <# Returns a named theme value from the palette. #>
    param([string]$Key)
    if ($script:Theme.ContainsKey($Key)) { return $script:Theme[$Key] }
    return $null
}

<#
.SYNOPSIS
  Get theme font.
#>
function Get-ThemeFont {
    <# Returns a System.Drawing.Font using the theme font family. #>
    param(
        [float]$Size = 0,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    if ($Size -le 0) { $Size = $script:Theme.FontSize }
    return (New-Object System.Drawing.Font($script:Theme.FontFamily, $Size, $Style))
}

# ========================== APPLY THEME TO FORM ==========================
function Set-ModernFormStyle {
    <#
    .SYNOPSIS  Applies the dark modern theme to a WinForms Form.
    .PARAMETER Form   The Form object to style.
    .PARAMETER Title  Optional new title text.
        .DESCRIPTION
      Detailed behaviour: Set modern form style.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.Form]$Form,
        [string]$Title
    )
    if (-not $PSCmdlet.ShouldProcess('Set-ModernFormStyle', 'Modify')) { return }

    $Form.BackColor       = $script:Theme.FormBack
    $Form.ForeColor       = $script:Theme.ControlFore
    $Form.Font            = Get-ThemeFont
    # DoubleBuffered is a protected property -- use reflection
    try {
        $Form.GetType().GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($Form, $true, $null)
    } catch { <# Non-fatal: skip double-buffering on non-standard forms #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    if ($Title) { $Form.Text = $Title }
}

# ========================== APPLY THEME TO MENUSTRIP ==========================

# Custom color table for dark menu with readable selected-item text
# Build referenced assemblies list — .NET 6+ (PS 7) moved Color to System.Drawing.Primitives
$_themeRefAsm = @('System.Drawing', 'System.Windows.Forms')
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $_themeRefAsm += 'System.Drawing.Primitives'
}
try {
    if (-not ([System.Management.Automation.PSTypeName]'DarkMenuColorTable').Type) {
        Add-Type -TypeDefinition @"
using System.Drawing;
using System.Windows.Forms;
public class DarkMenuColorTable : ProfessionalColorTable {
    public override Color MenuItemSelected           { get { return Color.FromArgb(62, 62, 66); } }
    public override Color MenuItemSelectedGradientBegin { get { return Color.FromArgb(62, 62, 66); } }
    public override Color MenuItemSelectedGradientEnd   { get { return Color.FromArgb(62, 62, 66); } }
    public override Color MenuItemBorder             { get { return Color.FromArgb(0, 122, 204); } }
    public override Color MenuBorder                 { get { return Color.FromArgb(51, 51, 55); } }
    public override Color MenuItemPressedGradientBegin { get { return Color.FromArgb(37, 37, 38); } }
    public override Color MenuItemPressedGradientEnd   { get { return Color.FromArgb(37, 37, 38); } }
    public override Color ImageMarginGradientBegin   { get { return Color.FromArgb(45, 45, 48); } }
    public override Color ImageMarginGradientEnd     { get { return Color.FromArgb(45, 45, 48); } }
    public override Color ImageMarginGradientMiddle  { get { return Color.FromArgb(45, 45, 48); } }
    public override Color ToolStripDropDownBackground { get { return Color.FromArgb(45, 45, 48); } }
    public override Color SeparatorDark              { get { return Color.FromArgb(63, 63, 70); } }
    public override Color SeparatorLight             { get { return Color.FromArgb(63, 63, 70); } }
}
public class DarkMenuRenderer : ToolStripProfessionalRenderer {
    public DarkMenuRenderer() : base(new DarkMenuColorTable()) { }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        if (e.Item.Selected || e.Item.Pressed)
            e.TextColor = Color.Black;
        base.OnRenderItemText(e);
    }
}
"@ -ReferencedAssemblies $_themeRefAsm
    }
} catch { <# Non-fatal: menu will use default renderer #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }

<#
.SYNOPSIS
  Set modern menu style.
#>
function Set-ModernMenuStyle {
    <# Applies dark theme to a MenuStrip and all nested items with black text on selection. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Windows.Forms.MenuStrip]$MenuStrip)
    if (-not $PSCmdlet.ShouldProcess('Set-ModernMenuStyle', 'Modify')) { return }

    $MenuStrip.BackColor = $script:Theme.MenuBack
    $MenuStrip.ForeColor = $script:Theme.MenuFore
    try {
        $MenuStrip.Renderer = New-Object DarkMenuRenderer
    } catch {
        $MenuStrip.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer(
            (New-Object System.Windows.Forms.ProfessionalColorTable)
        )
    }
    foreach ($item in $MenuStrip.Items) {
        Set-MenuItemColor $item
    }
}

function Set-MenuItemColor {
    [CmdletBinding(SupportsShouldProcess)]
    param($Item)
    if (-not $PSCmdlet.ShouldProcess('Set-MenuItemColor', 'Modify')) { return }

    if ($null -eq $Item) { return }
    try {
        $Item.BackColor = $script:Theme.MenuBack
        $Item.ForeColor = $script:Theme.MenuFore
        if ($Item -is [System.Windows.Forms.ToolStripMenuItem]) {
            foreach ($sub in $Item.DropDownItems) {
                if ($sub -is [System.Windows.Forms.ToolStripMenuItem]) {
                    Set-MenuItemColor $sub
                }
            }
        }
    } catch { try { Write-AppLog "Theme: Set-MenuItemColor failed - $_" 'Warning' } catch { <# Non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false } }
}

# ========================== APPLY THEME TO DGV ==========================
<#
.SYNOPSIS
  Set modern dgv style.
.DESCRIPTION
  Detailed behaviour: Set modern dgv style.
#>
function Set-ModernDgvStyle {
    <# Applies dark modern styling to a DataGridView. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Windows.Forms.DataGridView]$Dgv)
    if (-not $PSCmdlet.ShouldProcess('Set-ModernDgvStyle', 'Modify')) { return }

    try {
        $Dgv.BackgroundColor          = $script:Theme.DgvBack
        $Dgv.DefaultCellStyle.BackColor   = $script:Theme.DgvBack
        $Dgv.DefaultCellStyle.ForeColor   = $script:Theme.ControlFore
        $Dgv.DefaultCellStyle.SelectionBackColor = $script:Theme.AccentBlue
        $Dgv.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
        $Dgv.DefaultCellStyle.Font        = Get-ThemeFont
        $Dgv.AlternatingRowsDefaultCellStyle.BackColor = $script:Theme.DgvAltRow
        $Dgv.ColumnHeadersDefaultCellStyle.BackColor   = $script:Theme.DgvHeaderBack
        $Dgv.ColumnHeadersDefaultCellStyle.ForeColor   = $script:Theme.DgvHeaderFore
        $Dgv.ColumnHeadersDefaultCellStyle.Font        = Get-ThemeFont -Size ($script:Theme.FontSize) -Style Bold
        $Dgv.EnableHeadersVisualStyles  = $false
        $Dgv.GridColor                  = $script:Theme.DgvGridLine
        $Dgv.BorderStyle                = [System.Windows.Forms.BorderStyle]::None
    } catch { try { Write-AppLog "Theme: Set-ModernDgvStyle failed - $_" 'Warning' } catch { <# Non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false } }
}

# ========================== APPLY THEME TO BUTTON ==========================
<#
.SYNOPSIS
  Set modern button style.
.DESCRIPTION
  Detailed behaviour: Set modern button style.
#>
function Set-ModernButtonStyle {
    <# Applies flat dark styling to a Button. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Windows.Forms.Button]$Button)
    if (-not $PSCmdlet.ShouldProcess('Set-ModernButtonStyle', 'Modify')) { return }

    try {
        $Button.FlatStyle   = [System.Windows.Forms.FlatStyle]::Flat
        $Button.FlatAppearance.BorderColor = $script:Theme.BorderColor
        $Button.FlatAppearance.BorderSize  = 1
        $Button.BackColor   = $script:Theme.ButtonBack
        $Button.ForeColor   = $script:Theme.ButtonFore
        $Button.Font        = Get-ThemeFont -Size 10
        $Button.Cursor      = [System.Windows.Forms.Cursors]::Hand
        # Hover effect via MouseEnter/Leave
        $Button.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 78) })  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        $Button.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 60) })  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    } catch { try { Write-AppLog "Theme: Set-ModernButtonStyle failed - $_" 'Warning' } catch { <# Non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false } }
}

# ========================== APPLY THEME TO TABCONTROL ==========================
<#
.SYNOPSIS
  Set modern tab style.
.DESCRIPTION
  Detailed behaviour: Set modern tab style.
#>
function Set-ModernTabStyle {
    <# Applies theme colours to a TabControl and its pages. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Windows.Forms.TabControl]$TabControl)
    if (-not $PSCmdlet.ShouldProcess('Set-ModernTabStyle', 'Modify')) { return }

    try {
        foreach ($page in $TabControl.TabPages) {
            $page.BackColor = $script:Theme.FormBackAlt
            $page.ForeColor = $script:Theme.ControlFore
        }
    } catch { try { Write-AppLog "Theme: Set-ModernTabStyle failed - $_" 'Warning' } catch { <# Non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false } }
}

# ========================== RAINBOW PROGRESS BAR ==========================
$script:_RainbowColors = @(
    [System.Drawing.Color]::Red,
    [System.Drawing.Color]::OrangeRed,
    [System.Drawing.Color]::Orange,
    [System.Drawing.Color]::Yellow,
    [System.Drawing.Color]::GreenYellow,
    [System.Drawing.Color]::Lime,
    [System.Drawing.Color]::Cyan,
    [System.Drawing.Color]::DodgerBlue,
    [System.Drawing.Color]::Blue,
    [System.Drawing.Color]::BlueViolet,
    [System.Drawing.Color]::MediumPurple,
    [System.Drawing.Color]::DeepPink
)

function New-RainbowProgressBar {
    <#
    .SYNOPSIS  Creates a custom-painted rainbow progress bar Panel.
    .DESCRIPTION
        Returns a hashtable with:
          Panel    - the Panel control to add to your form
          Update   - scriptblock to call with (percent 0-100)
          Complete - scriptblock to call when done (fills bar green)
          Reset    - scriptblock to reset to 0
    .PARAMETER Width   Width of the bar (default 500)
    .PARAMETER Height  Height of the bar (default 16)
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$Width  = 500,
        [int]$Height = 16
    )
    if (-not $PSCmdlet.ShouldProcess('New-RainbowProgressBar', 'Create')) { return }


    $panel = New-Object System.Windows.Forms.Panel
    $panel.Size = New-Object System.Drawing.Size($Width, $Height)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    # Capture module-scoped rainbow colors into local so .GetNewClosure() can see it
    $rainbowColors = $script:_RainbowColors
    $colorCount    = @($rainbowColors).Count
    $state = @{ Percent = 0; ColorIndex = 0 }

    $panel.Add_Paint({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        # P034 fix: $sender shadows PowerShell automatic; use $evtSender
        param($evtSender, $e)
        $g = $e.Graphics
        $g.Clear($evtSender.BackColor)
        $pct = $state.Percent
        if ($pct -le 0) { return }
        $fillW = [int](($evtSender.ClientSize.Width) * ($pct / 100.0))
        if ($fillW -lt 1) { return }

        # Draw rainbow gradient segments
        $segW = [math]::Max(1, [int]($fillW / 12))
        $colors = $rainbowColors
        $offset = $state.ColorIndex
        for ($x = 0; $x -lt $fillW; $x += $segW) {
            $ci = if ($colorCount -gt 0) { (([int]($x / $segW) + $offset) % $colorCount) } else { 0 }
            $w  = [math]::Min($segW, $fillW - $x)
            $brush = New-Object System.Drawing.SolidBrush($colors[$ci])  # SIN-EXEMPT:P027 -- index access, context-verified safe
            $g.FillRectangle($brush, $x, 0, $w, $evtSender.ClientSize.Height)
            $brush.Dispose()
        }
    })

    $update = {
        param([int]$Percent)
        $state.Percent = [math]::Min(100, [math]::Max(0, $Percent))
        $state.ColorIndex = if ($colorCount -gt 0) { ($state.ColorIndex + 1) % $colorCount } else { 0 }
        $panel.Invalidate()
    }.GetNewClosure()

    $complete = {
        $state.Percent = 100
        $panel.Invalidate()
    }.GetNewClosure()

    $reset = {
        $state.Percent = 0
        $state.ColorIndex = 0
        $panel.Invalidate()
    }.GetNewClosure()

    return @{
        Panel    = $panel
        Update   = $update
        Complete = $complete
        Reset    = $reset
    }
}

# ========================== SPINNER / PREPROCESSING INDICATOR ==========================
$script:_SpinnerChars = @('/', '|', '\', '-', '/', '|', '\', '-')

function New-SpinnerLabel {
    <#
    .SYNOPSIS  Creates a label that cycles through spinner characters.
    .DESCRIPTION
        Returns a hashtable with:
          Label   - the Label control
          Timer   - a Timer that auto-advances the spinner
          Start   - scriptblock to start spinning
          Stop    - scriptblock to stop and clear
          SetText - scriptblock to set prefix text before spinner char
    .PARAMETER Interval  Milliseconds between frames (default 120)
    .PARAMETER Prefix    Text shown before the spinner glyph (default 'Processing')
    #>
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$Interval = 120,
        [string]$Prefix = 'Processing'
    )
    if (-not $PSCmdlet.ShouldProcess('New-SpinnerLabel', 'Create')) { return }


    $label = New-Object System.Windows.Forms.Label
    $label.Size = New-Object System.Drawing.Size(300, 20)
    $label.ForeColor = $script:Theme.AccentOrange
    $label.Font = New-Object System.Drawing.Font('Consolas', 9)
    $label.TextAlign = 'MiddleLeft'
    $label.Text = ''

    $spinState = @{ Index = 0; Prefix = $Prefix; Active = $false }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $Interval
    $timer.Add_Tick({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        if (-not $spinState.Active) { return }
        $ch = $script:_SpinnerChars[$spinState.Index % $script:_SpinnerChars.Count]
        $label.Text = "$($spinState.Prefix) $ch"
        $spinState.Index++
    })

    $start = {
        $spinState.Active = $true
        $spinState.Index = 0
        $timer.Start()
    }.GetNewClosure()

    $stop = {
        $spinState.Active = $false
        $timer.Stop()
        $label.Text = ''
    }.GetNewClosure()

    $setText = {
        param([string]$Text)
        $spinState.Prefix = $Text
    }.GetNewClosure()

    return @{
        Label   = $label
        Timer   = $timer
        Start   = $start
        Stop    = $stop
        SetText = $setText
    }
}

# ========================== THEME APPLICATION BATCH ==========================
function Set-ModernFormTheme {
    <#
    .SYNOPSIS  One-call theme applicator for an entire form.
    .DESCRIPTION  Walks all controls on a form and applies appropriate styling.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.Form]$Form,
        [switch]$IncludeMenuStrip
    )
    if (-not $PSCmdlet.ShouldProcess('Set-ModernFormTheme', 'Modify')) { return }

    Set-ModernFormStyle -Form $Form

    foreach ($ctl in $Form.Controls) {
        switch ($true) {
            ($ctl -is [System.Windows.Forms.MenuStrip] -and $IncludeMenuStrip) {
                Set-ModernMenuStyle -MenuStrip $ctl
            }
            ($ctl -is [System.Windows.Forms.DataGridView]) {
                Set-ModernDgvStyle -Dgv $ctl
            }
            ($ctl -is [System.Windows.Forms.Button]) {
                Set-ModernButtonStyle -Button $ctl
            }
            ($ctl -is [System.Windows.Forms.TabControl]) {
                Set-ModernTabStyle -TabControl $ctl
            }
            ($ctl -is [System.Windows.Forms.Panel]) {
                $ctl.BackColor = $script:Theme.PanelBack
                $ctl.ForeColor = $script:Theme.ControlFore
            }
            ($ctl -is [System.Windows.Forms.Label]) {
                $ctl.ForeColor = $script:Theme.ControlFore
            }
            ($ctl -is [System.Windows.Forms.TextBox]) {
                $ctl.BackColor = $script:Theme.ControlBack
                $ctl.ForeColor = $script:Theme.ControlFore
            }
            ($ctl -is [System.Windows.Forms.ComboBox]) {
                $ctl.BackColor = $script:Theme.ControlBack
                $ctl.ForeColor = $script:Theme.ControlFore
            }
            ($ctl -is [System.Windows.Forms.SplitContainer]) {
                $ctl.BackColor = $script:Theme.FormBackAlt
            }
        }
    }
}

# ======================== SAFE CONTROL HELPERS (Improvement #4) ========================
function Set-ControlProperty {
    <#
    .SYNOPSIS  Safely sets a property on a WinForms control with null guards.
    .PARAMETER Control  The control to modify (may be $null).
    .PARAMETER Property The property name to set.
    .PARAMETER Value    The value to assign (may be $null — assignment is skipped).
        .DESCRIPTION
      Detailed behaviour: Set control property.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param($Control, [string]$Property, $Value)
    if (-not $PSCmdlet.ShouldProcess('Set-ControlProperty', 'Modify')) { return }

    if ($null -ne $Control -and $null -ne $Value) {
        $Control.$Property = $Value
    }
}

function Set-ControlForeColor {
    <#
    .SYNOPSIS  Safely sets ForeColor on a control using a theme key or Color value.
    .PARAMETER Control   The control to modify.
    .PARAMETER ThemeKey  Named theme palette key (e.g. 'ControlFore', 'AccentGreen').
    .PARAMETER Color     Direct System.Drawing.Color value (overrides ThemeKey).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        $Control,
        [string]$ThemeKey,
        [System.Drawing.Color]$Color
    )
    if (-not $PSCmdlet.ShouldProcess('Set-ControlForeColor', 'Modify')) { return }

    if ($null -eq $Control) { return }
    $c = if ($Color -ne [System.Drawing.Color]::Empty) { $Color }
         elseif ($ThemeKey) { Get-ThemeValue $ThemeKey }
         else { $null }
    if ($null -ne $c) { $Control.ForeColor = $c }
}

function Set-ControlBackColor {
    <#
    .SYNOPSIS  Safely sets BackColor on a control using a theme key or Color value.
    .PARAMETER Control   The control to modify.
    .PARAMETER ThemeKey  Named theme palette key (e.g. 'FormBack', 'AccentBlue').
    .PARAMETER Color     Direct System.Drawing.Color value (overrides ThemeKey).
        .DESCRIPTION
      Detailed behaviour: Set control back color.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        $Control,
        [string]$ThemeKey,
        [System.Drawing.Color]$Color
    )
    if (-not $PSCmdlet.ShouldProcess('Set-ControlBackColor', 'Modify')) { return }

    if ($null -eq $Control) { return }
    $c = if ($Color -ne [System.Drawing.Color]::Empty) { $Color }
         elseif ($ThemeKey) { Get-ThemeValue $ThemeKey }
         else { $null }
    if ($null -ne $c) { $Control.BackColor = $c }
}

# ========================== EXPORTS ==========================

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
    'Get-ThemeValue',
    'Get-ThemeFont',
    'Set-ControlProperty',
    'Set-ControlForeColor',
    'Set-ControlBackColor',
    'Set-ModernFormStyle',
    'Set-ModernMenuStyle',
    'Set-ModernDgvStyle',
    'Set-ModernButtonStyle',
    'Set-ModernTabStyle',
    'Set-ModernFormTheme',
    'New-RainbowProgressBar',
    'New-SpinnerLabel'
)







