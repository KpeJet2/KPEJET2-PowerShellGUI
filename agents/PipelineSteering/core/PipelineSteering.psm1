function Scan-ForSinPattern028 {
    <#
    .SYNOPSIS
        Scan for Import-Module statements that reference .psm1 files instead of .psd1 manifests (SIN-PATTERN-028).
    .DESCRIPTION
        Reports all Import-Module calls that use a .psm1 file as a target, which is forbidden except for legacy wrappers.
    .PARAMETER WorkspacePath
        Workspace root folder to scan.
    .OUTPUTS
        [PSCustomObject[]]  FilePath, LineNumber, LineText
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [string[]]$ExcludePaths = @('.history', '~REPORTS', 'node_modules', '__pycache__', '.git', '~DOWNLOADS', 'CarGame')
    )

    $results = [System.Collections.ArrayList]::new()
    $files = Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
        Where-Object {
            $p = $_.FullName
            -not ($ExcludePaths | Where-Object { $p -like "*$_*" })
        }

    foreach ($file in $files) {
        $lines = @(Get-Content $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            # Use a minimal, PowerShell-safe regex for Import-Module .psm1 detection
            if ($line -match "Import-Module\s+\S+\.psm1") {
                [void]$results.Add([PSCustomObject]@{
                    FilePath   = $file.FullName
                    LineNumber = $i + 1
                    LineText   = $line.Trim()
                })
            }
        }
    }
    Write-SteerLog "Scan-ForSinPattern028: found $(@($results).Count) SIN-PATTERN-028 violation(s)" 'Warning'
    return @($results)
}
# VersionTag: 2604.B2.V33.1
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
#Requires -Version 5.1
<#
.SYNOPSIS
    PipelineSteering Agent -- workspace-wide code quality and documentation conformance steerer.
.DESCRIPTION
    Iterates all workspace .ps1 / .psm1 files and enforces:
      1. Internal function description fields (.SYNOPSIS, .DESCRIPTION, .NOTES)
      2. File-level header conformance: Outline, Problems, ToDo comment blocks
      3. Drift detection: identifies missing dotfiles (.outline / .problems / .todo)
      4. Template propagation: writes standard dotfiles to dirs that lack them
      5. Minor version increment on any file that is modified during steering
      6. Pipeline referential scans after all changes (bug scan + coverage audit)
      7. Steering report written to ~REPORTS/PipelineSteering/

    All runs are non-destructive by default (-WhatIf equivalent via -DryRun).
    Use -Apply to commit fixes.  Each fixed file has its minor version bumped.

    Outline / Problems / ToDo blocks use the canonical format markers:
        [Outline: ...]
        [Problems: ...]
        [ToDo: ...]
.NOTES
    Author  : The Establishment
    Date    : 2026-04-03
    FileRole: Agent-Core
    Version : 2604.B2.V33.0
#>

Set-StrictMode -Off

# ═══════════════════════════════════════════════════════════════════════════════
#  PRIVATE HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

function Write-SteerLog {
    [CmdletBinding()]
    param([string]$Message, [string]$Severity = 'Informational')
    $logged = $false
    try {
        if (Get-Command Write-CronLog -ErrorAction SilentlyContinue) {
            Write-CronLog -Message $Message -Severity $Severity -Source 'PipelineSteering'
            $logged = $true
        }
    } catch { <# Intentional: non-fatal — fallback logging chain; next option tried below #> }

    if (-not $logged) {
        try {
            if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
                Write-AppLog -Message "[PipelineSteering] $Message" -Level $Severity
                $logged = $true
            }
        } catch { <# Intentional: non-fatal — fallback to Write-Verbose below #> }
    }

    if (-not $logged) {
        Write-Verbose ("[PipelineSteering/{0}] {1}" -f $Severity, $Message)
    }
}

function Get-VersionTagFromContent {
    <#
    .SYNOPSIS  Extract VersionTag from script content string.
    #>
    [CmdletBinding()]
    param([string]$Content)
    if ($Content -match '# VersionTag:\s*([\w.\-]+)') { return $Matches[1] }
    return $null
}

function Set-VersionTagMinorBump {
    <#
    .SYNOPSIS  Increment the minor version number in a VersionTag string.
    .DESCRIPTION
        Handles VersionTag format: YYMM.BN.vMAJOR.MINOR
        Returns the new VersionTag string.
    #>
    [CmdletBinding()]
    param([string]$VersionTag)
    if ($VersionTag -match '^(\d{4}\.\w+\.[Vv]\d+\.)(\d+)$') {
        $prefix = $Matches[1]
        $minor  = [int]$Matches[2] + 1
        return "$prefix$minor"
    }
    return $VersionTag
}

function Update-FileVersionTag {
    <#
    .SYNOPSIS  Bump the minor version in a file's VersionTag header in-place.
    #>
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [switch]$DryRun
    )
    $content = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction Stop
    $oldTag  = Get-VersionTagFromContent -Content $content
    if (-not $oldTag) { return $false }
    $newTag  = Set-VersionTagMinorBump -VersionTag $oldTag
    if ($newTag -eq $oldTag) { return $false }
    if (-not $DryRun) {
        $updated = $content -replace [regex]::Escape("# VersionTag: $oldTag"), "# VersionTag: $newTag"
        Set-Content -LiteralPath $FilePath -Value $updated -Encoding UTF8 -ErrorAction Stop
        Write-SteerLog "VersionBump: $([IO.Path]::GetFileName($FilePath)) $oldTag -> $newTag" 'Informational'
    }
    return $true
}

function Get-CompatibilityTagDefaults {
    [CmdletBinding()]
    param()
    [PSCustomObject]@{
        SupportPS51           = 'null'
        SupportPS76           = 'null'
        SupportPS51TestedDate = 'null'
        SupportPS76TestedDate = 'null'
    }
}

function Ensure-CompatibilityDirectiveTags {
    <#
    .SYNOPSIS
        Ensure VersionTag-adjacent compatibility directives exist in script headers.
    .DESCRIPTION
        For each .ps1/.psm1 file, ensures the four compatibility directives exist directly
        after VersionTag in this order:
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
        Default values are null until tests confirm support.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$Apply,
        [string[]]$ExcludePaths = @('.history', '~REPORTS', 'node_modules', '__pycache__', '.git', '~DOWNLOADS', 'CarGame')
    )

    $changes = [System.Collections.ArrayList]::new()
    $defaults = Get-CompatibilityTagDefaults
    $files = Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
        Where-Object {
            $p = $_.FullName
            -not ($ExcludePaths | Where-Object { $p -like "*$_*" })
        }

    foreach ($file in $files) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        if ($content -notmatch '(?m)^\s*#\s*VersionTag:\s*.+$') { continue }

        $newLines = @()
        if ($content -notmatch '(?m)^\s*#\s*SupportPS5\.1\s*:') { $newLines += "# SupportPS5.1: $($defaults.SupportPS51)" }
        if ($content -notmatch '(?m)^\s*#\s*SupportsPS7\.6\s*:') { $newLines += "# SupportsPS7.6: $($defaults.SupportPS76)" }
        if ($content -notmatch '(?m)^\s*#\s*SupportPS5\.1TestedDate\s*:') { $newLines += "# SupportPS5.1TestedDate: $($defaults.SupportPS51TestedDate)" }
        if ($content -notmatch '(?m)^\s*#\s*SupportsPS7\.6TestedDate\s*:') { $newLines += "# SupportsPS7.6TestedDate: $($defaults.SupportPS76TestedDate)" }
        if (@($newLines).Count -eq 0) { continue }

        $insertBlock = "`r`n" + ($newLines -join "`r`n")
        $updated = [regex]::Replace($content, '(?m)^(\s*#\s*VersionTag\s*:\s*.+)$', "`$1$insertBlock", 1)

        if ($Apply) {
            Set-Content -LiteralPath $file.FullName -Value $updated -Encoding UTF8 -ErrorAction SilentlyContinue
            Update-FileVersionTag -FilePath $file.FullName | Out-Null
        }

        [void]$changes.Add([PSCustomObject]@{
            FilePath = $file.FullName
            Added    = @($newLines)
            Applied  = $Apply.IsPresent
        })
    }

    Write-SteerLog "Ensure-CompatibilityDirectiveTags: $(@($changes).Count) file(s) required compatibility directives" 'Informational'
    return @($changes)
}

function New-CompatibilityStandardsTemplates {
    <#
    .SYNOPSIS
        Create PS7.6-prioritized and PS5.1-compat template standards.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$Apply
    )

    $dir = Join-Path (Join-Path (Join-Path $WorkspacePath 'agents') 'PipelineSteering') 'templates'
    $created = [System.Collections.ArrayList]::new()
    $files = @(
        [PSCustomObject]@{
            Path    = Join-Path $dir 'PS76-Preferred-Template.ps1.txt'
            Content = @'
# VersionTag: YYMM.B0.V1.0
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
#Requires -Version 5.1
<#
.SYNOPSIS
    Template for PS7.6-prioritized scripts with PS5.1 compatibility planning.
.NOTES
    Prefer modern cmdlets and predictable parameter binding.
    Add fallback branch only when pipeline compatibility tests require it.
#>

if ($PSVersionTable.PSVersion -ge [version]'7.6') {
    # Preferred path
} else {
    # Legacy provisioning path (PS5.1 compatible)
}
'@
        },
        [PSCustomObject]@{
            Path    = Join-Path $dir 'PS51-Compatibility-Provisioning.ps1.txt'
            Content = @'
# Compatibility Provisioning Pattern

function Invoke-CompatFallback {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Modern,[Parameter(Mandatory)][scriptblock]$Legacy)

    if ($PSVersionTable.PSVersion -ge [version]'7.6') {
        & $Modern
    } else {
        & $Legacy
    }
}
'@
        }
    )

    foreach ($f in $files) {
        if ((Test-Path -LiteralPath $f.Path)) { continue }
        if ($Apply) {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-Content -LiteralPath $f.Path -Value $f.Content -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        [void]$created.Add([PSCustomObject]@{ FilePath = $f.Path; Applied = $Apply.IsPresent })
    }

    Write-SteerLog "New-CompatibilityStandardsTemplates: $(@($created).Count) template file(s) needed" 'Informational'
    return @($created)
}

function Invoke-CompatibilityMatrixAudit {
    <#
    .SYNOPSIS
        Run compatibility parse checks under PS5.1 and PS7+ engines.
    .DESCRIPTION
        Uses parser-only checks for safety; logs directional compatibility for SEMI-SIN ingestion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$Apply
    )

    $files = Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\.git\*' -and $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\node_modules\*' }

    $rows = [System.Collections.ArrayList]::new()
    $ps51Cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    $ps76Cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue

    foreach ($file in $files) {
        $escaped = $file.FullName.Replace("'", "''")
        $probe = "`$errs=`$null;[System.Management.Automation.Language.Parser]::ParseFile('$escaped',[ref]`$null,[ref]`$errs)|Out-Null;if(@(`$errs).Count -gt 0){`$errs|ForEach-Object{Write-Output `$_.Message};exit 1};exit 0"

        $ps51Ok = $false; $ps76Ok = $false
        $ps51Out = ''; $ps76Out = ''

        if ($ps51Cmd) {
            $ps51Out = (& powershell.exe -NoProfile -NonInteractive -Command $probe 2>&1 | Out-String)
            $ps51Ok = ($LASTEXITCODE -eq 0)
        }
        if ($ps76Cmd) {
            $ps76Out = (& pwsh.exe -NoProfile -NonInteractive -Command $probe 2>&1 | Out-String)
            $ps76Ok = ($LASTEXITCODE -eq 0)
        }

        $nowText = (Get-Date).ToString('yyyy-MM-dd')
        if ($Apply) {
            $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($content) {
                $tag51 = if ($ps51Ok) { "YES(As of: $nowText)" } else { 'null' }
                $tag76 = if ($ps76Ok) { "YES(As of: $nowText)" } else { 'null' }
                $upd = $content
                $upd = [regex]::Replace($upd, '(?m)^\s*#\s*SupportPS5\.1\s*:.*$', "# SupportPS5.1: $tag51")
                $upd = [regex]::Replace($upd, '(?m)^\s*#\s*SupportsPS7\.6\s*:.*$', "# SupportsPS7.6: $tag76")
                $upd = [regex]::Replace($upd, '(?m)^\s*#\s*SupportPS5\.1TestedDate\s*:.*$', "# SupportPS5.1TestedDate: $nowText")
                $upd = [regex]::Replace($upd, '(?m)^\s*#\s*SupportsPS7\.6TestedDate\s*:.*$', "# SupportsPS7.6TestedDate: $nowText")
                if ($upd -ne $content) { Set-Content -LiteralPath $file.FullName -Value $upd -Encoding UTF8 -ErrorAction SilentlyContinue }
            }
        }

        [void]$rows.Add([PSCustomObject]@{
            FilePath                    = $file.FullName
            SupportPS51                 = $ps51Ok
            SupportsPS76                = $ps76Ok
            SupportPS51TestedDate       = $nowText
            SupportsPS76TestedDate      = $nowText
            PS51Output                  = ($ps51Out.Trim())
            PS76Output                  = ($ps76Out.Trim())
            SemiSinDirectionOnlyWarning = ((-not $ps51Ok) -xor (-not $ps76Ok))
        })
    }

    $outDir = Join-Path (Join-Path (Join-Path $WorkspacePath '~REPORTS') 'PipelineSteering') 'compatibility'
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force -ErrorAction SilentlyContinue | Out-Null }
    $outFile = Join-Path $outDir ('compat-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json')
    @($rows) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outFile -Encoding UTF8 -ErrorAction SilentlyContinue

    Write-SteerLog "Invoke-CompatibilityMatrixAudit: wrote $(@($rows).Count) result(s) to $outFile" 'Informational'
    return [PSCustomObject]@{ ReportFile = $outFile; Results = @($rows) }
}

function New-WorkspaceCompatibilityIndex {
    <#
    .SYNOPSIS
        Build indexed compatibility/dependency table for workspace objects.
    .DESCRIPTION
        Produces CSV with language, mime type, default support target, and
        dependency tags in format SupportedItemName.version.(indexID).
        indexID=0 marks unresolved references for optional ADD review.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath
    )

    $extMap = @{
        '.ps1'   = @{ Mime = 'text/x-powershell'; Language = 'PowerShell'; DefaultSupportTarget = 'PS5.1+PS7.6' }
        '.psm1'  = @{ Mime = 'text/x-powershell'; Language = 'PowerShell'; DefaultSupportTarget = 'PS5.1+PS7.6' }
        '.xhtml' = @{ Mime = 'application/xhtml+xml'; Language = 'XHTML'; DefaultSupportTarget = 'Browser-XHTML1' }
        '.html'  = @{ Mime = 'text/html'; Language = 'HTML'; DefaultSupportTarget = 'Browser-HTML5' }
        '.json'  = @{ Mime = 'application/json'; Language = 'JSON'; DefaultSupportTarget = 'Data-Exchange' }
        '.css'   = @{ Mime = 'text/css'; Language = 'CSS'; DefaultSupportTarget = 'Browser-CSS3' }
        '.js'    = @{ Mime = 'application/javascript'; Language = 'JavaScript'; DefaultSupportTarget = 'Browser-ES5' }
        '.md'    = @{ Mime = 'text/markdown'; Language = 'Markdown'; DefaultSupportTarget = 'Docs-Markdown' }
    }

    $files = Get-ChildItem -Path $WorkspacePath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\.git\*' -and $_.FullName -notlike '*\node_modules\*' -and $_.FullName -notlike '*\.history\*' }

    $rows = [System.Collections.ArrayList]::new()
    $idx = 1
    foreach ($f in $files) {
        $ext = $f.Extension.ToLowerInvariant()
        if (-not $extMap.ContainsKey($ext)) { continue }

        $meta = $extMap[$ext]
        $depItems = @()
        $products = @()

        if ($ext -eq '.ps1' -or $ext -eq '.psm1') {
            $content = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($content) {
                $matches = [regex]::Matches($content, '(?im)\b(Import-Module|Using\s+module|#Requires\s+-Modules?)\b.+')
                foreach ($m in $matches) {
                    $line = $m.Value.Trim()
                    $name = ($line -replace '(?im)^.*?([A-Za-z][\w\-.]+).*$','$1')
                    if (-not $name) { $name = 'UnknownItem' }
                    $idVal = if ($name -eq 'UnknownItem') { 0 } else { $idx }
                    $depItems += ($name + '.1.0.(' + $idVal + ')')
                    if ($idVal -ne 0) { $idx++ }
                }
                if ($content -match 'Windows\.Forms|System\.Drawing') { $products += 'WinForms.NetFramework.(1)' }
                if ($content -match 'Write-AppLog|Write-CronLog') { $products += 'PwShGUI.Logging.(2)' }
            }
        }

        [void]$rows.Add([PSCustomObject]@{
            FilePath             = $f.FullName
            MimeType             = $meta.Mime
            Language             = $meta.Language
            DefaultSupportTarget = $meta.DefaultSupportTarget
            DependencyItems      = (($depItems | Select-Object -Unique) -join ',')
            Products             = (($products | Select-Object -Unique) -join ',')
        })
    }

    $outDir = Join-Path (Join-Path (Join-Path $WorkspacePath '~REPORTS') 'PipelineSteering') 'compatibility'
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force -ErrorAction SilentlyContinue | Out-Null }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $csvPath = Join-Path $outDir ('compatibility-index-' + $stamp + '.csv')
    $jsonPath = Join-Path $outDir ('compatibility-index-' + $stamp + '.json')
    @($rows) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    @($rows) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    Write-SteerLog "New-WorkspaceCompatibilityIndex: wrote $(@($rows).Count) row(s)" 'Informational'
    return [PSCustomObject]@{ CsvPath = $csvPath; JsonPath = $jsonPath; Rows = @($rows) }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  FUNCTION DESCRIPTION SCANNER
# ═══════════════════════════════════════════════════════════════════════════════

function Test-FunctionDescriptions {
    <#
    .SYNOPSIS
        Scan all .ps1 / .psm1 files for functions missing comment-based help blocks.
    .DESCRIPTION
        Looks for 'function Verb-Noun' declarations not immediately followed by a
        '<# .SYNOPSIS' comment block within 5 lines.  Returns an array of gap objects.
    .PARAMETER WorkspacePath
        Workspace root folder to scan.
    .PARAMETER ExcludePaths
        Optional array of partial paths to exclude (e.g. '.history', 'node_modules').
    .OUTPUTS
        [PSCustomObject[]]  FilePath, FunctionName, LineNumber
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [string[]]$ExcludePaths = @('.history', '~REPORTS', 'node_modules', '__pycache__', '.git')
    )

    $gaps = [System.Collections.ArrayList]::new()
    $files = Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
             Where-Object {
                 $p = $_.FullName
                 -not ($ExcludePaths | Where-Object { $p -like "*$_*" })
             }

    foreach ($file in $files) {
        $lines = @(Get-Content $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*function\s+([\w]+-[\w]+)\s*[\{(]?') {
                $fnName = $Matches[1]  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
                # Look forward up to 5 lines for '<#' comment block
                $hasHelp = $false
                $limit   = [math]::Min($i + 6, $lines.Count - 1)
                for ($j = $i + 1; $j -le $limit; $j++) {
                    if ($lines[$j] -match '<#|\.SYNOPSIS') { $hasHelp = $true; break }
                }
                if (-not $hasHelp) {
                    [void]$gaps.Add([PSCustomObject]@{
                        FilePath     = $file.FullName
                        FunctionName = $fnName
                        LineNumber   = $i + 1
                    })
                }
            }
        }
    }

    Write-SteerLog "Test-FunctionDescriptions: found $(@($gaps).Count) function(s) missing help" 'Informational'
    return @($gaps)
}

# ═══════════════════════════════════════════════════════════════════════════════
#  OUTLINE / PROBLEMS / TODO HEADER CONFORMANCE
# ═══════════════════════════════════════════════════════════════════════════════

function Resolve-OutlineConformance {
    <#
    .SYNOPSIS
        Check each .ps1 / .psm1 for Outline, Problems and ToDo comment blocks.
    .DESCRIPTION
        Scans for the presence of comment blocks with the markers:
            (* Outline:     *)
            (* Problems:    *)
            (* ToDo:        *)
        (Markers use angle-bracket-hash syntax in actual files.)
        Files missing any block are reported.  If -Apply is set, a stub block is
        appended after the header comment.
    .PARAMETER WorkspacePath
        Workspace root.
    .PARAMETER Apply
        If set, injects missing stub blocks into files.
    .PARAMETER ExcludePaths
        Partial paths to exclude.
    .OUTPUTS
        [PSCustomObject[]]  FilePath, MissingOutline, MissingProblems, MissingTodo, Fixed [bool]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$Apply,
        [string[]]$ExcludePaths = @('.history', '~REPORTS', 'node_modules', '__pycache__', '.git', 'CarGame', '~DOWNLOADS')
    )

    $results = [System.Collections.ArrayList]::new()
    $files   = Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
               Where-Object {
                   $p = $_.FullName
                   -not ($ExcludePaths | Where-Object { $p -like "*$_*" })
               }

    foreach ($file in $files) {
        $content      = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        $missingOL    = $content -notmatch '(?s)<#\s*Outline:'
        $missingProb  = $content -notmatch '(?s)<#\s*Problems?:'
        $missingTodo  = $content -notmatch '(?s)<#\s*To[-\s]?[Dd]o:'
        $fixed        = $false

        if (($missingOL -or $missingProb -or $missingTodo) -and $Apply) {
            $stubs = ''
            if ($missingOL)   { $stubs += "`n<# Outline:`n    Stub: describe module/script purpose here.`n#>`n" }
            if ($missingProb) { $stubs += "`n<# Problems:`n    Stub: list known issues here.`n#>`n" }
            if ($missingTodo) { $stubs += "`n<# ToDo:`n    Stub: list pending work here.`n#>`n" }
            # Append stubs before last Export-ModuleMember or at end of file
            if ($content -match 'Export-ModuleMember') {
                $updated = $content -replace '(Export-ModuleMember)', "$stubs`$1"
            } else {
                $updated = $content + $stubs
            }
            Set-Content -Path $file.FullName -Value $updated -Encoding UTF8 -ErrorAction SilentlyContinue
            Update-FileVersionTag -FilePath $file.FullName
            $fixed = $true
            Write-SteerLog "Resolve-OutlineConformance: patched $($file.Name)" 'Informational'
        }

        if ($missingOL -or $missingProb -or $missingTodo) {
            [void]$results.Add([PSCustomObject]@{
                FilePath        = $file.FullName
                MissingOutline  = $missingOL
                MissingProblems = $missingProb
                MissingTodo     = $missingTodo
                Fixed           = $fixed
            })
        }
    }

    Write-SteerLog "Resolve-OutlineConformance: $(@($results).Count) file(s) with missing header blocks" 'Informational'
    return @($results)
}

# ═══════════════════════════════════════════════════════════════════════════════
#  DOTFILE TEMPLATE PROPAGATION
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-DocTemplatePropagation {
    <#
    .SYNOPSIS
        Create standard dotfiles (.outline, .problems, .todo) in dirs that lack them.
    .DESCRIPTION
        Walks the workspace looking for directories containing .ps1 or .psm1 files.
        Any such directory that lacks a .outline, .problems, or .todo file gets the
        default template written.  Directories in ExcludePaths are skipped.
    .PARAMETER WorkspacePath
        Workspace root.
    .PARAMETER Apply
        If set, writes the dotfiles.  Otherwise reports what would be created.
    .PARAMETER ExcludePaths
        Partial path segments to exclude.
    .OUTPUTS
        [PSCustomObject[]] DirectoryPath, CreatedFiles [string[]]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$Apply,
        [string[]]$ExcludePaths = @('.git', '.history', 'node_modules', '__pycache__', '~DOWNLOADS', 'CarGame')
    )

    $created = [System.Collections.ArrayList]::new()
    $dirs    = Get-ChildItem -Path $WorkspacePath -Recurse -Directory -ErrorAction SilentlyContinue |
               Where-Object {
                   $dp = $_.FullName
                   -not ($ExcludePaths | Where-Object { $dp -like "*$_*" })
               }

    foreach ($dir in $dirs) {
        $hasPsFiles = @(Get-ChildItem -Path $dir.FullName -Filter '*.ps1' -ErrorAction SilentlyContinue) +
                      @(Get-ChildItem -Path $dir.FullName -Filter '*.psm1' -ErrorAction SilentlyContinue)
        if (@($hasPsFiles).Count -eq 0) { continue }

        $newFiles = [System.Collections.ArrayList]::new()
        $outlineFile  = Join-Path $dir.FullName '.outline'
        $problemsFile = Join-Path $dir.FullName '.problems'
        $todoFile     = Join-Path $dir.FullName '.todo'

        if (-not (Test-Path $outlineFile)) {
            if ($Apply) { Set-Content -Path $outlineFile -Value "# Outline`n# Describe the purpose of scripts in this directory." -Encoding UTF8 -ErrorAction SilentlyContinue }
            [void]$newFiles.Add('.outline')
        }
        if (-not (Test-Path $problemsFile)) {
            if ($Apply) { Set-Content -Path $problemsFile -Value "# Known Problems`n# List known issues and constraints here." -Encoding UTF8 -ErrorAction SilentlyContinue }
            [void]$newFiles.Add('.problems')
        }
        if (-not (Test-Path $todoFile)) {
            if ($Apply) { Set-Content -Path $todoFile -Value "# ToDo`n# List pending work items here." -Encoding UTF8 -ErrorAction SilentlyContinue }
            [void]$newFiles.Add('.todo')
        }

        if (@($newFiles).Count -gt 0) {
            [void]$created.Add([PSCustomObject]@{
                DirectoryPath = $dir.FullName
                CreatedFiles  = @($newFiles)
                Applied       = $Apply.IsPresent
            })
        }
    }

    Write-SteerLog "Invoke-DocTemplatePropagation: $(@($created).Count) dir(s) need dotfiles" 'Informational'
    return @($created)
}

# ═══════════════════════════════════════════════════════════════════════════════
#  POST-STEERING PIPELINE SCAN
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-SteeringPipelineScan {
    <#
    .SYNOPSIS
        Run bug scan and config-coverage audit after a steering session.
    .DESCRIPTION
        Calls Invoke-FullBugScan (if available) and Invoke-ConfigCoverageAudit.ps1
        to surface any new issues introduced or resolved during the steering pass.
        Writes a summary to the report object returned by Invoke-PipelineSteerSession.
    .PARAMETER WorkspacePath
        Workspace root.
    .OUTPUTS
        [PSCustomObject] BugScanResult, CoverageAuditResult
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $bugResult  = $null
    $covResult  = $null

    # Bug scan
    try {
        if (Get-Command Invoke-FullBugScan -ErrorAction SilentlyContinue) {
            $bugResult = Invoke-FullBugScan -WorkspacePath $WorkspacePath 2>&1
            Write-SteerLog 'SteeringPipelineScan: bug scan completed' 'Informational'
        } else {
            Write-SteerLog 'SteeringPipelineScan: Invoke-FullBugScan not available — skipping' 'Informational'
        }
    } catch {
        Write-SteerLog "SteeringPipelineScan: bug scan error: $($_.Exception.Message)" 'Warning'
    }

    # Config coverage audit script
    $covScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-ConfigCoverageAudit.ps1'
    try {
        if (Test-Path $covScript) {
            $covResult = & $covScript -WorkspacePath $WorkspacePath 2>&1
            Write-SteerLog 'SteeringPipelineScan: config coverage audit completed' 'Informational'
        } else {
            Write-SteerLog 'SteeringPipelineScan: Invoke-ConfigCoverageAudit.ps1 not found — skipping' 'Informational'
        }
    } catch {
        Write-SteerLog "SteeringPipelineScan: coverage audit error: $($_.Exception.Message)" 'Warning'
    }

    [PSCustomObject]@{
        BugScanResult       = $bugResult
        CoverageAuditResult = $covResult
    }
}

function Get-PipelineAgentRecommendations {
    <#
    .SYNOPSIS
        Collect agent health recommendations for koe-RumA and H-Ai-Nikr-Agi.
    .DESCRIPTION
        gap-2604-014 alignment hook for PipelineSteering. Produces lightweight
        health signals and recommendations even in DryRun mode.
    .PARAMETER WorkspacePath
        Workspace root path.
    .OUTPUTS
        [PSCustomObject[]] AgentId, Status, Detail, Recommendation
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $items = [System.Collections.ArrayList]::new()

    $koeHook = {
        # koe-RumA: monthly milestone health based on latest milestone report age
        $koeReportDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'KoeRumaMilestone'
        $status = 'DEGRADED'
        $detail = 'Milestone report directory missing.'
        $recommendation = 'Ensure TASK-MonthlyMilestone runs and writes milestone reports.'
        if (Test-Path $koeReportDir) {
            $latest = Get-ChildItem -Path $koeReportDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($latest) {
                $ageDays = [math]::Round(((Get-Date) - $latest.LastWriteTime).TotalDays, 1)
                if ($ageDays -le 35) {
                    $status = 'HEALTHY'
                    $detail = "Latest milestone report is $ageDays days old."
                    $recommendation = 'No action.'
                } else {
                    $status = 'DEGRADED'
                    $detail = "Latest milestone report is $ageDays days old (expected <= 35)."
                    $recommendation = 'Run milestone event and verify cron task dispatch for KoeRumaMilestone.'
                }
            }
        }
        return [PSCustomObject]@{ ok = ($status -eq 'HEALTHY'); status = $status; detail = $detail; recommendation = $recommendation }
    }.GetNewClosure()

    $nikrHook = {
        # H-Ai-Nikr-Agi: squabble log rotation health
        $nikrLog = Join-Path (Join-Path $WorkspacePath 'logs') 'hanikragi-squabble.enc'
        $status = 'DEGRADED'
        $detail = 'Squabble log not found.'
        $recommendation = 'Verify H-Ai-Nikr-Agi logging path and retention run.'
        if (Test-Path $nikrLog) {
            $nikrAgeDays = [math]::Round(((Get-Date) - (Get-Item $nikrLog).LastWriteTime).TotalDays, 1)
            if ($nikrAgeDays -le 30) {
                $status = 'HEALTHY'
                $detail = "Squabble log age is $nikrAgeDays days."
                $recommendation = 'No action.'
            } else {
                $status = 'DEGRADED'
                $detail = "Squabble log age is $nikrAgeDays days (expected <= 30)."
                $recommendation = 'Run Invoke-ReportRetention.ps1 and confirm squabble log rotation.'
            }
        }
        return [PSCustomObject]@{ ok = ($status -eq 'HEALTHY'); status = $status; detail = $detail; recommendation = $recommendation }
    }.GetNewClosure()

    # Optional gap-2604-014 registration path: bind hooks to AgentRegistry if available
    $registryPath = Join-Path (Join-Path (Join-Path $WorkspacePath 'sovereign-kernel') 'core') 'AgentRegistry.psm1'
    if (Test-Path $registryPath) {
        try {
            Import-Module $registryPath -Force -ErrorAction Stop
            if (Get-Command Register-ExternalAgent -ErrorAction SilentlyContinue) {
                Register-ExternalAgent -AgentId 'KOE_RUMA' -Function 'monthly_milestone_governance' -HealthCheckHook $koeHook -AutoHeal $true -DependsOn @()
                Register-ExternalAgent -AgentId 'H_AI_NIKR_AGI' -Function 'encryption_rotation_squabble' -HealthCheckHook $nikrHook -AutoHeal $true -DependsOn @()
            }
        } catch {
            Write-SteerLog "AgentRegistry hook registration skipped: $($_.Exception.Message)" 'Warning'
        }
    }

    $koeResult = & $koeHook
    [void]$items.Add([PSCustomObject]@{
        AgentId        = 'KOE_RUMA'
        Status         = $koeResult.status
        Detail         = $koeResult.detail
        Recommendation = $koeResult.recommendation
    })

    $nikrResult = & $nikrHook
    [void]$items.Add([PSCustomObject]@{
        AgentId        = 'H_AI_NIKR_AGI'
        Status         = $nikrResult.status
        Detail         = $nikrResult.detail
        Recommendation = $nikrResult.recommendation
    })

    return @($items)
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-PipelineSteerSession {
    <#
    .SYNOPSIS
        Run a full Pipeline Steering session across the workspace.
    .DESCRIPTION
        Orchestrates all steering phases in sequence:
          Phase 1 — Scan functions for missing help descriptions
          Phase 2 — Resolve Outline / Problems / ToDo header conformance
          Phase 3 — Propagate standard dotfile templates
          Phase 4 — Post-steering pipeline scan (bug scan + coverage audit)
          Phase 5 — Agent recommendations (koe-RumA and H-Ai-Nikr-Agi health)

        When -Apply is supplied, files are modified in-place and minor version
        bumped.  Without -Apply the session runs in DryRun mode (report only).

        Report is written to <WorkspacePath>\~REPORTS\PipelineSteering\steer-YYYYMMDD-HHmmss.json
    .PARAMETER WorkspacePath
        Workspace root.
    .PARAMETER Apply
        Commit fixes in-place.  Without this flag the session is read-only.
    .PARAMETER SkipPipelineScan
        Skip the post-fix bug scan and coverage audit.
    .OUTPUTS
        [PSCustomObject] with full session report.
    .EXAMPLE
        Invoke-PipelineSteerSession -WorkspacePath 'C:\PowerShellGUI' -Apply
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$Apply,
        [switch]$SkipPipelineScan,
        [switch]$SkipCompatibilityTests
    )

    $sessionStart = Get-Date
    Write-SteerLog "Invoke-PipelineSteerSession: starting (Apply=$($Apply.IsPresent))" 'Informational'


    # Phase 0 — SIN-PATTERN-028 scan (Import-Module .psm1 usage)
    Write-SteerLog 'PipelineSteer Phase 0: scanning for SIN-PATTERN-028 (.psm1 Import-Module usage)...' 'Warning'
    $sin028 = Scan-ForSinPattern028 -WorkspacePath $WorkspacePath

    # Phase 1 — function description gaps
    Write-SteerLog 'PipelineSteer Phase 1: scanning function descriptions...' 'Informational'
    $fnGaps = Test-FunctionDescriptions -WorkspacePath $WorkspacePath

    # Phase 2 — Outline/Problems/ToDo header blocks
    Write-SteerLog 'PipelineSteer Phase 2: resolving outline conformance...' 'Informational'
    $outlineResults = Resolve-OutlineConformance -WorkspacePath $WorkspacePath -Apply:$Apply

    # Phase 3 — dotfile template propagation
    Write-SteerLog 'PipelineSteer Phase 3: propagating doc templates...' 'Informational'
    $dotfileResults = Invoke-DocTemplatePropagation -WorkspacePath $WorkspacePath -Apply:$Apply

    # Phase 3b — compatibility directives + standards templates
    Write-SteerLog 'PipelineSteer Phase 3b: enforcing compatibility directives and templates...' 'Informational'
    $compatTagResults = Ensure-CompatibilityDirectiveTags -WorkspacePath $WorkspacePath -Apply:$Apply
    $compatTemplates  = New-CompatibilityStandardsTemplates -WorkspacePath $WorkspacePath -Apply:$Apply

    # Phase 4 — post-steering pipeline scan
    $scanResult = $null
    if (-not $SkipPipelineScan -and $Apply) {
        Write-SteerLog 'PipelineSteer Phase 4: running post-steering pipeline scan...' 'Informational'
        $scanResult = Invoke-SteeringPipelineScan -WorkspacePath $WorkspacePath
    }

    # Phase 5 — agent recommendations (always available, including DryRun)
    Write-SteerLog 'PipelineSteer Phase 5: collecting agent recommendations...' 'Informational'
    $agentRecommendations = Get-PipelineAgentRecommendations -WorkspacePath $WorkspacePath

    # Phase 6 — compatibility matrix tests
    $compatibilityResult = $null
    if (-not $SkipCompatibilityTests) {
        Write-SteerLog 'PipelineSteer Phase 6: running compatibility matrix tests (PS5.1 + PS7.6 parser checks)...' 'Informational'
        $compatibilityResult = Invoke-CompatibilityMatrixAudit -WorkspacePath $WorkspacePath -Apply:$Apply
    }

    Write-SteerLog 'PipelineSteer Phase 7: generating workspace compatibility index...' 'Informational'
    $compatibilityIndex = New-WorkspaceCompatibilityIndex -WorkspacePath $WorkspacePath

    $sessionEnd = Get-Date
    $elapsed    = ($sessionEnd - $sessionStart).TotalSeconds

    $report = [PSCustomObject]@{
        SessionId          = [guid]::NewGuid().ToString('N').Substring(0,8)
        Timestamp          = $sessionStart.ToString('yyyy-MM-dd HH:mm:ss')
        DryRun             = (-not $Apply.IsPresent)
        ElapsedSeconds     = [math]::Round($elapsed, 1)
        SinPattern028      = @($sin028)
        SinPattern028Count = @($sin028).Count
        FunctionGaps       = @($fnGaps)
        FunctionGapCount   = @($fnGaps).Count
        OutlineIssues      = @($outlineResults)
        OutlineIssueCount  = @($outlineResults).Count
        DotfilesNeeded     = @($dotfileResults)
        DotfileNeedCount   = @($dotfileResults).Count
        CompatibilityDirectiveChanges = @($compatTagResults)
        CompatibilityDirectiveChangeCount = @($compatTagResults).Count
        CompatibilityTemplateChanges  = @($compatTemplates)
        CompatibilityTemplateChangeCount = @($compatTemplates).Count
        PipelineScanResult = $scanResult
        CompatibilityResult = $compatibilityResult
        CompatibilityIndex = $compatibilityIndex
        AgentRecommendations = @($agentRecommendations)
        AgentRecommendationCount = @($agentRecommendations).Count
    }

    # Write report
    $reportDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'PipelineSteering'
    if (-not (Test-Path $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $reportFile = Join-Path $reportDir ("steer-" + $sessionStart.ToString('yyyyMMdd-HHmmss') + ".json")
    try {
        $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportFile -Encoding UTF8 -ErrorAction Stop
        Write-SteerLog "PipelineSteer: report written to $reportFile" 'Informational'
    } catch {
        Write-SteerLog "PipelineSteer: failed to write report: $($_.Exception.Message)" 'Warning'
    }

    Write-SteerLog "Invoke-PipelineSteerSession: complete. Gaps=$($report.FunctionGapCount) OutlineIssues=$($report.OutlineIssueCount) DotfilesNeeded=$($report.DotfileNeedCount) AgentRecs=$($report.AgentRecommendationCount) Elapsed=$($report.ElapsedSeconds)s" 'Informational'
    return $report
}

# ═══════════════════════════════════════════════════════════════════════════════
Export-ModuleMember -Function @(
    'Invoke-PipelineSteerSession'
    'Test-FunctionDescriptions'
    'Resolve-OutlineConformance'
    'Invoke-DocTemplatePropagation'
    'Invoke-SteeringPipelineScan'
    'Get-PipelineAgentRecommendations'
    'Update-FileVersionTag'
    'Ensure-CompatibilityDirectiveTags'
    'New-CompatibilityStandardsTemplates'
    'Invoke-CompatibilityMatrixAudit'
    'New-WorkspaceCompatibilityIndex'
)



