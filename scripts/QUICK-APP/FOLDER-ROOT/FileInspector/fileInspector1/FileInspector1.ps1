# VersionTag: 2605.B5.V46.0
# =============================================================================
# FileInspector.ps1  –  Expanded Edition
# Reads query parameters from .dat files and inspects every Path × Filter combo.
#
# Columns added over v1:
#   CreatedDate, ModifiedDate, Title, ScriptName, VersionTagValue
#
# Console highlighting:
#   GREEN  – HasVersionTag AND HasFileRole AND HasSchemaVer all True
#   YELLOW – 1 or 2 of those three are True
#   RED    – all three False
#
# After display, prompts to export Yellow + Red rows to a timestamped .log file
# and / or to Out-GridView.
# =============================================================================

# ── Data-file locations ───────────────────────────────────────────────────────
$PathsFile     = "$PSScriptRoot\paths.dat"
$FiltersFile   = "$PSScriptRoot\filters.dat"
$SizeUnitsFile = "$PSScriptRoot\sizeunits.dat"

# ── ANSI colour codes (Windows Terminal, PS 5.1+, VS Code terminal) ───────────
$ESC        = [char]27
$ansiGreen  = "$ESC[92m"
$ansiYellow = "$ESC[93m"
$ansiRed    = "$ESC[91m"
$ansiBold   = "$ESC[1m"
$ansiDim    = "$ESC[2m"
$ansiReset  = "$ESC[0m"

# =============================================================================
# HELPERS
# =============================================================================

# Parse a .dat file – handles comma-separated and/or line-per-value layouts
function Read-DatFile {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) {
        Write-Warning "Data file not found: $FilePath"
        return @()
    }
    $raw = Get-Content $FilePath -Raw
    return $raw -split '[,\r\n]+' |
           ForEach-Object { $_.Trim() } |
           Where-Object   { $_ -ne '' }
}

# Extract the value after a comment tag written as:  # TagName: <value>
function Get-CommentTagValue {
    param([string]$Content, [string]$TagName)
    if ($Content -match "(?m)^#\s*${TagName}\s*:\s*(.+)$") {
        return $Matches[1].Trim()
    }
    return ''
}

# Return 'Green', 'Yellow', or 'Red' for a result row
function Get-HighlightCategory {
    param($Row)
    $n = @($Row.HasVersionTag, $Row.HasFileRole, $Row.HasSchemaVer) |
         Where-Object { $_ -eq $true } | Measure-Object | Select-Object -ExpandProperty Count
    switch ($n) {
        3       { return 'Green'  }
        0       { return 'Red'    }
        default { return 'Yellow' }
    }
}

# Render one object as a padded, fixed-width table row string
function Format-TableRow {
    param([PSCustomObject]$Obj, [array]$ColDefs)
    -join ($ColDefs | ForEach-Object {
        $val = if ($null -ne $Obj.($_.Name)) { "$($Obj.($_.Name))" } else { '' }
        if ($val.Length -gt ($_.Width - 1)) {
            $val = $val.Substring(0, $_.Width - 2) + [char]0x2026   # ellipsis …
        }
        $val.PadRight($_.Width)
    })
}

function Write-Divider { param([int]$Len) Write-Host ($ansiDim + ('-' * $Len) + $ansiReset) }

# =============================================================================
# LOAD PARAMETER ARRAYS
# =============================================================================
$Paths     = Read-DatFile $PathsFile
$Filters   = Read-DatFile $FiltersFile
$SizeUnits = Read-DatFile $SizeUnitsFile

if (-not $Paths)     { Write-Error "No paths loaded from $PathsFile";         return }
if (-not $Filters)   { Write-Error "No filters loaded from $FiltersFile";     return }
if (-not $SizeUnits) { Write-Error "No size units loaded from $SizeUnitsFile"; return }

$UnitDivisor = @{ 'B' = 1; 'KB' = 1KB; 'MB' = 1MB; 'GB' = 1GB; 'TB' = 1TB }

# =============================================================================
# COLLECT RESULTS
# =============================================================================
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($searchPath in $Paths) {

    if (-not (Test-Path $searchPath)) {
        Write-Warning "Path not found, skipping: $searchPath"
        continue
    }

    foreach ($filter in $Filters) {

        $files = Get-ChildItem $searchPath -Filter $filter -ErrorAction SilentlyContinue

        foreach ($file in $files) {

            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content) { $content = '' }

            # ── Boolean tag detection ─────────────────────────────────────────
            $hasVTag   = [bool]($content -match '(?m)^#\s*VersionTag\s*:')
            $hasRole   = [bool]($content -match '(?m)^#\s*FileRole\s*:')
            $hasSchema = [bool]($content -match '(?m)^#\s*SchemaVersion\s*:')

            # ── Extracted tag values ──────────────────────────────────────────
            $vTagValue  = if ($hasVTag) { Get-CommentTagValue $content 'VersionTag' } else { '' }
            $titleVal   = Get-CommentTagValue $content 'Title'
            $scriptName = Get-CommentTagValue $content 'ScriptName'

            # ── Core property bag ─────────────────────────────────────────────
            $props = [ordered]@{
                File            = $file.Name
                Title           = $titleVal
                ScriptName      = $scriptName
                CreatedDate     = $file.CreationTime.ToString('yyyy-MM-dd HH:mm')
                ModifiedDate    = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                HasVersionTag   = $hasVTag
                HasFileRole     = $hasRole
                HasSchemaVer    = $hasSchema
                VersionTagValue = $vTagValue
                SourcePath      = $searchPath
                Filter          = $filter
            }

            # ── Dynamic size columns ──────────────────────────────────────────
            foreach ($unit in $SizeUnits) {
                $div = $UnitDivisor[$unit.ToUpper()]
                if ($null -eq $div) { Write-Warning "Unknown unit '$unit' – skipped."; continue }
                $props["Size_$($unit.ToUpper())"] = [Math]::Round($file.Length / $div, 1)
            }

            $row = [PSCustomObject]$props
            $row | Add-Member -NotePropertyName '_Highlight' `
                              -NotePropertyValue (Get-HighlightCategory $row) -Force
            $allResults.Add($row)
        }
    }
}

if ($allResults.Count -eq 0) {
    Write-Host "${ansiYellow}No matching files found across any path / filter combination.${ansiReset}"
    return
}

# =============================================================================
# DEFINE DISPLAY COLUMNS  (Name + fixed character width)
# =============================================================================
$colDefs = [System.Collections.Generic.List[hashtable]]::new()
$colDefs.Add(@{ Name='File';            Width=32 })
$colDefs.Add(@{ Name='Title';           Width=22 })
$colDefs.Add(@{ Name='ScriptName';      Width=22 })
$colDefs.Add(@{ Name='CreatedDate';     Width=18 })
$colDefs.Add(@{ Name='ModifiedDate';    Width=18 })
$colDefs.Add(@{ Name='HasVersionTag';   Width=14 })
$colDefs.Add(@{ Name='HasFileRole';     Width=12 })
$colDefs.Add(@{ Name='HasSchemaVer';    Width=12 })
$colDefs.Add(@{ Name='VersionTagValue'; Width=20 })
foreach ($unit in $SizeUnits) {
    $colDefs.Add(@{ Name="Size_$($unit.ToUpper())"; Width=10 })
}

# =============================================================================
# RENDER COLOUR TABLE
# =============================================================================
$headerObj = [ordered]@{}
foreach ($c in $colDefs) { $headerObj[$c.Name] = $c.Name }
$headerLine = Format-TableRow ([PSCustomObject]$headerObj) $colDefs
$tableWidth = $headerLine.Length

Write-Host ''
Write-Host "${ansiBold}${headerLine}${ansiReset}"
Write-Divider $tableWidth

foreach ($row in $allResults) {
    $line  = Format-TableRow $row $colDefs
    $color = switch ($row._Highlight) {
        'Green'  { $ansiGreen  }
        'Yellow' { $ansiYellow }
        'Red'    { $ansiRed    }
    }
    Write-Host "${color}${line}${ansiReset}"
}

Write-Divider $tableWidth

# ── Summary ───────────────────────────────────────────────────────────────────
$cntGreen  = ($allResults | Where-Object { $_._Highlight -eq 'Green'  }).Count
$cntYellow = ($allResults | Where-Object { $_._Highlight -eq 'Yellow' }).Count
$cntRed    = ($allResults | Where-Object { $_._Highlight -eq 'Red'    }).Count

Write-Host ''
Write-Host "${ansiBold}Summary  ${ansiReset}" +
    "${ansiGreen}●  All tags present : $cntGreen${ansiReset}   " +
    "${ansiYellow}●  Partial          : $cntYellow${ansiReset}   " +
    "${ansiRed}●  All tags missing : $cntRed${ansiReset}"
Write-Host ''
Write-Host (
    "${ansiDim}Legend :  " +
    "${ansiReset}${ansiGreen}GREEN${ansiReset}${ansiDim}  = all three tags True  |  " +
    "${ansiReset}${ansiYellow}YELLOW${ansiReset}${ansiDim} = 1 or 2 True  |  " +
    "${ansiReset}${ansiRed}RED${ansiReset}${ansiDim}    = all False${ansiReset}"
)
Write-Host ''

# =============================================================================
# EXPORT PROMPT  –  Yellow + Red rows
# =============================================================================
$flaggedRows = @($allResults | Where-Object { $_._Highlight -in 'Yellow', 'Red' })

if ($flaggedRows.Count -eq 0) {
    Write-Host "${ansiGreen}All files have complete tag coverage – nothing flagged for export.${ansiReset}"
    return
}

Write-Host "${ansiBold}Flagged rows (Yellow + Red): $($flaggedRows.Count)${ansiReset}"
Write-Host ''
Write-Host "What would you like to do with them?"
Write-Host "  ${ansiBold}[L]${ansiReset}  Save to log file"
Write-Host "  ${ansiBold}[G]${ansiReset}  View in Out-GridView"
Write-Host "  ${ansiBold}[B]${ansiReset}  Both"
Write-Host "  ${ansiBold}[S]${ansiReset}  Skip / do nothing"
Write-Host ''
$choice = (Read-Host "Choice").ToUpper().Trim()

# Clean export set – no internal _Highlight column
$exportRows = $flaggedRows | Select-Object -Property * -ExcludeProperty '_Highlight'

# ── Option L / B : write log file ─────────────────────────────────────────────
if ($choice -in 'L', 'B') {

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $logPath   = "$PSScriptRoot\FileInspector-FalseResults_${timestamp}.log"
    $lines     = [System.Collections.Generic.List[string]]::new()

    $lines.Add('=' * 80)
    $lines.Add('FileInspector – Partial / Missing Tag Results')
    $lines.Add("Generated  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("Total rows : $($flaggedRows.Count)   (Yellow: $cntYellow   Red: $cntRed)")
    $lines.Add('=' * 80)
    $lines.Add('')

    foreach ($row in $flaggedRows) {

        $category = if ($row._Highlight -eq 'Red') { 'ALL TAGS MISSING' } else { 'PARTIAL TAGS' }
        $lines.Add("[$category]")
        $lines.Add("  File             : $($row.File)")
        $lines.Add("  Title            : $($row.Title)")
        $lines.Add("  ScriptName       : $($row.ScriptName)")
        $lines.Add("  Source Path      : $($row.SourcePath)")
        $lines.Add("  Filter           : $($row.Filter)")
        $lines.Add("  Created          : $($row.CreatedDate)")
        $lines.Add("  Last Modified    : $($row.ModifiedDate)")

        $vTagDetail = if ($row.HasVersionTag) { "  →  Value: $($row.VersionTagValue)" } else { '' }
        $lines.Add("  HasVersionTag    : $($row.HasVersionTag)$vTagDetail")
        $lines.Add("  HasFileRole      : $($row.HasFileRole)")
        $lines.Add("  HasSchemaVer     : $($row.HasSchemaVer)")

        foreach ($unit in $SizeUnits) {
            $col = "Size_$($unit.ToUpper())"
            $lines.Add("  $($col.PadRight(17)): $($row.$col) $unit")
        }

        $lines.Add('-' * 60)
        $lines.Add('')
    }

    $lines | Set-Content -Path $logPath -Encoding UTF8
    Write-Host ''
    Write-Host "${ansiGreen}Log saved →${ansiReset} $logPath"
}

# ── Option G / B : Out-GridView ───────────────────────────────────────────────
if ($choice -in 'G', 'B') {
    $exportRows | Out-GridView -Title "FileInspector – Flagged Rows  ($cntYellow Yellow  +  $cntRed Red)"
}

if ($choice -notin 'L', 'G', 'B', 'S') {
    Write-Host "${ansiYellow}Unrecognised choice – export skipped.${ansiReset}"
}

