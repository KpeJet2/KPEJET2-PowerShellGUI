# VersionTag: 2604.B2.V31.0
# Author: The Establishment
# Date: 2025-06-05
# FileRole: Diagnostics
#Requires -Version 5.1
<#
.SYNOPSIS  Security Integrity Tests for PowerShellGUI workspace.
.DESCRIPTION
    Runs a structured suite of security-focused checks against the
    PowerShellGUI workspace, covering:
      1. Hardcoded credential detection (P001/OWASP A02)
      2. Unsafe invocation patterns (P010 / OWASP A03 injection)
      3. Path traversal / unvalidated path concatenation (P009 / OWASP A01)
      4. Insecure file encoding (P006/P012/P017)
      5. Sensitive keyword exposure in logs
      6. Vault/AssistedSASC access pattern integrity
      7. Critical module file hash baseline verification
      8. Privilege escalation indicators (unconditional -Force / RunAs)
      9. Invoke-Expression and dynamic scriptblock injection
     10. PKI / certificate export safety (no plaintext private key writes)

    Results are written as a structured JSON report to temp/ and optionally
    to the console. Exit code 1 is returned if any CRITICAL findings exist.

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace. Defaults to parent of $PSScriptRoot.
.PARAMETER OutputJson
    Path to write JSON results. Default: temp\security-integrity-report.json
.PARAMETER FailOnCritical
    When set, exits with code 1 if CRITICAL findings are detected.
.PARAMETER Quiet
    Suppress console output.

.NOTES
    Complements Invoke-SINPatternScanner.ps1.
    Integration: add as a phase in Run-AllTests.ps1 between PenanceScanner and smoke tests.
    SIN governance: avoids P001,P002,P003,P005,P006,P007,P009,P010,P012,P015,P018
#>
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputJson    = '',
    [switch]$FailOnCritical,
    [switch]$Quiet,
    [ValidateSet('Standard','Advisory','Audit')][string]$Mode = 'Standard'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($OutputJson)) {
    $OutputJson = Join-Path (Join-Path $WorkspacePath 'temp') 'security-integrity-report.json'
}

# ── SecDump log: individual timestamped log file per run ──────────
$secDumpDir = Join-Path (Join-Path $WorkspacePath 'logs') 'secdump'
if (-not (Test-Path $secDumpDir)) { New-Item -ItemType Directory -Path $secDumpDir -Force | Out-Null }
$secDumpFile = Join-Path $secDumpDir "secdump-$(Get-Date -Format 'yyyyMMdd-HHmm').log"

function Write-SecDumpLog {
    param([string]$Message, [string]$Severity = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Severity] $Message"
    Add-Content -LiteralPath $secDumpFile -Value $entry -Encoding UTF8
}

function Sanitize-SecretValue {
    <# Replace potential secret values with masked placeholders #>
    param([string]$Text)
    # Mask anything that looks like a token/key/password value
    $sanitized = $Text -replace '(?i)(password|secret|token|key|apikey|connectionstring)\s*[:=]\s*\S+', '$1=****'
    $sanitized = $sanitized -replace '(?i)(Bearer\s+)\S+', '${1}****'
    $sanitized = $sanitized -replace '[A-Za-z0-9+/]{40,}={0,2}', '****BASE64****'
    $sanitized
}

Write-SecDumpLog "Security Integrity Scan started | Mode=$Mode | Workspace=$WorkspacePath"

$scanId    = "SECSCAN-$(Get-Date -Format 'yyyyMMddHHmmss')"
$timestamp = [datetime]::UtcNow.ToString('o')
$findings  = [System.Collections.ArrayList]::new()

function Add-Finding {
    param(
        [string]$TestId,
        [string]$Severity,
        [string]$File,
        [int]   $Line,
        [string]$Detail,
        [string]$Remedy
    )
    [void]$findings.Add([PSCustomObject]@{
        testId   = $TestId
        severity = $Severity
        file     = ($File -replace [regex]::Escape($WorkspacePath), '.')
        line     = $Line
        detail   = $Detail
        remedy   = $Remedy
    })
    # Write sanitized finding to secdump log
    $safeDetail = Sanitize-SecretValue $Detail
    Write-SecDumpLog "FINDING [$Severity] $TestId | $(($File -replace [regex]::Escape($WorkspacePath), '.')) L$Line | $safeDetail" $Severity
}

function Write-Log {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Msg, [string]$Color = 'Cyan')
    if (-not $Quiet) { Write-Host $Msg -ForegroundColor $Color }
}

# ── Helper: enumerate source files ──────────────────────────────
function Get-SourceFiles {
    param([string]$Extension = '*.ps1', [string[]]$ExcludeDirs = @('.git','__pycache__','~DOWNLOADS','.venv','node_modules'))
    $allFiles = Get-ChildItem -Path $WorkspacePath -Filter $Extension -Recurse -File -ErrorAction SilentlyContinue
    $allFiles | Where-Object {
        $pathParts = $_.FullName -split '\\|/'
        -not ($ExcludeDirs | Where-Object { $pathParts -contains $_ })
    }
}

$psFiles   = @(Get-SourceFiles '*.ps1') + @(Get-SourceFiles '*.psm1')
$totalFiles = @($psFiles).Count
Write-Log "[$scanId] Scanning $totalFiles PS files in: $WorkspacePath"

# ════════════════════════════════════════════════════════════════
#  TEST 1: Hardcoded credentials / secrets (OWASP A02 / SIN-P001)
# ════════════════════════════════════════════════════════════════
Write-Log '[T1] Hardcoded credential detection...'

$credPatterns = @(
    @{ Pattern = 'password\s*=\s*["''][^"'']{4,}';           Desc = 'Hardcoded password assignment' },
    @{ Pattern = '(api[_-]?key|apikey)\s*=\s*["''][^"'']{4,}'; Desc = 'Hardcoded API key' },
    @{ Pattern = '(?i)secretkey\s*=\s*["''][^"'']{4,}';      Desc = 'Hardcoded secret key' },
    @{ Pattern = '(?i)token\s*=\s*["''][A-Za-z0-9+/]{20,}';  Desc = 'Hardcoded bearer/JWT token' },
    @{ Pattern = 'ConvertTo-SecureString\s+"[^"]';            Desc = 'Plaintext password in ConvertTo-SecureString' },
    @{ Pattern = '(?i)connectionstring\s*=\s*["''][^"'']{10,}'; Desc = 'Hardcoded connection string' }
)

foreach ($f in $psFiles) {
    try {
        $lines = Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $lines) { continue }
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            foreach ($pat in $credPatterns) {
                if ($line -match $pat.Pattern) {
                    Add-Finding 'T1-HARDCODED-CRED' 'CRITICAL' $f.FullName $lineNum $pat.Desc 'Move secrets to vault (AssistedSASC / Set-VaultSecret). Never embed credentials in source.'
                }
            }
        }
    } catch { <# skip unreadable files - non-fatal #> }
}

# ════════════════════════════════════════════════════════════════
#  TEST 2: Invoke-Expression / dynamic injection (OWASP A03 / P010)
# ════════════════════════════════════════════════════════════════
Write-Log '[T2] Invoke-Expression / injection patterns...'

$iexPatterns = @(
    @{ Pattern = '\biex\b|\bInvoke-Expression\b'; Desc = 'Invoke-Expression usage (P010)' },
    @{ Pattern = '\[scriptblock\]::Create\(';      Desc = 'Dynamic scriptblock creation from string' },
    @{ Pattern = 'Invoke-Command.*-ScriptBlock.*\$'; Desc = 'Invoke-Command with variable scriptblock' }
)

foreach ($f in $psFiles) {
    try {
        $lines = Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $lines) { continue }
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            # Skip comment lines
            if ($line.TrimStart() -match '^\s*#') { continue }
            foreach ($pat in $iexPatterns) {
                if ($line -match $pat.Pattern) {
                    Add-Finding 'T2-INJECTION' 'HIGH' $f.FullName $lineNum $pat.Desc 'Replace iex with & operator or named script blocks. Validate all dynamic strings.'
                }
            }
        }
    } catch { <# skip #> }
}

# ════════════════════════════════════════════════════════════════
#  TEST 3: Unvalidated path concatenation (OWASP A01 / P009)
# ════════════════════════════════════════════════════════════════
Write-Log '[T3] Path traversal / unvalidated path concat...'

$pathPatterns = @(
    @{ Pattern = 'Join-Path\s+.*\$(UserInput|inputPath|userPath|inputDir|rawPath)'; Desc = 'Join-Path with unbounded user-input variable' },
    @{ Pattern = '"[A-Za-z]:\\[^"]*\$\{?[A-Za-z]+';                               Desc = 'Hardcoded absolute path with variable interpolation (P015+P009)' },
    @{ Pattern = '\.\.[\\/]';                                                       Desc = 'Directory traversal sequence (..) in path literal' }
)

foreach ($f in $psFiles) {
    try {
        $lines = Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $lines) { continue }
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            if ($line.TrimStart() -match '^\s*#') { continue }
            foreach ($pat in $pathPatterns) {
                if ($line -match $pat.Pattern) {
                    Add-Finding 'T3-PATH-TRAVERSAL' 'HIGH' $f.FullName $lineNum $pat.Desc 'Validate and normalise all paths with [System.IO.Path]::GetFullPath(). Use $PSScriptRoot anchors.'
                }
            }
        }
    } catch { <# skip #> }
}

# ════════════════════════════════════════════════════════════════
#  TEST 4: Plaintext private key writes (cert manager safety)
# ════════════════════════════════════════════════════════════════
Write-Log '[T4] Plaintext private key write detection...'

$pkiPatterns = @(
    @{ Pattern = '\.Export\([^)]*Pfx[^)]*\).*Set-Content|Out-File'; Desc = 'PFX export written directly to file without vault' },
    @{ Pattern = 'ExportPkcs12|ExportCertificate.*private';          Desc = 'PKCS12/private cert export outside vault function' },
    @{ Pattern = '\[byte\[\]\]\$.*privateKey.*Set-Content|Out-File'; Desc = 'Raw private key bytes written to disk' }
)

$certFiles = $psFiles | Where-Object { $_.Name -match 'Cert|PKI|Certificate|Vault' }
foreach ($f in $certFiles) {
    try {
        $lines = Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $lines) { continue }
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            if ($line.TrimStart() -match '^\s*#') { continue }
            foreach ($pat in $pkiPatterns) {
                if ($line -match $pat.Pattern) {
                    Add-Finding 'T4-PLAINTEXT-PRIVKEY' 'CRITICAL' $f.FullName $lineNum $pat.Desc 'Always route private key material through Set-VaultSecret (AssistedSASC). Never write unencrypted key bytes to disk.'
                }
            }
        }
    } catch { <# skip #> }
}

# ════════════════════════════════════════════════════════════════
#  TEST 5: Sensitive keyword leakage in log calls
# ════════════════════════════════════════════════════════════════
Write-Log '[T5] Sensitive keyword exposure in log statements...'

$sensitiveInLogPattern = '(Write-(Host|Output|Verbose|AppLog|CronLog).*)(password|secret|apikey|token|privatekey|pfx|p12)'
foreach ($f in $psFiles) {
    try {
        $lines = Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $lines) { continue }
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            if ($line.TrimStart() -match '^\s*#') { continue }
            if ($line -imatch $sensitiveInLogPattern) {
                Add-Finding 'T5-LOG-EXPOSURE' 'HIGH' $f.FullName $lineNum 'Potential sensitive value logged verbatim' 'Redact sensitive values before logging: show only last 4 chars or hash the value.'
            }
        }
    } catch { <# skip #> }
}

# ════════════════════════════════════════════════════════════════
#  TEST 6: Vault access pattern integrity
#          All AssistedSASC imports must use try/catch (P003)
# ════════════════════════════════════════════════════════════════
Write-Log '[T6] Vault access pattern integrity...'

foreach ($f in $psFiles) {
    try {
        $content = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        # Check: Import-Module AssistedSASC WITHOUT -SilentlyContinue outside a try block
        if ($content -imatch 'Import-Module.*AssistedSASC.*-ErrorAction\s+SilentlyContinue') {
            $lines  = $content -split "`n"
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                if ($line -imatch 'Import-Module.*AssistedSASC.*-ErrorAction\s+SilentlyContinue') {
                    Add-Finding 'T6-VAULT-IMPORT-P003' 'MEDIUM' $f.FullName $lineNum 'Import-Module AssistedSASC with -SilentlyContinue (P003 violation)' 'Wrap in try/catch and log failures explicitly with Write-CronLog -Severity Error.'
                }
            }
        }
        # Check: Get-VaultSecret / Set-VaultSecret called without error handling
        if ($content -imatch '(Get|Set)-VaultSecret') {
            $inTryBlock = $content -imatch 'try\s*\{[^}]*?(Get|Set)-VaultSecret'
            if (-not $inTryBlock) {
                $lineNums = @()
                $lno = 0
                foreach ($line in ($content -split "`n")) {
                    $lno++
                    if ($line -imatch '(Get|Set)-VaultSecret') { $lineNums += $lno }
                }
                foreach ($ln in $lineNums) {
                    Add-Finding 'T6-VAULT-UNGUARDED' 'MEDIUM' $f.FullName $ln 'Vault call outside try/catch — may expose unhandled errors' 'Wrap Get/Set-VaultSecret in try/catch. Log failures with Write-CronLog -Severity Critical.'
                }
            }
        }
    } catch { <# skip #> }
}

# ════════════════════════════════════════════════════════════════
#  TEST 7: Critical module file hash baseline
#          Compares SHA256 of core modules against a stored baseline,
#          or creates the baseline on first run.
# ════════════════════════════════════════════════════════════════
Write-Log '[T7] Critical module hash baseline check...'

$criticalModules = @(
    'modules\AssistedSASC.psm1',
    'modules\CronAiAthon-EventLog.psm1',
    'modules\CronAiAthon-Pipeline.psm1',
    'sovereign-kernel\core\CryptoEngine.psm1',
    'sovereign-kernel\core\LedgerWriter.psm1',
    'sovereign-kernel\SovereignKernel.psm1'
)

$baselineFile = Join-Path (Join-Path $WorkspacePath 'temp') 'security-hash-baseline.json'
$currentHashes = [ordered]@{}
foreach ($rel in $criticalModules) {
    $full = Join-Path $WorkspacePath $rel
    if (Test-Path $full) {
        try {
            $hash = (Get-FileHash -Path $full -Algorithm SHA256).Hash
            $currentHashes[$rel] = $hash
        } catch {
            Add-Finding 'T7-HASH-READ-FAIL' 'MEDIUM' $full 0 "Could not hash critical module: $_" 'Check file permissions on critical modules.'
        }
    } else {
        Add-Finding 'T7-MISSING-MODULE' 'HIGH' $full 0 "Critical module not found: $rel" 'Restore missing module from version control.'
    }
}

if (Test-Path $baselineFile) {
    try {
        $baseline = Get-Content $baselineFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($rel in $criticalModules) {
            if (-not $currentHashes.Contains($rel)) { continue }
            $savedHash = if ($baseline.PSObject.Properties[$rel]) { $baseline.$rel } else { $null }
            if ($savedHash -and $savedHash -ne $currentHashes[$rel]) {
                Add-Finding 'T7-HASH-MISMATCH' 'HIGH' (Join-Path $WorkspacePath $rel) 0 "Hash changed since baseline. Saved: $savedHash / Current: $($currentHashes[$rel])" 'Verify the change was intentional. If not, restore from VCS. Update baseline with -UpdateBaseline switch if change is approved.'
            }
        }
    } catch {
        Add-Finding 'T7-BASELINE-READ-FAIL' 'MEDIUM' $baselineFile 0 "Could not read hash baseline: $_" 'Delete and regenerate baseline by re-running this script.'
    }
} else {
    # First run: create baseline
    $currentHashes | ConvertTo-Json -Depth 3 | Set-Content -Path $baselineFile -Encoding UTF8
    Write-Log "[T7] Created new hash baseline at: $baselineFile" 'Yellow'
}

# ════════════════════════════════════════════════════════════════
#  TEST 8: Privilege escalation indicators
# ════════════════════════════════════════════════════════════════
Write-Log '[T8] Privilege escalation indicators...'

$privPatterns = @(
    @{ Pattern = 'Start-Process.*-Verb\s+[''"]?RunAs';          Desc = 'Unconditional RunAs elevation' },
    @{ Pattern = 'Set-ExecutionPolicy\s+(Unrestricted|Bypass)'; Desc = 'Weakening ExecutionPolicy' },
    @{ Pattern = '-AllowClobber\s.*(Force|AllowPrerelease)';    Desc = 'Unconditional module install with AllowClobber+Force' },
    @{ Pattern = 'Disable-WindowsOptionalFeature|Enable-WindowsOptionalFeature'; Desc = 'Windows feature modification requiring elevation' }
)

foreach ($f in $psFiles) {
    try {
        $lines = Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $lines) { continue }
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            if ($line.TrimStart() -match '^\s*#') { continue }
            foreach ($pat in $privPatterns) {
                if ($line -match $pat.Pattern) {
                    Add-Finding 'T8-PRIV-ESCALATION' 'MEDIUM' $f.FullName $lineNum $pat.Desc 'Ensure privilege escalation is guarded by explicit user confirmation or only triggered from trusted code paths.'
                }
            }
        }
    } catch { <# skip #> }
}

# ════════════════════════════════════════════════════════════════
#  TEST 9: Empty catch blocks hiding errors (P002)
# ════════════════════════════════════════════════════════════════
Write-Log '[T9] Empty catch block detection (P002)...'

foreach ($f in $psFiles) {
    try {
        $content = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        $matches = [regex]::Matches($content, '(?s)catch\s*\{(\s*)\}')
        foreach ($m in $matches) {
            $inner = $m.Groups[1].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($inner)) {
                # Compute approximate line number
                $lineNo = ($content.Substring(0, $m.Index) -split "`n").Count
                Add-Finding 'T9-EMPTY-CATCH' 'HIGH' $f.FullName $lineNo 'Empty catch block swallows all errors silently (P002)' 'Add Write-CronLog -Severity Error or at minimum a comment: <# Intentional: non-fatal #>'
            }
        }
    } catch { <# skip #> }
}

# ════════════════════════════════════════════════════════════════
#  TEST 10: Insecure encoding (P006 BOM check for Unicode files)
# ════════════════════════════════════════════════════════════════
Write-Log '[T10] BOM check for Unicode-containing PS files...'

$unicodeRx = [regex]'[\u2500-\u257F\u2600-\u26FF\u2700-\u27BF\u2713\u2714]|\p{Emoji}'
foreach ($f in $psFiles) {
    try {
        $content = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($unicodeRx.IsMatch($content)) {
            # Read raw bytes to check for BOM (EF BB BF)
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            if ($bytes.Length -lt 3 -or -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {  # SIN-EXEMPT: P027 - $bytes[N] with .Length guard on adjacent/same line
                Add-Finding 'T10-MISSING-BOM' 'HIGH' $f.FullName 0 'File contains Unicode characters but is missing UTF-8 BOM (P006). PS 5.1 will misread it.' 'Save file as UTF-8 WITH BOM (BOM = EF BB BF). Use VS Code: File > Save with Encoding > UTF-8 with BOM.'
            }
        }
    } catch { <# skip #> }
}

# ════════════════════════════════════════════════════════════════
#  RESULTS
# ════════════════════════════════════════════════════════════════
$criticals = @($findings | Where-Object { $_.severity -eq 'CRITICAL' })
$highs     = @($findings | Where-Object { $_.severity -eq 'HIGH' })
$mediums   = @($findings | Where-Object { $_.severity -eq 'MEDIUM' })
$totalFin  = @($findings).Count

$report = [ordered]@{
    scanId       = $scanId
    timestamp    = $timestamp
    workspacePath= $WorkspacePath
    filesScanned = $totalFiles
    summary      = [ordered]@{
        total    = $totalFin
        critical = @($criticals).Count
        high     = @($highs).Count
        medium   = @($mediums).Count
    }
    findings     = @($findings)
}

$reportDir = Split-Path $OutputJson -Parent
if (-not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputJson -Encoding UTF8

# ── Console summary ─────────────────────────────────────────────
if (-not $Quiet) {
    $sepLine = '═' * 60
    Write-Host $sepLine -ForegroundColor DarkCyan
    Write-Host " SECURITY INTEGRITY SCAN COMPLETE  [$scanId]" -ForegroundColor Cyan
    Write-Host $sepLine -ForegroundColor DarkCyan
    Write-Host (" Files scanned : {0}" -f $totalFiles)
    Write-Host (" Total findings: {0}" -f $totalFin)
    if (@($criticals).Count -gt 0) {
        Write-Host (" CRITICAL      : {0}" -f @($criticals).Count) -ForegroundColor Red
    }
    if (@($highs).Count -gt 0) {
        Write-Host (" HIGH          : {0}" -f @($highs).Count)     -ForegroundColor Yellow
    }
    if (@($mediums).Count -gt 0) {
        Write-Host (" MEDIUM        : {0}" -f @($mediums).Count)   -ForegroundColor Magenta
    }
    if ($totalFin -eq 0) {
        Write-Host ' No security findings.' -ForegroundColor Green
    } else {
        Write-Host (" Report        : $OutputJson") -ForegroundColor Gray
        Write-Host ''
        $findings | Sort-Object severity, file, line | ForEach-Object {
            $color = switch ($_.severity) { 'CRITICAL' { 'Red' } 'HIGH' { 'Yellow' } default { 'Magenta' } }
            Write-Host (" [$($_.severity)] $($_.file):$($_.line) - $($_.detail)") -ForegroundColor $color
        }
    }
    Write-Host $sepLine -ForegroundColor DarkCyan
}

if ($FailOnCritical -and @($criticals).Count -gt 0) {
    exit 1
}

# ── SecDump log completion ─────────────────────────────────────────
Write-SecDumpLog "Scan complete | Files=$totalFiles Findings=$totalFin Critical=$(@($criticals).Count) High=$(@($highs).Count) Medium=$(@($mediums).Count)" 'INFO'
Write-SecDumpLog "JSON report: $OutputJson" 'INFO'
Write-SecDumpLog "SecDump logfile: $secDumpFile" 'INFO'

# ── Completion Banner ──────────────────────────────────────────────
if (-not $Quiet) {
    if (Get-Command Write-ProcessBanner -ErrorAction SilentlyContinue) {
        Write-ProcessBanner -ProcessName 'Security Integrity Tests' -Success (@($criticals).Count -eq 0)
    }
    Write-Host " SecDump log: $secDumpFile" -ForegroundColor Gray
}

# ── Open secdump subfolder in Advisory or Audit mode ──────────────
if ($Mode -in @('Advisory','Audit')) {
    if (Test-Path $secDumpDir) {
        Start-Process explorer.exe -ArgumentList $secDumpDir
    }
}

