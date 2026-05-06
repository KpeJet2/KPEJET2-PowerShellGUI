# VersionTag: 2605.B2.V31.7
# Module: PwShGUI-SecretScan
# Purpose: Regex sweep for accidentally-committed secrets (extends P001).

$Script:SecretRules = @(
    @{ Id = 'AWS_ACCESS_KEY';   Regex = 'AKIA[0-9A-Z]{16}' },
    @{ Id = 'AZURE_STORAGE';    Regex = 'DefaultEndpointsProtocol=https;AccountName=[A-Za-z0-9]+;AccountKey=[A-Za-z0-9+/=]{20,}' },
    @{ Id = 'GITHUB_PAT';       Regex = 'gh[pousr]_[A-Za-z0-9]{36,}' },
    @{ Id = 'SLACK_TOKEN';      Regex = 'xox[baprs]-[A-Za-z0-9-]{10,}' },
    @{ Id = 'PRIVATE_KEY';      Regex = '-----BEGIN (RSA|EC|OPENSSH|PRIVATE) KEY-----' },
    @{ Id = 'GENERIC_API_KEY';  Regex = '(?i)(api[_-]?key|secret|token)\s*[:=]\s*["\047][A-Za-z0-9_\-]{24,}["\047]' },
    @{ Id = 'JWT';              Regex = 'eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}' }
)

function Invoke-SecretScan {
    <#
    .SYNOPSIS
    Scan files for likely embedded secrets.
    .DESCRIPTION
    Walks -Root, applies a curated rule set, and returns one finding per match
    with file, line, rule id, and a redacted preview.
    .EXAMPLE
    Invoke-SecretScan -Root . -OutputPath .\reports\secrets.json
    #>
    [CmdletBinding()]
    param(
        [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
        [string[]]$Include = @('*.ps1', '*.psm1', '*.psd1', '*.json', '*.xhtml', '*.html', '*.js', '*.ts', '*.bat', '*.cmd', '*.yaml', '*.yml', '*.md', '*.config', '*.env'),
        [string[]]$ExcludeDir = @('.git', 'node_modules', '.venv', 'logs', 'temp', 'checkpoints'),
        [string]$OutputPath
    )
    $files = Get-ChildItem -Path $Root -Recurse -File -Include $Include -ErrorAction SilentlyContinue |
        Where-Object {
            $full = $_.FullName
            -not ($ExcludeDir | Where-Object { $full -like "*\$_\*" })
        }
    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $content = $null
        try { $content = Get-Content -Raw -Encoding UTF8 -Path $f.FullName } catch { continue }
        if (-not $content) { continue }
        foreach ($rule in $Script:SecretRules) {
            try {
                $rx = [regex]::new($rule.Regex)
                foreach ($m in $rx.Matches($content)) {
                    $line = ([regex]::Matches($content.Substring(0, $m.Index), "`n")).Count + 1
                    $preview = $m.Value
                    if ($preview.Length -gt 8) { $preview = $preview.Substring(0, 4) + '...' + $preview.Substring($preview.Length - 4) }
                    $findings.Add([PSCustomObject]@{
                        Rule    = $rule.Id
                        File    = $f.FullName
                        Line    = $line
                        Preview = $preview
                    })
                }
            } catch { Write-Verbose "Bad rule $($rule.Id): $_" }
        }
    }
    $arr = $findings.ToArray()
    if ($OutputPath) {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $arr | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputPath -Encoding UTF8
    }
    $arr
}

Export-ModuleMember -Function Invoke-SecretScan

