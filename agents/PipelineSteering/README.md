# VersionTag: 2604.B0.v1
# PipelineSteering Agent

**Version**: 2603.B0.v1.0  
**Author**: The Establishment  
**Date**: 2026-04-03  
**FileRole**: README

---

## Purpose

The PipelineSteering agent performs workspace-wide code quality and documentation conformance steering.  It is the automated enforcement arm for ensuring all scripts and modules maintain:

- Function-level comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`)
- File-level narrative headers (`<# Outline: #>`, `<# Problems: #>`, `<# ToDo: #>`)
- Standard dotfiles (`.outline`, `.problems`, `.todo`) in each code directory
- Minor version increments on every file modified by a steering pass
- Post-fix pipeline referential scans (bug scan + config coverage audit)

---

## Directory Layout

```
agents/PipelineSteering/
├── core/
│   └── PipelineSteering.psm1    ← main module (this agent's logic)
├── config/
│   └── steering-config.json     ← tunable scan parameters
├── logs/                        ← steering session logs (auto-created)
└── README.md                    ← this file
```

---

## Exported Functions

| Function | Description |
|---|---|
| `Invoke-PipelineSteerSession` | Main entry point — runs all phases, writes report |
| `Test-FunctionDescriptions` | Scans for functions missing comment-based help |
| `Resolve-OutlineConformance` | Checks / fixes Outline/Problems/ToDo header blocks |
| `Invoke-DocTemplatePropagation` | Creates `.outline` / `.problems` / `.todo` dotfiles |
| `Invoke-SteeringPipelineScan` | Post-fix bug scan + coverage audit |
| `Update-FileVersionTag` | Bumps minor version in a file's VersionTag header |

---

## Cron Integration

Two cron tasks are registered:

| Task ID | Type | Schedule | Purpose |
|---|---|---|---|
| `TASK-PipelineSteer` | `PipelineSteer` | Daily (1440 min) | DryRun scan; report to `~REPORTS/PipelineSteering/` |
| `TASK-PipelineSteerApply` | `PipelineSteerApply` | Weekly (10080 min) | Apply fixes, bump versions, run pipeline scan |

---

## Usage

```powershell
# Load agent
Import-Module 'C:\PowerShellGUI\agents\PipelineSteering\core\PipelineSteering.psm1' -Force

# DryRun — report only, no changes
Invoke-PipelineSteerSession -WorkspacePath 'C:\PowerShellGUI'

# Apply — fix issues and bump version tags
Invoke-PipelineSteerSession -WorkspacePath 'C:\PowerShellGUI' -Apply

# Skip post-fix scan during apply (for speed)
Invoke-PipelineSteerSession -WorkspacePath 'C:\PowerShellGUI' -Apply -SkipPipelineScan
```

---

## Report Output

Each session writes a JSON report to:

```
~REPORTS/PipelineSteering/steer-YYYYMMDD-HHmmss.json
```

The report contains:
- `FunctionGaps` — functions missing help blocks
- `OutlineIssues` — files missing Outline / Problems / ToDo blocks
- `DotfilesNeeded` — directories needing dotfiles
- `PipelineScanResult` — bug scan + coverage audit summary
- `ElapsedSeconds`, `DryRun` mode flag, `SessionId`

