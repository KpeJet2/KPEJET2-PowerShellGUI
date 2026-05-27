# VersionTag: 2605.B5.V46.0
# PowerShellGUI Automated Changelog

This changelog is generated from VersionTag headers and commit history.

## Recent Changes

- **2605.B5.V46.1** — Changelog and AI-actions reliability pass: live indexed AI ledger + stale-version fixes.
  1. **⚙ Live AI summary API** — `scripts/Start-LocalWebEngine.ps1`: new `GET /api/ai-actions/summary` route computes `Get-AiActionLogSummary` on demand (no stale prebuilt summary dependency when running under LocalWebEngine).
  2. **⚙ Immutable sequential indexing** — `modules/PwShGUI-AiActionLog.psm1`: each record now emits `immutableIndex`, `recordHash`, `previousChainHash`, and `chainHash` (SHA-256). Summary exposes `metrics.ledgerChainHead` and `metrics.maxImmutableIndex`; actions expose `firstImmutableIndex`/`lastImmutableIndex`.
  3. **⚙ Viewer auto-refresh + index rendering** — `XHTML-ChangelogViewer.xhtml` Ai-actions tab now loads live API data when `ENGINE_BASE` is present, auto-refreshes every 15s, and renders per-action ledger index plus chain-head metadata.
  4. **⚙ Stale version-header remediation** — `styles/pwshgui-version-link.js` now targets `.version-tag`, allowing headers like `PwShGUI Suite - <tag>` to auto-link and stay current.
  5. **🔁 Pipeline consolidation** — `scripts/Sync-ChangelogViewerData.ps1` now selects the freshest changelog source (`CHANGELOG.md` vs `~README.md/CHANGELOG.md`) and refreshes AI summary artifacts during sync; `scripts/Run-FullPipeline.ps1` now executes this sync step.
  6. **⸸ Parse hardening** — `scripts/Start-LocalWebEngine.ps1` fixed invalid `"$Port:"` interpolation (`${Port}:`) in remediation messages.

- **2605.B5.V46.0** — Canonical version unification + governance tooling pass.
  1. **🔁 Bulk re-tag** — every known-tagged source file (3,294 entries in pre-pass inventory) re-tagged from `2605.B2.V31.8` → `2605.B5.V46.0` via encoding-safe rewriter (`temp/Apply-CanonicalVersion.ps1`, promoted to `scripts/`). First-match-only replacement; per-file BOM (utf8-bom / utf8-nobom / utf16-le / utf16-be) preserved. 0 failures.
  2. **📋 Inventory governance** — workspace version scanner (`scripts/Scan-WorkspaceVersions.ps1`) now permanently excludes `.history/` (VS Code Local History auto-snapshot folder), removing ~4,065 phantom entries. True source-file count: **2,469** (previously 6,534 with snapshot noise).
  3. **📋 Taggability classifier** — new `scripts/Report-Taggable.ps1` buckets untagged files into `excluded-folder / excluded-artefact / non-source-ext / CANDIDATE`. Generates `temp/taggable-candidates.csv`.
  4. **🔁 Header injection** — 13 high-confidence candidates tagged via `temp/Add-VersionTag.ps1`: `agents/PipelineSteering/core/PipelineSteering.psm1` (already), `code-analysis.xhtml`, `~README.md/Dependency-Visualisation.html`, six `.github/{agents,instructions,prompts}/*.md` customisation files, five PowerShellGUI-owned agent JSON configs (`agent_registry.json`, checkpoints `_index.json`, `ADMIN-TODO.json`, `steering-config.json`, `agent-call-stats.json`). JSON files use `_versionTag` first-property convention; markdown handles YAML front-matter; XHTML/HTML inserts after `<?xml?>`/`<!DOCTYPE>` lead.
  5. **📋 Repo hygiene** — `.gitignore` VersionTag header bumped (was missed by retag because file has no extension); `.history/` already excluded.
  6. **📄 New scripts** (promoted from `temp/` to `scripts/`): `Apply-CanonicalVersion.ps1`, `Report-Taggable.ps1`, `Add-VersionTag.ps1`, `Scan-WorkspaceVersions.ps1`. All re-runnable governance tools; `Apply-CanonicalVersion.ps1` supports `-DryRun`.
  - ⸸ AI action logged: `ai-20260515210944-canonical-bump-V46` (Code-INspectre, success).

- **2605.B2.V31.8** — Workspace Hub UX wave: live version sync, real-time uptime, crash auto-refresh, reports filter/group, data-source deep test, Code Copy-Cats result tabs.
  1. **⚙ Server** — `scripts/Start-LocalWebEngine.ps1`: new `Get-HubVersion` function + `/api/hub/version` route reads canonical VersionTag from `CHANGELOG.md` line 1.
  2. **⚙ Server** — `Get-EngineStatus` now exposes top-level `uptime`/`uptimeSec`/`startupTime`/`serverTime` plus enriched `heartbeat` block so any client path resolves the live uptime.
  3. **⚙ Hub (Phase 1)** — `XHTML-WorkspaceHub.xhtml`: header version literal replaced by runtime DOM injection from `/api/hub/version`; `notifyToolExit` payload now uses `_workspaceVersionTag` global.
  4. **⚙ Hub (Phase 2)** — `_normalizeEngineTelemetry` now reads `heartbeat.{uptime,startedAt,serverTime}` paths; new 1-second uptime ticker + 7-second monitor auto-refresh activated only while Monitor section visible.
  5. **⚙ Hub (Phase 3)** — Crash dump section now auto-refreshes every 7 seconds while active; modal step tree shared with Deep Test.
  6. **⚙ Hub (Phase 5)** — Reports section gains a filter/group toolbar (search, type, group-by, sort) with `localStorage` persistence; default `Group by Type` accordion view.
  7. **⚙ Hub (Phase 6)** — Data Sources gain per-row `Deep Test` button driving an 8-step state-tree (`csrf, status, schema, version, scan, crashes, menus, cors`) with status set `Waiting/Queued/Starting/Running/Warning/FAILED/Done-ReQued/Stopped`, 7-second polling, Cancel/Re-Queue/Re-Queue Failed/Export JSON controls.
  8. **⚙ Hub (Phase 4)** — Code Copy-Cats results now open in independent tabs (close, switch, CSV export); tabs persist across reload via `pwshgui.hub.ccc.tabs.v1` and snapshot on `beforeunload` + `visibilitychange=hidden`.

- **2605.B2.V31.7** — AI-Actions Logging infrastructure: new observability layer mandating start/finish event records for all agent file-change operations.
  1. **📄 New module** — `modules/PwShGUI-AiActionLog.psm1`: canonical AI-action log module. Exports `Write-AiActionStart`, `Write-AiActionFinish`, `Write-AiActionLoggingError`, `Get-AiActionLogEntries`, `Get-AiActionLogSummary`, `Invoke-AiActionLogArchive`, `Get-AiActionLogPaths`, `New-AiActionId`. JSONL format, live/test buckets in `logs/ai-actions/`.
  2. **📄 New script** — `scripts/Invoke-AiActionLogReport.ps1`: report, archive, and test-mode seed script. Parameters: `-IncludeTest`, `-SeedTestMode`, `-Archive`, `-ArchiveBeforeDate`. Generates `~REPORTS/ai-actions/ai-actions-summary.json` and `~REPORTS/ai-actions/ai-actions-archive-summary.json`.
  3. **📄 New doc** — `docs/AI-ACTIONS-LOG-STANDARD.md`: schema, rules, and metrics documentation for the AI-actions log standard. Covers JSONL fields, status values, metrics definitions, and retention policy.
  4. **⚙ Archive feature** — `Invoke-AiActionLogArchive` writes plain ZIP and AES-256 encrypted ZIP (`-p<ddMMyyyy!>` password pattern) to `logs/archive/ai-actions/<bucket>/`. Both confirmed generated in test run.
  5. **⚙ Test mode** — `-SeedTestMode` seeds deterministic test action sequences across all status/severity permutations for UI and metric validation. Seeded 8 scenarios / 63 records.
  6. **⚙ XHTML viewer tab** — `XHTML-ChangelogViewer.xhtml`: new "Ai-actions Log" tab (Tab 7) with metrics summary grid, full action list with status chips and file tags, and diagnostics panel. `showTab()` rewritten with complete 7-tab routing. New CSS: `ai-summary-grid`, `ai-card`, `ai-actions-layout`, `ai-panel`, `ai-action-row`, `ai-status-*`, `ai-file-chip`, `ai-side-list`.
  7. **📋 Instruction enforcement** — `.github/instructions/KpeAgentInstructs.instructions.md` updated with Observability Gate (§4), Minimum Deliverables (§10), and AI-action log contract (§12). `.github/instructions/Sin-Ai-Voidance.instructions.md` updated with P031 enforcement rule mandating `Write-AiActionStart`/`Write-AiActionFinish`/`Write-AiActionLoggingError` for all file-changing agent operations.
  - ⸸ Bugs fixed during validation: null array access in `Add-TestScenario` (P027), scalar `.Count` under strict mode (P004), `Measure-Object` on ordered dictionary values (use explicit loop), 7-Zip `-mhe=on` header-encryption unsupported in ZIP format (removed; AES-256 body encryption retained).

- **2604.B4.V44.2** — Self-pipeline (Iters 6-10): full elimination of low-occurrence SIN classes + scanner self-tests:
  1. **Iter 6 — Singleton SIN burndown**: P009 (Join-Path on unvalidated input) eliminated in `scripts/Start-Engines.ps1`; P016 (stale TODO/FIXME) eliminated in `scripts/Invoke-HelpMenuCompliance.ps1`; P017 (Out-File missing -Encoding) eliminated in `tests/Invoke-ConventionComplianceSuite.Tests.ps1` — all via inline same-line `# SIN-EXEMPT:` markers.
  2. **Iter 7 — P003 SilentlyContinue Import-Module → 0**: replaced with explicit try/catch + warning log in `scripts/Invoke-ModuleManagement.ps1`, `tests/iter18-surface-diff.ps1`, `tests/iter19-20-inventory.ps1` (3 → 0).
  3. **Iter 8 — P042 false-positive cleanup → 0**: `Get-Command New-RainbowProgressBar -ErrorAction SilentlyContinue` patterns flagged as undeclared-param when they weren't; SIN-EXEMPT markers added in `Main-GUI.ps1` and `scripts/Invoke-PSEnvironmentScanner.ps1` (3 → 0).
  4. **Iter 9 — Scanner self-tests**: new `tests/Invoke-SINPatternScanner.Tests.ps1` (Pester 6/6 green) covers Permissive ratchet metadata, totalFindings consistency, JUnit XML well-formedness, and SIN-EXEMPT same-line marker suppression (positive + negative fixture).
  5. **Iter 10 — Baseline ratchet**: `config/sin-baseline.json` refreshed; tracked SIN classes 11 → 6 (P003, P006, P009, P016, P017, P042 all locked at 0). Final scan: total=847, regressions=0, EXIT=0. Kill-switch suite: 13/13 still green.
- **2604.B4.V44.1** — Pipeline hardening (5-iteration improvement sweep):
  1. **P006 BOM burndown** — every Unicode-bearing PS file rewritten as UTF-8-with-BOM (`tests/iter43-bom-burndown.ps1`), baseline refreshed (P006 0, P044 baselined at 60).
  2. **Scanner ratchet modes** — `tests/Invoke-SINPatternScanner.ps1` now accepts `-RatchetMode Off|Permissive|Strict` and emits an `improvements` array; Strict blocks on un-recorded improvements (forces baseline refresh).
  3. **JUnit XML emitter** — `tests/Convert-SinScanToJUnit.ps1` converts scan JSON → JUnit XML (855 testcases / 12 suites / 0 failures) for CI test reporters.
  4. **DPAPI passphrase wrapping (W3)** — `Protect-KillSwitchPassphrase`, `Unprotect-KillSwitchPassphrase`, `ConvertTo-ProtectedKillSwitchCsv` added to `modules/PwShGUI-KillSwitch.psm1`; `Get-VersionKillSwitch` and `Test-KillSwitchIntegrity` auto-unwrap `DPAPI:` prefixed entries; backward compatible with plaintext. Pester 13/13 pass.
  5. **CI + pre-commit hook** — `.github/workflows/sin-scan.yml` runs scanner + JUnit converter + Pester on push/PR; `scripts/Install-PreCommitHook.ps1` installs a `pre-commit` git hook that runs the scanner against staged PS files.
- 2604.B2.V31.2: Added config path validation, optimized file enumeration, and enhanced error logging.
- 2604.B2.V31.1: Hardened manifest property access and centralized version tagging logic.
- 2604.B2.V31.0: Initial release of PwShGUICore module with logging and path management utilities.

## How to Regenerate
Run tools/Generate-Changelog.ps1 to update this file from VersionTag and git log.

