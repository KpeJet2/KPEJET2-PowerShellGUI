# VersionTag: 2604.B0.V1.0
#Requires -Version 5.1
<#
.SYNOPSIS  Security Code Scanner — scans workspace for common security vulnerabilities.
.DESCRIPTION
    Complements Invoke-SINPatternScanner by focusing on OWASP Top 10,
    credential leaks, injection risks, and insecure patterns.
    Findings are logged and optionally registered as SIN incidents.

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace. Default: script parent directory.
.PARAMETER OutputJson
    Path to write JSON results. Default: temp/security-scan-results.json.
.PARAMETER AutoRegister
    Create SIN incidents for each finding.
.PARAMETER FailOnCritical
    Exit code 1 if CRITICAL findings detected.
.PARAMETER Quiet
    Suppress console output.
#>
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputJson    = '',
    [switch]$AutoRegister,
    [switch]$FailOnCritical,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve paths ──
if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $OutputJson = Join-Path (Join-Path $WorkspacePath 'temp') 'security-scan-results.json'
}
$tempDir = Split-Path $OutputJson -Parent
if (-not (Test-Path $tempDir)) { $null = New-Item -ItemType Directory -Path $tempDir -Force }

# ── Security patterns ──
$securityPatterns = @(
    @{ Id='SEC-001'; Severity='CRITICAL'; Name='Hardcoded Password/Token';
       Regex='(?i)(password|passwd|secret|api_?key|token|bearer)\s*=\s*[''"][^''"]{4,}[''"]';
       Exclude='\.tests?\.ps1$|\.md$|\.json$|sin_registry' }

    @{ Id='SEC-002'; Severity='CRITICAL'; Name='SSL Certificate Bypass';
       Regex='ServerCertificateValidationCallback\s*=|SkipCertificateCheck';
       Exclude='\.md$' }

    @{ Id='SEC-003'; Severity='HIGH'; Name='Invoke-Expression (Code Injection)';
       Regex='(?<!\#.*)\bInvoke-Expression\b|\biex\s+\$';
       Exclude='\.tests?\.ps1$|\.md$|SIN-PATTERN|CheatSheet' }

    @{ Id='SEC-004'; Severity='HIGH'; Name='ConvertTo-SecureString Plaintext';
       Regex='ConvertTo-SecureString\s+-String\s';
       Exclude='\.md$' }

    @{ Id='SEC-005'; Severity='HIGH'; Name='Unrestricted ExecutionPolicy';
       Regex='Set-ExecutionPolicy\s+(Unrestricted|Bypass)\s+-Force';
       Exclude='\.md$|\.bat$' }

    @{ Id='SEC-006'; Severity='MEDIUM'; Name='No TLS Version Enforcement';
       Regex='\[Net\.ServicePointManager\]::SecurityProtocol\s*=.*Ssl3|Tls\b[^12]';
       Exclude='\.md$' }

    @{ Id='SEC-007'; Severity='MEDIUM'; Name='Start-Process with User Credentials';
       Regex='Start-Process.*-Credential\b';
       Exclude='\.md$' }

    @{ Id='SEC-008'; Severity='MEDIUM'; Name='Unvalidated Path Join';
       Regex='Join-Path\s.*\$_(\.|\[)|Join-Path\s.*\$input';
       Exclude='\.md$' }

    @{ Id='SEC-009'; Severity='LOW'; Name='Write-Host with Sensitive Context';
       Regex='Write-Host.*\$(password|secret|token|apikey)';
       Exclude='\.md$' }

    @{ Id='SEC-010'; Severity='HIGH'; Name='Net.WebClient DownloadString/File';
       Regex='Net\.WebClient.*Download(String|File)|Invoke-WebRequest.*\|\s*iex';
       Exclude='\.md$|\.tests?\.ps1$' }
)

# ── File discovery ──
$includeExts = @('*.ps1','*.psm1','*.psd1','*.ps1xml')
$excludeDirs = @('.git','.history','.venv','node_modules','~DOWNLOADS','~REPORTS','checkpoints','UPM')

$allFiles = @()
foreach ($ext in $includeExts) {
    $found = Get-ChildItem -Path $WorkspacePath -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
    $allFiles += @($found)
}

# Filter out excluded directories
$allFiles = @($allFiles | Where-Object {
    $path = $_.FullName
    $excluded = $false
    foreach ($d in $excludeDirs) {
        if ($path -like "*\$d\*") { $excluded = $true; break }
    }
    -not $excluded
})

if (-not $Quiet) {
    Write-Host "Security Code Scanner v2604.B0.V1.0" -ForegroundColor Cyan
    Write-Host "Workspace: $WorkspacePath"
    Write-Host "Files to scan: $(@($allFiles).Count)"
    Write-Host "Patterns: $(@($securityPatterns).Count)"
    Write-Host ('-' * 60)
}

# ── Scan ──
$findings = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($pattern in $securityPatterns) {
    $patternRegex = [regex]::new($pattern.Regex, 'IgnoreCase')
    $excludeRegex = if ($pattern.Exclude) { [regex]::new($pattern.Exclude, 'IgnoreCase') } else { $null }

    foreach ($file in $allFiles) {
        if ($null -ne $excludeRegex -and $excludeRegex.IsMatch($file.FullName)) { continue }

        try {
            $lines = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction Stop
        }
        catch { continue }

        for ($i = 0; $i -lt @($lines).Count; $i++) {
            $line = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            # Skip comment-only lines
            if ($line -match '^\s*#') { continue }

            if ($patternRegex.IsMatch($line)) {
                $trimmed = $line.Trim()
                $findings += [PSCustomObject]@{
                    PatternId = $pattern.Id
                    Severity  = $pattern.Severity
                    Name      = $pattern.Name
                    File      = $file.FullName.Replace($WorkspacePath, '').TrimStart('\\')
                    Line      = ($i + 1)
                    Content   = $trimmed.Substring(0, [Math]::Min(120, $trimmed.Length))
                }
            }
        }
    }
}
$sw.Stop()

# ── Summary ──
$critCount = @($findings | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
$highCount = @($findings | Where-Object { $_.Severity -eq 'HIGH' }).Count
$medCount  = @($findings | Where-Object { $_.Severity -eq 'MEDIUM' }).Count
$lowCount  = @($findings | Where-Object { $_.Severity -eq 'LOW' }).Count

$summary = [PSCustomObject]@{
    ScanDate     = Get-Date -Format 'o'
    Workspace    = $WorkspacePath
    FilesScanned = @($allFiles).Count
    Patterns     = @($securityPatterns).Count
    TotalFindings = @($findings).Count
    Critical     = $critCount
    High         = $highCount
    Medium       = $medCount
    Low          = $lowCount
    ElapsedMs    = $sw.ElapsedMilliseconds
    Findings     = $findings
}

# ── Output ──
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputJson -Encoding UTF8

if (-not $Quiet) {
    Write-Host ''
    Write-Host "Scan complete in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    Write-Host "  CRITICAL: $critCount | HIGH: $highCount | MEDIUM: $medCount | LOW: $lowCount"
    Write-Host "  Total findings: $(@($findings).Count)"
    Write-Host "  Results: $OutputJson"

    if (@($findings).Count -gt 0) {
        Write-Host ''
        $findings | Sort-Object Severity, PatternId | Format-Table -Property PatternId, Severity, File, Line, Name -AutoSize | Out-String -Width 200 | Write-Host
    }
}

# ── Auto-register SIN incidents ──
if ($AutoRegister -and @($findings).Count -gt 0) {
    $sinDir = Join-Path $WorkspacePath 'sin_registry'
    if (Test-Path $sinDir) {
        $stamp = Get-Date -Format 'yyyyMMdd'
        foreach ($f in $findings) {
            $sinId = "SIN-$stamp-$($f.PatternId)-$(($f.File -replace '[\\\/\.]','-').Substring(0,[Math]::Min(30,($f.File -replace '[\\\/\.]','-').Length)))"
            $sinPath = Join-Path $sinDir "$sinId.json"
            if (-not (Test-Path $sinPath)) {
                $sinEntry = [PSCustomObject]@{
                    sin_id      = $sinId
                    pattern_id  = $f.PatternId
                    severity    = $f.Severity
                    file        = $f.File
                    line        = $f.Line
                    description = $f.Name
                    detail      = $f.Content
                    detected_at = Get-Date -Format 'o'
                    status      = 'OPEN'
                }
                $sinEntry | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $sinPath -Encoding UTF8
            }
        }
        if (-not $Quiet) { Write-Host "SIN incidents registered in: $sinDir" -ForegroundColor Yellow }
    }
}

# ── Exit code ──
if ($FailOnCritical -and $critCount -gt 0) {
    Write-Host "FAIL: $critCount CRITICAL security findings detected" -ForegroundColor Red
    exit 1
}

return $summary
