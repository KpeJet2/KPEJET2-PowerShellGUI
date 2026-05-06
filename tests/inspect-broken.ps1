# VersionTag: 2605.B2.V31.7
$f = Get-ChildItem 'C:\PowerShellGUI\scripts\Build-Agentic*' | Select-Object -First 1
"FullName: $($f.FullName)"
"Length: $($f.Name.Length) chars"
$bytes = [System.Text.Encoding]::Unicode.GetBytes($f.Name)
($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
$tokens=$null;$errs=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$errs)
"Errors: $($errs.Count)"
$errs | Select-Object -First 3 | ForEach-Object { "  L$($_.Extent.StartLineNumber): $($_.Message)" }

