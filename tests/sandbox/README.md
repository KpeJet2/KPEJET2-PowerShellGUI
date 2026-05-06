# Interactive Sandbox Test Tool

**Version:** 2604.B1.v1.0  
**Author:** The Establishment  
**Category:** Testing & Quality Assurance  
**Type:** Widget Tool  

## Overview

The Interactive Sandbox Test Tool provides iterative, isolated GUI testing for PowerShellGUI using Windows Sandbox. Test code changes, run smoke test**s, and launch the full GUI—all in total system isolation without affecting your host machine.

---

## Features

### 🔒 **Total Isolation**
- **Network:** Disabled by default (no internet, no LAN access)
- **Filesystem:** Workspace mapped read-only; sandbox works on local copy
- **State:** Fully disposable—close sandbox and everything is gone
- **GPU:** Enabled for WinForms rendering fidelity

### ⚡ **Iterative Testing**
- **Sync:** Push code changes from host to sandbox
- **Test:** Run automated headless smoke tests
- **GUI:** Launch Main-GUI.ps1 interactively (visible in sandbox window)
- **Custom:** Execute ad-hoc PowerShell commands inside sandbox
- **Chaos:** Run chaos test conditions

### 📊 **Dashboard Interface**
- Real-time session status monitoring
- Quick-action buttons for common operations
- Activity log with color-coded messages
- Results viewer for test outputs and logs

---

## Prerequisites

### Required
- **OS:** Windows 10 Pro/Enterprise or Windows 11 Pro/Enterprise
- **Feature:** Windows Sandbox must be enabled
- **PowerShell:** 5.1 or 7+

### Enable Windows Sandbox
1. Open **Settings** → **Apps** → **Optional Features** → **More Windows Features**
2. Check **Windows Sandbox**
3. Restart if prompted

---

## Files

### Core Scripts
| File | Location | Purpose |
|------|----------|---------|
| `Show-SandboxTestTool.ps1` | `scripts/` | WinForms GUI launcher (called from Main-GUI Tools menu) |
| `Start-InteractiveSandbox.ps1` | `tests/sandbox/` | Host orchestrator—generates `.wsb`, launches sandbox |
| `Invoke-SandboxBootstrap.ps1` | `tests/sandbox/` | Runs inside sandbox—copies workspace, enters command loop |
| `Send-SandboxCommand.ps1` | `tests/sandbox/` | Host CLI for sending iteration commands to running sandbox |

### Launchers
| File | Location | Purpose |
|------|----------|---------|
| `Launch-SandboxInteractive.bat` | Root | Batch file launcher with mode selection menu |
| `README.md` | `tests/sandbox/` | This documentation file |

---

## Usage

### Method 1: From Main-GUI (Recommended)
1. Launch **Main-GUI.ps1**
2. Menu: **Tools** → **Interactive Sandbox Test**
3. Dashboard appears:
   - Click **Launch Sandbox** to start a new isolated session
   - Wait for status to show **READY** (green)
   - Use quick-action buttons:
     - **Iterate**: Full cycle (Sync + Test + GUI)
     - **Sync Code**: Push code changes into sandbox
     - **Run Tests**: Execute headless smoke tests
     - **Launch GUI**: Open Main-GUI.ps1 in sandbox (visible)
     - **Shutdown Sandbox**: Terminate session

### Method 2: Batch Launcher
Double-click **`Launch-SandboxInteractive.bat`** in root folder:
```
Select mode:
  1. Launch sandbox (isolated, no network)
  2. Launch sandbox + auto-open GUI
  3. Launch sandbox with networking enabled
  4. Launch sandbox + GUI + networking
```

### Method 3: PowerShell CLI
```powershell
# Start sandbox
$s = .\tests\sandbox\Start-InteractiveSandbox.ps1 -AutoLaunchGUI

# Iterate (sync code + run tests + launch GUI)
.\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir $s.SessionDir -Action Iterate

# Individual commands
.\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir $s.SessionDir -Action Sync
.\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir $s.SessionDir -Action Test -Headless
.\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir $s.SessionDir -Action GUI

# Check status
.\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir $s.SessionDir -Action Status

# Custom command
.\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir $s.SessionDir -Action Exec -Command 'Get-Module'

# Shutdown
.\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir $s.SessionDir -Action Shutdown
```

---

## Workflow

### Development Iteration Cycle
```
┌─────────────────────────────────────────────┐
│  HOST MACHINE                               │
│  1. Edit code in VS Code                    │
│  2. Save changes                            │
│  3. Click "Iterate" in Sandbox Test Tool    │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  WINDOWS SANDBOX (isolated)                 │
│  1. Sync: Re-copy changed files             │
│  2. Test: Run headless smoke tests          │
│  3. GUI:  Launch Main-GUI.ps1 (visible)     │
│  4. Interact: Click buttons, test features  │
│                                             │
│  Results written to shared output folder   │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  HOST MACHINE                               │
│  View results in:                           │
│  temp/sandbox-interactive-*/output/         │
│  - Test logs                                │
│  - Error reports                            │
│  - Screenshots (if captured)                │
└─────────────────────────────────────────────┘
```

---

## Command Reference

### Actions (via Send-SandboxCommand.ps1)

| Action | Description | Example |
|--------|-------------|---------|
| `Sync` | Re-sync workspace changes to sandbox | `-Action Sync` |
| `Test` | Run smoke tests (optionally headless) | `-Action Test -Headless` |
| `GUI` | Launch Main-GUI.ps1 in sandbox | `-Action GUI -GUIMode quik_jnr` |
| `StopGUI` | Stop the running GUI process | `-Action StopGUI` |
| `Chaos` | Run chaos test conditions | `-Action Chaos` |
| `Exec` | Execute custom PowerShell command | `-Action Exec -Command 'Get-Process'` |
| `Iterate` | Full cycle: Sync + Test + GUI | `-Action Iterate` |
| `Status` | Check sandbox status (no command sent) | `-Action Status` |
| `Shutdown` | Gracefully shut down sandbox | `-Action Shutdown` |

### Sandbox Configuration Options

**Start-InteractiveSandbox.ps1** parameters:
- `-MemoryMB`: Sandbox RAM allocation (default: 4096)
- `-Networking`: `Enable` or `Disable` (default: Disable for isolation)
- `-vGPU`: `Enable` or `Disable` (default: Enable for WinForms)
- `-AutoLaunchGUI`: Auto-start GUI after bootstrap
- `-MaxIdleMinutes`: Auto-shutdown after idle period (default: 120)

---

## Output Structure

Results are saved in `temp/sandbox-<session>-<timestamp>/`:
```
temp/
└─ sandbox-interactive-20260404-100000/
   ├─ cmd/                          # Command files (host writes, sandbox reads)
   │  └─ 20260404100530-001.cmd.json
   ├─ output/                       # Results (sandbox writes, host reads)
   │  ├─ sandbox-status.json
   │  ├─ sandbox-bootstrap.log
   │  ├─ 20260404100530-001.result.json
   │  └─ XPS15-MS-20260404-100545-SmokeTest.log
   ├─ bootstrap/
   │  └─ Invoke-SandboxBootstrap.ps1
   ├─ session-meta.json
   └─ PwShGUI-interactive-20260404-100000.wsb
```

---

## Troubleshooting

### Sandbox doesn't launch
- **Check:** Windows Sandbox feature enabled & system restart after enabling
- **Check:** Virtualization enabled in BIOS
- **Try:** `WindowsSandbox.exe` from Run dialog to verify feature works

### Status stays "Initializing..."
- **Cause:** Sandbox VM starting (esp. on first launch post-reboot)
- **Wait:** Can take 30-60 seconds on slower machines
- **Check:** `temp/sandbox-*/output/sandbox-bootstrap.log` for errors

### Commands not executing
- **Check:** Sandbox status is **READY** or **RUNNING** (not SHUTDOWN/ERROR)
- **Try:** Refresh status button in dashboard
- **Check:** `cmd/` folder for command files—should be consumed/deleted by sandbox

### Tests fail inside sandbox
- **Check:** Output logs in `temp/sandbox-*/output/`
- **Try:** Run sync first to ensure latest code is in sandbox
- **Tip:** Test failures in sandbox = isolated—won't affect host

---

## Integration

### Main-GUI Menu Entry
Added to **Tools** menu in `Main-GUI.ps1`:
```powershell
Menu: Tools > Interactive Sandbox Test
Script: scripts\Show-SandboxTestTool.ps1
Function: Show-SandboxTestTool -WorkspacePath $PSScriptRoot
```

### Pipeline Integration
Registered in **CronAiAthon-Pipeline** as a tool widget:
- Type: `WIDGET_TOOL`
- Category: `Testing`
- Status: `ACTIVE`
- Files tracked in todo/ system

### Manifest Entry
Auto-discovered by `Build-AgenticManifest.ps1`:
- Exported function: `Show-SandboxTestTool`
- Action domain: `test.sandbox`
- Category: `testing.isolation`

---

## Best Practices

### ✅ DO
- Launch sandbox once, iterate multiple times (edit → sync → test)
- Use **Iterate** action for full test cycles
- Check output logs after test failures
- Let sandbox auto-shutdown on idle (conserves resources)

### ❌ DON'T
- Leave sandbox running indefinitely (uses RAM & CPU)
- Manually edit files in `temp/sandbox-*/` folders
- Run multiple sandboxes at once (resource contention)
- Enable networking unless needed for specific tests

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2604.B1.v1.0 | 2026-04-04 | Initial release: WinForms dashboard, 3 core scripts, batch launcher, CLI iteration support |

---

## See Also

- **Smoke Test Framework**: `tests/Invoke-GUISmokeTest.ps1`
- **Chaos Testing**: `tests/Invoke-ChaosTestConditions.ps1`
- **SIN Governance**: `sin_registry/` for code quality patterns
- **Main GUI**: `Main-GUI.ps1` - primary application

---

## Support

For issues, feature requests, or contributions:
- **Check:** `~README.md/ENHANCEMENTS-LOG.md` for roadmap
- **Log:** Issues in `logs/` folder
- **Pipeline:** Add feature request via **Cron-Ai-Athon Tool** (Tools menu)

---

**Status:** ✅ Production-ready  
**Maintenance:** Active  
**Dependencies:** Windows Sandbox feature, PowerShell 5.1+, Main-GUI.ps1
