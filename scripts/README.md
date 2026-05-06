# scripts/ Directory

> VersionTag: 2604.B2.V31.2 | Auto-generated index of all scripts

## Pipeline & Automation

| Script | Description |
|--------|-------------|
| Invoke-CronProcessor.ps1 | 10-minute automated maintenance cycle (17 steps) |
| Register-CronTask.ps1 | Registers CronProcessor as a Windows Scheduled Task |
| Invoke-CyclicRenameCheck.ps1 | 48-hour cyclic wrapper for Invoke-RenameProposal.ps1 |
| Register-CyclicRenameTask.ps1 | Registers the cyclic rename check as a scheduled task |
| Invoke-ErrorHandlingContinuousLoop.ps1 | Iterative error-handling scan/remediation loops |
| Invoke-ErrorHandlingRemediation.ps1 | Automated batch remediation for error handling violations |
| Invoke-PipelineIntegrityCheck.ps1 | Validate pipeline artifact coherence and stale checks |
| Invoke-SelfReviewCycle.ps1 | Evaluates workspace health across 8 dimensions |
| Invoke-PipeGAP.ps1 | Pipeline alignment diagnostics (workplans, todo gaps, relics, parse, stale checks) |
| Invoke-SINRegistryReindex.ps1 | Reindex SIN registry with timestamped filenames |
| Invoke-SINRemedyEngine.ps1 | Iterative remedy-scan-retry engine for SIN violations |
| Normalize-TodoStatusVocabulary.ps1 | Normalise todo status/type values to canonical vocabulary |

## Build & Generation

| Script | Description |
|--------|-------------|
| Build-AgenticManifest.ps1 | Machine-readable JSON agentic API manifest for workspace |
| Build-DirectoryTree.ps1 | Generates canonical DIRECTORY-TREE.md from filesystem |
| Build-ToolsInventory.ps1 | Build/update widget tools inventory JSON |
| Invoke-TodoBundleRebuild.ps1 | Rebuilds todo/_bundle.js aggregate |
| Invoke-ReleasePreFlight.ps1 | Pre-release validation for PowerShellGUI |
| Invoke-VersionAlignmentTool.ps1 | Version validation and minor cleanup across workspace |

## Data & Migration

| Script | Description |
|--------|-------------|
| ConvertTo-FeatureToDo.ps1 | Converts Feature Requests from XHTML JSON into todo/ items |
| Invoke-DataMigration.ps1 | One-time migration of Feature/Bug JSON into unified todo/ |
| Invoke-TodoArchiver.ps1 | Archives completed/rejected/blocked todo items to subfolders |
| Invoke-TodoManager.ps1 | Manages todo/: reindex, validate, report, add items |

## Scanning & Auditing

| Script | Description |
|--------|-------------|
| Invoke-AgentCallStats.ps1 | Computes per-agent call statistics (24h/7d/all-time) from JSONL logs; updates agent-call-stats.json |
| Invoke-ConfigCoverageAudit.ps1 | Audits config file coverage |
| Invoke-DependencyScanManager.ps1 | Orchestrates dependency scans across modules and scripts |
| Invoke-EngineCrashCleanup.ps1 | Quarantines crashed engine artefacts and generates cleanup report |
| Invoke-FullSystemsScan.ps1 | Multithreaded workspace integrity orchestrator |
| Invoke-OrphanAudit.ps1 | Scans for orphaned files not referenced by any script |
| Invoke-OrphanCleanup.ps1 | Removes/archives orphaned files from audit |
| Invoke-ReferenceIntegrityCheck.ps1 | Validates canonical docs/XHTML/link integrity |
| Invoke-ScriptDependencyMatrix.ps1 | Builds cross-reference dependency matrix |
| Invoke-StaticWorkspaceScan.ps1 | Multi-phase static analysis scan: folder index, module validation, DNS check, bug reporting |
| Invoke-WorkspaceDependencyMap.ps1 | Scans folders, modules, functions, variables, config keys |
| Invoke-XhtmlReportTriage.ps1 | Triages XHTML report files by validating structure |
| Find-ModuleReferences.ps1 | Finds module import references across workspace |

## Reporting

| Script | Description |
|--------|-------------|
| Export-SystemReport.ps1 | Comprehensive HTML system diagnostic report |
| Invoke-ReportRetention.ps1 | Enforces retention policy on report files |
| Invoke-HistoryRotation.ps1 | Rotates .history files, keeping recent N per source |
| Invoke-FileChangeTracker.ps1 | Structured lifecycle logging for file changes |
| Invoke-RenameProposal.ps1 | Proposes renames for non-standard file names |

## GUI Tools (WinForms)

| Script | Description |
|--------|-------------|
| Show-AppTemplateManager.ps1 | App inventory, gap analysis, winget orchestration |
| Show-CertificateManager.ps1 | Read-only Windows certificate store browser |
| Show-CronAiAthonTool.ps1 | Multi-tab pipeline management dashboard |
| Show-EventLogViewer.ps1 | Browse and filter Windows Event Logs |
| Show-MCPServiceConfig.ps1 | MCP service configuration GUI |
| Show-SandboxTestTool.ps1 | Interactive sandbox test tool for GUI testing |
| Show-ScanDashboard.ps1 | Scan results dashboard |
| Show-WorkspaceIntentReview.ps1 | Development intent management, change logging, intent sealing GUI |
| UserProfile-Manager.ps1 | GUI for user profile capture/compare/restore |
| WinRemote-PSTool.ps1 | Remote PowerShell management GUI |

## Infrastructure & Setup

| Script | Description |
|--------|-------------|
| Install-BitwardenLite.ps1 | Guided Bitwarden CLI installer for Assisted SASC |
| Repair-ModulePaths.ps1 | Repairs PSModulePath to include modules directory |
| Start-BWServe.ps1 | Launch Bitwarden CLI HTTP API service |
| Start-LocalWebEngine.ps1 | Local HTTP/WebSocket API engine (port 8042) — 11 routes, CSRF protection |
| Test-ModuleDependencies.ps1 | Reports on installed, missing and errored modules |
| Test-Prerequisites.ps1 | Validates system prerequisites for PowerShellGUI |
| Invoke-ChecklistActions.ps1 | Automated checklist actions for Getting Started |
| Invoke-ModuleManagement.ps1 | Module management lifecycle operations |
| New-InstallerScript.ps1 | Installer script generation |
| Invoke-WorkspaceRollback.ps1 | Rollback workspace files to a checkpoint snapshot |
| Invoke-TestRoutine.ps1 | Executes Testing Routine Builder JSON templates |

## Utility Scripts (Script-A through Script6)

| Script | Description |
|--------|-------------|
| Script-A.ps1 | User Management |
| Script-B.ps1 | User Management |
| Script-C.ps1 | User Management |
| Script-D.ps1 | User Management |
| Script-E.ps1 | User Management |
| Script-F.ps1 | User Management |
| Script-F-ClonedFrom_MainGUI.ps1 | User Management (cloned) |
| Script-F-LinkToConfigJson.ps1 | Configuration Template Validator |
| Script1.ps1 | Account & User Management |
| Script2.ps1 | Backup Operations |
| Script3.ps1 | Configuration Sync |
| Script4.ps1 | Database Maintenance |
| Script5.ps1 | Network Diagnostics |
| Script6.ps1 | System Cleanup (Interactive with WhatIf) |

## Version Fix Utilities

| Script | Description |
|--------|-------------|
| fix_check_version.ps1 | Version check utility |
| fix_update_version.ps1 | Version update utility |

## Reference

| Script | Description |
|--------|-------------|
| PS-CheatSheet-EXAMPLES.ps1 | PowerShell Cheat Sheet V1 |
| PS-CheatSheet-EXAMPLES-V2.ps1 | PowerShell Cheat Sheet V2 -- Expanded Reference |

---
*86 scripts total. Generated for CronProcessor pipeline step 7b.*
