# VersionTag: 2605.B2.V31.7
$today = (Get-Date).ToString('yyyy-MM-dd')
$files = Get-ChildItem C:\PowerShellGUI\sin_registry -Filter 'SIN-20260430081505-P034-*.json'
foreach ($f in $files) {
    $j = Get-Content -Raw -Encoding UTF8 $f.FullName | ConvertFrom-Json
    $j | Add-Member -NotePropertyName resolution_date -NotePropertyValue $today -Force
    $j | Add-Member -NotePropertyName resolution_commit -NotePropertyValue 'iter14-rename-shadowing' -Force
    $j.status = 'RESOLVED'
    $j | ConvertTo-Json -Depth 6 | Set-Content -Path $f.FullName -Encoding UTF8
}
Write-Host ("Updated: " + $files.Count)

