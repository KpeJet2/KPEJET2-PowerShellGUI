# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-05-02
# SupportsPS7.6TestedDate: 2026-05-02
# FileRole: Module
# VersionBuildHistory:
#   2605.B1.V33.1  2026-05-02  Add MajorVersion/FileName validation (P009 path-traversal guard); use ZipArchive entry stream on PS7+ to avoid full extraction; PS5.1 fallback retained.
#   2604.B3.V33.0  2026-04-28  PS7.6/PS5.1 validation metadata added.

function Get-HistoryFileFromZip {
    <#
    .SYNOPSIS
        Read a single named file out of a versioned history archive.
    .PARAMETER MajorVersion
        Major version label, e.g. 'V31'. Must match ^V\d+$.
    .PARAMETER FileName
        Leaf file name to extract from the archive. Must contain no path separators.
    .PARAMETER ArchiveDir
        Directory containing 'history-<MajorVersion>.zip'. Defaults to ../history-archives.
    .NOTES
        On PS7+ the archive entry is streamed directly. On PS5.1 the archive is
        extracted to a per-call temp directory which is removed before returning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^V\d+$')]
        [string]$MajorVersion,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FileName,

        [string]$ArchiveDir = (Join-Path $PSScriptRoot '..\history-archives')
    )

    # P009 path-traversal guard: reject any separator or parent-dir token.
    if ($FileName -match '[\\/]' -or $FileName -match '\.\.') {
        throw "Invalid FileName (path components not allowed): $FileName"
    }

    $zipPath = Join-Path $ArchiveDir ("history-" + $MajorVersion + ".zip")
    if (-not (Test-Path -LiteralPath $zipPath)) { throw "Archive not found: $zipPath" }

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # PS7.6 primary path: stream entry directly without extracting whole archive.
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $entry = $zip.Entries | Where-Object { $_.Name -eq $FileName } | Select-Object -First 1
            if (-not $entry) { throw "File not found in archive: $FileName" }
            $stream = $entry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($stream)
                try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
    }

    # PS5.1 fallback: extract to scoped temp dir, read, clean up.
    $tempDir = Join-Path $env:TEMP ([guid]::NewGuid().ToString())
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempDir)
        $target = Join-Path $tempDir $FileName
        if (-not (Test-Path -LiteralPath $target)) { throw "File not found in archive: $FileName" }
        return (Get-Content -LiteralPath $target -Raw -Encoding UTF8)
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


<# Outline:
    Single-function module that retrieves the contents of a single named file from a versioned
    history zip archive (e.g. history-V31.zip). PS7.6 path streams the ZipArchive entry directly;
    PS5.1 fallback extracts to a scoped temp dir and cleans up afterwards.
#>

<# Problems:
    None. Path-traversal guard rejects FileName values containing separators or '..'.
    Archive integrity (CRC) is delegated to System.IO.Compression.
#>

<# ToDo:
    Optional: stream large entries to a caller-provided StringBuilder/Stream for memory efficiency.
#>
Export-ModuleMember -Function Get-HistoryFileFromZip



