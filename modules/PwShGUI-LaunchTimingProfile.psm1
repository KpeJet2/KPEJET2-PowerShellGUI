# VersionTag: 2605.B2.V31.7
# Module: PwShGUI-LaunchTimingProfile
# Purpose: Aggregate Launch-GUI*.bat startup timings from logs into a trend.

function Get-LaunchTimingProfile {
    <#
    .SYNOPSIS
    Aggregate Launch-GUI*.bat startup timings from logs/ into a trend report.
    .DESCRIPTION
    Greps logs/ for "STARTUP_MS=" or similar timing markers, groups by date,
    and emits average/min/max per day for each launcher variant.
    Falls back gracefully if no markers are present yet.
    #>
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param(
        [string]$LogsPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'logs'),
        [string]$OutputPath
    )
    if (-not (Test-Path $LogsPath)) { Write-Verbose "No logs path"; return @() }
    $rx = '(?im)^.*?(?<date>\d{4}-\d{2}-\d{2})[^\r\n]*?(?<variant>Launch-[A-Za-z\-]+)[^\r\n]*?STARTUP_MS=(?<ms>\d+)'
    $files = @(Get-ChildItem -Path $LogsPath -Recurse -File -Include '*.log', '*.txt' -ErrorAction SilentlyContinue)
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $text = $null
        try { $text = Get-Content -Raw -Encoding UTF8 -Path $f.FullName } catch { continue }
        if (-not $text) { continue }
        foreach ($m in [regex]::Matches($text, $rx)) {
            $records.Add([PSCustomObject]@{
                Date    = $m.Groups['date'].Value
                Variant = $m.Groups['variant'].Value
                Ms      = [int]$m.Groups['ms'].Value
                Source  = $f.Name
            })
        }
    }
    $rows = $records | Group-Object Date, Variant | ForEach-Object {
        $g = $_.Group
        [PSCustomObject]@{
            Date    = $g[0].Date
            Variant = $g[0].Variant
            Samples = @($g).Count
            AvgMs   = [int](($g | Measure-Object Ms -Average).Average)
            MinMs   = ($g | Measure-Object Ms -Minimum).Minimum
            MaxMs   = ($g | Measure-Object Ms -Maximum).Maximum
        }
    } | Sort-Object Date, Variant
    $arr = @($rows)
    if ($OutputPath) {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $arr | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputPath -Encoding UTF8
    }
    $arr
}

Export-ModuleMember -Function Get-LaunchTimingProfile

