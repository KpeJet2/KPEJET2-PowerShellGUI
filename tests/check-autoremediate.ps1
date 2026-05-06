# VersionTag: 2605.B2.V31.7
$t=$null;$e=$null
[void][System.Management.Automation.Language.Parser]::ParseFile('C:\PowerShellGUI\modules\PwShGUI-AutoRemediate.psm1',[ref]$t,[ref]$e)
"Errors: $($e.Count)"
$e | Select-Object -First 5 | ForEach-Object { "  L$($_.Extent.StartLineNumber): $($_.Message)" }

