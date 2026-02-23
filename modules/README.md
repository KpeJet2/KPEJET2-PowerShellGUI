# modules/ Directory

> VersionTag: 2604.B2.V31.2 | Auto-generated index of all modules

## Core Infrastructure

| Module | Description | Approx Lines |
|--------|-------------|-------------|
| PwShGUICore.psm1 | Shared logging, lifecycle, and helper functions | ~1800 |
| PwShGUI-IntegrityCore.psm1 | Centralised startup and runtime integrity checking | ~900 |
| PwShGUI-Theme.psm1 | Modern styling, rainbow progress bars, spinners | ~1200 |
| PwShGUI-VersionManager.psm1 | Major.Minor versioning, CPSR HTML reports, checkpoint epochs | ~800 |
| PwShGUI-TrayHost.psm1 | Background process host, custom tray icon | ~600 |
| PwShGUI-PSVersionStandards.psm1 | PS version standards, optimal/minimum definitions | ~400 |
| Get-LaunchTelemetry.psm1 | System telemetry collection for launch logging | ~300 |

## Pipeline & Automation

| Module | Description | Approx Lines |
|--------|-------------|-------------|
| CronAiAthon-Pipeline.psm1 | Unified pipeline registry for Features, Bugs, Todos | ~1500 |
| CronAiAthon-Scheduler.psm1 | Cyclic job execution, history, and scheduling | ~800 |
| CronAiAthon-EventLog.psm1 | EventLog & SYSLOG -- Windows Event Log integration | ~600 |
| CronAiAthon-BugTracker.psm1 | Bug detection, classification, and tracking | ~700 |
| SINGovernance.psm1 | SIN pattern governance and enforcement | ~500 |
| RE-memorAiZ.psm1 | Pipeline completeness enforcement, agent handback, workspace memory | ~520 |

## Workspace Governance

| Module | Description | Approx Lines |
|--------|-------------|-------------|
| WorkspaceIntentReview.psm1 | Intent sealing, indexed change logging, development direction governance | ~350 |

## Security & Credentials

| Module | Description | Approx Lines |
|--------|-------------|-------------|
| AssistedSASC.psm1 | Secret Access & Security Checks (Bitwarden integration) | **~2650** |
| SASC-Adapters.psm1 | Target-specific credential injection adapters | ~1200 |
| PKIChainManager.psm1 | PKI certificate chain management | ~800 |

## User & Profile Management

| Module | Description | Approx Lines |
|--------|-------------|-------------|
| UserProfileManager.psm1 | Capture, save, compare, restore user profile snapshots | ~1800 |

## Networking

| Module | Description | Approx Lines |
|--------|-------------|-------------|
| AVPN-Tracker.psm1 | VPN connection tracking and management | **~2100** |

## Data & Communication

| Module | Description | Approx Lines |
|--------|-------------|-------------|
| PwShGUI-ConvoVault.psm1 | Encrypted conversation registry for Rumi/Sumi exchanges | ~900 |
| PwShGUI_AutoIssueFinder.psm1 | Automated issue detection and filing | ~700 |

## Data Translation

| Module | Description | Approx Lines |
|--------|-------------|-------------|
| PwShGUI-SchemaTranslator.psm1 | Scan schema version detection and cross-version data translation | ~370 |

## Utilities

| Module | Description | Approx Lines |
|--------|-------------|-------------|
| PwSh-HelpFilesUpdateSource-ReR.psm1 | PowerShell help files remote resource retrieval | ~400 |
| _TEMPLATE-Module.psm1 | Module template for new modules | ~100 |

## Dependency Map

```
Main-GUI.ps1
  +-- PwShGUICore.psm1 (logging, lifecycle)
  +-- PwShGUI-Theme.psm1 (UI styling)
  +-- PwShGUI-IntegrityCore.psm1 (startup checks)
  +-- PwShGUI-VersionManager.psm1 (version display)
  +-- PwShGUI-TrayHost.psm1 (tray icon)
  +-- Get-LaunchTelemetry.psm1 (startup metrics)
  +-- AssistedSASC.psm1 (credential access)
  |     +-- SASC-Adapters.psm1 (target adapters)
  +-- AVPN-Tracker.psm1 (VPN panel)
  +-- UserProfileManager.psm1 (profile panel)
  +-- PKIChainManager.psm1 (certificate panel)

Invoke-CronProcessor.ps1
  +-- CronAiAthon-Pipeline.psm1 (pipeline registry)
  +-- CronAiAthon-Scheduler.psm1 (job scheduling)
  +-- CronAiAthon-EventLog.psm1 (event logging)
  +-- CronAiAthon-BugTracker.psm1 (bug detection)
  +-- SINGovernance.psm1 (compliance checks)
  +-- PwShGUI_AutoIssueFinder.psm1 (issue detection)
  +-- RE-memorAiZ.psm1 (pipeline completeness, agent handback)

Show-WorkspaceIntentReview.ps1
  +-- PwShGUICore.psm1 (logging)
  +-- WorkspaceIntentReview.psm1 (intent/change-log management)
  +-- RE-memorAiZ.psm1 (pipeline orchestration)
```

## Oversized Modules (Split Candidates)

| Module | Lines | Split rationale |
|--------|-------|-----------------|
| AssistedSASC.psm1 | ~2650 | Bitwarden CLI, session mgmt, and vault ops could separate |
| AVPN-Tracker.psm1 | ~2100 | Connection logic vs GUI rendering vs config management |
| UserProfileManager.psm1 | ~1800 | Snapshot capture vs comparison vs restoration |
| PwShGUICore.psm1 | ~1800 | Logging vs lifecycle vs UI helpers |

---
*24 modules total. Generated for CronProcessor pipeline step 7b.*
