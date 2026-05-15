<#
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-30)
# SupportsPS7.6: YES(As of: 2026-04-30)
.SYNOPSIS
    PwShGUI-SinFromScan - Convert scanner output rows into SIN registry JSON.
.DESCRIPTION
    Accepts scan output (BugTracker JSON, SyntaxGuard JSON, or PSCustomObject
    array with File, Line, Pattern, Message, Severity) and creates one
    sin_registry/SIN-YYYYMMDDHHmmss-<hash>.json file per finding.
#>
#Requires -Version 5.1

$script:ModuleVersion = '2604.B3.V28.0'

function Get-SinHashId {
    param([string]$Seed)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
    $hash = $sha.ComputeHash($bytes)
    -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })
}

function New-SINFromScan {
    <#
    .SYNOPSIS  Materialise SIN JSON files from scan findings.
    .PARAMETER Findings  Array of objects: File, Line, Pattern, Message, [Severity], [Category]
    .PARAMETER RegistryPath  Default: <ws>\sin_registry
        .DESCRIPTION
      Detailed behaviour: New s i n from scan.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$Findings,
        [string]$WorkspacePath = (Get-Location).Path,
        [string]$RegistryPath,
        [string]$AgentName = 'AutoSinGen'
    )

    begin {
        if (-not $RegistryPath) { $RegistryPath = Join-Path $WorkspacePath 'sin_registry' }
        if (-not (Test-Path $RegistryPath)) {
            if ($PSCmdlet.ShouldProcess($RegistryPath, 'Create')) {
                New-Item -ItemType Directory -Path $RegistryPath -Force | Out-Null
            }
        }
        $created = New-Object System.Collections.Generic.List[string]
        $skipped = 0
    }
    process {
        foreach ($f in @($Findings)) {
            if ($null -eq $f) { continue }
            $props = $f.PSObject.Properties.Name
            $file    = if ($props -contains 'File')     { [string]$f.File }    else { '' }
            $line    = if ($props -contains 'Line')     { [int]$f.Line }       else { 0 }
            $pattern = if ($props -contains 'Pattern')  { [string]$f.Pattern } else { 'UNKNOWN' }
            $msg     = if ($props -contains 'Message')  { [string]$f.Message } else { '' }
            $sev     = if ($props -contains 'Severity') { [string]$f.Severity }else { 'MEDIUM' }
            $cat     = if ($props -contains 'Category') { [string]$f.Category }else { 'scan-finding' }

            if (-not $file -or -not $pattern) { $skipped++; continue }

            $stamp = (Get-Date).ToString('yyyyMMddHHmmss')
            $hash  = Get-SinHashId -Seed "$file|$line|$pattern|$msg"
            $sinId = "SIN-$stamp-$hash"
            $outFile = Join-Path $RegistryPath ("{0}.json" -f $sinId)

            # Idempotency: skip if a SIN with same hash already exists
            $existing = @(Get-ChildItem -Path $RegistryPath -Filter "*$hash.json" -ErrorAction SilentlyContinue)
            if ($existing.Count -gt 0) { $skipped++; continue }

            $sin = [ordered]@{
                sin_id        = $sinId
                title         = "${pattern}: ${msg}"
                category      = $cat
                severity      = $sev
                agent         = $AgentName
                status        = 'OPEN'
                is_resolved   = $false
                file_path     = $file
                line          = $line
                pattern_id    = $pattern
                description   = $msg
                created_at    = (Get-Date).ToUniversalTime().ToString('o')
                source        = 'scan-import'
            }

            if ($PSCmdlet.ShouldProcess($outFile, "Create SIN $sinId")) {
                $sin | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding UTF8
                $created.Add($sinId) | Out-Null
            }
        }
    }
    end {
        [PSCustomObject]@{
            CreatedCount = @($created).Count
            SkippedCount = $skipped
            Created      = @($created)
        }
    }
}

Export-ModuleMember -Function New-SINFromScan

