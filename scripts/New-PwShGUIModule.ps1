# VersionTag: 2604.B2.V31.0
# FileRole: Builder
#Requires -Version 5.1
<#
.SYNOPSIS
    Module scaffold generator for PwShGUI (Improvement #2).
.DESCRIPTION
    Creates a new SIN-compliant PowerShell module (.psm1) with:
    - UTF-8 BOM encoding, VersionTag header, CmdletBinding
    - Error handling templates (Template 3/5) pre-wired
    - Theme integration via Get-ThemeValue / Set-ControlProperty
    - Write-AppLog instead of Write-Warning/Write-Error
    - Export-ModuleMember with explicit function list
.PARAMETER ModuleName
    Name of the new module (without .psm1 extension).
.PARAMETER OutputDir
    Directory to create the module in. Default: modules/
.PARAMETER Type
    Module type: 'WinForms' (Template 5 handlers) or 'Service' (Template 3 I/O).
.PARAMETER Functions
    Array of function names to scaffold (Verb-Noun format).
.EXAMPLE
    .\New-PwShGUIModule.ps1 -ModuleName 'MyNewWidget' -Type WinForms -Functions @('Show-MyWidget','Update-MyWidget')
.NOTES
    Author  : The Establishment
    Created : 2026-04-05
#>
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Z][a-zA-Z0-9-]+$')]
    [string]$ModuleName,

    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'),

    [ValidateSet('WinForms', 'Service')]
    [string]$Type = 'Service',

    [string[]]$Functions = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = '2604.B2.V31.0'
$outPath = Join-Path $OutputDir "$ModuleName.psm1"

if (Test-Path $outPath) {
    Write-Warning "Module already exists: $outPath"
    return
}

# ── Build module content ────────────────────────────────────────────────
$sb = [System.Text.StringBuilder]::new()

# Header
[void]$sb.AppendLine("# VersionTag: $version")
[void]$sb.AppendLine('#Requires -Version 5.1')
[void]$sb.AppendLine('<#')
[void]$sb.AppendLine(".SYNOPSIS")
[void]$sb.AppendLine("    $ModuleName module for PwShGUI.")
[void]$sb.AppendLine(".DESCRIPTION")
[void]$sb.AppendLine("    Auto-generated SIN-compliant module scaffold.")
[void]$sb.AppendLine(".NOTES")
[void]$sb.AppendLine("    Author   : The Establishment")
[void]$sb.AppendLine("    Version  : $version")
[void]$sb.AppendLine("    Created  : $(Get-Date -Format 'dd MMMM yyyy')")
[void]$sb.AppendLine('#>')
[void]$sb.AppendLine('')

# Theme import for WinForms modules
if ($Type -eq 'WinForms') {
    [void]$sb.AppendLine('# ── Theme Integration ──')
    [void]$sb.AppendLine('try {')
    [void]$sb.AppendLine("    `$themeMod = Join-Path `$PSScriptRoot 'PwShGUI-Theme.psm1'")
    [void]$sb.AppendLine('    if (Test-Path $themeMod) { Import-Module $themeMod -Force -ErrorAction Stop }')
    [void]$sb.AppendLine('} catch {')
    [void]$sb.AppendLine("    Write-Warning `"Theme module unavailable: `$(`$_.Exception.Message)`"")
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine('')
}

# Logging helper reference
[void]$sb.AppendLine('# ── Logging (use Write-AppLog from PwShGUICore or fall back) ──')
[void]$sb.AppendLine('if (-not (Get-Command Write-AppLog -ErrorAction SilentlyContinue)) {')
[void]$sb.AppendLine('    function Write-AppLog {')
[void]$sb.AppendLine('        [CmdletBinding()]')
[void]$sb.AppendLine("        param([string]`$Message, [string]`$Severity = 'Informational')")
[void]$sb.AppendLine("        Write-Verbose `"[`$Severity] `$Message`"")
[void]$sb.AppendLine('    }')
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')

# Generate each function
foreach ($funcName in $Functions) {
    [void]$sb.AppendLine("function $funcName {")
    [void]$sb.AppendLine('    [CmdletBinding()]')
    [void]$sb.AppendLine('    param()')
    [void]$sb.AppendLine('')

    if ($Type -eq 'WinForms') {
        # Template 5: WinForms handler pattern
        [void]$sb.AppendLine('    # Template 5: WinForms handler — null guards + force-array before .Count')
        [void]$sb.AppendLine('    try {')
        [void]$sb.AppendLine("        Write-AppLog -Message '$funcName started' -Severity 'Debug'")
        [void]$sb.AppendLine('        # TODO: Implement')
        [void]$sb.AppendLine("        Write-AppLog -Message '$funcName completed' -Severity 'Informational'")
        [void]$sb.AppendLine('    }')
        [void]$sb.AppendLine('    catch {')
        [void]$sb.AppendLine("        Write-AppLog -Message `"$funcName failed: `$(`$_.Exception.Message)`" -Severity 'Error'")
        [void]$sb.AppendLine('    }')
    }
    else {
        # Template 3: File/I/O operations pattern
        [void]$sb.AppendLine('    # Template 3: File operations — try/catch + Write-AppLog + -ErrorAction Stop')
        [void]$sb.AppendLine('    try {')
        [void]$sb.AppendLine("        Write-AppLog -Message '$funcName started' -Severity 'Debug'")
        [void]$sb.AppendLine('        # TODO: Implement')
        [void]$sb.AppendLine("        Write-AppLog -Message '$funcName completed' -Severity 'Informational'")
        [void]$sb.AppendLine('    }')
        [void]$sb.AppendLine('    catch {')
        [void]$sb.AppendLine("        Write-AppLog -Message `"$funcName failed: `$(`$_.Exception.Message)`" -Severity 'Error'")
        [void]$sb.AppendLine('        throw')
        [void]$sb.AppendLine('    }')
    }
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine('')
}

# Exports
[void]$sb.AppendLine('# ========================== EXPORTS ==========================')
$funcList = ($Functions | ForEach-Object { "    '$_'" }) -join ",`n"
if ($funcList) {
    [void]$sb.AppendLine("Export-ModuleMember -Function @(")
    [void]$sb.AppendLine($funcList)
    [void]$sb.AppendLine(")")
}
else {
    [void]$sb.AppendLine('# Export-ModuleMember -Function @()')
}

# Write with UTF-8 BOM
$bom = [byte[]](0xEF, 0xBB, 0xBF)
$contentBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
$allBytes = New-Object byte[] ($bom.Length + $contentBytes.Length)
[System.Array]::Copy($bom, 0, $allBytes, 0, $bom.Length)
[System.Array]::Copy($contentBytes, 0, $allBytes, $bom.Length, $contentBytes.Length)
[System.IO.File]::WriteAllBytes($outPath, $allBytes)

Write-Host "Module scaffold created: $outPath" -ForegroundColor Green
Write-Host "  Type:      $Type" -ForegroundColor Gray
Write-Host "  Functions: $(@($Functions).Count)" -ForegroundColor Gray
Write-Host "  BOM:       Yes (UTF-8)" -ForegroundColor Gray
Write-Host "  SIN-compliant: VersionTag, CmdletBinding, Write-AppLog, try/catch" -ForegroundColor Gray
