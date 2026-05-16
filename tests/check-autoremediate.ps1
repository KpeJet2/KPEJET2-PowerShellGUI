# VersionTag: 2605.B5.V46.0
$t=$null;$e=$null
[void][System.Management.Automation.Language.Parser]::ParseFile('C:\PowerShellGUI\modules\PwShGUI-AutoRemediate.psm1',[ref]$t,[ref]$e)
"Errors: $($e.Count)"
$e | Select-Object -First 5 | ForEach-Object { "  L$($_.Extent.StartLineNumber): $($_.Message)" }

