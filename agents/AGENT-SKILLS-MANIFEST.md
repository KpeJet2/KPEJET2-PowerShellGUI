---
# VersionTag: 2607.B1.V52.0
description: Enhanced agent capabilities, skills matrix, and workspace tooling for PowerShellGUI infrastructure
applyTo: "agents/*, .github/instructions/*, scripts/*, tools/*"
---

# Agent Skills & Capabilities Manifest (v2607.B1.V52.0)

## 1) Core Competencies

### 1.1 Workspace Navigation & Discovery
- ✓ File search (glob patterns, regex), directory traversal, metadata extraction
- ✓ Manifest inspection (agentic-manifest.json, dynamic-manifest.json, SIN registry)
- ✓ Version tracking (VersionTag parsing, changelog alignment, release history)
- ✓ Dependency graph analysis (module imports, script cross-references, function calls)
- ✓ Build artifact identification (logs, reports, manifests, intermediate outputs)

### 1.2 Code Analysis & Quality
- ✓ PowerShell AST parsing (function extraction, parameter analysis, complexity metrics)
- ✓ SIN pattern detection (P001-P033 blocking patterns, semi-SIN advisories)
- ✓ Encoding compliance validation (UTF-8 with BOM for Unicode files)
- ✓ Syntax validation (parse checks, scope analysis, variable shadowing)
- ✓ Coverage mapping (tested vs untested functions, engine-specific coverage)

### 1.3 Testing Infrastructure
- ✓ Dual-engine test orchestration (PS7.6 primary, PS5.1 fallback with 24h gating)
- ✓ Smoke test execution (UI automation via System.Windows.Automation)
- ✓ Sandbox test orchestration (Windows Sandbox with bootstrap scripts)
- ✓ Pester integration (test discovery, execution, report aggregation)
- ✓ Test result tracking (history archival, regression detection, coverage trending)

### 1.4 Security & Secrets
- ✓ Bitwarden CLI integration (vault unlock, secret retrieval, audit logging)
- ✓ DPAPI encryption (Windows Hello PIN-based vault access)
- ✓ Credential validation (format checks, rotation policies, access controls)
- ✓ PKI certificate management (pki/ folder, key pair generation, signing)
- ✓ Audit trail generation (vault access logs, CI/CD action tracking)

### 1.5 Build & Release
- ✓ Version tag canonicalization (YYMM.B<build>.V<major>.<minor> format)
- ✓ Changelog generation & synchronization (incremental updates, milestone tracking)
- ✓ Manifest generation (agentic-manifest.json, dynamic-manifest.json, SIN registry)
- ✓ Artifact packaging (release bundles, snapshots, migration notes)
- ✓ Pipeline gate orchestration (Run-FullPipeline.ps1 with conditional blocking)

## 2) Specialized Tooling

### 2.1 DynaManifest System (NEW)
**Files**: scripts/Build-DynaManifest.ps1, scripts/Invoke-DynaManifestValidation.ps1

**Capabilities**:
- Generate unified dynamic manifest combining file inventory, metadata, drift guards
- Validate version alignment (all modules have canonical VersionTag)
- Check encoding compliance (UTF-8 with BOM for Unicode files — P006)
- Track test recency (PS5/PS7 last-tested stamps)
- Verify file integrity (SHA-256 hashes, modification detection)
- Generate pre-test blockers (CRITICAL/HIGH violations block pipeline)
- Output: config/dynamic-manifest.json + history snapshots

**Integration**: Runs in Run-FullPipeline.ps1 steps 3.1–3.2 (between manifest build and tests)

### 2.2 Workspace Integrity Manager (NEW)
**Files**: scripts/Invoke-WorkspaceIntegrityCheck.ps1

**Capabilities**:
- Full workspace material validation in audit/remediate/strict modes
- Version tag alignment across all files
- File hash integrity verification
- Dependency validation (orphan detection)
- SIN pattern compliance reporting
- Test coverage analysis
- Output: logs/workspace-integrity-<timestamp>.json

**Modes**:
- `audit`: read-only report
- `remediate`: attempt to fix issues (add missing VersionTags, convert encodings)
- `strict`: fail exit code if any issues found (CI integration)

### 2.3 P006 Encoding Remediation (NEW)
**Files**: scripts/Fix-P006-EncodingViolations.ps1

**Capabilities**:
- Batch scan for Unicode content without UTF-8 BOM
- Convert all affected files to UTF-8 with BOM encoding
- Generate remediation summary (fixed, failed, skipped counts)
- Standalone or integrated into repair workflows

### 2.4 Bitwarden Vault Integration (NEW)
**Files**: modules/ConvoVault-BWcli.psm1

**Capabilities**:
- Test BW CLI availability and version
- Authenticate with Bitwarden (email + password)
- Unlock vault for automated secret access
- Retrieve secrets by ID or search term
- Store secrets with metadata tagging
- Lock vault after operations
- Audit logging for all vault operations (DPAPI protected)

**Functions**:
- `Test-BwCliAvailable` — check BW CLI setup
- `Unlock-BitwokenVault` — authenticate + unlock vault
- `Get-BitwokenSecret` — retrieve secret by ID/search
- `Set-BitwokenSecret` — store secret with tags
- `Lock-BitwokenVault` — lock vault + clear session

## 3) Skills Matrix (Agent to Task Mapping)

| Task | Skill | Tool/Script | Status |
|------|-------|-------------|--------|
| Generate manifest | Code analysis + manifest generation | Build-DynaManifest.ps1 | ✓ READY |
| Validate drift guards | Code analysis + quality gates | Invoke-DynaManifestValidation.ps1 | ✓ READY |
| Fix encoding violations | File manipulation + remediation | Fix-P006-EncodingViolations.ps1 | ✓ READY |
| Check workspace integrity | Multi-section audit | Invoke-WorkspaceIntegrityCheck.ps1 | ✓ READY |
| Unlock vault for CI | Security + credential management | ConvoVault-BWcli.psm1 | ✓ READY |
| Run dual-engine smoke tests | Testing orchestration + UI automation | tests/Invoke-GUISmokeTest.ps1 | ✓ READY |
| Execute Pester + sandbox tests | Test orchestration + Windows Sandbox | tests/Run-AllTests.ps1, Invoke-SandboxSmokeTest.ps1 | ✓ READY |
| Analyze function coverage | Code analysis + manifest inspection | Build-AgenticManifest.ps1 | ✓ READY |
| Detect SIN violations | Code scanning + pattern matching | scripts/Invoke-SINPatternScanner.ps1 | ✓ READY |
| Generate release notes | Changelog + version tracking | scripts/Sync-ChangelogViewerData.ps1 | ✓ READY |
| Orchestrate full pipeline | Multi-stage gate sequencing | scripts/Run-FullPipeline.ps1 | ✓ READY |

## 4) Workspace Conventions & Assumptions

### 4.1 File Organization
```
c:\PowerShellGUI\
├── modules/           → PowerShell modules (.psm1 + .psd1)
├── scripts/           → Standalone scripts (.ps1)
├── tests/             → Pester tests + smoke tests (.Tests.ps1)
├── config/            → Configuration files + manifests (.json)
├── pki/               → PKI certificates + keys (.pem)
├── logs/              → Runtime logs + reports (.log, .json)
├── ~README.md/        → Documentation + guides (.md)
├── agents/            → Agent instruction files + tools
├── .github/           → GitHub workflows + agent instructions
└── tools/             → Utility scripts + helpers
```

### 4.2 Version Tag Format
**Canonical**: `YYMM.B<build>.V<major>.<minor>`
- Example: `2607.B1.V52.0`
- YYMM = year-month (26 = 2026, 07 = July)
- B<build> = build number (B1, B2, ...)
- V<major>.<minor> = semantic version

### 4.3 Encoding Standards
- **PowerShell files**: UTF-8 WITH BOM (required for PS 5.1 + Unicode)
- **JSON/YAML**: UTF-8 (BOM optional for these formats)
- **Text logs**: UTF-8 (configurable)
- **Validation**: scripts/Fix-P006-EncodingViolations.ps1

### 4.4 Logging Standards
- **AppLog**: modules/PwShGUI-AiActionLog.psm1 (Write-AppLog)
- **CronLog**: modules/CronAiAthon-EventLog.psm1 (Write-CronLog)
- **ProcessBanner**: modules/PwShGUI-Core.psm1 (Write-ProcessBanner)
- **Severity**: Emergency, Alert, Critical, Error, Warning, Notice, Informational, Debug
- **Output**: logs/<category>-<date>.log (daily rotation)

### 4.5 AI Action Logging
- **Start**: `Write-AiActionStart -Operation "<desc>" -Target "<scope>"`
- **Finish**: `Write-AiActionFinish -Status "success|failed" -TouchedFiles @(...)`
- **Logging**: logs/ai-actions/live/*.jsonl (canonical)
- **Reports**: ~REPORTS/ai-actions/ai-actions-summary.json (auto-generated)

## 5) Prerequisite Checks (Agent Pre-Flight)

Before executing any workspace modification task, verify:

✓ **PowerShell Version**: PS 5.1 or higher (PS 7.6+ preferred)
✓ **Module Load Path**: $PSModulePath includes modules/ directory
✓ **Manifest Files**: config/agentic-manifest.json + config/dynamic-manifest.json exist
✓ **Test Framework**: Pester 5.0+ available (or -AutoInstallPester)
✓ **Encoding**: All source files UTF-8 with BOM (checked by Invoke-WorkspaceIntegrityCheck.ps1)
✓ **SIN Compliance**: No blocking patterns (P001-P033) in modified files
✓ **Version Tags**: All scripts/modules include VersionTag header
✓ **Vault Access**: BW CLI available if secrets needed (optional for most tasks)

## 6) Error Handling & Fallback Strategies

| Scenario | Fallback |
|----------|----------|
| Manifest missing | Regenerate via Build-DynaManifest.ps1 |
| Encoding violation detected | Fix via Fix-P006-EncodingViolations.ps1 |
| Version tag missing | Remediate via Invoke-WorkspaceIntegrityCheck.ps1 -Mode remediate |
| Test fails on PS5 only | Check logs\ps5-last-tested.json for 24h gate condition |
| SIN violation blocks pipeline | Review finding, add exemption to sin_registry/, or fix source |
| Vault unlock fails | Fall back to interactive prompt or skip secrets (if non-essential) |
| Encoding write fails | Retry with -Force flag or check disk permissions |

## 7) Agent Instruction Integration Points

### 7.1 KpeAgentInstructs.instructions.md
- Primary workspace engineering methodology (SOV-Sys-zero framework)
- Quality gates (build, correctness, security, reliability, observability, integration)
- Operating model (discover, design, implement, verify, release, reflect)
- Feature tagging (feature:core, feature:security, etc.)

### 7.2 Sin-Ai-Voidance.instructions.md
- PS7.6-first with PS5.1 fallback rules
- Dual-engine test requirements
- SIN blocking patterns (P001-P033) with exemption workflow
- AI action logging contract

### 7.3 Agent Skills Manifest (THIS FILE)
- Consolidated tool listing + capabilities
- Skills matrix (task → tool mapping)
- Workspace conventions + assumptions
- Prerequisite checks for agent pre-flight
- Error handling + fallback strategies

## 8) Known Limitations & Future Work

| Area | Current | Limitation | Planned |
|------|---------|-----------|---------|
| Dependency graph | Basic imports only | No function-call tracing | v52.1: Full call graph analysis |
| Subfunction tracking | Not implemented | Can't map internal functions | v52.2: AST-based subfunction registry |
| File/folder ACLs | Basic checks only | No permission enforcement | v53.0: Full security envelope validation |
| Agentic routing | Manual mapping | No automatic action→handler | v53.0: Dynamic routing + function dispatch |
| Test coverage | Basic counting | No branch/line coverage | v53.1: Code coverage integration |
| Performance optimization | Single-threaded | Slow on large codebases | v53.2: Parallel scanning + caching |

## 9) Support & Troubleshooting

- **DynaManifest issues**: See [DYNA-MANIFEST-INTEGRATION.md](../~README.md/DYNA-MANIFEST-INTEGRATION.md)
- **Encoding problems**: Run `Fix-P006-EncodingViolations.ps1` + verify with `file <path>` command
- **Test failures**: Check `logs/ps5-last-tested.json` for 24h gate, verify both engines installed
- **SIN violations**: Review `sin_registry/*.json` for patterns + exemptions
- **Vault access**: Ensure `bw.exe` installed + `$env:BW_SERVER` set correctly

## 10) References

- [KpeAgentInstructs.instructions.md](../.github/instructions/KpeAgentInstructs.instructions.md)
- [Sin-Ai-Voidance.instructions.md](../.github/instructions/Sin-Ai-Voidance.instructions.md)
- [DYNA-MANIFEST-INTEGRATION.md](../~README.md/DYNA-MANIFEST-INTEGRATION.md)
- [SIN Governance](../~README.md/DOC-ICON-STANDARD.md)
- [Full Pipeline](../scripts/Run-FullPipeline.ps1)
