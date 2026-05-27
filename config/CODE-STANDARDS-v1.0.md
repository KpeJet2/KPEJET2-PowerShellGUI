<!-- markdownlint-disable -->

# PwShGUI Code Standards v1.0
**Last Updated**: 2026-04-27  
**Schema Version**: `CodeStandards/1.0`  
**Version Tag Format**: `YYYY.Bx.VNn.n`

---

## 1. Module Structure & Metadata

### 1.1 Header Format (ALL PowerShell Modules & Scripts)
```powershell
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES|NO|null (As of: YYYY-MM-DD)
# SupportsPS7.6: YES|NO|null (As of: YYYY-MM-DD)
# SupportPS5.1TestedDate: YYYY-MM-DD
# SupportsPS7.6TestedDate: YYYY-MM-DD
# FileRole: Module|Script|Config|Tool
# SchemaVersion: [DOMAIN]/[VERSION]
# Author: The Establishment
# Date: YYYY-MM-DD
```

**Required Fields**:
- `VersionTag`: Tracks build and version incrementally
- `FileRole`: Identifies file purpose (Module, Script, Config, Tool)
- `SchemaVersion`: For configs, declares the schema this file adheres to

### 1.2 VersionTag Format
Format: `YYYY.Bx.VNn.n`
- `YYYY`: Year
- `B{x}`: Build sequence (B0=early, B2=mid-dev, B9=release candidate)
- `VN{n}`: Feature version number (V31, V32, V33)
- Final `.n`: Patch/revision

Example: `2604.B2.V32.3` = April 2026, Build 2, Version 32, Patch 3

---

## 2. Error Handling & Logging

### 2.1 Function-Level Error Logging
```powershell
function Invoke-Action {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$InputPath)
    
    try {
        # ... logic ...
    } catch {
        $bugId = "Bug-$(Get-Date -Format 'yyyyMMddHHmmss')-$(([guid]::NewGuid()).ToString().Substring(0,8))"
        Write-AppLog -Message "Action failed: $($_.Exception.Message)" -Level Error
        
        # Link to Bugs2FIX
        $bugItem = New-PipelineItem -Type 'Bug' `
            -Title "Error in Invoke-Action: $($_.Exception.Message)" `
            -Description "$($_.ScriptStackTrace)" `
            -Priority 'HIGH' `
            -Source 'RuntimeError' `
            -Category 'runtime' `
            -AffectedFiles @($InputPath) `
            -SuggestedBy 'ErrorHandler'
        
        $null = Add-PipelineItem -WorkspacePath $script:WorkspacePath -Item $bugItem
        throw "Invoke-Action failed: $_"
    }
}
```

### 2.2 Pipeline Error Auto-Linking
When any pipeline agent step, task, or engine reports an error:
1. Capture: step name, error message, timestamp, affected files/modules
2. Create: Bug item with `source='PipelineError'`
3. Create: Bugs2FIX item as child of Bug
4. Log: Entry in event log with SYSLOG level 3 (Error)
5. Event format: `"Pipeline[{agent}].{step} FAILED: {error} -> BugId: {bugId}"`

---

## 3. Schema Versioning & Compatibility

### 3.1 Schema Declaration in Config Files
```json
{
  "$schema": "DomainName-ConfigType/VERSION",
  "schemaVersion": "DomainName-ConfigType/VERSION",
  "meta": {
    "description": "Human-readable purpose",
    "generated": "2026-04-27T00:00:00Z",
    "generator": "scripts/Generate-Config.ps1",
    "minCompatibleSchema": "DomainName-ConfigType/0.9"
  }
}
```

### 3.2 Transform Chain Pattern
When schema versions diverge:
1. Define transform in `config/schema-transforms.json`
2. Transform path: OldSchema → IntermediateN → NewSchema
3. Each operation: field add/remove/rename/convert
4. Validation: before & after JSON schema validation

Example transform:
```json
{
  "id": "DependencyMap/0.9-to-DependencyMap/1.0",
  "fromSchema": "DependencyMap/0.9",
  "toSchema": "DependencyMap/1.0",
  "operations": [
    { "op": "add-field", "target": "root", "field": "schemaVersion", "value": "DependencyMap/1.0", "position": "first" }
  ]
}
```

### 3.3 Items2Do Pattern (Schema-Breaking Changes)
When a data format change requires user/admin action:
```powershell
$item2do = New-PipelineItem -Type 'Items2ADD' `
    -Title 'Schema Migration Required: XyZ v1 → v2' `
    -Description "Action: Run Invoke-SchemaMigration -Path '...' -Target 'v2'" `
    -Priority 'HIGH' `
    -Source 'SchemaMigration'
```

---

## 4. XHTML Tools Standard

### 4.1 File Header
```xml
<?xml version="1.0" encoding="UTF-8"?>
# VersionTag: 2605.B5.V46.0
<!-- FileRole: XhtmlTool -->
<!-- SchemaVersion: PipelineUI/1.0 -->
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
```

### 4.2 CSS Variables (Dark Theme)
```css
:root {
  --bg: #1e1e1e;
  --bg-alt: #2d2d30;
  --panel: #252526;
  --control: #333337;
  --control-fg: #dcdcdc;
  --accent: #007acc;
  --accent-green: #4ec9b0;
  --accent-orange: #ce913c;
  --heading: #007acc;
  --heading-fg: #fff;
  --fg: #d4d4d4;
  --fg-subtle: #969696;
  --border: #3f3f46;
  --btn-bg: #37373c;
  --btn-hover: #46464e;
  --btn-fg: #e6e6e6;
  --pass: #4ec9b0;
  --warn: #dcdcaa;
  --fail: #f44747;
  --info: #569cd6;
}
```

### 4.3 Data Fetch Pattern
```javascript
async function loadPipelineData() {
  try {
    const response = await fetch('/api/pipeline/items');
    const data = await response.json();
    if (data.$schema !== 'PipelineUI/1.0') {
      console.warn('Schema mismatch:', data.$schema);
    }
    return data;
  } catch (error) {
    console.error('Data load failed:', error);
    return null;
  }
}
```

---

## 5. Module Export Pattern

### 5.1 Module Manifest (.psd1)
```powershell
@{
    RootModule        = 'ModuleName.psm1'
    ModuleVersion     = '2604.B2.V32.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Public-Func1', 'Public-Func2')
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('pwshgui', 'pipeline', 'module')
            LicenseUri = 'https://...'
            ProjectUri = 'https://...'
        }
    }
}
```

### 5.2 Outline/Problems/Todo Comments
At the END of every module (.psm1):
```powershell
<# Outline:
    Brief summary of module purpose, exported functions, and key workflows.
#>

<# Problems:
    - Known issue 1: Description and severity
    - Known issue 2: Description and severity
#>

<# Todo:
    - [ ] Enhancement 1
    - [ ] Enhancement 2
#>

Export-ModuleMember -Function @('Func1', 'Func2', ...)
```

---

## 6. Pipeline Item Schema (Canonical)

All pipeline items MUST adhere to:
```json
{
  "id": "Type-YYYYMMDDHHmmss-xxxx",
  "type": "FeatureRequest|Bug|Items2ADD|Bugs2FIX|ToDo",
  "title": "string",
  "description": "string",
  "priority": "CRITICAL|HIGH|MEDIUM|LOW",
  "status": "OPEN|PLANNED|IN_PROGRESS|TESTING|DONE|BLOCKED|FAILED|CLOSED",
  "source": "Manual|AutoCron|Subagent|BugTracker|SinRegistry|RuntimeError|PipelineError",
  "category": "string (parsing, runtime, security, data, feature, etc.)",
  "affectedFiles": ["path/to/file1", "path/to/file2"],
  "suggestedBy": "Commander|CronAiAthon|SinRegistry|ErrorHandler",
  "priority": "CRITICAL|HIGH|MEDIUM|LOW",
  "created": "ISO8601",
  "modified": "ISO8601",
  "sessionModCount": 1,
  "outlineTag": "OUTLINE-PROTO-v0",
  "outlineVersion": "v0",
  "outlinePhase": "assessment|planning|implementation|testing|done"
}
```

---

## 7. Code Style Requirements

### 7.1 PowerShell
- **Indentation**: 4 spaces (no tabs)
- **Naming**: PascalCase for functions, camelCase for variables
- **Comment blocks**: Use `#>` for PSDoc, `#` for inline
- **Error handling**: Always use try/catch with logging
- **Encoding**: UTF-8 BOM for .ps1, UTF-8 for .psm1

### 7.2 XHTML/CSS/JavaScript
- **Indentation**: 2 spaces
- **CSS**: Use CSS variables for theming
- **JavaScript**: ES6+ where supported; avoid inline event handlers
- **Accessibility**: ARIA labels, keyboard navigation required

### 7.3 JSON
- **Indentation**: 2 spaces
- **Schema reference**: Always include `$schema` at root
- **Versioning**: Include `schemaVersion` field
- **Metadata**: Always include `meta` object with generator info

---

## 8. Testing & Validation

### 8.1 Module Load Test
```powershell
$modulePath = 'modules\ModuleName.psm1'
$null = Import-Module -FullyQualifiedName $modulePath -Force -ErrorAction Stop
Get-Module ModuleName | Select-Object Name, Version, ExportedFunctions
```

### 8.2 Script Parse Check
```powershell
$file = 'scripts\Script.ps1'
[void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
if ($errors) { "PARSE ERROR"; $errors }
```

### 8.3 Schema Validation
```powershell
$json = Get-Content 'config/file.json' | ConvertFrom-Json
if ($null -eq $json.'$schema') { "MISSING $schema field" }
```

---

## 9. Documentation Requirements

Every module and script must include:
- **Synopsis**: One-line purpose
- **Description**: Detailed explanation
- **Parameters**: Full .PARAMETER documentation
- **Outputs**: Expected return types
- **Examples**: Minimum 1, ideally 2-3
- **Notes**: Author, version, created date, modified date

---

## 10. Compliance Checklist

Before committing any module/script/config:

- [ ] VersionTag present and incremented
- [ ] FileRole declared
- [ ] All functions documented with .SYNOPSIS and .DESCRIPTION
- [ ] Error handling includes try/catch + logging
- [ ] Schema version declared (if applicable)
- [ ] Outline/Problems/Todo comments filled
- [ ] Functions exported via Export-ModuleMember
- [ ] JSON files include $schema and schemaVersion
- [ ] No hardcoded paths (use $PSScriptRoot, config paths)
- [ ] Tested on both PS 5.1 and PS 7.6+ (if cross-platform)

---

**This standard applies to ALL new and modified code effective 2026-04-27.**

