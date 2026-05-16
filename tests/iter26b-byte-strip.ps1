# VersionTag: 2605.B5.V46.0
# iter26b: byte-level trailing-ws strip on the fragile file
$path = 'C:\PowerShellGUI\modules\PwSh-HelpFilesUpdateSource-ReR.psm1'
$bytes = [IO.File]::ReadAllBytes($path)
$out = New-Object System.Collections.Generic.List[byte]
$i = 0
$wsRun = New-Object System.Collections.Generic.List[byte]
while ($i -lt $bytes.Length) {
    $b = $bytes[$i]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    if ($b -eq 0x20 -or $b -eq 0x09) {
        $wsRun.Add($b)
    } elseif ($b -eq 0x0D -or $b -eq 0x0A) {
        # discard accumulated trailing ws
        $wsRun.Clear()
        $out.Add($b)
    } else {
        # flush ws then add
        if ($wsRun.Count -gt 0) { foreach ($w in $wsRun) { $out.Add($w) }; $wsRun.Clear() }
        $out.Add($b)
    }
    $i++
}
# tail flush
if ($wsRun.Count -gt 0) { foreach ($w in $wsRun) { $out.Add($w) } }
$origSize = $bytes.Length; $newSize = $out.Count
Write-Host ("Bytes: $origSize -> $newSize (diff " + ($origSize - $newSize) + ")")
[IO.File]::WriteAllBytes($path, $out.ToArray())

# Validate parse
$tokens = $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
Write-Host ("Parse errors: " + @($errors).Count)
$errors | Select-Object -First 3 | ForEach-Object { Write-Host ("  L" + $_.Extent.StartLineNumber + " " + $_.Message) }

# Re-scan
$f = Invoke-ScriptAnalyzer -Path $path -IncludeRule PSAvoidTrailingWhitespace
Write-Host ("Remaining trailing-ws: " + @($f).Count)

