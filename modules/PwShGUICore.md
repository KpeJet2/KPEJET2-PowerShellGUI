# VersionTag: 2605.B5.V46.0
# Module Documentation: PwShGUICore.psm1

## Purpose
Central utility module for logging, path management, config validation, and file enumeration in PowerShellGUI.

## Key Functions
- Write-AppLog: Buffered log writer with severity filtering.
- Initialize-CorePaths: Sets up all workspace and config paths.
- Get-ProjectPath: Returns a path from the central registry.
- Validate-ConfigPaths: Validates all critical config and workspace paths.
- Get-AllProjectFiles: Optimized file enumeration utility.

## SIN Compliance
- No hardcoded credentials (P001)
- No empty catch blocks (P002)
- All file writes specify -Encoding (P012/P017)
- VersionTag present (P007)

## Usage Example
Import-Module (Join-Path $modulesDir 'PwShGUICore.psm1') -Force
Initialize-CorePaths -ScriptDir $workspaceRoot
Validate-ConfigPaths
$files = Get-AllProjectFiles

## See Also
- PwShGUI-VersionTag.psm1
- PwShGUI-Theme.psm1
- PwShGUI-PSVersionStandards.psm1

