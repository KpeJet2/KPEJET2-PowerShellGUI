# VersionTag: 2605.B5.V46.0
$path = 'C:\PowerShellGUI\modules\PwSh-HelpFilesUpdateSource-ReR.psm1'
$tokens = $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
$errors | ForEach-Object { Write-Host ("L" + $_.Extent.StartLineNumber + ":C" + $_.Extent.StartColumnNumber + " " + $_.Message) }

