# VersionTag: 2605.B5.V46.0
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile('c:\PowerShellGUI\Main-GUI.ps1', [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Host ("[{0}] {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
    exit 1
} else {
    Write-Host ("Parse OK on PS {0} (Tokens={1})" -f $PSVersionTable.PSVersion, $tokens.Count) -ForegroundColor Green
}

