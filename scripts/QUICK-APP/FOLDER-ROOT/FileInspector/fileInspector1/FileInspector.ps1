# VersionTag: 2605.B5.V46.0
# =============================================================================
# FileInspector.ps1
# Reads query parameters from .dat files (comma- or newline-separated values)
# and runs Get-ChildItem inspection across every combination of Path × Filter × SizeUnit.
# =============================================================================

# ── Data-file locations ───────────────────────────────────────────────────────
$PathsFile     = "$PSScriptRoot\paths.dat"
$FiltersFile   = "$PSScriptRoot\filters.dat"
$SizeUnitsFile = "$PSScriptRoot\sizeunits.dat"

# ── Helper: parse a .dat file into a clean array ──────────────────────────────
# Accepts both comma-separated values on one/many lines AND plain line-per-value.
function Read-DatFile {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        Write-Warning "Data file not found: $FilePath"
        return @()
    }

    $raw = Get-Content $FilePath -Raw          # read whole file as one string
    # Split on commas OR newlines, trim whitespace, drop blanks
    $values = $raw -split '[,\r\n]+' |
              ForEach-Object { $_.Trim() } |
              Where-Object   { $_ -ne '' }

    return $values
}

# ── Load parameter arrays ─────────────────────────────────────────────────────
$Paths     = Read-DatFile $PathsFile      # e.g. C:\PowerShellGUI\modules
$Filters   = Read-DatFile $FiltersFile    # e.g. *.psd1
$SizeUnits = Read-DatFile $SizeUnitsFile  # e.g. KB  → becomes Size_KB column

if (-not $Paths     ) { Write-Error "No paths loaded.";     return }
if (-not $Filters   ) { Write-Error "No filters loaded.";   return }
if (-not $SizeUnits ) { Write-Error "No size units loaded."; return }

# ── Build the divisor map (extend as needed) ──────────────────────────────────
$UnitDivisor = @{
    'B'  = 1
    'KB' = 1KB
    'MB' = 1MB
    'GB' = 1GB
    'TB' = 1TB
}

# ── Main loop: every Path × Filter × SizeUnit combination ────────────────────
$allResults = foreach ($searchPath in $Paths) {

    if (-not (Test-Path $searchPath)) {
        Write-Warning "Path not found, skipping: $searchPath"
        continue
    }

    foreach ($filter in $Filters) {

        # Get-ChildItem supports only one -Filter value at a time.
        # If the .dat file supplies several filters on one comma-separated line
        # they will already be split individually by Read-DatFile, so each
        # $filter here is always a single glob pattern.
        $files = Get-ChildItem $searchPath -Filter $filter -ErrorAction SilentlyContinue

        foreach ($file in $files) {
            $content = Get-Content $file.FullName -Raw

            # Build a dynamic property bag starting with identity columns
            $props = [ordered]@{
                SourcePath = $searchPath
                Filter     = $filter
                File       = $file.Name
                HasVersionTag = ($content -match '# VersionTag:')
                HasFileRole   = ($content -match '# FileRole:')
                HasSchemaVer  = ($content -match '# SchemaVersion:')
            }

            # Add one size column per requested unit  (e.g. Size_KB, Size_MB)
            foreach ($unit in $SizeUnits) {
                $divisor = $UnitDivisor[$unit.ToUpper()]
                if ($null -eq $divisor) {
                    Write-Warning "Unknown size unit '$unit' – skipping column."
                    continue
                }
                $colName = "Size_$($unit.ToUpper())"
                $props[$colName] = [Math]::Round($file.Length / $divisor, 1)
            }

            [PSCustomObject]$props
        }
    }
}

# ── Output ────────────────────────────────────────────────────────────────────
if ($allResults) {
    $allResults | Format-Table -AutoSize
} else {
    Write-Host "No matching files found across any combination of paths and filters."
}

