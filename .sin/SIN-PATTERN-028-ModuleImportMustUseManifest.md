# VersionTag: 2605.B5.V46.0
# SIN-PATTERN-028: Module Import Must Use Manifest
#
# All Import-Module statements for workspace modules must reference the .psd1 manifest file, not the .psm1 script file.
# This ensures correct module loading, versioning, and dependency resolution. Direct .psm1 imports are forbidden except for legacy compatibility wrappers.
#
# Example (CORRECT):
#   Import-Module ./modules/MyModule.psd1
# Example (SIN):
#   Import-Module ./modules/MyModule.psm1
#
# Remediation: Update all Import-Module calls to use the .psd1 manifest if present. If the module lacks a manifest, generate one using New-ModuleManifest.
#
# Category: Module Loading
# Reason: Ensures PowerShell module system works as intended, prevents partial/failed loads, and enables pipeline-driven upgrades.
#
# See also: https://learn.microsoft.com/powershell/scripting/developer/module/understanding-a-windows-powershell-module

