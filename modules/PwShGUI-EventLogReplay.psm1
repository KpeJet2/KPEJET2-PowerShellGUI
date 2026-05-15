# VersionTag: 2605.B5.V46.0
# Module: PwShGUI-EventLogReplay
# Purpose: Replay captured event JSON envelopes for regression diffing.

function Invoke-EventLogReplay {
    <#
    .SYNOPSIS
    Replay events from sovereign-kernel/events/*.json into a target adapter and capture output.
    .DESCRIPTION
    Reads each event envelope, calls -AdapterCommand (default Write-EventEnvelope),
    captures success/failure, and returns a row per event for diffing.
    Use -OutputPath to persist a baseline.
    #>
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param(
        [string]$EventsPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'sovereign-kernel\events'),
        [string]$AdapterCommand = 'Write-EventEnvelope',
        [string]$OutputPath
    )
    if (-not (Test-Path $EventsPath)) { Write-Warning "EventsPath not found: $EventsPath"; return @() }
    $files = @(Get-ChildItem -Path $EventsPath -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue)
    $cmd = Get-Command -Name $AdapterCommand -ErrorAction SilentlyContinue
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $row = [ordered]@{ File = $f.FullName; Ok = $false; Error = $null; AdapterFound = [bool]$cmd }
        try {
            $envelope = Get-Content -Raw -Encoding UTF8 -Path $f.FullName | ConvertFrom-Json
            if ($cmd) {
                & $cmd -InputObject $envelope -ErrorAction Stop | Out-Null
            }
            $row.Ok = $true
        } catch {
            $row.Error = "$_"
        }
        $rows.Add([PSCustomObject]$row)
    }
    $arr = $rows.ToArray()
    if ($OutputPath) {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $arr | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputPath -Encoding UTF8
    }
    $arr
}

Export-ModuleMember -Function Invoke-EventLogReplay

