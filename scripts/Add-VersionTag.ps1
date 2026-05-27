# VersionTag: 2605.B5.V46.0
# Insert a VersionTag header into specified files. Encoding-preserving.
# Skips files that already have a VersionTag.

[CmdletBinding()]
param(
    [string]$TargetVersion = '2605.B5.V46.0',
    [string]$LogPath       = 'C:\PowerShellGUI\temp\add-tag-log.csv'
)

$ErrorActionPreference = 'Stop'
$ws = 'C:\PowerShellGUI'

# (b) source candidates + (c) .github customisation files + (d) safe-to-tag agent JSON configs.
# Each entry = relative path. Comment style inferred by extension; JSON uses _versionTag property.
$targets = @(
    # (b) source
    'agents/PipelineSteering/core/PipelineSteering.psm1',
    'code-analysis.xhtml',
    '~README.md/Dependency-Visualisation.html',
    # (c) .github
    '.github/agents/IoT-NetOps.agent.md',
    '.github/agents/Shop-ListedItemsBot.agent.md',
    '.github/instructions/KpeAgentInstructs.instructions.md',
    '.github/instructions/Sin-Ai-Voidance.instructions.md',
    '.github/prompts/Pipeline testplan.prompt.md',
    '.github/prompts/shop-listeditems-compare.prompt.md',
    # (d) agent-system JSON configs (mutating but project-owned)
    'agents/focalpoint-null/config/agent_registry.json',
    'agents/focalpoint-null/checkpoints/_index.json',
    'agents/focalpoint-null/todo/ADMIN-TODO.json',
    'agents/PipelineSteering/config/steering-config.json',
    'config/agent-call-stats.json'
)

function Get-FileEncodingInfo {
    param([string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 4
        $n = $fs.Read($buf, 0, 4)
    } finally { $fs.Dispose() }
    if ($n -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) {
        return @{ Name='utf8-bom';  Encoding=[System.Text.UTF8Encoding]::new($true) }
    }
    if ($n -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) {
        return @{ Name='utf16-le';  Encoding=[System.Text.UnicodeEncoding]::new($false,$true) }
    }
    if ($n -ge 2 -and $buf[0] -eq 0xFE -and $buf[1] -eq 0xFF) {
        return @{ Name='utf16-be';  Encoding=[System.Text.UnicodeEncoding]::new($true,$true) }
    }
    return @{ Name='utf8-nobom'; Encoding=[System.Text.UTF8Encoding]::new($false) }
}

$detect = [regex]'VersionTag:\s*[0-9]{4}\.B\d+\.[Vv]\d+(?:\.\d+)?'
$results = New-Object System.Collections.Generic.List[object]

foreach ($rel in $targets) {
    $abs = Join-Path $ws ($rel -replace '/', '\')
    $row = [ordered]@{ Path=$rel; Action=''; Encoding=''; Detail='' }

    if ($rel -match '^todo/(Bug|Bugs2FIX)-.*\.json$') {
        $row.Action = 'exempt-todo-bug-json'
        $results.Add([pscustomobject]$row) | Out-Null
        continue
    }

    if (-not (Test-Path -LiteralPath $abs)) {
        $row.Action = 'missing'
    } else {
        try {
            $enc  = Get-FileEncodingInfo -Path $abs
            $row.Encoding = $enc.Name
            $text = [System.IO.File]::ReadAllText($abs, $enc.Encoding)
            if ($detect.IsMatch($text)) { $row.Action = 'already-tagged'; }
            else {
                $ext = [System.IO.Path]::GetExtension($rel).ToLower()
                $newText = $null
                switch -Regex ($ext) {
                    '^\.(ps1|psm1|psd1)$' {
                        $hdr = "# VersionTag: $TargetVersion`r`n"
                        $newText = $hdr + $text
                    }
                    '^\.(md)$' {
                        # Place after YAML front matter if present
                        $hdr = "<!-- VersionTag: $TargetVersion -->`r`n"
                        if ($text -match '^---\r?\n[\s\S]*?\r?\n---\r?\n') {
                            $fm = $Matches[0]
                            $newText = $fm + $hdr + $text.Substring($fm.Length)
                        } else {
                            $newText = $hdr + $text
                        }
                    }
                    '^\.(xhtml|html|htm)$' {
                        $hdr = "<!-- VersionTag: $TargetVersion -->`r`n"
                        # Insert after XML/DOCTYPE declarations if present
                        $rxLead = [regex]'^(?:\xEF\xBB\xBF)?(?:\s*<\?xml[^?]*\?>\s*)?(?:\s*<!DOCTYPE[^>]*>\s*)?'
                        $m = $rxLead.Match($text)
                        if ($m.Success -and $m.Length -gt 0) {
                            $newText = $text.Substring(0, $m.Length) + $hdr + $text.Substring($m.Length)
                        } else {
                            $newText = $hdr + $text
                        }
                    }
                    '^\.json$' {
                        # Insert "_versionTag" as first property of root object (preserve object syntax).
                        # Strategy: locate first '{' and inject after it.
                        $idx = $text.IndexOf('{')
                        if ($idx -lt 0) { $row.Action='skip-non-object-json'; break }
                        # Find indentation of next non-whitespace line for pretty-print
                        $insert = "`r`n  ""_versionTag"": ""$TargetVersion"","
                        $tail   = $text.Substring($idx + 1)
                        # If next non-WS char is '}', omit comma
                        $trim = $tail.TrimStart()
                        if ($trim.StartsWith('}')) {
                            $insert = "`r`n  ""_versionTag"": ""$TargetVersion"""
                        }
                        $newText = $text.Substring(0, $idx + 1) + $insert + $tail
                        # Validate JSON parses
                        try { $null = $newText | ConvertFrom-Json -ErrorAction Stop }
                        catch { $row.Action='skip-json-parse-fail'; $row.Detail=$_.Exception.Message; $newText=$null }
                    }
                    default { $row.Action='skip-unknown-ext' }
                }
                if ($newText -and $row.Action -eq '') {
                    [System.IO.File]::WriteAllText($abs, $newText, $enc.Encoding)
                    $row.Action = 'tagged'
                }
            }
        } catch {
            $row.Action = 'error'
            $row.Detail = $_.Exception.Message
        }
    }
    $results.Add([pscustomobject]$row) | Out-Null
}

$results | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "================ Add-VersionTag Summary ================"
$results | Group-Object Action | Sort-Object Count -Descending |
    ForEach-Object { '{0,-22} {1,3}' -f $_.Name, $_.Count } | Out-Host
Write-Host ""
$results | Format-Table Path,Action,Encoding -AutoSize | Out-String -Width 200 | Write-Host
Write-Host ("Log: {0}" -f $LogPath)
