# VersionTag: 2605.B5.V46.0
# Module: PwShGUI-LegacyEncoding
# Purpose: Detect and repair P006 (no-BOM UTF-8 with Unicode) and P023 (double-encoded UTF-8).
# History: V2.0 (2026-04-30) - P039 fix: strip BOM before Win-1252 round-trip.

function Test-FileEncoding {
    <#
    .SYNOPSIS
    Inspect a file's byte signature and report encoding facts.
    .DESCRIPTION
    Returns BOM flag, presence of non-ASCII bytes, and detection of the
    P023 "C3 A2 E2 80" double-encoding signature.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $hasNonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 0x7F) { $hasNonAscii = $true; break } }
    $doubleEncoded = $false
    for ($i = 0; $i -lt ($bytes.Length - 3); $i++) {
        if ($bytes[$i] -eq 0xC3 -and $bytes[$i + 1] -eq 0xA2 -and $bytes[$i + 2] -eq 0xE2 -and $bytes[$i + 3] -eq 0x80) {
            $doubleEncoded = $true; break
        }
    }
    [PSCustomObject]@{
        Path          = $Path
        HasBom        = $hasBom
        HasNonAscii   = $hasNonAscii
        DoubleEncoded = $doubleEncoded
        SizeBytes     = $bytes.Length
        NeedsFix      = (($hasNonAscii -and -not $hasBom) -or $doubleEncoded)
    }
}

function Convert-LegacyEncoding {
    <#
    .SYNOPSIS
    Repair P006 (no-BOM with Unicode) and P023 (double-encoded UTF-8) files.
    .DESCRIPTION
    For each input file: if double-encoded, round-trip Win-1252 -> UTF-8.
    If non-ASCII without BOM, re-save as UTF-8 with BOM.
    Always preserves CRLF line endings on Windows. Use -WhatIf to preview.
    .EXAMPLE
    Get-ChildItem .\modules -Filter *.psm1 | Convert-LegacyEncoding -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [string[]]$Path
    )
    process {
        foreach ($p in $Path) {
            if (-not (Test-Path $p)) { continue }
            $info = Test-FileEncoding -Path $p
            if (-not $info.NeedsFix) { continue }
            if (-not $PSCmdlet.ShouldProcess($p, 'Convert encoding')) { continue }
            $bytes = [System.IO.File]::ReadAllBytes($p)
            # P039: strip leading UTF-8 BOM before round-tripping; otherwise
            # GetEncoding(1252).GetBytes(U+FEFF) produces 0x3F ('?') and
            # corrupts the first character of the file.
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $stripped = New-Object byte[] ($bytes.Length - 3)
                [Array]::Copy($bytes, 3, $stripped, 0, $bytes.Length - 3)
                $bytes = $stripped
            }
            $text = $null
            if ($info.DoubleEncoded) {
                $utf8 = [System.Text.Encoding]::UTF8.GetString($bytes)
                $win1252Bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes($utf8)
                $text = [System.Text.Encoding]::UTF8.GetString($win1252Bytes)
            } else {
                $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            }
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($p, $text, $utf8Bom)
            Write-Verbose "Repaired: $p"
            [PSCustomObject]@{ Path = $p; FixedDoubleEncoded = $info.DoubleEncoded; AddedBom = (-not $info.HasBom) }
        }
    }
}

Export-ModuleMember -Function Test-FileEncoding, Convert-LegacyEncoding

