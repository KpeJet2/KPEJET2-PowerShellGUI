# VersionTag: 2605.B5.V46.0
<!-- VersionBuildHistory: 2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 4 entries) -->
<!-- FileRole: README -->

# PowerShellGUI - Smoke Test Harness

**Script:** `tests/Invoke-GUISmokeTest.ps1`  
**Launcher:** `Launch-GUI-SmokeTest.bat`  
**Author:** The Establishment  
**Version:** 2602.a.13  
**Created:** 04 Mar 2026  

---

## Purpose

Exercises every menu item, main-form button, and key sub-dialog in
`Main-GUI.ps1` using the **System.Windows.Automation** (UI Automation)
API, then logs detailed pass/fail results to the console **and** a
timestamped log file under `logs/`.

The harness is designed for quick regression checks after code changes
and can run fully unattended (headless mode) or with the live GUI.

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Windows 10 / 11 / Server 2016+ |
| PowerShell | 5.1 or 7+ (launcher auto-detects `pwsh`) |
| Assemblies | UIAutomationClient, UIAutomationTypes (loaded automatically) |
| WinForms | System.Windows.Forms + System.Drawing |
| Main-GUI.ps1 | Must be present in the workspace root |
| config/ | `system-variables.xml` must exist |

---

## Quick Start

### One-Click (recommended)

Double-click **`Launch-GUI-SmokeTest.bat`** in the workspace root.
It detects `pwsh` (PowerShell 7+) and falls back to
`powershell.exe` if unavailable.

### Command Line

```powershell
# Full smoke test (all phases)
.\tests\Invoke-GUISmokeTest.ps1

# Run matrix in both shells (PowerShell 5.1 + PowerShell 7 where available)
.\tests\Invoke-GUISmokeTest.ps1 -RunShellMatrix

# Headless only (Phase 0 — no GUI launched)
.\tests\Invoke-GUISmokeTest.ps1 -HeadlessOnly

# Skip specific phases
.\tests\Invoke-GUISmokeTest.ps1 -SkipPhase 3,4

# Custom window-detection timeout
.\tests\Invoke-GUISmokeTest.ps1 -Timeout 60
```

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-HeadlessOnly` | Switch | `$false` | Run only Phase 0 (non-GUI validation) and exit. |
| `-SkipPhase` | Int[] | `@()` | Phase numbers (0–5) to skip. Phases 6–7 always run. |
| `-Timeout` | Int | `45` | Seconds to wait for the main window to appear. |
| `-Shell` | String | `auto` | Select launch host for Phase 1 (`auto`, `powershell`, `pwsh`). |
| `-RunShellMatrix` | Switch | `$false` | Re-runs the smoke routine under both PowerShell 5.1 and PowerShell 7 (if available). |
| `-SkipMenuItems` | String[] | `Version Check` | Menu item names to skip during Phase 2 (default skips build/version check option). |

---

## Phases

| Phase | Name | What It Does |
|---|---|---|
| **0** | Headless | Syntax-parses `Main-GUI.ps1`, imports every `modules/*.psm1` module, validates `config/system-variables.xml`, spot-checks JSON files, and confirms the main script file exists. |
| **0f** | Launcher Targets | Validates `Launch-GUI.bat` menu target files, excluding build-version options; `.ps1` targets are parse-validated in both PowerShell 5.1 and 7 hosts. |
| **1** | Launch | Starts `Main-GUI.ps1 -StartupMode quik_jnr` in a new process and waits for the main window to appear (UI Automation `RootElement` search). |
| **2** | Menus | Walks every top-level menu bar item, expanding and collapsing each. Logs which menus were found. |
| **3** | Buttons | Clicks each of the 12 main-form buttons. Auto-dismisses any UAC / elevation dialogs that pop up. |
| **4** | Dialogs | Re-opens key sub-dialogs (e.g., Path Settings, Script Folders) and verifies expected controls exist. |
| **5** | Logs | Reads today's app event log and cross-checks for expected entries (button clicks, menu selects, elevation events). |
| **6** | Cleanup | Closes the GUI gracefully (File ▸ Exit → WindowPattern.Close → `Stop-Process` fallback). Always runs. |
| **7** | Report | Writes a colour-coded summary table to the console and saves a full log to `logs/<COMPUTERNAME>-<timestamp>-SmokeTest.log`. Always runs. |

---

## Output

### Console
A colour-coded table with Status, Phase, Test Name, and Detail for every check:

```
STATUS  PHASE    TEST             DETAIL
------  ------   ----             ------
PASS    Phase0   SyntaxParse      Main-GUI.ps1 parses without errors
PASS    Phase0   ModuleImport     Loaded 5 modules
FAIL    Phase3   Button_Btn07     Timed out waiting for dialog
...
```

### Log File
Saved to `logs/<COMPUTERNAME>-<yyyyMMdd-HHmmss>-SmokeTest.log` in the
same tabular format (ANSI codes stripped).

### Exit Code
- **0** — all tests passed (or only warnings/skips)
- **1** — one or more tests failed

---

## Helper Functions

| Function | Purpose |
|---|---|
| `Write-TestLog` | Dual-output (console + file) with colour coding |
| `Wait-Window` | Polls `AutomationElement.RootElement` for a window by name |
| `Find-Control` | Searches the automation tree for a control by type/name |
| `Invoke-MenuPath` | Expands a menu hierarchy and invokes the leaf item |
| `Close-Dialog` | Sends close/cancel to a dialog using UI Automation |
| `Collapse-MenuItem` | Collapses an expanded menu to restore state |
| `Dismiss-Dialog` | Dismisses elevation or confirmation dialogs |
| `Show-Report` | Prints the final results table and writes the log file |

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Phase 1 times out | `Main-GUI.ps1` failed to start or window title changed | Increase `-Timeout`, verify the script runs standalone. |
| Phase 3 mostly fails | UAC prompts block the automation thread | Run the test from an **elevated** (admin) terminal. |
| Phase 5 warns "no log" | The app hadn't flushed its log when the check ran | Harmless — the log is checked once; timestamps may not align. |
| All phases skipped | `-HeadlessOnly` was passed | Remove the switch for a full GUI run. |
| Batch launcher shows "not found" | Working directory is wrong | Run the `.bat` from the workspace root, not a subfolder. |

---

## Integration with CI / Automation

```powershell
# Exit code 0 = green, 1 = red
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-GUISmokeTest.ps1
if ($LASTEXITCODE -ne 0) { throw "Smoke test failed" }
```

Because the harness launches a live WinForms window, it requires a
**desktop session** (RDP, interactive logon, or a CI runner with
desktop access). Headless-only mode (`-HeadlessOnly`) can run in any
environment.

---

*End of README-SmokeTest.md*






