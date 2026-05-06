# VersionTag: 2605.B2.V31.7
$path = 'C:\PowerShellGUI\scripts\Build-AgenticManifest.ps1'
$bytes = [System.IO.File]::ReadAllBytes($path)
# bytes 0-2 = BOM, byte 3 = stray '?' (3F) from round-trip damage
if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF -and $bytes[3] -eq 0x3F) {
    $repaired = New-Object byte[] ($bytes.Length - 1)
    [Array]::Copy($bytes, 0, $repaired, 0, 3)
    [Array]::Copy($bytes, 4, $repaired, 3, $bytes.Length - 4)
    [System.IO.File]::WriteAllBytes($path, $repaired)
    "Stripped stray ? after BOM"
} else { "No stray ? after BOM" }
$tokens=$null;$errs=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errs)
"Parse errors: $($errs.Count)"

