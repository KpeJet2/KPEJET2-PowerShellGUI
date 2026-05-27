# VersionTag: 2605.B5.V46.0
# Summary helper for the bat/xhtml SIN scan output.
param(
    [string]$JsonPath = 'C:\PowerShellGUI\reports\sin-scan-bat-xhtml.json'
)
Set-StrictMode -Version Latest
$j = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$findings = @($j.findings)
Write-Host ("Total findings : {0}" -f $findings.Count) -ForegroundColor Cyan
Write-Host ('Files scanned  : {0}' -f $j.filesScanned)
Write-Host ('Patterns run   : {0}' -f $j.patternsLoaded)
Write-Host ''
Write-Host '== Findings by SIN id ==' -ForegroundColor Yellow
$findings | Group-Object sinId | Sort-Object Count -Descending |
    Select-Object Count, Name | Format-Table -AutoSize
Write-Host ''
Write-Host '== Findings by file extension ==' -ForegroundColor Yellow
$findings | ForEach-Object { [pscustomobject]@{ Ext = [System.IO.Path]::GetExtension($_.file).ToLower(); SinId = $_.sinId } } |
    Group-Object Ext | Sort-Object Count -Descending |
    Select-Object Count, Name | Format-Table -AutoSize
Write-Host ''
Write-Host '== Findings only in .bat / .xhtml ==' -ForegroundColor Yellow
$batXhtml = $findings | Where-Object { $_.file -match '\.(bat|xhtml)$' }
Write-Host ("Subset count   : {0}" -f @($batXhtml).Count)
$batXhtml | Group-Object sinId | Sort-Object Count -Descending |
    Select-Object Count, Name | Format-Table -AutoSize
Write-Host ''
Write-Host '== Sample (first 20 .bat/.xhtml findings) ==' -ForegroundColor Yellow
$batXhtml | Select-Object -First 20 sinId, severity, file, line, content | Format-Table -AutoSize -Wrap

