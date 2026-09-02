# VersionTag: 2606.B5.V51.4
$path = 'C:\PowerShellGUI\reports\iter17\HEAD-helpfiles.psm1'
$tokens = $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
Write-Host ("HEAD version parse errors: " + @($errors).Count)
$errors | Select-Object -First 5 | ForEach-Object { Write-Host ("  L" + $_.Extent.StartLineNumber + " " + $_.Message) }



