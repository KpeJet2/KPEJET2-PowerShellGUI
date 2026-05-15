# VersionTag: 2605.B5.V46.0
# Analyse untagged files for taggability candidacy.

[CmdletBinding()]
param(
    [string]$CsvPath = 'C:\PowerShellGUI\temp\workspace-versions.csv',
    [string]$OutPath = 'C:\PowerShellGUI\temp\taggable-candidates.csv'
)

$rows = Import-Csv -LiteralPath $CsvPath
$untagged = $rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Version) }
Write-Host ("Untagged total: {0}" -f @($untagged).Count)

# Folder/path exclusion patterns: artefacts / generated / historical / vendor
$excludeFolderRx = '^(\.history/|checkpoints/|logs/|temp/|reports/|Report/|~REPORTS/|~DOWNLOADS/|gallery/|sin_registry/|todo/|pki/|UPM/|\.venv/|node_modules/|\.git/|sovereign-kernel/snapshot|Fing-mcp/(node_modules|dist))'

# Filename / extension exclusions
$excludeNameRx   = '\.(csv|xml|log|lock|bak|backup|tmp|min\.js|min\.css|map|lnk|exe|dll|pdb|zip|7z|tar|gz|png|jpg|jpeg|gif|ico|svg|woff2?|ttf|otf|wav|mp3|mp4|pdf|db|sqlite|sqlite3)$|\.backup_|\.bak-|\.tests?\.results\.|^testResults\.'

# Taggable extensions (human-authored source / config / docs)
$taggableExtRx   = '\.(ps1|psm1|psd1|bat|cmd|py|js|ts|css|md|xhtml|html|htm|yaml|yml|json|ini|conf|toml|sh|reg)$'

$cands = New-Object System.Collections.Generic.List[object]
foreach ($r in $untagged) {
    $p = $r.Path
    $reason = ''
    if ($p -match $excludeFolderRx) { $reason = 'excluded-folder' }
    elseif ($p -match $excludeNameRx) { $reason = 'excluded-artefact' }
    elseif ($p -notmatch $taggableExtRx) { $reason = 'non-source-ext' }
    else { $reason = 'CANDIDATE' }
    $cands.Add([pscustomobject]@{
        Path     = $p
        SizeKB   = $r.SizeKB
        Decision = $reason
    }) | Out-Null
}

$cands | Export-Csv -LiteralPath $OutPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "================ Taggability Buckets ================"
$cands | Group-Object Decision | Sort-Object Count -Descending |
    ForEach-Object { '{0,-20} {1,5}' -f $_.Name, $_.Count } | Out-Host

$candidates = $cands | Where-Object { $_.Decision -eq 'CANDIDATE' }
Write-Host ""
Write-Host ("CANDIDATE files ({0}) — by extension:" -f @($candidates).Count)
$candidates | ForEach-Object {
    $ext = [System.IO.Path]::GetExtension($_.Path).ToLower()
    if ([string]::IsNullOrEmpty($ext)) { $ext = '(none)' }
    [pscustomobject]@{ Path=$_.Path; Ext=$ext }
} | Group-Object Ext | Sort-Object Count -Descending |
    ForEach-Object { '{0,-10} {1,5}' -f $_.Name, $_.Count } | Out-Host

Write-Host ""
Write-Host ("Top 30 CANDIDATE files (by folder):")
$candidates | Sort-Object Path | Select-Object -First 30 |
    ForEach-Object { '  {0}' -f $_.Path } | Out-Host

Write-Host ""
Write-Host ("Full report: {0}" -f $OutPath)
