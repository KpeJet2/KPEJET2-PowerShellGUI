<!-- markdownlint-disable -->

# Code Standards Application Strategy v1.0
**Target Date**: 2026-04-30  
**Schema Version**: `ApplicationStrategy/1.0`  
**Scope**: Apply CODE-STANDARDS-v1.0 across all existing modules, scripts, and configs

---

## Executive Summary

**Goal**: Retrofit the entire PowerShell GUI codebase with:
1. ✅ VersionTag headers (with schema version support)
2. ✅ FileRole declarations
3. ✅ Error → Bugs2FIX linking
4. ✅ Unified schema tracking
5. ✅ Cross-platform compatibility markers

**Phased Approach**: 3 phases over 2 weeks  
**Risk Level**: Low (changes are additive, non-breaking)  
**Automation**: 80% via PowerShell scripts, 20% manual review

---

## Phase 1: Assessment & Inventory (Days 1-2)

### 1.1 Scan Current State

```powershell
# Script: scripts/Invoke-CodeStandardsAssessment.ps1
$assessment = @{
    modulesWithoutVersionTag = @()
    modulesWithoutFileRole = @()
    modulesWithoutSchemaVersion = @()
    scriptsWithoutErrorHandling = @()
    configsWithoutSchemaField = @()
    xhtmlToolsWithoutVersionTag = @()
}

# Detect gaps across all files
Get-ChildItem 'modules' -Filter '*.psm1' | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    if ($content -notmatch '# VersionTag:') { 
        $assessment.modulesWithoutVersionTag += $_.Name 
    }
    if ($content -notmatch '# FileRole:') { 
        $assessment.modulesWithoutFileRole += $_.Name 
    }
    if ($content -notmatch '# SchemaVersion:') { 
        $assessment.modulesWithoutSchemaVersion += $_.Name 
    }
}

# Report and create Items2Do for gaps
$assessment | ConvertTo-Json | Tee-Object 'reports/standards-assessment.json'
```

### 1.2 Create Inventory Items2Do

For each category of missing standards, create tracking items:

```powershell
$gaps = @(
    @{ category = 'VersionTag'; count = 8; priority = 'HIGH' },
    @{ category = 'FileRole'; count = 5; priority = 'MEDIUM' },
    @{ category = 'SchemaVersion'; count = 12; priority = 'MEDIUM' },
    @{ category = 'ErrorHandling'; count = 15; priority = 'HIGH' }
)

foreach ($gap in $gaps) {
    $item = New-PipelineItem -Type 'Items2ADD' `
        -Title "Add $($gap.category) to $($gap.count) files" `
        -Description "Retrofit $($gap.category) headers to meet CODE-STANDARDS-v1.0" `
        -Priority $gap.priority `
        -Source 'CodeAudit' `
        -Category 'standards-compliance'
    
    Add-PipelineItem -WorkspacePath 'C:\PowerShellGUI' -Item $item
}
```

### 1.3 Document Target State

Create reference showing "before" and "after":

```
BEFORE:
# Some module
Set-StrictMode -Version Latest
function Get-Something { ... }

AFTER:
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-27)
# SupportsPS7.6: YES(As of: 2026-04-27)
# FileRole: Module
# SchemaVersion: ModuleName/1.0
# Author: The Establishment
# Date: 2026-04-27
#Requires -Version 5.1

Set-StrictMode -Version Latest
function Get-Something { ... }
```

---

## Phase 2: Apply Standards to Core Modules (Days 3-5)

### 2.1 Priority-Order Modules

**Tier 1** (Critical — apply first):
- `CronAiAthon-Pipeline.psm1` — Already has VersionTag; add FileRole + SchemaVersion
- `CronAiAthon-BugTracker.psm1` — Add missing headers
- `CronAiAthon-EventLog.psm1` — Add missing headers
- `PwShGUI-SchemaTranslator.psm1` — Already compliant, verify

**Tier 2** (High priority):
- `PwShGUI-VersionManager.psm1`
- `PwShGUI-VersionTag.psm1`
- `PwShGUI-IntegrityCore.psm1`
- `AssistedSASC.psm1`

**Tier 3** (Medium priority):
- All remaining modules (15+)

### 2.2 Apply Headers Script

Create and run: `scripts/Apply-CodeStandardsHeaders.ps1`

```powershell
# Pseudo-code for automated header application

function Add-StandardsHeader {
    param([string]$FilePath, [string]$FileRole = 'Module')
    
    $content = Get-Content $FilePath -Raw
    if ($content -match '# VersionTag:') {
        Write-Host "✓ $FilePath already has VersionTag, skipping"
        return
    }
    
    $header = @(
        "# VersionTag: 2605.B5.V46.0"
        "# SupportPS5.1: null"
        "# SupportsPS7.6: null"
        "# SupportPS5.1TestedDate: 2026-04-27"
        "# SupportsPS7.6TestedDate: 2026-04-27"
        "# FileRole: $FileRole"
        "# SchemaVersion: ModuleName/1.0"
        "# Author: The Establishment"
        "# Date: 2026-04-27"
        "#Requires -Version 5.1"
        ""
    ) -join "`n"
    
    $newContent = $header + $content
    $newContent | Set-Content $FilePath -Encoding UTF8
    
    Write-Host "✓ Updated: $FilePath" -ForegroundColor Green
}

# Apply to all modules in priority order
$modules = @(
    'modules/CronAiAthon-Pipeline.psm1',
    'modules/CronAiAthon-BugTracker.psm1',
    'modules/CronAiAthon-EventLog.psm1'
    # ... more
)

foreach ($module in $modules) {
    Add-StandardsHeader -FilePath $module -FileRole 'Module'
}
```

### 2.3 Manual Review Checkpoints

For each Tier 1 module:
1. ✅ Header added
2. ✅ VersionTag format correct
3. ✅ FileRole accurate
4. ✅ Schema version identified
5. ✅ Outline/Problems/Todo comments present
6. ✅ Functions exported properly
7. ✅ Test import: `Import-Module -FullyQualifiedName $modulePath -Force`

---

## Phase 3: Add Error Linking & Config Updates (Days 6-10)

### 3.1 Update Core Error-Handling Functions

For each module with error handling, wrap in error-linking:

```powershell
# BEFORE
function Invoke-Action {
    param([string]$Input)
    try {
        # ... logic ...
    } catch {
        Write-Host "ERROR: $_"
        throw
    }
}

# AFTER (using CronAiAthon-ErrorLinker)
function Invoke-Action {
    param([string]$Input)
    try {
        # ... logic ...
    } catch {
        $workspacePath = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $linkResult = Add-ErrorToPipeline -Exception $_ `
            -FunctionName 'Invoke-Action' `
            -WorkspacePath $workspacePath `
            -AffectedFiles @($Input) `
            -ErrorSource 'RuntimeError'
        
        Write-AppLog -Message "Error linked to Bug: $($linkResult.BugId)" -Level Error
        throw
    }
}
```

**Target Functions** (High-impact):
- `Invoke-*` functions (50+ across codebase)
- `Get-*` functions that validate input (20+)
- Pipeline module functions (15+)
- Schema translator functions (8+)

### 3.2 Update Config Files with Schema Declarations

**Pattern**: Add `$schema` and `schemaVersion` to all JSON configs

```powershell
# Script: scripts/Add-SchemaFieldsToConfigs.ps1

$configs = Get-ChildItem 'config' -Filter '*.json'
foreach ($config in $configs) {
    $json = Get-Content $config.FullName | ConvertFrom-Json
    
    # Add schema fields if missing
    if (-not $json.'$schema') {
        $json | Add-Member -Type NoteProperty -Name '$schema' `
            -Value "PwShGUI-$($config.BaseName)/1.0" -Force
    }
    
    if (-not $json.schemaVersion) {
        $json | Add-Member -Type NoteProperty -Name 'schemaVersion' `
            -Value "PwShGUI-$($config.BaseName)/1.0" -Force
    }
    
    $json | ConvertTo-Json -Depth 10 | Set-Content $config.FullName -Encoding UTF8
    Write-Host "✓ Updated: $($config.Name)" -ForegroundColor Green
}
```

### 3.3 XHTML Tools Version Tag Check

**Script**: `scripts/Update-XhtmlVersionTags.ps1`

```powershell
$xhtmlFiles = Get-ChildItem -Recurse -Filter '*.xhtml'
foreach ($file in $xhtmlFiles) {
    $content = Get-Content $file.FullName -Raw
    
    if ($content -notmatch '<!-- VersionTag:') {
        $newHeader = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n" +
                     "<!-- VersionTag: 2605.B5.V46.0 -->`n" +
                     "<!-- FileRole: XhtmlTool -->`n"
        $content = $newHeader + $content
        $content | Set-Content $file.FullName -Encoding UTF8
        Write-Host "✓ Updated: $($file.Name)" -ForegroundColor Green
    }
}
```

### 3.4 Verify & Test All Changes

```powershell
# Test Import: All modules load without errors
Get-ChildItem 'modules' -Filter '*.psm1' | ForEach-Object {
    try {
        Import-Module $_.FullName -Force -ErrorAction Stop
        Write-Host "✓ Import OK: $($_.BaseName)" -ForegroundColor Green
    } catch {
        Write-Host "✗ Import FAILED: $($_.BaseName) - $_" -ForegroundColor Red
    }
}

# Validate JSON Schemas
Get-ChildItem 'config' -Filter '*.json' | ForEach-Object {
    $json = Get-Content $_.FullName | ConvertFrom-Json
    if (-not $json.'$schema' -or -not $json.schemaVersion) {
        Write-Host "⚠ Schema fields missing: $($_.Name)" -ForegroundColor Yellow
    } else {
        Write-Host "✓ Schema OK: $($_.Name)" -ForegroundColor Green
    }
}

# Parse check: All PowerShell files
Get-ChildItem -Recurse -Filter '*.ps1', '*.psm1' | ForEach-Object {
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
    if ($errors) {
        Write-Host "✗ Parse error: $($_.Name)" -ForegroundColor Red
    }
}
```

---

## Phase 4: Documentation & Cleanup (Days 11-14)

### 4.1 Generate Compliance Report

```powershell
$report = @{
    timestamp = Get-Date -Format 'o'
    standardsVersion = 'CODE-STANDARDS-v1.0'
    complianceMetrics = @{
        modulesCompliant = 0
        scriptsCompliant = 0
        configsCompliant = 0
        xhtmlToolsCompliant = 0
    }
}

# Scan and count compliant files...

$report | ConvertTo-Json | Tee-Object 'reports/compliance-report-2026-04-30.json'
```

### 4.2 Update README Files

Add to `~README.md/CODE-STANDARDS-COMPLIANCE.md`:

```markdown
# Code Standards Compliance Report
Generated: 2026-04-27

## Summary
- Modules: 25/25 compliant ✅
- Scripts: 42/50 compliant (8 pending)
- Configs: 15/15 compliant ✅
- XHTML Tools: 6/6 compliant ✅

## Non-Compliant Items (In Progress)
- scripts/Script-A.ps1 (pending review)
- scripts/Script-B.ps1 (pending review)
- ...

## Standards Applied
- [x] VersionTag headers
- [x] FileRole declarations
- [x] SchemaVersion tracking
- [x] Error → Bugs2FIX linking
- [x] Cross-platform markers
- [x] Outline/Problems/Todo comments
```

### 4.3 Create Migration Checklist

Store in `todo/standards-migration-checklist.json`:

```json
{
  "id": "StandardsMigration-2026-04",
  "type": "ToDo",
  "title": "Apply CODE-STANDARDS-v1.0 Across Codebase",
  "status": "IN_PROGRESS",
  "subtasks": [
    { "title": "Phase 1: Assessment", "status": "DONE" },
    { "title": "Phase 2: Core Modules", "status": "IN_PROGRESS" },
    { "title": "Phase 3: Error Linking", "status": "NOT_STARTED" },
    { "title": "Phase 4: Documentation", "status": "NOT_STARTED" }
  ]
}
```

---

## Rollout Schedule

| Week | Phase | Activity | Owner |
|------|-------|----------|-------|
| Apr 29-30 | 1 | Assessment & Gap Analysis | PwShGUI Team |
| May 1-3 | 2 | Core Modules (Tier 1) | Code Review Board |
| May 4-7 | 2 | Core Modules (Tier 2+3) | Distributed |
| May 8-10 | 3 | Error Linking & Config Updates | Code Review Board |
| May 11-14 | 4 | Testing, Docs, Cleanup | PwShGUI Team |
| May 15+ | — | **Full Compliance** ✅ | — |

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Breaking existing code | Changes are additive only; no behavior change |
| Parse errors introduced | Parse-check all files before commit |
| Schema misalignment | Use schema-transforms.json for auto-migration |
| Incomplete migration | Create Items2Do for remaining tasks |
| Version conflicts | Use VersionTag format uniformly |

---

## Success Criteria

✅ All modules have valid VersionTag headers  
✅ All modules/scripts/configs have FileRole declared  
✅ All configs have $schema + schemaVersion fields  
✅ Error handling includes try/catch + Bugs2FIX linking  
✅ Cross-platform support markers accurate  
✅ Parse checks pass for all files  
✅ Compliance report generated and shared  
✅ No regressions in CI/CD pipeline

---

## Reference Files

- `config/CODE-STANDARDS-v1.0.md` — Full standards guide
- `config/schema-transforms.json` — Automated migrations
- `config/ITEMS2DO-GUIDE.md` — Schema change procedures
- `modules/CronAiAthon-ErrorLinker.psm1` — Error → Bug/Bugs2FIX linking
- `XHTML-PipelineManager.xhtml` — Pipeline visualization tool

---

**Approval**: PwShGUI Project Leadership  
**Effective Date**: 2026-04-27  
**Next Review**: 2026-05-31


