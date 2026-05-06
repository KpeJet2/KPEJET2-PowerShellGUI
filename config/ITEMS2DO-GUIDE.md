<!-- markdownlint-disable -->

# Items2Do (Schema Migration & Compatibility Guide)
**Version**: 1.0  
**Last Updated**: 2026-04-27  
**Schema Version**: `Items2Do/1.0`  
**FileRole**: Guide

---

## Overview

**Items2Do** are special **Items2ADD** pipeline items that notify administrators and developers when:
1. **Schema versions break compatibility** (data format changes)
2. **Manual migration required** (scripts cannot auto-migrate)
3. **Configuration updates needed** (new required fields)
4. **Deprecated functions will be removed** (sunset notices)

**Purpose**: Bridge the gap between automated schema transforms and human action requirements.

---

## When to Create Items2Do

### Scenario 1: Breaking Schema Change (Cannot Auto-Migrate)
```
Example: Pipeline item field "affectedFiles" changes from string[] to object[]
Auto-Migrate: No (structure fundamentally different)
Action: Admin must update all todo/*.json files using a provided script
Create: Items2Do with remediation script
```

### Scenario 2: New Required Configuration
```
Example: New XHTML tools require CSS variable entry
Auto-Migrate: Partial (can add defaults, but may need tuning)
Action: Admin may need to customize colors per tool
Create: Items2Do with "optional action" flag
```

### Scenario 3: Deprecation Notice
```
Example: Function "Get-OldConfigFormat" will be removed in v2.0
Auto-Migrate: No (requires finding all usages)
Action: Developers must update code references
Create: Items2Do with deadline and migration guide
```

### Scenario 4: Cross-Version Incompatibility
```
Example: PowerShell 5.1 compatibility layer being removed
Auto-Migrate: No (different runtime)
Action: Users on PS 5.1 must upgrade or stay on older branch
Create: Items2Do with support matrix
```

---

## Schema

### Items2Do Pipeline Item Structure

```json
{
  "id": "Items2Do-YYYYMMDDHHmmss-xxxx",
  "type": "Items2ADD",
  "title": "BREAKING: Schema change — {FeatureName} — action required",
  "description": "User-friendly explanation of what changed and why",
  "category": "schema-migration|deprecation|configuration|upgrade",
  "priority": "CRITICAL|HIGH|MEDIUM",
  "status": "OPEN|PLANNED|IN_PROGRESS|DONE",
  "source": "SchemaMigration|Deprecation|ConfigChange",
  "suggestedBy": "SchemaValidator|DeprecationNotice|ConfigAudit",
  "created": "ISO8601",
  "modified": "ISO8601",
  
  "items2do_metadata": {
    "actionRequired": true|false,
    "affectedVersions": ["2604.B0+", "2605.*"],
    "targetDeadline": "ISO8601 or null for no deadline",
    "migrationScript": "scripts/Invoke-SchemaMigration.ps1 -Target v2",
    "backupRecommended": true|false,
    "rollbackPossible": true|false,
    "estimatedManualTime": "15 minutes",
    "documentationLink": "~README.md/SCHEMA-MIGRATION-v1-to-v2.md",
    "supportTier": "admin|developer|all"
  }
}
```

---

## Implementation Guide

### Step 1: Identify Breaking Change

When planning a schema version bump:

```powershell
$break = @{
    oldSchema   = 'PipelineItem/1.0'
    newSchema   = 'PipelineItem/1.1'
    change      = 'affectedFiles: string[] → object[]'
    autoMigrate = $false
    impact      = 'All pipeline items in todo/*.json'
    estimate    = '30 minutes per 100 items'
}
```

### Step 2: Create Migration Script

Store in `scripts/Invoke-SchemaMigration-PipelineItem-1-0-to-1-1.ps1`

```powershell
# VersionTag: 2605.B2.V31.7
# FileRole: MigrationScript
# SchemaVersion: PipelineItemMigration/1.0
#Requires -Version 5.1

<#
.SYNOPSIS
    Migrate PipelineItem schema 1.0 → 1.1: affectedFiles restructuring
.PARAMETER SourcePath
    Path to todo/ directory containing .json files
.PARAMETER Backup
    Create backup before migration (default: $true)
#>

param(
    [Parameter(Mandatory)] [string]$SourcePath,
    [switch]$Force,
    [switch]$NoBackup
)

if (-not $NoBackup) {
    $backup = Join-Path (Split-Path $SourcePath) "backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item -Path $SourcePath -Destination $backup -Recurse -Force
    Write-Host "Backup created at: $backup" -ForegroundColor Green
}

$files = Get-ChildItem $SourcePath -Filter '*.json' -File
foreach ($file in $files) {
    $item = Get-Content $file -Raw | ConvertFrom-Json
    
    if ($item.schemaVersion -eq 'PipelineItem/1.0') {
        # Transform: affectedFiles from string[] to object[]
        $newAffectedFiles = @(
            $item.affectedFiles | ForEach-Object {
                @{
                    path       = $_
                    modified   = $false
                    fixesNeeded = @()
                }
            }
        )
        
        $item | Add-Member -MemberType NoteProperty -Name affectedFiles -Value $newAffectedFiles -Force
        $item | Add-Member -MemberType NoteProperty -Name schemaVersion -Value 'PipelineItem/1.1' -Force
        
        $item | ConvertTo-Json -Depth 10 | Set-Content $file -Encoding UTF8
        Write-Host "✓ Migrated: $($file.Name)" -ForegroundColor Green
    }
}

Write-Host "`nMigration complete!" -ForegroundColor Cyan
```

### Step 3: Create Items2Do Entry

```powershell
$item2do = @{
    type = 'Items2ADD'
    title = 'BREAKING SCHEMA CHANGE: PipelineItem 1.0 → 1.1 — affectedFiles restructuring'
    description = @"
The 'affectedFiles' field in pipeline items is changing from a simple string array to a structured object array.

WHAT CHANGED:
  Old: affectedFiles: ["C:\path\file1.ps1", "C:\path\file2.ps1"]
  New: affectedFiles: [{path: "...", modified: false, fixesNeeded: []}, ...]

WHY: Allows tracking which files have been fixed and what issues remain.

ACTION REQUIRED: Yes
  1. Back up your todo/ directory
  2. Run: scripts/Invoke-SchemaMigration-PipelineItem-1-0-to-1-1.ps1 -SourcePath 'todo'
  3. Test pipeline queries
  4. Verify no regressions

DEADLINE: 2026-05-31 (after this date, old format will error)
ROLLBACK: Possible until deadline. See rollback instructions.
TIME ESTIMATE: 15 minutes
"@
    priority = 'HIGH'
    source = 'SchemaMigration'
    category = 'schema-migration'
    
    items2do_metadata = @{
        actionRequired     = $true
        affectedVersions   = @('2604.B1+', '2605.*')
        targetDeadline     = '2026-05-31T23:59:59Z'
        migrationScript    = 'scripts/Invoke-SchemaMigration-PipelineItem-1-0-to-1-1.ps1'
        backupRecommended  = $true
        rollbackPossible   = $true
        estimatedManualTime = '15 minutes'
        documentationLink  = '~README.md/SCHEMA-CHANGES-v1-0-to-v1-1.md'
        supportTier        = 'admin'
    }
}

Add-PipelineItem -WorkspacePath $PSScriptRoot -Item $item2do
```

---

## Guidelines for Items2Do

### ✅ DO

- **Create Items2Do for breaking changes** that users must act on
- **Provide clear before/after examples**
- **Include migration scripts whenever possible**
- **Set realistic deadlines** (not before users have time to plan)
- **Document rollback procedures** if possible
- **Estimate time to completion** for planning
- **Link to full documentation** for detailed info

### ❌ DON'T

- **Hide breaking changes** — always create Items2Do
- **Provide only vague instructions** — be specific
- **Remove old code immediately** — deprecate first, then remove
- **Make Items2Do for every minor update** — use only for breaking changes
- **Set unrealistic deadlines** — consider admin workload

---

## Deprecation Lifecycle

### Phase 1: Announce (Release N)
Create Items2Do (actionRequired=false) notifying of upcoming change

```
DEPRECATION NOTICE: Function 'Get-OldFormat' deprecated.
Will be removed in v2.0 (estimated: 2026-09-30).
Use 'Get-NewFormat' instead.
```

### Phase 2: Warn (Release N+1)
Function still works but emits warnings

```powershell
Write-Warning "Get-OldFormat is deprecated. Use Get-NewFormat instead."
```

### Phase 3: Break (Release N+2)
Remove the function entirely (update Items2Do with deadline passed)

---

## Migration Workflow Example

### Scenario: Update CronAiAthon-Pipeline schema

**1. Identify Change**
```
OLD: Bug item with flat "affectedFiles": ["path1", "path2"]
NEW: Bug item with structured files: [{path, lineNumber, fixStatus}]
```

**2. Create Migration Script**
```
scripts/Invoke-PipelineItemSchemaMigration-1-0-to-1-1.ps1
```

**3. Create Items2Do**
```
pipeline item type: Items2ADD
title: "BREAKING: Bug schema change — affectedFiles structure update required"
priority: HIGH
actionRequired: true
deadline: 2026-05-31
```

**4. Add to Pipeline**
```powershell
$item2do = New-PipelineItem -Type 'Items2ADD' -Title "..." -Description "..." -Source 'SchemaMigration'
Add-PipelineItem -WorkspacePath 'C:\PowerShellGUI' -Item $item2do
```

**5. Announce in Changelog**
```
# Version 2605.B0 - BREAKING CHANGES
## PipelineItem Schema Update
- affectedFiles structure changed (see Items2Do entry for migration instructions)
- Migration script: scripts/Invoke-PipelineItemSchemaMigration-1-0-to-1-1.ps1
- Deadline: 2026-05-31
```

---

## Common Patterns

### Pattern 1: Field Structure Change
```
Old: field: string
New: field: object { subfield1, subfield2 }

Items2Do content: Explain transformation, provide examples, include migration script
```

### Pattern 2: Field Removal (Deprecated)
```
Old: field: value (deprecated)
New: field removed, use alternativeField instead

Items2Do content: Deprecation timeline, search/replace instructions
```

### Pattern 3: Required New Field
```
Old: field: (optional/missing)
New: field: required

Items2Do content: Default value info, validation requirements
```

### Pattern 4: Enum Value Change
```
Old: status: 'PENDING' | 'ACTIVE' | 'DONE'
New: status: 'OPEN' | 'PLANNED' | 'IN_PROGRESS' | 'DONE' | 'BLOCKED' | 'FAILED'

Items2Do content: Enum mapping table, migration rules
```

---

## Validation Checklist

Before releasing a breaking schema change:

- [ ] Created migration script and tested it
- [ ] Created Items2Do with actionRequired=true
- [ ] Set realistic deadline (≥30 days)
- [ ] Documented before/after examples
- [ ] Tested rollback procedure
- [ ] Updated CHANGELOG.md
- [ ] Notified admins (email, Teams, etc.)
- [ ] Added documentation link in Items2Do
- [ ] Estimated manual time per admin
- [ ] Provided schema transform config (if autoMigration possible)

---

## Reference

See related files:
- `config/schema-transforms.json` — Auto-migration transforms
- `modules/PwShGUI-SchemaTranslator.psm1` — Transform execution
- `modules/CronAiAthon-Pipeline.psm1` — Pipeline item management
- `config/CODE-STANDARDS-v1.0.md` — Overall standards


