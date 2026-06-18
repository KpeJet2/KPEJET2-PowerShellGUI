# VersionTag: 2606.B5.V51.4
<!-- VersionBuildHistory: 2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 3 entries) -->
<!-- FileRole: Changelog -->

# PowerShellGUI - UPM Version History

---

## v1.4.0 — 2026-03-01

### New Features
- **UPM subfolder** — all files now reside under `c:\PowerShellGUI\UPM\` with dedicated `modules\`, `docs\`, `logs\`, `config\`, `Report\` sub-directories
- **4-part status bar** — displays user UPN, computer name, admin elevation indicator, and dynamic status message
- **Menu bar** — File menu (Capture, Save Profile, Open Profile Store, Open Log Folder, Exit) and Help menu (User Guide, Version History, WhatIf Simulation)
- **CaptureIndex** — 23-entry ordered hashtable mapping each capture category to its function, data key, tree sub-tags, save/compare/restore support flags, and inline code examples
- **Session-scoped logging** — `Write-UPMLog` writes a single log file per session to `%TEMP%\UPM-Backups\<ProfileName>\<ScriptName>-<Computer>-<User>-<Timestamp>.log`; calling `Update-LogProfile` re-targets the log to a profile-specific sub-directory
- **WhatIf Simulation dialog** — multi-select any of the 23 capture operations, choose Save or Restore mode, run a preview pass, and review the output HTML inline

### Bug Fixes
- `terminal_wt` and `terminal_profiles` tree switch cases were missing → added
- `psver` tree switch case was missing → added
- `cmpCombo.Tag` was being set inside the `foreach` profile-combo loop → moved after loop completion
- `ise_profile` path check would throw on an empty string → guarded with explicit null/empty test

---

## v1.3.0 — 2026-02-20

### New Features
- Environment Variables capture (`Get-EnvironmentVariables`) — user, machine and process scopes
- Mapped Drives capture (`Get-MappedDrives`) — network UNC paths via WMI Win32_MappedLogicalDisk
- Installed Fonts inventory (`Get-InstalledFonts`) — HKLM and HKCU font registry
- Language & Speech capture (`Get-LanguageAndSpeech`) — language packs, speech recognisers, TTS voices, dictionaries, custom word lists
- Quick Access Links capture (`Get-QuickAccessLinks`) — frequent folders, recent files, pinned items via Shell.Application COM
- Explorer Folder View capture (`Get-ExplorerFolderView`) — Advanced/General options, BagMRU view state
- Search Providers capture (`Get-SearchProviders`) — IE/Edge search scopes, Windows Search index paths, Cortana preferences
- ISE sub-categories expanded (profile, snippets, registry, options, add-ons, recent files)

### Bug Fixes
- WiFi `Get-Content -Raw` piped to `.Trim()` was called on `Object[]` → fixed with `Get-Field` helper reading `.Line`
- MRU `[Collections.Generic.List[string]]::new().Add()` wrong argument count → fixed by building `$entry` then calling `Add($entry)`
- Display `LogPixels` property check threw on machines without per-monitor DPI registry → guarded with `PSObject.Properties` check
- Mapped Drives `$disk` variable scope lost inside nested `Where-Object` → captured `$disk = $_` before sub-closure
- Speech `Language` attribute was in the sub-key `Attributes`, not on the provider key directly → read `Attributes` sub-key first
- TTS `Language` / `Gender` sub-key issue — same fix pattern as Speech
- Quick Access `-Filter` array was passed to `Where-Object -Filter` incorrectly → changed to `Where-Object { $_ -match ... }`

---

## v1.2.0 — 2026-02-16

### New Features
- WiFi Profiles capture (`Get-WiFiProfiles`) — netsh profile metadata + encrypted XML export
- Recent Locations MRU capture (`Get-MRULocations`) — typed paths, Run dialog, OpenSave dialog, recent extensions
- Certificate Stores inventory (`Get-CertificateStores`) — CurrentUser and LocalMachine stores
- ISE Configuration capture (`Get-ISEConfiguration`) — profile path, snippets, registry settings
- Terminal Configuration capture (`Get-TerminalConfiguration`) — ConsoleHost registry, Windows Terminal settings.json
- PS Repositories capture (`Get-PSHelpRepositories`) — registered PSRepositories and module paths
- Screensaver Settings capture (`Get-ScreensaverSettings`)
- Power Configuration capture (`Get-PowerConfiguration`) — power plans with active plan identification
- Display Layout capture (`Get-DisplayLayout`) — resolution, refresh rate, DPI, per-monitor scaling
- Regional & Language settings capture (`Get-RegionalSettings`)
- Tree view nodes added for all new categories
- Compare tab updated with diff support for all new comparable categories

---

## v1.1.0 — 2026-02-10

### New Features
- AES-256-CBC + PBKDF2-SHA256 (200,000 iterations) optional profile encryption
- `.upjson` file format with `Meta` and `Data` envelope
- COMPARE tab — side-by-side diff against a saved snapshot with colour-coded grids
- RESTORE tab — selective restore with rollback snapshot, progress log, and rollback button
- Password dialog for encrypted profiles (confirm on save, single entry on load/restore)
- Profile picker combo refreshes from store folder on each tab activation

---

## v1.0.0 — 2026-02-01

### Initial Release
- 5 capture categories: Winget Applications, PowerShell Environment, User App Configs, Taskbar Layout, Print Drivers, MIME Types
- VIEW tab — live snapshot tree view with expandable categories
- SAVE tab — save snapshot to `.upjson` profile file
- Dark-themed WinForms GUI with owner-draw TabControl
- Module: `UserProfileManager.psm1` with `Export-ModuleMember` for all public functions








