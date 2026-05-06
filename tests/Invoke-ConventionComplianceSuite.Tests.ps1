# VersionTag: 2604.B2.V31.3
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Test
# VersionBuildHistory:
#   2604.B2.V31.1  2026-04-14  Initial — XHTML structure, VersionTag format, FileRole coverage,
#                               module PSD1 pairing, config JSON validity, filename conventions,
#                               SIN exemption validity, markdown coverage, log infra, manifest alignment
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Convention compliance suite — validates content types, tag structure,
    naming conventions, and pipeline feature alignment across the workspace.
.DESCRIPTION
    Pester 5 test suite covering:
      Section 1  — XHTML structure (XML decl order, VersionTag position,
                   DOCTYPE, xmlns, FileRole tag, XML well-formedness)
      Section 2  — VersionTag format (canonical YYMM.Bx.Vx.x, first-5-lines
                   position, no duplicates)
      Section 3  — FileRole tag coverage (modules, scripts)
      Section 4  — Module .psd1 manifest pairing
      Section 5  — Config JSON parse validity
      Section 6  — Filename conventions (root launchers, config JSON)
      Section 7  — SIN exemption comment validity (P001-P027, SS-001-SS-006)
      Section 8  — Markdown FileRole and VersionTag coverage
      Section 9  — Log infrastructure (secdump dir, daily log naming)
      Section 10 — Manifest alignment (required sections, module counts)

    Tests that detect CURRENT violations will fail intentionally — the
    violation list in each result tells you exactly what needs remediation.
.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.1
    Created  : 2026-04-14
    Requires : Pester 5.0+, PowerShell 5.1+
.EXAMPLE
    Invoke-Pester tests\Invoke-ConventionComplianceSuite.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:Root         = Split-Path $PSScriptRoot -Parent
    $script:ModDir       = Join-Path $script:Root 'modules'
    $script:ScriptDir    = Join-Path $script:Root 'scripts'
    $script:ConfigDir    = Join-Path $script:Root 'config'
    $script:LogsDir      = Join-Path $script:Root 'logs'
    $script:ReadmeMdDir  = Join-Path $script:Root '~README.md'
    $script:ManifestPath = Join-Path $script:ConfigDir 'agentic-manifest.json'

    # Canonical VersionTag format per project standard: YYMM.Bx.Vx.x (e.g. 2604.B2.V31.0)
    $script:VTagFormatPattern = '\d{4}\.B\d+\.V\d+\.\d+'

    # All valid SIN exemption IDs (P001-P027, SS-001-SS-006)
    $script:ValidSinIds = @(
        'P001','P002','P003','P004','P005','P006','P007','P008','P009','P010',
        'P011','P012','P013','P014','P015','P016','P017','P018','P019','P020',
        'P021','P022','P023','P024','P025','P026','P027',
        'SS-001','SS-002','SS-003','SS-004','SS-005','SS-006'
    )

    # XHTML files — exclude auto-generated ~REPORTS and .history snapshots
    $script:XhtmlFiles = @(
        Get-ChildItem $script:Root -Recurse -Filter '*.xhtml' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike '*~REPORTS*'  -and
            $_.FullName -notlike '*\.history*' -and
            $_.FullName -notlike '*\.venv*'
        }
    )

    # All .ps1 / .psm1 — exclude .history, .git, .venv, node_modules
    $script:AllPsFiles = @(
        Get-ChildItem $script:Root -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike '*\.history*'    -and
            $_.FullName -notlike '*\.git*'        -and
            $_.FullName -notlike '*\.venv*'       -and
            $_.FullName -notlike '*node_modules*'
        }
    )

    # Module .psm1 files — exclude template
    $script:ModuleFiles = @(
        Get-ChildItem $script:ModDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '_TEMPLATE*' }
    )

    # Scripts — exclude scaffolding placeholders, cheatsheets, and bulk archive subdirs
    # (scripts\QUICK-APP = 2000+ template files, scripts\windguits = external ui tools)
    $script:ScriptFiles = @(
        Get-ChildItem $script:ScriptDir -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike '*\.history*'             -and
            $_.FullName -notlike '*~REPORTS*'              -and
            $_.FullName -notlike '*\scripts\QUICK-APP\*'  -and
            $_.FullName -notlike '*\scripts\windguits\*'  -and
            $_.FullName -notlike '*\scripts\scripts\*'    -and
            $_.Name     -notlike 'Script-*.ps1'            -and
            $_.Name     -notlike 'PS-CheatSheet*'
        }
    )

    # Files requiring VersionTag — exclude tests/sandbox data, temp, logs, ~REPORTS, bulk
    # archive subdirs (scripts\QUICK-APP = 2000+ template files, scripts\windguits = external tools)
    # Also excludes temp\ (transient working scripts) and any .ps1 files that contain
    # non-PowerShell content (e.g. Invoke-PreCommitValidation.ps1 = JSON report artifact)
    $script:VTagFiles = @(
        $script:AllPsFiles | Where-Object {
            $_.FullName -notlike '*\.history*'               -and
            $_.FullName -notlike '*testing-routine-saves*'  -and
            $_.FullName -notlike '*~REPORTS*'               -and
            $_.FullName -notlike '*\.vscode*'               -and
            $_.FullName -notlike '*\scripts\QUICK-APP\*'   -and
            $_.FullName -notlike '*\scripts\windguits\*'   -and
            $_.FullName -notlike '*\scripts\scripts\*'     -and
            $_.FullName -notlike '*\temp\*'                 -and
            $_.Name     -notlike 'Script-*.ps1'              -and
            $_.Name     -notlike 'Script?.ps1'              -and
            $_.Name     -notlike 'PS-CheatSheet*'           -and
            $_.Name     -notlike '_TEMPLATE*'               -and
            $_.Name     -notlike 'Invoke-PreCommitValidation.ps1'
        }
    )

    # Source files for SIN-EXEMPT scan: modules + scripts only (not tests which contain
    # exemption pattern text in descriptions and chaos-test stubs like R3-StressTest.ps1)
    $script:SinExemptScanFiles = @(
        @($script:ModuleFiles) +
        @($script:ScriptFiles | Where-Object { $_.Name -notlike 'R3-StressTest*' })
    )

    # Config JSON files — exclude manifest history archive
    $script:ConfigJsonFiles = @(
        Get-ChildItem $script:ConfigDir -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\agentic-manifest-history\*' }
    )

    # Root-level .bat launchers
    $script:RootBatFiles = @(
        Get-ChildItem $script:Root -Filter '*.bat' -File -ErrorAction SilentlyContinue
    )

    # Markdown files in ~README.md/ — exclude prompt templates and session notes
    $script:MdFiles = @(
        Get-ChildItem $script:ReadmeMdDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -notlike '*.prompt.md'             -and
            $_.Name -notlike '*SESSION-*'               -and
            $_.Name -notlike '*CFRM ENU-FIX-SESSION*'
        }
    )
}

# =============================================================================
# Section 1 — XHTML Content Conventions
# =============================================================================
Describe 'XHTML Content Conventions' {

    It 'XML declaration is first content (after optional BOM, no preceding comments or whitespace)' {
        $violations = @()
        foreach ($f in $script:XhtmlFiles) {
            try {
                $bytes    = [System.IO.File]::ReadAllBytes($f.FullName)
                $byteLen  = @($bytes).Count
                $offset   = 0
                # Skip UTF-8 BOM (EF BB BF) if present
                if ($byteLen -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                    $offset = 3
                }
                $readLen = [Math]::Min($byteLen - $offset, 300)
                if ($readLen -le 0) { $violations += "$($f.Name): empty file"; continue }
                $head = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $readLen).TrimStart()
                if (-not $head.StartsWith('<?xml')) {
                    $violations += $f.Name
                }
            } catch {
                $violations += "$($f.Name): read error — $($_.Exception.Message)"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'Repo rule: XML declaration must be first content — VersionTag comment goes AFTER <?xml?> (prevents browser render failure)'
    }

    It 'VersionTag comment does not precede the XML declaration' {
        $violations = @()
        foreach ($f in $script:XhtmlFiles) {
            try {
                $bytes   = [System.IO.File]::ReadAllBytes($f.FullName)
                $raw     = [System.Text.Encoding]::UTF8.GetString($bytes)
                $xmlPos  = $raw.IndexOf('<?xml')
                $vtPos   = $raw.IndexOf('VersionTag:')
                if ($vtPos -lt 0 -or $xmlPos -lt 0) { continue }
                if ($vtPos -lt $xmlPos) { $violations += $f.Name }
            } catch {
                $violations += "$($f.Name): read error — $($_.Exception.Message)"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'VersionTag comment must appear AFTER the <?xml?> declaration (P007 + XHTML ordering rule)'
    }

    It 'DOCTYPE declaration present in each XHTML file' {
        $violations = @()
        foreach ($f in $script:XhtmlFiles) {
            try {
                $top = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop | Select-Object -First 8
                if (($top -join ' ') -notmatch 'DOCTYPE') { $violations += $f.Name }
            } catch {
                $violations += "$($f.Name): read error — $($_.Exception.Message)"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'XHTML files require a DOCTYPE declaration'
    }

    It 'html element declares XHTML namespace' {
        $violations = @()
        foreach ($f in $script:XhtmlFiles) {
            try {
                $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                if ($raw -notmatch 'xmlns\s*=\s*"http://www\.w3\.org/1999/xhtml"') {
                    $violations += $f.Name
                }
            } catch {
                $violations += "$($f.Name): read error — $($_.Exception.Message)"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'XHTML root element must declare xmlns="http://www.w3.org/1999/xhtml"'
    }

    It 'FileRole comment tag present in each XHTML file' {
        $violations = @()
        foreach ($f in $script:XhtmlFiles) {
            try {
                $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                if ($raw -notmatch 'FileRole\s*:') { $violations += $f.Name }
            } catch {
                $violations += "$($f.Name): read error — $($_.Exception.Message)"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'Every XHTML file must carry a FileRole tag (P007 extension — e.g. <!-- FileRole: XhtmlTool -->)'
    }

    It 'All XHTML files are well-formed XML' {
        $violations = @()
        foreach ($f in $script:XhtmlFiles) {
            try {
                $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                # Strip DOCTYPE to avoid external entity resolution
                $san = $raw -replace '<!DOCTYPE[^>]+>', ''
                # Substitute common named HTML entities not defined in base XML
                $san = $san -replace '&nbsp;',  '&#160;'
                $san = $san -replace '&copy;',  '&#169;'
                $san = $san -replace '&mdash;', '&#8212;'
                $san = $san -replace '&ndash;', '&#8211;'
                $san = $san -replace '&laquo;', '&#171;'
                $san = $san -replace '&raquo;', '&#187;'
                $san = $san -replace '&trade;', '&#8482;'
                $san = $san -replace '&reg;',   '&#174;'
                $doc = New-Object System.Xml.XmlDocument
                $doc.LoadXml($san)
            } catch {
                $msg = $_.Exception.Message
                # Tolerate residual undeclared HTML entity errors (present when DOCTYPE is valid)
                if ($msg -notmatch '(?i)undeclared entity|entity.*referenced|entity.*declared') {
                    $violations += "$($f.Name): $msg"
                }
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'XHTML files must be well-formed XML (structural errors only — entity errors tolerated with valid DOCTYPE)'
    }
}

# =============================================================================
# Section 2 — VersionTag Format Compliance
# =============================================================================
Describe 'VersionTag Format Compliance' {

    It 'VersionTag present within first 5 lines of every tracked .ps1/.psm1 file' {
        $violations = @()
        foreach ($f in $script:VTagFiles) {
            try {
                $top5 = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop | Select-Object -First 5
                if (($top5 -join ' ') -notmatch 'VersionTag:') {
                    $violations += $f.FullName.Replace($script:Root, '').TrimStart('\', '/')
                }
            } catch {
                $violations += "$($f.Name): read error"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'P007: VersionTag header must appear in the first 5 lines of every script/module'
    }

    It 'VersionTag value matches canonical YYMM.Bx.Vx.x format' {
        $violations = @()
        foreach ($f in $script:VTagFiles) {
            try {
                $top5 = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop | Select-Object -First 5
                foreach ($line in $top5) {
                    if ($line -match '(?i)VersionTag:\s*(.+)$') {
                        $tagVal = $Matches[1].Trim()
                        if ($tagVal -notmatch $script:VTagFormatPattern) {
                            $violations += "$($f.Name): found '$tagVal' (expected e.g. '2604.B2.V31.0')"
                        }
                        break
                    }
                }
            } catch {
                $violations += "$($f.Name): read error"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'VersionTag must match YYMM.Bx.Vx.x — always uppercase B and V (e.g. 2604.B2.V31.0)'
    }

    It 'No file has duplicate VersionTag header lines' {
        $violations = @()
        foreach ($f in $script:VTagFiles) {
            try {
                # Only check the first 10 lines (header zone) to avoid false positives from
                # functions that reference VersionTag as a template string in the script body
                $headerLines = Get-Content -LiteralPath $f.FullName -TotalCount 10 -Encoding UTF8 -ErrorAction Stop
                $tagHits = @($headerLines | Where-Object { $_ -match '(?i)^\s*#\s*VersionTag:' })
                if (@($tagHits).Count -gt 1) {
                    $violations += "$($f.Name) ($(@($tagHits).Count) occurrences in first 10 lines)"
                }
            } catch {
                $violations += "$($f.Name): read error"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'Duplicate VersionTag lines indicate conflicting history entries; keep only the current one'
    }
}

# =============================================================================
# Section 3 — FileRole Tag Coverage
# =============================================================================
Describe 'FileRole Tag Coverage' {

    It 'All modules/*.psm1 (non-template) have a FileRole tag' {
        $violations = @()
        foreach ($f in $script:ModuleFiles) {
            try {
                $top20 = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop | Select-Object -First 20
                if (($top20 -join ' ') -notmatch 'FileRole\s*:') {
                    $violations += $f.Name
                }
            } catch {
                $violations += "$($f.Name): read error"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'FileRole tag required in all module files (e.g. # FileRole: Module)'
    }

    It 'All scripts/*.ps1 (non-scaffolding) have a FileRole tag' {
        $violations = @()
        foreach ($f in $script:ScriptFiles) {
            try {
                $top20 = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop | Select-Object -First 20
                if (($top20 -join ' ') -notmatch 'FileRole\s*:') {
                    $violations += $f.FullName.Replace($script:Root,'').TrimStart('\','/')
                }
            } catch {
                $violations += "$($f.Name): read error"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'FileRole tag required in non-scaffolding scripts (e.g. # FileRole: Pipeline)'
    }
}

# =============================================================================
# Section 4 — Module PSD1 Manifest Pairing
# =============================================================================
Describe 'Module PSD1 Manifest Pairing' {

    It 'Every modules/*.psm1 (non-template) has a paired .psd1 manifest file' {
        $missing = @(
            $script:ModuleFiles | Where-Object {
                $psd1 = Join-Path $_.DirectoryName ($_.BaseName + '.psd1')
                -not (Test-Path -LiteralPath $psd1)
            }
        )
        $missing | ForEach-Object { $_.Name } | Should -BeNullOrEmpty -Because 'Each module needs a .psd1 manifest (PowerShellVersion, Author, FunctionsToExport)'
    }
}

# =============================================================================
# Section 5 — Config JSON Parse Validity
# =============================================================================
Describe 'Config JSON Parse Validity' {

    It 'All config/*.json files (excluding manifest history) parse as valid JSON' {
        $violations = @()
        foreach ($f in $script:ConfigJsonFiles) {
            try {
                $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                $null = $raw | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $violations += "$($f.Name): $($_.Exception.Message)"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'All config JSON files must be valid JSON (parseable by ConvertFrom-Json)'
    }
}

# =============================================================================
# Section 6 — Filename Conventions
# =============================================================================
Describe 'Filename Conventions' {

    It 'Root .bat launchers follow approved naming prefix (Launch-*, SmokeTest-*, Start-*, etc.)' {
        $allowedPattern = '^(Launch|SmokeTest|Test|Start|Run|Install|Setup|View)-'
        $violations = @(
            $script:RootBatFiles | Where-Object { $_.Name -notmatch $allowedPattern }
        )
        $violations | ForEach-Object { $_.Name } | Should -BeNullOrEmpty -Because 'Root .bat files must use an approved verb prefix (Launch-*, SmokeTest-*, Start-*, etc.)'
    }

    It 'Config JSON filenames contain no spaces or parentheses' {
        $violations = @(
            $script:ConfigJsonFiles | Where-Object { $_.Name -match '[\s\(\)]' }
        )
        $violations | ForEach-Object { $_.Name } | Should -BeNullOrEmpty -Because 'Config JSON names must not contain spaces or parentheses (breaks Join-Path and -LiteralPath patterns)'
    }

    It 'XHTML filenames contain no spaces' {
        $violations = @(
            $script:XhtmlFiles | Where-Object { $_.Name -match '\s' }
        )
        $violations | ForEach-Object { $_.Name } | Should -BeNullOrEmpty -Because 'XHTML filenames must not contain spaces'
    }
}

# =============================================================================
# Section 7 — SIN Exemption Comment Validity
# =============================================================================
Describe 'SIN Exemption Comment Validity' {

    It 'All SIN-EXEMPT comments reference known pattern IDs (P001-P027 or SS-001-SS-006)' {
        $violations = @()
        foreach ($f in $script:SinExemptScanFiles) {
            try {
                $content      = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                $exemptHits   = [regex]::Matches($content, 'SIN-EXEMPT:\s*(P\d{3}|SS-\d{3})')
                foreach ($hit in $exemptHits) {
                    $id = $hit.Groups[1].Value
                    if ($script:ValidSinIds -notcontains $id) {
                        $violations += "$($f.Name): unknown SIN ID '$id'"
                    }
                }
            } catch {
                $violations += "$($f.Name): read error — $($_.Exception.Message)"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'SIN-EXEMPT comments must reference valid P001-P027 or SS-001-SS-006 IDs only'
    }

    It 'SIN-EXEMPT comments in modules and scripts follow canonical format' {
        $violations = @()
        foreach ($f in $script:SinExemptScanFiles) {
            try {
                $lines = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop
                $lineNum = 0
                foreach ($line in $lines) {
                    $lineNum++
                    # Skip comment explanation lines (they may have SIN-EXEMPT in prose)
                    if ($line -match '(?i)SIN-EXEMPT(?!:\s*(?:P\d{3}|SS-\d{3}))') {
                        # Only flag if it looks like an exemption declaration (has a colon), not prose
                        if ($line -match 'SIN-EXEMPT:\s*(?!(?:P\d{3}|SS-\d{3}))\S') {
                            $violations += "$($f.Name):$lineNum — $($line.Trim())"
                        }
                    }
                }
            } catch {
                $violations += "$($f.Name): read error — $($_.Exception.Message)"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'SIN-EXEMPT: must be followed by a valid ID (e.g. SIN-EXEMPT: P027) to be recognised by the SIN scanner'
    }
}

# =============================================================================
# Section 8 — Markdown FileRole and VersionTag Coverage
# =============================================================================
Describe 'Markdown FileRole and VersionTag Coverage' {

    It 'All ~README.md/*.md guide files contain a FileRole tag' {
        $violations = @()
        foreach ($f in $script:MdFiles) {
            try {
                $top15 = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop | Select-Object -First 15
                if (($top15 -join ' ') -notmatch 'FileRole\s*:') {
                    $violations += $f.Name
                }
            } catch {
                $violations += "$($f.Name): read error"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'Markdown docs should carry <!-- FileRole: Guide --> or # FileRole: Guide tag (P007 extension)'
    }

    It 'All ~README.md/*.md guide files contain a VersionTag within first 5 lines' {
        $violations = @()
        foreach ($f in $script:MdFiles) {
            try {
                $top5 = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop | Select-Object -First 5
                if (($top5 -join ' ') -notmatch 'VersionTag:') {
                    $violations += $f.Name
                }
            } catch {
                $violations += "$($f.Name): read error"
            }
        }
        $violations | Should -BeNullOrEmpty -Because 'Markdown docs must carry a VersionTag (P007) — use # VersionTag: or <!-- VersionTag: --> on line 1-2'
    }
}

# =============================================================================
# Section 9 — Log Infrastructure
# =============================================================================
Describe 'Log Infrastructure' {

    It 'logs/secdump/ directory exists for security audit logs' {
        $secdumpDir = Join-Path $script:LogsDir 'secdump'
        Test-Path -LiteralPath $secdumpDir | Should -Be $true -Because 'Security dump log directory required (DPAPI/vault audit logs go here)'
    }

    It 'At least one current-format daily app log exists (MACHINE-YYYY-MM-DD.log)' {
        $dailyLogs = @(
            Get-ChildItem $script:LogsDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\w[\w-]+-\d{4}-\d{2}-\d{2}\.log$' }
        )
        @($dailyLogs).Count | Should -BeGreaterThan 0 -Because 'Daily app logs must exist under logs/ — missing logs indicate logging infrastructure failure'
    }

    It 'SmokeTest log files follow expected naming conventions' {
        $smokeFiles = @(
            Get-ChildItem $script:LogsDir -Filter '*SmokeTest*.log' -File -ErrorAction SilentlyContinue
        )
        if (@($smokeFiles).Count -eq 0) {
            Set-ItResult -Skipped -Because 'No SmokeTest logs present; run Invoke-GUISmokeTest.ps1 first'
            return
        }
        # Accept both patterns:
        #   MACHINE-YYYYMMDD-HHMMSS-SmokeTest.log  (Invoke-GUISmokeTest.ps1 output)
        #   SmokeTest-Category-EventType.log       (FireUpAllEngines harness output)
        $violations = @(
            $smokeFiles | Where-Object {
                $_.Name -notmatch '^\w[\w-]+-\d{8}-\d{6}-SmokeTest\.log$' -and
                $_.Name -notmatch '^SmokeTest-[\w-]+\.log$'
            }
        )
        $violations | ForEach-Object { $_.Name } | Should -BeNullOrEmpty -Because 'SmokeTest logs must follow a recognised naming pattern'
    }

    It 'No zero-byte log files in logs/ (indicates broken write path)' {
        $empty = @(
            Get-ChildItem $script:LogsDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -eq 0 }
        )
        $empty | ForEach-Object { $_.Name } | Should -BeNullOrEmpty -Because 'Zero-byte .log files indicate a broken logging write path (check Write-AppLog / Out-File calls)'
    }
}

# =============================================================================
# Section 10 — Manifest Alignment
# =============================================================================
Describe 'Manifest Alignment' {

    BeforeAll {
        $script:Manifest = $null
        if (Test-Path -LiteralPath $script:ManifestPath) {
            try {
                $script:Manifest = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json -ErrorAction Stop
            } catch {
                <# Intentional: load failure is reported by the first It block below #>
            }
        }
    }

    It 'agentic-manifest.json exists and parses as valid JSON' {
        Test-Path -LiteralPath $script:ManifestPath | Should -Be $true -Because 'Manifest must exist at config/agentic-manifest.json'
        $script:Manifest | Should -Not -BeNullOrEmpty -Because 'Manifest must parse without ConvertFrom-Json errors'
    }

    It 'Manifest contains all required top-level sections' {
        if ($null -eq $script:Manifest) { Set-ItResult -Skipped -Because 'Manifest not loaded'; return }
        $required = @('modules','scripts','tests','configs','agents','xhtmlTools','styles')
        $present  = @($script:Manifest.PSObject.Properties.Name)
        $missing  = @($required | Where-Object { $present -notcontains $_ })
        $missing  | Should -BeNullOrEmpty -Because 'All pipeline sections must be present in the manifest'
    }

    It 'Manifest module count matches modules/*.psm1 filesystem count' {
        if ($null -eq $script:Manifest) { Set-ItResult -Skipped -Because 'Manifest not loaded'; return }
        $fsCount = @(Get-ChildItem $script:ModDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue).Count
        $mfCount = @($script:Manifest.modules).Count
        $mfCount | Should -Be $fsCount -Because "Manifest module count ($mfCount) must equal filesystem .psm1 count ($fsCount) — run Build-AgenticManifest.ps1 to regenerate"
    }

    It 'Manifest test count is within 5 of filesystem tests/*.ps1 count' {
        if ($null -eq $script:Manifest) { Set-ItResult -Skipped -Because 'Manifest not loaded'; return }
        $testsDir  = Join-Path $script:Root 'tests'
        $fsTests   = @(Get-ChildItem $testsDir -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue).Count
        $mfTests   = @($script:Manifest.tests).Count
        $diff      = [Math]::Abs($mfTests - $fsTests)
        $diff | Should -BeLessOrEqual 5 -Because "Manifest test count ($mfTests) should be within 5 of filesystem count ($fsTests)"
    }

    It 'Manifest XHTML count matches non-REPORTS XHTML file count' {
        if ($null -eq $script:Manifest) { Set-ItResult -Skipped -Because 'Manifest not loaded'; return }
        $fsXhtml = @($script:XhtmlFiles).Count
        $mfXhtml = @($script:Manifest.xhtmlTools).Count
        $diff    = [Math]::Abs($mfXhtml - $fsXhtml)
        $diff | Should -BeLessOrEqual 5 -Because "Manifest xhtmlTools count ($mfXhtml) should be within 5 of filesystem count ($fsXhtml)"
    }
}

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




