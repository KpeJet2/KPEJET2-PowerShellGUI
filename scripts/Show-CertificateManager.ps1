# Author: The Establishment
# Date: 2603
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: UIForm
# FileRole: Script
#Requires -Version 5.1
<#
.SYNOPSIS
    Certificate Manager - read-only Windows certificate store browser with
    root-store monitoring and vault-secured private key export.

.DESCRIPTION
    Provides a WinForms GUI for:
      - Browsing CurrentUser and LocalMachine certificate stores (read-only view)
      - Viewing public certificate details: subject, issuer, thumbprint, expiry,
        key algorithm, key length, Subject Alternative Names, intended purposes
      - Flagging suspicious Trusted Root CA entries (recently added,
        non-Microsoft, non-well-known issuers)
      - Comparing current root store against a saved baseline snapshot
      - Exporting private keys ONLY to the vault via Set-VaultSecret (AssistedSASC)
      - All export events written to the sovereign kernel ledger (AUDIT)

.NOTES
    Author  : The Establishment
    Version : 2604.B2.V31.0
    Created : 2026

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace. Defaults to parent of $PSScriptRoot.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ── Assembly loading (PS 5.1 compatible) ────────────────────────────────────
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Warning "[CertMgr] Assembly load error: $_"
    return
}

# ── Module imports ───────────────────────────────────────────────────────────
$modDir = Join-Path $WorkspacePath 'modules'
foreach ($mod in @('PKIChainManager', 'AssistedSASC', 'CronAiAthon-EventLog', 'PwShGUI-Theme')) {
    $mp = Join-Path $modDir "$mod.psm1"
    if (Test-Path $mp) {
        try {
            Import-Module $mp -Force
        } catch {
            Write-Warning "[CertMgr] Could not load $mod : $_"
        }
    }
}

# ── Config paths ─────────────────────────────────────────────────────────────
$baselinePath = Join-Path $WorkspacePath (Join-Path 'config' 'cert-store-baseline.json')
$reportDir    = Join-Path $WorkspacePath '~REPORTS'
$certReportDir = Join-Path $reportDir 'CertMonitor'
if (-not (Test-Path $certReportDir)) {
    New-Item $certReportDir -ItemType Directory -Force | Out-Null
}

# ── Well-known trusted root issuers (non-exhaustive, used for flagging) ──────
$WellKnownIssuers = @(
    'Microsoft','DigiCert','Entrust','GlobalSign','GoDaddy','Comodo','Sectigo',
    'VeriSign','Thawte','GeoTrust','Symantec','Amazon','Baltimore','Starfield',
    'ISRG',"Let's Encrypt",'SwissSign','T-TeleSec','USERTrust',
    'QuoVadis','Network Solutions','Trustwave','Cybertrust','AddTrust',
    'Certigna','SECOM','Izenpe','Buypass','SSL.com','Actalis','HARICA'
)

# ── Helper: Get all stores and their certificates ────────────────────────────
function Get-AllStoreCertificates {
    [CmdletBinding()]
    param()
    $result = [System.Collections.ArrayList]::new()
    $locations = @('CurrentUser', 'LocalMachine')
    $storeNames = @(
        'Root', 'CA', 'My', 'TrustedPublisher', 'Disallowed',
        'AuthRoot', 'TrustedPeople', 'SmartCardRoot'
    )
    foreach ($loc in $locations) {
        foreach ($sname in $storeNames) {
            try {
                $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
                    $sname,
                    [System.Security.Cryptography.X509Certificates.StoreLocation]::$loc
                )
                $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
                foreach ($cert in $store.Certificates) {
                    $sans = ''
                    try {
                        $sanExt = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Subject Alternative Name' }
                        if ($sanExt) { $sans = $sanExt.Format($false) }
                    } catch { <# Intentional: non-fatal SAN parse #> }

                    $keyLen = 0
                    try {
                        if ($cert.PublicKey.Key) { $keyLen = $cert.PublicKey.Key.KeySize }
                    } catch { <# Intentional: non-fatal key size read #> }

                    $purposes = ''
                    try {
                        $ekuExt = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Enhanced Key Usage' }
                        if ($ekuExt) { $purposes = $ekuExt.Format($false) }
                    } catch { <# Intentional: non-fatal EKU parse #> }

                    $hasPrivKey = $false
                    try { $hasPrivKey = $cert.HasPrivateKey } catch { <# Intentional: non-fatal #> }

                    $result.Add([PSCustomObject]@{
                        StoreLocation  = $loc
                        StoreName      = $sname
                        Subject        = $cert.Subject
                        Issuer         = $cert.Issuer
                        Thumbprint     = $cert.Thumbprint
                        NotBefore      = $cert.NotBefore
                        NotAfter       = $cert.NotAfter
                        KeyAlgorithm   = $cert.PublicKey.Oid.FriendlyName
                        KeyLength      = $keyLen
                        SANs           = $sans
                        Purposes       = $purposes
                        HasPrivateKey  = $hasPrivKey
                        FriendlyName   = $cert.FriendlyName
                        SerialNumber   = $cert.SerialNumber
                        Version        = $cert.Version
                        IsExpired      = ($cert.NotAfter -lt [datetime]::Now)
                        DaysUntilExpiry = [Math]::Round(($cert.NotAfter - [datetime]::Now).TotalDays)
                    })
                }
                $store.Close()
            } catch {
                <# Intentional: some stores may not be accessible without elevation #>
            }
        }
    }
    return $result
}

# ── Helper: Detect suspicious root certs ─────────────────────────────────────
function Get-SuspiciousRootCerts {
    [CmdletBinding()]
    param([psobject[]]$AllCerts)
    $roots = $AllCerts | Where-Object { $_.StoreName -eq 'Root' }
    $suspicious = [System.Collections.ArrayList]::new()
    foreach ($c in $roots) {
        $flag = $false
        $reason = @()
        # Check if issuer is well-known
        $issuerCN = ''
        if ($c.Issuer -match 'CN=([^,]+)') { $issuerCN = $Matches[1].Trim() }
        $wellKnown = $WellKnownIssuers | Where-Object { $issuerCN -like "*$_*" }
        if (-not $wellKnown) {
            $flag = $true
            $reason += 'Issuer not in well-known list'
        }
        # Flag certs added in last 90 days
        if ($c.NotBefore -gt [datetime]::Now.AddDays(-90)) {
            $flag = $true
            $reason += 'Recently added (< 90 days)'
        }
        # Flag expired root certs still in store
        if ($c.IsExpired) {
            $flag = $true
            $reason += 'Expired cert in Root store'
        }
        if ($flag) {
            $suspicious.Add([PSCustomObject]@{
                Thumbprint = $c.Thumbprint
                Subject    = $c.Subject
                Issuer     = $c.Issuer
                Reason     = ($reason -join '; ')
                NotBefore  = $c.NotBefore
                NotAfter   = $c.NotAfter
            })
        }
    }
    return $suspicious
}

# ── Helper: Save/compare baseline snapshot ───────────────────────────────────
function Save-RootStoreBaseline {
    [CmdletBinding()]
    param([psobject[]]$AllCerts)
    $allRoots = $AllCerts | Where-Object { $_.StoreName -eq 'Root' }
    $roots = $allRoots | Select-Object Thumbprint, Subject, Issuer, NotBefore, NotAfter, StoreLocation
    $snapshot = @{
        CapturedAt = [datetime]::UtcNow.ToString('o')
        Certs      = @($roots)
    }
    $snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $baselinePath -Encoding UTF8
    return "Baseline saved: $(@($roots).Count) root certs -> $baselinePath"
}

function Compare-RootStoreToBaseline {
    [CmdletBinding()]
    param([psobject[]]$AllCerts)
    if (-not (Test-Path $baselinePath)) {
        return @{ Added = @(); Removed = @(); Message = 'No baseline found. Use Save Baseline first.' }
    }
    $baseJson = Get-Content $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $baseThumbs = @($baseJson.Certs | ForEach-Object { $_.Thumbprint })
    $currRoots = $AllCerts | Where-Object { $_.StoreName -eq 'Root' }
    $currThumbs = @($currRoots | ForEach-Object { $_.Thumbprint })

    $added   = $currRoots | Where-Object { $baseThumbs -notcontains $_.Thumbprint }
    $removed = $baseJson.Certs | Where-Object { $currThumbs -notcontains $_.Thumbprint }

    return @{
        Added   = @($added)
        Removed = @($removed)
        Message = "Added: $(@($added).Count)  Removed: $(@($removed).Count)  (vs baseline from $($baseJson.CapturedAt))"
    }
}

# ── Helper: Vault-secured private key export ──────────────────────────────────
function Export-PrivateKeyToVault {
    [CmdletBinding()]
    param(
        [string]$Thumbprint,
        [string]$StoreLocation = 'CurrentUser',
        [string]$StoreName = 'My',
        [string]$VaultItemName
    )
    # Locate the certificate
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::$StoreLocation
    )
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    $cert = $store.Certificates | Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
    $store.Close()

    if (-not $cert) { throw "Certificate not found: thumbprint $Thumbprint in $StoreLocation\$StoreName" }
    if (-not $cert.HasPrivateKey) { throw "Certificate $Thumbprint has no private key accessible." }

    # Require vault to be available before proceeding
    if (-not (Get-Command Set-VaultSecret -ErrorAction SilentlyContinue)) {
        throw 'Vault not available. Load AssistedSASC module and authenticate before exporting.'
    }

    # Prompt for export password
    $pwd = [System.Windows.Forms.MessageBox]::Show(
        "Export certificate `"$($cert.Subject)`" private key to vault?`n`nThis will prompt for a PFX password.",
        'Confirm Private Key Export',
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($pwd -ne [System.Windows.Forms.DialogResult]::OK) { return 'Export cancelled.' }

    $pwdForm = [System.Windows.Forms.Form]::new()
    $pwdForm.Text = 'PFX Export Password'
    $pwdForm.Size = [System.Drawing.Size]::new(340, 130)
    $pwdForm.FormBorderStyle = 'FixedDialog'
    $pwdForm.StartPosition = 'CenterScreen'
    $pwdLbl = [System.Windows.Forms.Label]::new(); $pwdLbl.Text = 'Password:'; $pwdLbl.Location = [System.Drawing.Point]::new(10, 12); $pwdLbl.AutoSize = $true
    $pwdBox = [System.Windows.Forms.TextBox]::new(); $pwdBox.Location = [System.Drawing.Point]::new(80, 9); $pwdBox.Size = [System.Drawing.Size]::new(230, 22); $pwdBox.UseSystemPasswordChar = $true
    $okBtn  = [System.Windows.Forms.Button]::new(); $okBtn.Text = 'OK'; $okBtn.Location = [System.Drawing.Point]::new(120, 50); $okBtn.DialogResult = 'OK'
    $pwdForm.Controls.AddRange(@($pwdLbl, $pwdBox, $okBtn))
    $pwdForm.AcceptButton = $okBtn
    $r = $pwdForm.ShowDialog()
    if ($r -ne [System.Windows.Forms.DialogResult]::OK -or [string]::IsNullOrEmpty($pwdBox.Text)) {
        return 'Export cancelled (no password).'
    }

    $securePwd = ConvertTo-SecureString $pwdBox.Text -AsPlainText -Force

    # Export PFX to temp file, read bytes, remove temp immediately
    $tempPfx = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.pfx'
    try {
        $pfxBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $securePwd)
        [System.IO.File]::WriteAllBytes($tempPfx, $pfxBytes)

        # Encode to base64 and store in vault
        $base64 = [Convert]::ToBase64String($pfxBytes)
        $vaultName = if ([string]::IsNullOrEmpty($VaultItemName)) { "PFX-$($cert.Thumbprint.Substring(0,8))" } else { $VaultItemName }
        Set-VaultSecret -Name $vaultName -Value $base64

        # Write audit ledger entry
        if (Get-Command Write-LedgerEntry -ErrorAction SilentlyContinue) {
            Write-LedgerEntry -EventType 'AUDIT' -Source 'Show-CertificateManager' -Data @{
                action     = 'PrivateKeyExportToVault'
                thumbprint = $Thumbprint
                subject    = $cert.Subject
                vaultItem  = $vaultName
            }
        }
        return "Private key exported to vault item: $vaultName"
    } finally {
        # Always remove the temp PFX
        if (Test-Path $tempPfx) { Remove-Item $tempPfx -Force -ErrorAction SilentlyContinue }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# ── GUI BUILD ────────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

# Colours
$bgDark  = [System.Drawing.Color]::FromArgb(28, 28, 30)
$bgMed   = [System.Drawing.Color]::FromArgb(38, 38, 40)
$bgLight = [System.Drawing.Color]::FromArgb(52, 52, 55)
$fgMain  = [System.Drawing.Color]::FromArgb(220, 220, 220)
$fgDim   = [System.Drawing.Color]::FromArgb(140, 140, 140)
$accentB = [System.Drawing.Color]::FromArgb(0, 120, 215)
$accentG = [System.Drawing.Color]::FromArgb(0, 180, 100)
$accentR = [System.Drawing.Color]::FromArgb(220, 60, 60)
$accentY = [System.Drawing.Color]::FromArgb(220, 180, 0)
$fntMono = [System.Drawing.Font]::new('Consolas', 9)
$fntNorm = [System.Drawing.Font]::new('Segoe UI', 9)
$fntBold = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fntHead = [System.Drawing.Font]::new('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)

# ── Main Form ────────────────────────────────────────────────────────────────
$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Certificate Manager  ·  v2603.B1.v1.0  ·  Read-Only Cert Store Browser'
$form.Size = [System.Drawing.Size]::new(1280, 800)
$form.MinimumSize = [System.Drawing.Size]::new(1000, 600)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bgDark
$form.ForeColor = $fgMain
$form.Font = $fntNorm

# ── Tab control ───────────────────────────────────────────────────────────────
$tabs = [System.Windows.Forms.TabControl]::new()
$tabs.Dock = 'Fill'
$tabs.BackColor = $bgDark
$tabs.ForeColor = $fgMain
$form.Controls.Add($tabs)

# ─ Helper to make a tab page ─
function New-TabPage {
    param([string]$Text)
    $tp = [System.Windows.Forms.TabPage]::new()
    $tp.Text = $Text
    $tp.BackColor = $bgDark
    $tp.ForeColor = $fgMain
    $tp.Padding = [System.Windows.Forms.Padding]::new(4)
    return $tp
}

# ─ Tab 1: Certificate Browser ─────────────────────────────────────────────────
$tabBrowse = New-TabPage 'Certificate Browser'
$tabs.TabPages.Add($tabBrowse)

# Filter panel (top)
$filterPanel = [System.Windows.Forms.Panel]::new()
$filterPanel.Dock = 'Top'
$filterPanel.Height = 42
$filterPanel.BackColor = $bgMed
$tabBrowse.Controls.Add($filterPanel)

$lblStore = [System.Windows.Forms.Label]::new()
$lblStore.Text = 'Store:'; $lblStore.Location = [System.Drawing.Point]::new(6,12); $lblStore.AutoSize = $true; $lblStore.ForeColor = $fgMain
$cmbStore = [System.Windows.Forms.ComboBox]::new()
$cmbStore.DropDownStyle = 'DropDownList'; $cmbStore.Location = [System.Drawing.Point]::new(48,8); $cmbStore.Width = 130; $cmbStore.BackColor = $bgLight; $cmbStore.ForeColor = $fgMain
@('All','CurrentUser\Root','CurrentUser\CA','CurrentUser\My','LocalMachine\Root','LocalMachine\CA','LocalMachine\My','LocalMachine\TrustedPublisher') | ForEach-Object { [void]$cmbStore.Items.Add($_) }
$cmbStore.SelectedIndex = 0

$lblFilter = [System.Windows.Forms.Label]::new()
$lblFilter.Text = 'Search:'; $lblFilter.Location = [System.Drawing.Point]::new(195,12); $lblFilter.AutoSize = $true; $lblFilter.ForeColor = $fgMain
$txtFilter = [System.Windows.Forms.TextBox]::new()
$txtFilter.Location = [System.Drawing.Point]::new(244,8); $txtFilter.Width = 260; $txtFilter.BackColor = $bgLight; $txtFilter.ForeColor = $fgMain

$btnRefresh = [System.Windows.Forms.Button]::new()
$btnRefresh.Text = 'Refresh All'; $btnRefresh.Location = [System.Drawing.Point]::new(520,7); $btnRefresh.Width = 90; $btnRefresh.Height = 26
$btnRefresh.BackColor = $accentB; $btnRefresh.ForeColor = [System.Drawing.Color]::White; $btnRefresh.FlatStyle = 'Flat'

$btnExportKey = [System.Windows.Forms.Button]::new()
$btnExportKey.Text = 'Export Private Key -> Vault'; $btnExportKey.Location = [System.Drawing.Point]::new(620,7); $btnExportKey.Width = 190; $btnExportKey.Height = 26
$btnExportKey.BackColor = $accentY; $btnExportKey.ForeColor = [System.Drawing.Color]::Black; $btnExportKey.FlatStyle = 'Flat'

$lblStatus = [System.Windows.Forms.Label]::new()
$lblStatus.Text = 'Status: Ready'; $lblStatus.Location = [System.Drawing.Point]::new(820,12); $lblStatus.AutoSize = $true; $lblStatus.ForeColor = $fgDim

$filterPanel.Controls.AddRange(@($lblStore, $cmbStore, $lblFilter, $txtFilter, $btnRefresh, $btnExportKey, $lblStatus))

# Split container: list on left, details on right
$splitBrowse = [System.Windows.Forms.SplitContainer]::new()
$splitBrowse.Dock = 'Fill'
$splitBrowse.SplitterDistance = 680
$splitBrowse.BackColor = $bgDark
$tabBrowse.Controls.Add($splitBrowse)

# ListView - cert list
$lvCerts = [System.Windows.Forms.ListView]::new()
$lvCerts.Dock = 'Fill'
$lvCerts.View = 'Details'
$lvCerts.FullRowSelect = $true
$lvCerts.GridLines = $true
$lvCerts.BackColor = $bgMed; $lvCerts.ForeColor = $fgMain
$lvCerts.Font = $fntMono
$lvCerts.MultiSelect = $false

foreach ($col in @(
    @{Text='Store';Width=130}, @{Text='Subject CN'; Width=200}, @{Text='Issuer CN'; Width=180},
    @{Text='Expiry'; Width=90}, @{Text='Days'; Width=55}, @{Text='Algorithm'; Width=80},
    @{Text='Bits'; Width=48}, @{Text='HasKey'; Width=52}, @{Text='Thumbprint'; Width=120}
)) {
    $c = [System.Windows.Forms.ColumnHeader]::new()
    $c.Text = $col.Text; $c.Width = $col.Width
    [void]$lvCerts.Columns.Add($c)
}
$splitBrowse.Panel1.Controls.Add($lvCerts)

# Details panel on right
$rtbDetails = [System.Windows.Forms.RichTextBox]::new()
$rtbDetails.Dock = 'Fill'
$rtbDetails.BackColor = $bgMed; $rtbDetails.ForeColor = $fgMain
$rtbDetails.Font = $fntMono; $rtbDetails.ReadOnly = $true
$rtbDetails.Text = 'Select a certificate to view details.'
$splitBrowse.Panel2.Controls.Add($rtbDetails)

# ─ Tab 2: Root Store Monitor ──────────────────────────────────────────────────
$tabRoot = New-TabPage 'Root Store Monitor'
$tabs.TabPages.Add($tabRoot)

$rootCtrlPanel = [System.Windows.Forms.Panel]::new()
$rootCtrlPanel.Dock = 'Top'; $rootCtrlPanel.Height = 42; $rootCtrlPanel.BackColor = $bgMed
$tabRoot.Controls.Add($rootCtrlPanel)

$btnSaveBaseline = [System.Windows.Forms.Button]::new()
$btnSaveBaseline.Text = 'Save Baseline'; $btnSaveBaseline.Location = [System.Drawing.Point]::new(6,7); $btnSaveBaseline.Width = 110; $btnSaveBaseline.Height = 26
$btnSaveBaseline.BackColor = $accentG; $btnSaveBaseline.ForeColor = [System.Drawing.Color]::Black; $btnSaveBaseline.FlatStyle = 'Flat'

$btnCompare = [System.Windows.Forms.Button]::new()
$btnCompare.Text = 'Compare to Baseline'; $btnCompare.Location = [System.Drawing.Point]::new(126,7); $btnCompare.Width = 150; $btnCompare.Height = 26
$btnCompare.BackColor = $accentB; $btnCompare.ForeColor = [System.Drawing.Color]::White; $btnCompare.FlatStyle = 'Flat'

$btnFlagSuspicious = [System.Windows.Forms.Button]::new()
$btnFlagSuspicious.Text = 'Flag Suspicious'; $btnFlagSuspicious.Location = [System.Drawing.Point]::new(286,7); $btnFlagSuspicious.Width = 120; $btnFlagSuspicious.Height = 26
$btnFlagSuspicious.BackColor = $accentR; $btnFlagSuspicious.ForeColor = [System.Drawing.Color]::White; $btnFlagSuspicious.FlatStyle = 'Flat'

$btnSaveReport = [System.Windows.Forms.Button]::new()
$btnSaveReport.Text = 'Save Report'; $btnSaveReport.Location = [System.Drawing.Point]::new(416,7); $btnSaveReport.Width = 100; $btnSaveReport.Height = 26
$btnSaveReport.BackColor = $bgLight; $btnSaveReport.ForeColor = $fgMain; $btnSaveReport.FlatStyle = 'Flat'

$lblBaselineInfo = [System.Windows.Forms.Label]::new()
$lblBaselineInfo.Text = "Baseline: $(if (Test-Path $baselinePath) { 'EXISTS' } else { 'NONE' })"
$lblBaselineInfo.Location = [System.Drawing.Point]::new(526,12); $lblBaselineInfo.AutoSize = $true; $lblBaselineInfo.ForeColor = $fgDim

$rootCtrlPanel.Controls.AddRange(@($btnSaveBaseline, $btnCompare, $btnFlagSuspicious, $btnSaveReport, $lblBaselineInfo))

$rtbRootLog = [System.Windows.Forms.RichTextBox]::new()
$rtbRootLog.Dock = 'Fill'; $rtbRootLog.BackColor = $bgMed; $rtbRootLog.ForeColor = $fgMain
$rtbRootLog.Font = $fntMono; $rtbRootLog.ReadOnly = $true
$rtbRootLog.Text = "Root Store Monitor ready.`r`nClick 'Save Baseline' to capture current state, then 'Compare' to detect changes."
$tabRoot.Controls.Add($rtbRootLog)

# ─ Tab 3: Expired / About to Expire ──────────────────────────────────────────
$tabExpiry = New-TabPage 'Expiry Watch'
$tabs.TabPages.Add($tabExpiry)

$expiryCtrl = [System.Windows.Forms.Panel]::new()
$expiryCtrl.Dock = 'Top'; $expiryCtrl.Height = 42; $expiryCtrl.BackColor = $bgMed
$tabExpiry.Controls.Add($expiryCtrl)

$lblDays = [System.Windows.Forms.Label]::new()
$lblDays.Text = 'Warn within (days):'; $lblDays.Location = [System.Drawing.Point]::new(6,12); $lblDays.AutoSize = $true; $lblDays.ForeColor = $fgMain
$nudDays = [System.Windows.Forms.NumericUpDown]::new()
$nudDays.Location = [System.Drawing.Point]::new(148,8); $nudDays.Width = 70; $nudDays.Minimum = 0; $nudDays.Maximum = 3650; $nudDays.Value = 90
$nudDays.BackColor = $bgLight; $nudDays.ForeColor = $fgMain

$btnScanExpiry = [System.Windows.Forms.Button]::new()
$btnScanExpiry.Text = 'Scan Expiry'; $btnScanExpiry.Location = [System.Drawing.Point]::new(228,7); $btnScanExpiry.Width = 100; $btnScanExpiry.Height = 26
$btnScanExpiry.BackColor = $accentB; $btnScanExpiry.ForeColor = [System.Drawing.Color]::White; $btnScanExpiry.FlatStyle = 'Flat'

$expiryCtrl.Controls.AddRange(@($lblDays, $nudDays, $btnScanExpiry))

$lvExpiry = [System.Windows.Forms.ListView]::new()
$lvExpiry.Dock = 'Fill'; $lvExpiry.View = 'Details'; $lvExpiry.FullRowSelect = $true
$lvExpiry.GridLines = $true; $lvExpiry.BackColor = $bgMed; $lvExpiry.ForeColor = $fgMain; $lvExpiry.Font = $fntMono
foreach ($col in @(
    @{Text='Status';Width=70}, @{Text='Days';Width=55}, @{Text='Expiry Date';Width=100},
    @{Text='Subject CN';Width=220}, @{Text='Store';Width=140}, @{Text='Thumbprint';Width=130}
)) {
    $c = [System.Windows.Forms.ColumnHeader]::new(); $c.Text = $col.Text; $c.Width = $col.Width
    [void]$lvExpiry.Columns.Add($c)
}
$tabExpiry.Controls.Add($lvExpiry)

# ══════════════════════════════════════════════════════════════════════════════
# ── Data state ────────────────────────────────────────────────────────────────
$script:AllCerts = @()

# ── Load all certs function ──────────────────────────────────────────────────
function Load-AllCerts {
    $lblStatus.Text = 'Status: Loading...'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $script:AllCerts = Get-AllStoreCertificates
        Apply-CertFilter
        $lblStatus.Text = "Status: $(@($script:AllCerts).Count) certs loaded"
    } catch {
        $lblStatus.Text = "Status: ERROR - $_"
    }
}

# ── Helper: Get CN from Distinguished Name ────────────────────────────────────
function Get-CN {
    param([string]$dn)
    if ($dn -match 'CN=([^,]+)') { return $Matches[1].Trim() }
    return $dn
}

# ── Apply filter to ListView ──────────────────────────────────────────────────
function Apply-CertFilter {
    $lvCerts.Items.Clear()
    $storeFilter = $cmbStore.SelectedItem
    $textFilter  = $txtFilter.Text.ToLower()

    foreach ($c in $script:AllCerts) {
        $storeKey = "$($c.StoreLocation)\$($c.StoreName)"
        if ($storeFilter -ne 'All' -and $storeKey -ne $storeFilter) { continue }
        if ($textFilter -and (
            $c.Subject.ToLower()    -notlike "*$textFilter*" -and
            $c.Issuer.ToLower()     -notlike "*$textFilter*" -and
            $c.Thumbprint.ToLower() -notlike "*$textFilter*" -and
            $c.FriendlyName.ToLower() -notlike "*$textFilter*"
        )) { continue }

        $item = [System.Windows.Forms.ListViewItem]::new($storeKey)
        $item.Font = $fntMono
        $item.SubItems.AddRange(@(
            (Get-CN $c.Subject),
            (Get-CN $c.Issuer),
            $c.NotAfter.ToString('yyyy-MM-dd'),
            $c.DaysUntilExpiry.ToString(),
            $c.KeyAlgorithm,
            $c.KeyLength.ToString(),
            $(if ($c.HasPrivateKey) { 'Yes' } else { 'No' }),
            $c.Thumbprint.Substring(0, [Math]::Min(16, $c.Thumbprint.Length))
        ))
        # Colour coding
        if ($c.IsExpired) { $item.ForeColor = $accentR }
        elseif ($c.DaysUntilExpiry -lt 30) { $item.ForeColor = $accentY }
        elseif ($c.StoreName -eq 'Root') { $item.ForeColor = [System.Drawing.Color]::FromArgb(180, 210, 255) }

        $item.Tag = $c
        [void]$lvCerts.Items.Add($item)
    }
}

# ── Show cert details in right pane ──────────────────────────────────────────
$lvCerts.add_SelectedIndexChanged({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    if ($lvCerts.SelectedItems.Count -eq 0) { return }
    $c = $lvCerts.SelectedItems[0].Tag
    if (-not $c) { return }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('═══════════════ CERTIFICATE DETAILS ═══════════════')
    [void]$sb.AppendLine("Store        : $($c.StoreLocation)\$($c.StoreName)")
    [void]$sb.AppendLine("FriendlyName : $($c.FriendlyName)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Subject      : $($c.Subject)")
    [void]$sb.AppendLine("Issuer       : $($c.Issuer)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Not Before   : $($c.NotBefore)")
    [void]$sb.AppendLine("Not After    : $($c.NotAfter)")
    [void]$sb.AppendLine("Days Remain  : $($c.DaysUntilExpiry)  $(if($c.IsExpired){'[EXPIRED]'}elseif($c.DaysUntilExpiry -lt 30){'[EXPIRING SOON]'})")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Serial No.   : $($c.SerialNumber)")
    [void]$sb.AppendLine("Thumbprint   : $($c.Thumbprint)")
    [void]$sb.AppendLine("Version      : $($c.Version)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Key Algorithm: $($c.KeyAlgorithm)")
    [void]$sb.AppendLine("Key Length   : $($c.KeyLength) bits")
    [void]$sb.AppendLine("Has PrivKey  : $($c.HasPrivateKey)")
    if ($c.SANs) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("SANs         : $($c.SANs)")
    }
    if ($c.Purposes) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("Key Usages   : $($c.Purposes)")
    }
    $rtbDetails.Text = $sb.ToString()
})

# ── Filter / Refresh handlers ─────────────────────────────────────────────────
$btnRefresh.add_Click({ Load-AllCerts })  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
$cmbStore.add_SelectedIndexChanged({ Apply-CertFilter })  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
$txtFilter.add_TextChanged({ Apply-CertFilter })  # SIN-EXEMPT:P029 -- handler pending try/catch wrap

# ── Export Private Key handler ────────────────────────────────────────────────
$btnExportKey.add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    if ($lvCerts.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Select a certificate first.', 'No Selection', 'OK', 'Warning') | Out-Null
        return
    }
    $c = $lvCerts.SelectedItems[0].Tag
    if (-not $c.HasPrivateKey) {
        [System.Windows.Forms.MessageBox]::Show("This certificate has no private key accessible.`n`nOnly certificates in 'My' (Personal) store with accessible private keys can be exported.", 'No Private Key', 'OK', 'Information') | Out-Null
        return
    }
    if ($c.StoreName -eq 'Root') {
        [System.Windows.Forms.MessageBox]::Show('Private key export from the Trusted Root store is not permitted for security reasons.', 'Export Blocked', 'OK', 'Error') | Out-Null
        return
    }
    try {
        $result = Export-PrivateKeyToVault -Thumbprint $c.Thumbprint -StoreLocation $c.StoreLocation -StoreName $c.StoreName
        [System.Windows.Forms.MessageBox]::Show($result, 'Export Result', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Export failed:`n$_", 'Export Error', 'OK', 'Error') | Out-Null
    }
})

# ── Root Monitor: Save Baseline ───────────────────────────────────────────────
$btnSaveBaseline.add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    try {
        if (@($script:AllCerts).Count -eq 0) { Load-AllCerts }
        $msg = Save-RootStoreBaseline -AllCerts $script:AllCerts
        $lblBaselineInfo.Text = "Baseline: EXISTS"
        $rtbRootLog.AppendText("`r`n[$(Get-Date -Format 'HH:mm:ss')] $msg")
    } catch {
        $rtbRootLog.AppendText("`r`n[ERROR] $_")
    }
})

# ── Root Monitor: Compare ─────────────────────────────────────────────────────
$btnCompare.add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    try {
        if (@($script:AllCerts).Count -eq 0) { Load-AllCerts }
        $diff = Compare-RootStoreToBaseline -AllCerts $script:AllCerts
        $rtbRootLog.AppendText("`r`n[$(Get-Date -Format 'HH:mm:ss')] === COMPARISON RESULT ===")
        $rtbRootLog.AppendText("`r`n$($diff.Message)")
        if (@($diff.Added).Count -gt 0) {
            $rtbRootLog.AppendText("`r`n  ADDED certs (may warrant investigation):")
            foreach ($a in $diff.Added) {
                $rtbRootLog.AppendText("`r`n    + $(Get-CN $a.Subject)  [$($a.Thumbprint.Substring(0,12))...]")
            }
        }
        if (@($diff.Removed).Count -gt 0) {
            $rtbRootLog.AppendText("`r`n  REMOVED certs:")
            foreach ($r in $diff.Removed) {
                $rtbRootLog.AppendText("`r`n    - $(if ($r.Subject) { Get-CN $r.Subject } else { $r.Thumbprint })")
            }
        }
    } catch {
        $rtbRootLog.AppendText("`r`n[ERROR] $_")
    }
})

# ── Root Monitor: Flag Suspicious ─────────────────────────────────────────────
$btnFlagSuspicious.add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    try {
        if (@($script:AllCerts).Count -eq 0) { Load-AllCerts }
        $suspect = Get-SuspiciousRootCerts -AllCerts $script:AllCerts
        $rtbRootLog.AppendText("`r`n[$(Get-Date -Format 'HH:mm:ss')] === SUSPICIOUS ROOT CERTS: $(@($suspect).Count) found ===")
        if (@($suspect).Count -eq 0) {
            $rtbRootLog.AppendText("`r`n  None flagged. All root issuers appear well-known.")
        } else {
            foreach ($s in $suspect) {
                $rtbRootLog.AppendText("`r`n  [FLAG] $(Get-CN $s.Subject)")
                $rtbRootLog.AppendText("`r`n         Issuer : $($s.Issuer)")
                $rtbRootLog.AppendText("`r`n         Reason : $($s.Reason)")
                $rtbRootLog.AppendText("`r`n         Thumb  : $($s.Thumbprint)")
            }
        }
    } catch {
        $rtbRootLog.AppendText("`r`n[ERROR] $_")
    }
})

# ── Root Monitor: Save Report ─────────────────────────────────────────────────
$btnSaveReport.add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    try {
        if (@($script:AllCerts).Count -eq 0) { Load-AllCerts }
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $reportFile = Join-Path $certReportDir "CertMonitor-$ts.json"
        $suspect = Get-SuspiciousRootCerts -AllCerts $script:AllCerts
        $diff    = Compare-RootStoreToBaseline -AllCerts $script:AllCerts
        $report  = @{
            GeneratedAt = [datetime]::UtcNow.ToString('o')
            TotalCerts  = @($script:AllCerts).Count
            Suspicious  = @($suspect)
            Comparison  = $diff
        }
        $report | ConvertTo-Json -Depth 5 | Set-Content -Path $reportFile -Encoding UTF8
        $rtbRootLog.AppendText("`r`n[$(Get-Date -Format 'HH:mm:ss')] Report saved: $reportFile")
    } catch {
        $rtbRootLog.AppendText("`r`n[ERROR] $_")
    }
})

# ── Expiry Watch: Scan ────────────────────────────────────────────────────────
$btnScanExpiry.add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
    $lvExpiry.Items.Clear()
    if (@($script:AllCerts).Count -eq 0) { Load-AllCerts }
    $warnDays = [int]$nudDays.Value
    $cands = $script:AllCerts | Where-Object { $_.DaysUntilExpiry -le $warnDays } | Sort-Object DaysUntilExpiry
    foreach ($c in $cands) {
        $status = if ($c.IsExpired) { 'EXPIRED' } elseif ($c.DaysUntilExpiry -le 14) { 'CRITICAL' } else { 'WARNING' }
        $item = [System.Windows.Forms.ListViewItem]::new($status)
        $item.SubItems.AddRange(@(
            $c.DaysUntilExpiry.ToString(),
            $c.NotAfter.ToString('yyyy-MM-dd'),
            (Get-CN $c.Subject),
            "$($c.StoreLocation)\$($c.StoreName)",
            $c.Thumbprint.Substring(0, [Math]::Min(16, $c.Thumbprint.Length))
        ))
        $item.ForeColor = $(if ($status -eq 'EXPIRED') { $accentR } elseif ($status -eq 'CRITICAL') { $accentY } else { $fgMain })
        $item.Tag = $c
        [void]$lvExpiry.Items.Add($item)
    }
})

# ── Initial data load ────────────────────────────────────────────────────────
Load-AllCerts

# ── Show form ────────────────────────────────────────────────────────────────
[System.Windows.Forms.Application]::Run($form)


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





