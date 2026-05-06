# VersionTag: 2605.B2.V31.7
# iter24: enumerate actual function names per module, replace '*' with explicit list
$targets = @(
    @{ Name='PwShGUI-NetworkTools';   Psm1='C:\PowerShellGUI\modules\PwShGUI-NetworkTools.psm1';   Psd1='C:\PowerShellGUI\modules\PwShGUI-NetworkTools.psd1' }
    @{ Name='PwShGUI-SchemaTranslator';Psm1='C:\PowerShellGUI\modules\PwShGUI-SchemaTranslator.psm1';Psd1='C:\PowerShellGUI\modules\PwShGUI-SchemaTranslator.psd1' }
    @{ Name='RE-memorAiZ';            Psm1='C:\PowerShellGUI\modules\RE-memorAiZ.psm1';            Psd1='C:\PowerShellGUI\modules\RE-memorAiZ.psd1' }
    @{ Name='WorkspaceIntentReview';  Psm1='C:\PowerShellGUI\modules\WorkspaceIntentReview.psm1';  Psd1='C:\PowerShellGUI\modules\WorkspaceIntentReview.psd1' }
)
foreach ($t in $targets) {
    Write-Host ("=== " + $t.Name + " ===")
    Import-Module $t.Psm1 -Force -DisableNameChecking -ErrorAction Stop
    $cmds = @(Get-Command -Module $t.Name -CommandType Function -ErrorAction SilentlyContinue | Sort-Object Name)
    Write-Host ("  Functions: " + $cmds.Count)
    if ($cmds.Count -eq 0) { Write-Host "  (skip - no exports)"; continue }
    $list = "@(" + (($cmds.Name | ForEach-Object { "'" + $_ + "'" }) -join ', ') + ")"
    $manifest = Get-Content $t.Psd1 -Raw -Encoding UTF8
    $new = $manifest -replace "(?m)^FunctionsToExport\s*=\s*'\*'\s*$", "FunctionsToExport = $list"
    if ($new -ne $manifest) {
        # Preserve BOM
        $bytes = [IO.File]::ReadAllBytes($t.Psd1)
        $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $enc = New-Object System.Text.UTF8Encoding($hadBom)
        [IO.File]::WriteAllBytes($t.Psd1, $enc.GetPreamble() + $enc.GetBytes($new))
        Write-Host ("  Patched: " + $t.Psd1)
    } else {
        Write-Host "  No match - check manifest format"
    }
}

