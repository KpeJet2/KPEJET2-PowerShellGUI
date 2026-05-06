# VersionTag: 2605.B2.V31.7
$b = [IO.File]::ReadAllBytes('C:\PowerShellGUI\modules\PwSh-HelpFilesUpdateSource-ReR.psm1')
# Locate "Save-Help operation completed" anchor and dump 200 bytes before it
$text = [Text.Encoding]::UTF8.GetString($b)
$idx = $text.IndexOf('Save-Help operation completed')
Write-Host "Anchor at char-idx $idx"
# Find byte index... use UTF8 conversion of substring
$prefBytes = [Text.Encoding]::UTF8.GetBytes($text.Substring(0, $idx))
$bIdx = $prefBytes.Length
Write-Host "Anchor at byte-idx $bIdx"
$start = [Math]::Max(0, $bIdx - 350)
$end = [Math]::Min($b.Length-1, $bIdx + 50)
$slice = $b[$start..$end]
$sb = New-Object System.Text.StringBuilder
foreach ($byte in $slice) { [void]$sb.AppendFormat('{0:X2} ', $byte) }
Write-Host $sb.ToString()

