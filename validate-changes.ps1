# VersionTag: 2607.B1.V52.0
# Quick validation script
[CmdletBinding()]
param()

$scripts = @(
    'scripts\Build-DynaManifest.ps1'
    'scripts\Invoke-DynaManifestValidation.ps1'
    'scripts\Fix-P006-EncodingViolations.ps1'
    'scripts\Invoke-WorkspaceIntegrityCheck.ps1'
    'modules\ConvoVault-BWcli.psm1'
    'modules\PwShGUI-AiActionLog.psm1'
)

Write-Host "╔════ Comprehensive Validation ════╗" -ForegroundColor Cyan
$parseErrors = 0

foreach ($script in $scripts) {
    if (Test-Path $script) {
        try {
            [void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
            Write-Host ("✓ " + $script) -ForegroundColor Green
        } catch {
            Write-Host ("✗ " + $script + ": " + $_.Exception.Message) -ForegroundColor Red
            $parseErrors++
        }
    } else {
        Write-Host ("? " + $script + " not found") -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Parse validation: $parseErrors errors" -ForegroundColor $(if ($parseErrors -gt 0) { "Red" } else { "Green" })
exit $parseErrors
