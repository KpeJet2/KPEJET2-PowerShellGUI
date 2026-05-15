# VersionTag: 2605.B5.V46.0
# iter26: targeted trailing-ws strip on files PSSA flagged, preserving BOM and CRLF
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidTrailingWhitespace
$byFile = $f | Group-Object ScriptPath
Write-Host ("Files with trailing-ws: " + @($byFile).Count)
foreach ($g in $byFile) {
    $path = $g.Name
    if ($path -like '*PwSh-HelpFilesUpdateSource-ReR*') { Write-Host "  SKIP (iter15 known-fragile): $path"; continue }
    $bytes = [IO.File]::ReadAllBytes($path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom) { $text = $text.Substring(1) } # strip BOM char
    # split preserving CRLF; we'll rewrite with CRLF
    $lines = $text -split "`r`n", 0
    $changed = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $orig = $lines[$i]
        $stripped = $orig -replace '[ \t]+$', ''
        if ($stripped -ne $orig) { $lines[$i] = $stripped; $changed++ }
    }
    if ($changed -gt 0) {
        $newText = $lines -join "`r`n"
        $enc = New-Object System.Text.UTF8Encoding($hadBom)
        [IO.File]::WriteAllBytes($path, $enc.GetPreamble() + $enc.GetBytes($newText))
        Write-Host ("  Cleaned: $path (lines fixed: $changed)")
    }
}
# Re-scan
$f2 = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidTrailingWhitespace
Write-Host ("Remaining trailing-ws: " + @($f2).Count)
$f2 | Format-Table ScriptName, Line -AutoSize

