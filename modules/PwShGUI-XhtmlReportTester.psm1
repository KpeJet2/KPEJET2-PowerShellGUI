# VersionTag: 2605.B5.V46.0
# Module: PwShGUI-XhtmlReportTester
# Purpose: Validate every ~REPORTS/*.xhtml as well-formed XML and check for P032/P033 violations.

function Test-XhtmlReports {
    <#
    .SYNOPSIS
    Validate XHTML reports for well-formedness and SIN P032/P033 compliance.
    .DESCRIPTION
    For each XHTML file under -Path: try to load via [xml], scan inline
    script bodies for unescaped end-tag tokens (P032), and scan for duplicate
    top-level var declarations (P033). Returns one result row per file.
    .EXAMPLE
    Test-XhtmlReports -Path C:\PowerShellGUI\~REPORTS -OutputPath .\reports\xhtml-test.json
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path '~REPORTS'),
        [string]$OutputPath
    )
    if (-not (Test-Path $Path)) { throw "Path not found: $Path" }
    $files = Get-ChildItem -Path $Path -Recurse -Filter '*.xhtml' -File -ErrorAction SilentlyContinue
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $row = [ordered]@{
            File      = $f.FullName
            XmlOk     = $false
            XmlError  = $null
            P032Fail  = $false
            P033Fail  = $false
            DupVars   = @()
        }
        $raw = $null
        try { $raw = Get-Content -Raw -Encoding UTF8 -Path $f.FullName } catch { $row.XmlError = "$_" }
        if ($raw) {
            try { [xml]$null = $raw; $row.XmlOk = $true }
            catch { $row.XmlError = $_.Exception.Message }

            # P032 check: any literal </script or </style inside <script> body
            $sm = [regex]::Matches($raw, '(?is)<script[^>]*>(.*?)</script>')
            foreach ($m in $sm) {
                $body = $m.Groups[1].Value
                # CDATA wrappers are fine, but a *literal* </script not part of the closing tag is the violation.
                if ($body -match '(?i)</(script|style)') { $row.P032Fail = $true; break }
            }
            # P033 check: duplicate top-level var X = ...
            $names = [regex]::Matches($raw, '(?m)^\s*var\s+(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value }
            $dup = $names | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name
            if (@($dup).Count -gt 0) { $row.P033Fail = $true; $row.DupVars = @($dup) }
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

Export-ModuleMember -Function Test-XhtmlReports

