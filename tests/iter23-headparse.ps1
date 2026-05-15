# VersionTag: 2605.B5.V46.0
$path = 'C:\PowerShellGUI\reports\iter17\HEAD-helpfiles.psm1'
$tokens = $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
Write-Host ("HEAD version parse errors: " + @($errors).Count)
$errors | Select-Object -First 5 | ForEach-Object { Write-Host ("  L" + $_.Extent.StartLineNumber + " " + $_.Message) }

