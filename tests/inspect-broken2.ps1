# VersionTag: 2605.B5.V46.0
$path = 'C:\PowerShellGUI\scripts\Build-AgenticManifest.ps1'
$bytes = [System.IO.File]::ReadAllBytes($path)
"Total bytes: $($bytes.Length)"
"First 20 bytes: " + (($bytes[0..19] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
# find line 37/38 boundaries
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
$lines = $text -split "`n"
"Line count: $($lines.Count)"
35..40 | ForEach-Object {
    if ($_ -lt $lines.Count) {
        $l = $lines[$_]
        $hex = (([char[]]$l) | Select-Object -First 30 | ForEach-Object { '{0:X2}' -f [int]$_ }) -join ' '
        "L$($_+1): $hex"
        "      $l"
    }
}

