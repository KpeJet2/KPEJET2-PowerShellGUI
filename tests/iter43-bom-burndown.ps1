# VersionTag: 2605.B5.V46.0
# Iter43 — P006 BOM burndown helper
# Reads latest scan JSON, ensures UTF-8 BOM on every flagged file.
[CmdletBinding()]
param(
    [string]$ScanJson = 'C:\PowerShellGUI\reports\sin-scan-bat-xhtml.json',
    [string]$WorkspaceRoot = 'C:\PowerShellGUI'
)

$ErrorActionPreference = 'Stop'
$j = Get-Content -LiteralPath $ScanJson -Raw | ConvertFrom-Json
$files = @($j.findings | Where-Object { $_.sinId -like '*006*' } |
    ForEach-Object { $_.file } | Sort-Object -Unique)

$utf8Bom = New-Object System.Text.UTF8Encoding $true
$fixed = 0; $skipped = 0; $missing = 0
foreach ($rel in $files) {
    $full = Join-Path $WorkspaceRoot $rel
    if (-not (Test-Path -LiteralPath $full)) { $missing++; continue }
    $b = [IO.File]::ReadAllBytes($full)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        $skipped++; continue
    }
    $text = [IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($full, $text, $utf8Bom)
    $fixed++
}
Write-Output "Fixed=$fixed Skipped=$skipped Missing=$missing Total=$($files.Count)"

