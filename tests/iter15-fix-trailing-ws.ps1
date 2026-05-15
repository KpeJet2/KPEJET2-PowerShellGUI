# VersionTag: 2605.B5.V46.0
# Iter15: trailing whitespace mass-fix in modules/, preserves UTF-8 BOM if present
$ErrorActionPreference = 'Stop'
$root = 'C:\PowerShellGUI\modules'
$files = Get-ChildItem -Path $root -Recurse -Include '*.psm1','*.psd1','*.ps1' -File
$fixed = 0
$linesFixed = 0
foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -eq 0) { continue }
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $startIdx = if ($hasBom) { 3 } else { 0 }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, $startIdx, $bytes.Length - $startIdx)
    $orig = $text
    # Detect line-ending style
    $crlf = $text -match "`r`n"
    # Remove trailing whitespace per line (preserves line endings)
    $newText = [regex]::Replace($text, '[ \t]+(?=\r?\n)', '')
    # Also trim trailing whitespace on final line (no terminator)
    $newText = [regex]::Replace($newText, '[ \t]+\z', '')
    if ($newText -ne $orig) {
        $delta = ($orig -split "`n").Count - ($newText -split "`n").Count
        # count fixes: difference in length / approximate
        $linesFixed += [Math]::Max(1, ($orig.Length - $newText.Length))
        $bom = if ($hasBom) { [byte[]](0xEF, 0xBB, 0xBF) } else { @() }
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($newText)
        [System.IO.File]::WriteAllBytes($f.FullName, $bom + $bodyBytes)
        $fixed++
    }
}
Write-Host ("Files fixed: " + $fixed)
Write-Host ("Approx chars removed: " + $linesFixed)
$after = Invoke-ScriptAnalyzer -Path $root -Recurse -IncludeRule PSAvoidTrailingWhitespace
Write-Host ("PSSA PSAvoidTrailingWhitespace remaining: " + @($after).Count)

