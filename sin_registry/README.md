# SIN Registry — README

> **VersionTag:** 2604.B2.V31.0  
> **Updated:** 2026-04-05  
> **Format:** v2-timestamped

---

## Overview

The SIN (Software Integrity Notice) Registry is the governance backbone for code quality,
security, and PS 5.1 compatibility enforcement in PowerShellGUI. It contains:

- **SIN-PATTERN definitions** — 24 blocking anti-patterns (P001–P024)
- **SEMI-SIN definitions** — 7 advisory penance warnings (SS-001–SS-007)
- **SIN instance records** — Auto-generated detections linked to parent patterns
- **Remedy fixes** — Recorded successful fixes in `fixes/` for systematic reuse

---

## File Naming Convention (v2)

All pattern and advisory definition files use the **v2-timestamped** format:

```
SIN-PATTERN-NNN-DESCRIPTIVE-NAME_yyyyMMddhhmm.json
SEMI-SIN-NNN-DESCRIPTIVE-NAME_yyyyMMddhhmm.json
```

| Component | Description |
|-----------|-------------|
| `SIN-PATTERN-` / `SEMI-SIN-` | Prefix identifying the class |
| `NNN` | 3-digit sequential number (001–999) |
| `DESCRIPTIVE-NAME` | UPPER-KEBAB-CASE short name |
| `_yyyyMMddhhmm` | Creation/reindex timestamp suffix |
| `.json` | All definitions are JSON |

**Instance records** use: `SIN-YYYYMMDD-<8char-hash>.json` or `SIN-YYYYMMDDHHMMSS-<hash>.json`

**Fix records** use: `FIX-yyyyMMddhhmm-<random>.json` in the `fixes/` directory

---

## Remedy Tracking Schema

Every SIN definition and instance now includes a `remedy_tracking` object:

```json
{
  "remedy_tracking": {
    "attempts": [
      {
        "attempt_number": 1,
        "timestamp": "2026-04-04T22:57:00.000Z",
        "method": "external-fix-detected",
        "success": true,
        "notes": "Finding no longer detected at original location."
      }
    ],
    "last_attempt_at": "2026-04-04T22:57:00.000Z",
    "total_attempts": 1,
    "successful_count": 1,
    "failed_count": 0,
    "status": "RESOLVED",
    "auto_retry": false
  }
}
```

### Remedy Status Values

| Status | Description |
|--------|-------------|
| `PENDING` | No remedy attempted yet |
| `RETRY` | Previous attempt failed, will retry on next cycle |
| `RESOLVED` | Finding confirmed fixed after remedy |
| `ESCALATED` | Max retries (default 3) exhausted, needs manual review |

---

## Files in This Directory

### Pattern Definitions (24 Blocking)

| # | File Pattern | Title | Severity |
|---|-------------|-------|----------|
| P001 | `SIN-PATTERN-001-HARDCODED-CREDENTIALS_*.json` | No hardcoded credentials | CRITICAL |
| P002 | `SIN-PATTERN-002-EMPTYCATCH-SWALLOW_*.json` | No empty catch blocks | HIGH |
| P003 | `SIN-PATTERN-003-SILENTCONTINUE-IMPORT_*.json` | No SilentlyContinue on Import-Module | HIGH |
| P004 | `SIN-PATTERN-004-DOTCOUNT-WITHOUT-ARRAY_*.json` | Always `@()` before `.Count` | HIGH |
| P005 | `SIN-PATTERN-005-PS7ONLY-OPERATORS_*.json` | No PS7-only operators | HIGH |
| P006 | `SIN-PATTERN-006-UTF8-NOBOM-UNICODE_*.json` | UTF-8 BOM for Unicode files | HIGH |
| P007 | `SIN-PATTERN-007-VERSIONTAG-STALE_*.json` | Include VersionTag header | MEDIUM |
| P008 | `SIN-PATTERN-008-ADDTYPE-MISSING-ASSEMBLY_*.json` | Conditional Add-Type assemblies | HIGH |
| P009 | `SIN-PATTERN-009-UNVALIDATED-PATH-JOIN_*.json` | Validate paths before Join-Path | MEDIUM |
| P010 | `SIN-PATTERN-010-IEX-DYNAMIC-STRING_*.json` | No Invoke-Expression | CRITICAL |
| P011 | `SIN-PATTERN-011-DUPLICATE-FUNCTION-DEF_*.json` | No duplicate function names | MEDIUM |
| P012 | `SIN-PATTERN-012-SETCONTENT-NO-ENCODING_*.json` | `-Encoding UTF8` on Set-Content | HIGH |
| P013 | `SIN-PATTERN-013-FILESIZEBLOWOUT_*.json` | Scripts under 5MB | HIGH |
| P014 | `SIN-PATTERN-014-CONVERTJSON-NO-DEPTH_*.json` | `-Depth` on ConvertTo-Json | MEDIUM |
| P015 | `SIN-PATTERN-015-HARDCODED-ABSOLUTE-PATH_*.json` | No hardcoded absolute paths | HIGH |
| P016 | `SIN-PATTERN-016-TODO-FIXME-STALE_*.json` | No stale TODO/FIXME/HACK | MEDIUM |
| P017 | `SIN-PATTERN-017-OUTFILE-NO-ENCODING_*.json` | `-Encoding` on Out-File | MEDIUM |
| P018 | `SIN-PATTERN-018-JOINPATH-3PLUS-ARGS_*.json` | Join-Path max 2 args | HIGH |
| P019 | `SIN-PATTERN-019-ADDCONTENT-NO-ENCODING_*.json` | `-Encoding` on Add-Content | MEDIUM |
| P020 | `SIN-PATTERN-020-SSL-CERT-BYPASS_*.json` | No SSL cert bypass | CRITICAL |
| P021 | `SIN-PATTERN-021-DIVZERO-UNGUARDED_*.json` | Guard division for zero | HIGH |
| P022 | `SIN-PATTERN-022-NULL-METHOD-CALL_*.json` | Null guard before method calls | HIGH |
| P023 | `SIN-PATTERN-023-DOUBLE-ENCODED-UTF8_*.json` | No double-encoded UTF-8 (mojibake C3 A2 E2 80) | CRITICAL |
| P024 | `SIN-PATTERN-024-STRICTMODE-SHOWDIALOG-BLEED_*.json` | StrictMode scope bleed via ShowDialog | HIGH |

### Advisory Definitions (7 Penance)

| # | File Pattern | Title |
|---|-------------|-------|
| SS-001 | `SEMI-SIN-001-SIZE-GROWTH-51PCT_*.json` | File size grew >51% |
| SS-002 | `SEMI-SIN-002-FILE-OUTSIDE-WORKSPACE_*.json` | File outside workspace |
| SS-003 | `SEMI-SIN-003-WRITEHOST-IN-MODULE_*.json` | Write-Host in modules |
| SS-004 | `SEMI-SIN-004-STARTSLEEP-UI-BLOCKING_*.json` | Start-Sleep blocking UI |
| SS-005 | `SEMI-SIN-005-MISSING-CMDLETBINDING_*.json` | Missing [CmdletBinding()] |
| SS-006 | `SEMI-SIN-006-ADDCONTENT-NO-ENCODING_*.json` | Add-Content no encoding |
| SS-007 | `SEMI-SIN-007-COMPLIANCE-BACKUP-SCOPE-DRIFT_*.json` | Compliance/backup drift |

### Subdirectories

| Directory | Purpose |
|-----------|---------|
| `fixes/` | Recorded remedy fixes (FIX-*.json) for systematic reuse |

### Special Files

| File | Purpose |
|------|---------|
| `REINDEX-MAP.json` | Old-to-new filename mapping from last reindex |

---

## Pipeline Integration

The SIN governance pipeline runs in this order:

1. **Step 3.5: SIN Pattern Scan** — `tests/Invoke-SINPatternScanner.ps1`
   - Loads all `SIN-PATTERN-*.json` definitions (v2 format with timestamps)
   - Scans workspace for pattern matches
   - Auto-registers new SIN instances with `-AutoRegister`
   - New instances include `remedy_tracking` with status `PENDING`

2. **Step 3.6: SIN Remedy Engine** — `scripts/Invoke-SINRemedyEngine.ps1`
   - Loads pending SIN instances (status = PENDING or RETRY)
   - Rescans to check if findings are still present
   - Attempts known fixes from `fixes/` catalogue
   - Records each attempt in `remedy_tracking.attempts[]`
   - On success: saves fix to `fixes/` for reuse, marks RESOLVED
   - On failure: marks RETRY (up to 3 attempts) then ESCALATED

3. **Weekly: SIN Pattern Scanner** — Full baseline scan (cron Monday)

4. **Post-test: SemiSin Penance Scanner** — `tests/Invoke-SemiSinPenanceScanner.ps1`
   - Advisory warnings only, never blocks pipeline

---

## Creating New SIN Patterns

When adding a new SIN-PATTERN:

```powershell
# Compute the next number
$existing = Get-ChildItem sin_registry -Filter 'SIN-PATTERN-*.json' |
    ForEach-Object { if ($_.BaseName -match 'SIN-PATTERN-(\d{3})') { [int]$Matches[1] } } |
    Sort-Object -Descending | Select-Object -First 1
$nextNum = '{0:D3}' -f ($existing + 1)
$ts = Get-Date -Format 'yyyyMMddHHmm'
$fileName = "SIN-PATTERN-${nextNum}-YOUR-NAME_${ts}.json"
```

Required JSON fields:
- `sin_id` — must match filename (without `.json`)
- `title`, `description`, `severity` (CRITICAL/HIGH/MEDIUM)
- `category`, `scan_regex`, `scan_file_pattern`
- `remedy`, `preventionRule`
- `remedy_tracking` — use default PENDING object (see schema above)

---

## Tools

| Script | Purpose |
|--------|---------|
| `scripts/Invoke-SINRegistryReindex.ps1` | Reindex/rename files to v2 timestamped format |
| `scripts/Invoke-SINRemedyEngine.ps1` | Iterative remedy-scan-retry engine |
| `tests/Invoke-SINPatternScanner.ps1` | Full blocking SIN pattern scanner |
| `tests/Invoke-SemiSinPenanceScanner.ps1` | Advisory penance scanner |
| `modules/SINGovernance.psm1` | Review, approval, SINeProofed workflow |
