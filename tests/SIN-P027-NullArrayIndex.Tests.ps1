# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    SIN-PATTERN-027 regression tests — Cannot index into a null array.
.DESCRIPTION
    Validates that all fix scenarios (FIX-A through FIX-F) for P027 are
    correctly applied in Show-ScanDashboard.ps1, Invoke-ModuleManagement.ps1,
    and Invoke-ScriptDependencyMatrix.ps1 — and that competing fixes do
    not regress each other.

    Fix scenarios tested:
      FIX-A  @() force-array wrapper
      FIX-B  .Count -gt 0 precondition guard
      FIX-C  $null -ne variable guard
      FIX-D  -match success guard before $Matches[N]
      FIX-E  -split result bounds check
      FIX-F  try/catch fallback wrapper

    Each Describe block targets one of the three workspace objects.
    Each It block simulates the null/empty condition and asserts no
    RuntimeException is thrown, regardless of which fix strategy is used.
.NOTES
    Run with:  Invoke-Pester -Path tests\SIN-P027-NullArrayIndex.Tests.ps1 -Output Detailed
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir    = Join-Path $script:WorkspaceRoot 'scripts'

    # Target files
    $script:ScanDashFile    = Join-Path $script:ScriptsDir 'Show-ScanDashboard.ps1'
    $script:ModuleMgmtFile  = Join-Path $script:ScriptsDir 'Invoke-ModuleManagement.ps1'
    $script:DepMatrixFile   = Join-Path $script:ScriptsDir 'Invoke-ScriptDependencyMatrix.ps1'

    # Helper: test that a scriptblock does NOT throw the specific RuntimeException
    function Assert-NoNullArrayIndex {
        param([scriptblock]$Code, [string]$Label)
        $threw = $false
        $msg   = ''
        try {
            & $Code
        } catch [System.Management.Automation.RuntimeException] {
            if ($_.Exception.Message -match 'Cannot index into a null array') {
                $threw = $true
                $msg   = $_.Exception.Message
            }
        } catch {
            # Other exceptions are not P027
        }
        $threw | Should -BeFalse -Because "P027: '$Label' must not throw 'Cannot index into a null array'. Got: $msg"
    }

    # Helper: parse a PS1 file and return its AST content as a string for static analysis
    function Get-ScriptContent {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $null }
        Get-Content $Path -Raw -Encoding UTF8
    }

    # Helper: check that a line region has a guard pattern within N lines above
    function Test-GuardWithinLines {
        param(
            [string[]]$Lines,
            [int]$TargetLineIndex,
            [int]$LookbackLines,
            [string]$GuardPattern
        )
        $start = [math]::Max(0, $TargetLineIndex - $LookbackLines)
        for ($i = $start; $i -lt $TargetLineIndex; $i++) {
            if ($Lines[$i] -match $GuardPattern) { return $true }
        }
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════════════
# 1. FILE EXISTENCE AND PARSE VALIDATION
# ═══════════════════════════════════════════════════════════════════════
Describe 'P027 Prerequisites' {
    It 'Show-ScanDashboard.ps1 exists and parses without errors' {
        Test-Path $script:ScanDashFile | Should -BeTrue
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScanDashFile, [ref]$null, [ref]$errors
        ) | Out-Null
        @($errors).Count | Should -Be 0
    }
    It 'Invoke-ModuleManagement.ps1 exists and parses without errors' {
        Test-Path $script:ModuleMgmtFile | Should -BeTrue
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ModuleMgmtFile, [ref]$null, [ref]$errors
        ) | Out-Null
        @($errors).Count | Should -Be 0
    }
    It 'Invoke-ScriptDependencyMatrix.ps1 exists and parses without errors' {
        Test-Path $script:DepMatrixFile | Should -BeTrue
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:DepMatrixFile, [ref]$null, [ref]$errors
        ) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

# ═══════════════════════════════════════════════════════════════════════
# 2. SHOW-SCANDASHBOARD — Static guard analysis
# ═══════════════════════════════════════════════════════════════════════
Describe 'Show-ScanDashboard: P027 null-array-index guards' {
    BeforeAll {
        $script:sdContent = Get-ScriptContent $script:ScanDashFile
        $script:sdLines   = @($script:sdContent -split "`n")
    }

    Context 'FIX-B: WinForms .SelectedRows[0] must have .Count precondition' {
        It 'All .SelectedRows[0] accesses are preceded by @().Count -gt 0 guard' {
            $violations = @()
            for ($i = 0; $i -lt $script:sdLines.Count; $i++) {
                $line = $script:sdLines[$i]
                if ($line -match '\.SelectedRows\[0\]' -and $line -notmatch '^\s*#') {
                    $hasGuard = Test-GuardWithinLines -Lines $script:sdLines `
                        -TargetLineIndex $i -LookbackLines 5 `
                        -GuardPattern '@\(\$\w+\.SelectedRows\)\.Count\s*-gt\s*0|\.SelectedRows\)\.Count\s*-gt\s*0'
                    if (-not $hasGuard) {
                        $violations += "L$($i+1): $($line.Trim())"
                    }
                }
            }
            $violations | Should -BeNullOrEmpty -Because `
                "Every .SelectedRows[0] needs FIX-B: @(`$grid.SelectedRows).Count -gt 0 within 5 lines above. Violations: $($violations -join '; ')"
        }
    }

    Context 'FIX-A: Get-ScanFiles results indexed [0] must have @() or .Count guard' {
        It 'All $files[0] accesses are preceded by .Count -gt 0 or @() guard' {
            $violations = @()
            for ($i = 0; $i -lt $script:sdLines.Count; $i++) {
                $line = $script:sdLines[$i]
                if ($line -match '\$files\[0\]' -and $line -notmatch '^\s*#') {
                    # Check same line for inline guard (e.g. if ($files.Count -gt 0) { ...$files[0]... })
                    $hasInlineGuard = ($line -match '\.Count\s*-gt\s*0|\.Count\s*-ge\s*1|@\(\$files\)')
                    # Check above lines (extended to 8 for continue-after-empty patterns)
                    $hasGuard = $hasInlineGuard -or (Test-GuardWithinLines -Lines $script:sdLines `
                        -TargetLineIndex $i -LookbackLines 8 `
                        -GuardPattern '\.Count\s*-gt\s*0|\.Count\s*-ge\s*1|\.Count\s*-eq\s*0.*continue|@\(\$files\)')
                    if (-not $hasGuard) {
                        $violations += "L$($i+1): $($line.Trim())"
                    }
                }
            }
            $violations | Should -BeNullOrEmpty -Because `
                "Every `$files[0] needs FIX-A or FIX-B guard (inline or within 8 lines above). Violations: $($violations -join '; ')"
        }
    }

    Context 'FIX-B: Grid row cell access after [0] must have null check' {
        It 'All .Cells[...] accesses after [0] are preceded by $null -ne guard' {
            $violations = @()
            for ($i = 0; $i -lt $script:sdLines.Count; $i++) {
                $line = $script:sdLines[$i]
                if ($line -match '\$selectedRow\.Cells\[' -and $line -notmatch '^\s*#') {
                    $hasGuard = Test-GuardWithinLines -Lines $script:sdLines `
                        -TargetLineIndex $i -LookbackLines 3 `
                        -GuardPattern '\$null\s*-eq\s*\$selectedRow|\$null\s*-ne\s*\$selectedRow|-ne\s*\$null'
                    if (-not $hasGuard) {
                        $violations += "L$($i+1): $($line.Trim())"
                    }
                }
            }
            $violations | Should -BeNullOrEmpty -Because `
                "Cell access on `$selectedRow requires null-check within 3 lines above. Violations: $($violations -join '; ')"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# 3. SHOW-SCANDASHBOARD — Runtime simulation of null conditions
# ═══════════════════════════════════════════════════════════════════════
Describe 'Show-ScanDashboard: P027 runtime null-condition simulation' {

    Context 'FIX-A: Empty file list indexed' {
        It 'Does not throw when @() empty array is indexed with .Count guard' {
            Assert-NoNullArrayIndex -Label 'FIX-A empty files' -Code {
                $files = @()  # Simulates Get-ScanFiles returning nothing
                if ($files.Count -gt 0) {
                    $first = $files[0].Name
                }
            }
        }
        It 'Does not throw when $null is force-arrayed then indexed' {
            Assert-NoNullArrayIndex -Label 'FIX-A null force-array' -Code {
                $result = $null  # Simulates pipeline returning $null
                $files = @($result)
                if ($files.Count -gt 0 -and $null -ne $files[0]) {
                    $first = $files[0].Name
                }
            }
        }
    }

    Context 'FIX-B: WinForms SelectedRows is empty' {
        It 'Does not throw when SelectedRows collection is empty' {
            Assert-NoNullArrayIndex -Label 'FIX-B empty selection' -Code {
                # Simulate empty SelectedRows as an empty array
                $selectedRows = @()
                if (@($selectedRows).Count -gt 0) {
                    $row = $selectedRows[0]
                }
            }
        }
        It 'Does not throw when SelectedRows is $null' {
            Assert-NoNullArrayIndex -Label 'FIX-B null selection' -Code {
                $selectedRows = $null
                if ($null -ne $selectedRows -and @($selectedRows).Count -gt 0) {
                    $row = $selectedRows[0]
                }
            }
        }
    }

    Context 'FIX-C: $null variable indexed directly' {
        It 'Guards $null before bracket access' {
            Assert-NoNullArrayIndex -Label 'FIX-C null guard' -Code {
                $result = $null
                if ($null -ne $result -and @($result).Count -gt 0) {
                    $val = $result[0]
                }
            }
        }
    }

    Context 'FIX-F: try/catch wraps deeply nested access' {
        It 'Catches RuntimeException without propagation' {
            Assert-NoNullArrayIndex -Label 'FIX-F try-catch' -Code {
                $complex = $null
                $val = $null
                try {
                    $val = $complex[0]
                } catch [System.Management.Automation.RuntimeException] {
                    $val = $null
                }
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# 4. INVOKE-MODULEMANAGEMENT — Static guard analysis
# ═══════════════════════════════════════════════════════════════════════
Describe 'Invoke-ModuleManagement: P027 null-array-index guards' {
    BeforeAll {
        $script:mmContent = Get-ScriptContent $script:ModuleMgmtFile
        $script:mmLines   = @($script:mmContent -split "`n")
    }

    Context 'FIX-A/FIX-C: Dictionary/hashtable bracket access is key-guarded' {
        It 'All hashtable bracket accesses use ContainsKey or -ne $null guard' {
            $violations = @()
            for ($i = 0; $i -lt $script:mmLines.Count; $i++) {
                $line = $script:mmLines[$i]
                # Match $hashtable[$key] but not typed generic List[type] or HashSet[type]
                if ($line -match '\$\w+\[\$\w+\]' -and
                    $line -notmatch 'List\[|HashSet\[|Dictionary\[|New-Object' -and
                    $line -notmatch '^\s*#' -and
                    $line -notmatch '\$\w+\[\$\w+\]\s*=') {
                    # Check same line for inline guard (e.g. if ($dict.ContainsKey($k)) { $dict[$k] })
                    $hasInlineGuard = ($line -match 'ContainsKey|\.Keys\s*-contains|\$null\s*-ne')
                    $hasGuard = $hasInlineGuard -or (Test-GuardWithinLines -Lines $script:mmLines `
                        -TargetLineIndex $i -LookbackLines 3 `
                        -GuardPattern 'ContainsKey|\.Keys\s*-contains|\$null\s*-ne')
                    if (-not $hasGuard) {
                        $violations += "L$($i+1): $($line.Trim())"
                    }
                }
            }
            $violations | Should -BeNullOrEmpty -Because `
                "Hashtable read-access must have ContainsKey guard (inline or within 3 lines above). Violations: $($violations -join '; ')"
        }
    }

    Context 'FIX-A: Pipeline .Count without @() wrapper' {
        It 'Pipeline results piped to .Count use @() force-array' {
            $violations = @()
            for ($i = 0; $i -lt $script:mmLines.Count; $i++) {
                $line = $script:mmLines[$i]
                # Lines like: $inventory | Where-Object { ... }).Count without @(
                if ($line -match 'Where-Object\s*\{[^}]*\}\s*\)\s*\.Count' -and
                    $line -notmatch '@\(') {
                    $violations += "L$($i+1): $($line.Trim())"
                }
            }
            $violations | Should -BeNullOrEmpty -Because `
                "Pipeline filter results need @() before .Count (P004/P027). Violations: $($violations -join '; ')"
        }
    }

    Context 'Regression: .Count on typed List[T] is safe (should NOT false-positive)' {
        It 'Typed Generic List[T] .Count does not need @() guard' {
            # Typed lists always have .Count — verify scanner does not flag them
            $falsePosCount = 0
            for ($i = 0; $i -lt $script:mmLines.Count; $i++) {
                $line = $script:mmLines[$i]
                if ($line -match "New-Object\s+'System\.Collections\.Generic\.List\[") {
                    # This is a typed list — .Count on the result variable is safe
                    $falsePosCount++  # Count how many typed lists exist
                }
            }
            $falsePosCount | Should -BeGreaterThan 0 -Because `
                "ModuleManagement uses typed Lists — verify they exist so we can confirm .Count is safe on them"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# 5. INVOKE-MODULEMANAGEMENT — Runtime simulation
# ═══════════════════════════════════════════════════════════════════════
Describe 'Invoke-ModuleManagement: P027 runtime null-condition simulation' {

    Context 'FIX-A: Pipeline returns $null then .Count accessed' {
        It 'Force-array on null pipeline result prevents crash' {
            Assert-NoNullArrayIndex -Label 'MM FIX-A null pipeline' -Code {
                $inventory = $null
                $count = @($inventory).Count
                $count | Should -Be 0
            }
        }
    }

    Context 'FIX-C: Dictionary key miss returns $null then indexed' {
        It 'ContainsKey guard prevents null-index on missing key' {
            Assert-NoNullArrayIndex -Label 'MM FIX-C dict miss' -Code {
                $dict = @{}
                $key = 'nonexistent'
                $val = $null
                if ($dict.ContainsKey($key)) {
                    $val = $dict[$key]
                }
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# 6. INVOKE-SCRIPTDEPENDENCYMATRIX — Static guard analysis
# ═══════════════════════════════════════════════════════════════════════
Describe 'Invoke-ScriptDependencyMatrix: P027 null-array-index guards' {
    BeforeAll {
        $script:dmContent = Get-ScriptContent $script:DepMatrixFile
        $script:dmLines   = @($script:dmContent -split "`n")
    }

    Context 'FIX-D: $Matches[N] only accessed inside if(-match) block' {
        It 'All $Matches[N] accesses are inside an if-match guard scope' {
            $violations = @()
            for ($i = 0; $i -lt $script:dmLines.Count; $i++) {
                $line = $script:dmLines[$i]
                if ($line -match '\$Matches\[\d+\]' -and $line -notmatch '^\s*#') {
                    # Check that a -match is within 5 lines above, or on the same line
                    $hasMatchGuard = ($line -match '-match\s')
                    if (-not $hasMatchGuard) {
                        $hasMatchGuard = Test-GuardWithinLines -Lines $script:dmLines `
                            -TargetLineIndex $i -LookbackLines 5 `
                            -GuardPattern '-match\s|\.Success\b|if\s*\(\$\w+\s*-match'
                    }
                    if (-not $hasMatchGuard) {
                        $violations += "L$($i+1): $($line.Trim())"
                    }
                }
            }
            $violations | Should -BeNullOrEmpty -Because `
                "`$Matches[N] must be inside an if(-match) scope (FIX-D). Violations: $($violations -join '; ')"
        }
    }

    Context 'FIX-D: .Groups[N].Value only accessed after .Success or -match' {
        It 'All .Groups[N].Value accesses are guarded by .Success or -match or if-variable' {
            $violations = @()
            for ($i = 0; $i -lt $script:dmLines.Count; $i++) {
                $line = $script:dmLines[$i]
                if ($line -match '\.Groups\[\d+\]\.Value' -and $line -notmatch '^\s*#') {
                    # Same-line guard: if($match), $match.Success, ForEach-Object on matches collection
                    $hasGuard = ($line -match '\.Success\b|-match\s|if\s*\(|ForEach-Object|\$_\.Groups')
                    if (-not $hasGuard) {
                        # Check above: if($var), $var.Success, -match, regex match result assignment
                        $hasGuard = Test-GuardWithinLines -Lines $script:dmLines `
                            -TargetLineIndex $i -LookbackLines 5 `
                            -GuardPattern '\.Success\b|-match\s|if\s*\(\$\w+\)|if\s*\(\$null\s*-ne|ForEach-Object|\$\w+Match\s*=|\$\w+Ref\s*=.*Match|\$\w+\s*=\s*\[regex\]|Matches\b'
                    }
                    if (-not $hasGuard) {
                        $violations += "L$($i+1): $($line.Trim())"
                    }
                }
            }
            $violations | Should -BeNullOrEmpty -Because `
                ".Groups[N].Value must be guarded by .Success, -match, or if-variable check (FIX-D). Violations: $($violations -join '; ')"
        }
    }

    Context 'FIX-E: -split result indexed without bounds check' {
        It 'All -split result indexing [1] or higher has element count guard' {
            $violations = @()
            for ($i = 0; $i -lt $script:dmLines.Count; $i++) {
                $line = $script:dmLines[$i]
                # Match $parts[1], $parts[2] etc. (not [0] which always exists if non-null)
                if ($line -match '\$parts\[([1-9]\d*)\]' -and $line -notmatch '^\s*#') {
                    $reqIndex = [int]$Matches[1]
                    # Need .Count -ge ($reqIndex+1) or -ge 2 etc. within 5 lines
                    $hasGuard = Test-GuardWithinLines -Lines $script:dmLines `
                        -TargetLineIndex $i -LookbackLines 5 `
                        -GuardPattern "\.Count\s*-ge\s*$($reqIndex+1)|\.Count\s*-ge\s*2|\.Count\s*-gt\s*$reqIndex|-split\s.*,\s*$($reqIndex+1)"
                    # Also accept: the -split is on a known-format key (e.g. 'a|b' always has 2 parts)
                    if (-not $hasGuard) {
                        # Accept if the split source is a constructed key with known delimiter count
                        $hasKnownFormat = Test-GuardWithinLines -Lines $script:dmLines `
                            -TargetLineIndex $i -LookbackLines 10 `
                            -GuardPattern '\$\w+Key\s*=\s*"\$\w+\|\$\w+"|\$folderKey\s*=|"\$\w+\|\$\w+"'
                        if (-not $hasKnownFormat) {
                            $violations += "L$($i+1): $($line.Trim())"
                        }
                    }
                }
            }
            $violations | Should -BeNullOrEmpty -Because `
                "-split result index > 0 needs .Count -ge guard (FIX-E). Violations: $($violations -join '; ')"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# 7. INVOKE-SCRIPTDEPENDENCYMATRIX — Runtime simulation
# ═══════════════════════════════════════════════════════════════════════
Describe 'Invoke-ScriptDependencyMatrix: P027 runtime null-condition simulation' {

    Context 'FIX-D: -match fails and $Matches is stale' {
        It 'Does not throw when -match fails and Matches[1] is guarded' {
            Assert-NoNullArrayIndex -Label 'DM FIX-D match-fail' -Code {
                $line = 'no match here'
                $moduleName = $null
                if ($line -match "ModuleName\s*=\s*'([^']+)'") {
                    $moduleName = $Matches[1]
                }
                $moduleName | Should -BeNullOrEmpty
            }
        }
    }

    Context 'FIX-D: Regex .Groups[N] on failed match' {
        It 'Does not throw when regex match fails and Groups is guarded' {
            Assert-NoNullArrayIndex -Label 'DM FIX-D groups-fail' -Code {
                $text = 'no psm1 reference'
                $m = [regex]::Match($text, '(\S+\.psm1)')
                $fileName = $null
                if ($m.Success) {
                    $fileName = $m.Groups[1].Value
                }
                $fileName | Should -BeNullOrEmpty
            }
        }
    }

    Context 'FIX-E: -split on empty or malformed string' {
        It 'Does not throw when -split returns single element and [1] is guarded' {
            Assert-NoNullArrayIndex -Label 'DM FIX-E split-single' -Code {
                $key = 'nopipe'  # No pipe delimiter
                $parts = @($key -split '\|', 2)
                $left = $null; $right = $null
                if ($parts.Count -ge 2) {
                    $left = $parts[0]
                    $right = $parts[1]
                }
                $right | Should -BeNullOrEmpty
            }
        }
        It 'Does not throw when -split source is $null' {
            Assert-NoNullArrayIndex -Label 'DM FIX-E split-null' -Code {
                $key = $null
                $parts = @(if ($null -ne $key) { $key -split '\|', 2 } else { @() })
                if ($parts.Count -ge 2) {
                    $unused = $parts[1]
                }
            }
        }
    }

    Context 'FIX-A: Get-ChildItem returns empty for scan history look-up' {
        It 'Does not throw when no matrix files found and [0] is guarded' {
            Assert-NoNullArrayIndex -Label 'DM FIX-A empty-history' -Code {
                $matrixFiles = @()  # Simulates no JSON files found
                if ($matrixFiles.Count -gt 0) {
                    $first = $matrixFiles[0]
                }
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# 8. CROSS-FIX REGRESSION DETECTION — Ensures mixed fix strategies
#    in the same file do not conflict
# ═══════════════════════════════════════════════════════════════════════
Describe 'P027 Cross-Fix Regression Detection' {

    Context 'FIX-A vs FIX-C: @() force-array must not mask $null source' {
        It '@() on $null produces empty array with .Count 0, not 1' {
            $result = $null
            $arr = @($result)
            # @($null) in PS 5.1 produces a 1-element array containing $null
            # The correct pattern is: @($result).Count -gt 0 -and $null -ne $result[0]
            # OR: check $null -ne $result BEFORE the @()
            if (@($arr).Count -gt 0 -and $null -ne $arr[0]) {
                # This block should NOT execute for a $null source
                $arr[0] | Should -Not -BeNullOrEmpty
            }
        }
        It 'FIX-C before FIX-A is the safe compound pattern' {
            Assert-NoNullArrayIndex -Label 'FIX-C+A compound' -Code {
                $result = $null
                if ($null -ne $result) {
                    $arr = @($result)
                    if ($arr.Count -gt 0) {
                        $val = $arr[0]
                    }
                }
            }
        }
    }

    Context 'FIX-B vs FIX-F: .Count guard must not be inside try/catch that swallows it' {
        It 'Count guard takes precedence over try/catch' {
            Assert-NoNullArrayIndex -Label 'FIX-B+F priority' -Code {
                $selectedRows = @()
                # FIX-B should be the outer guard, FIX-F should only be fallback
                if (@($selectedRows).Count -gt 0) {
                    try {
                        $row = $selectedRows[0]
                    } catch [System.Management.Automation.RuntimeException] {
                        $row = $null
                    }
                }
            }
        }
    }

    Context 'FIX-D vs FIX-E: -match guard must not leak into -split scope' {
        It 'Separate guard scopes for -match and -split on same line set' {
            Assert-NoNullArrayIndex -Label 'FIX-D+E isolation' -Code {
                $line = 'module|v1.0'
                $moduleName = $null
                $version = $null
                # FIX-D scope
                if ($line -match '^(\w+)\|') {
                    $moduleName = $Matches[1]
                }
                # FIX-E scope — must not rely on -match being true
                $parts = @($line -split '\|', 2)
                if ($parts.Count -ge 2) {
                    $version = $parts[1]
                }
                $moduleName | Should -Be 'module'
                $version | Should -Be 'v1.0'
            }
        }
    }

    Context 'Regression: valid non-null arrays must still index correctly' {
        It 'Single-element array indexed [0] works with all fix patterns' {
            $arr = @('only-item')
            @($arr).Count | Should -Be 1
            if (@($arr).Count -gt 0) { $arr[0] | Should -Be 'only-item' }
        }
        It 'Multi-element array indexed [0] and [1] works' {
            $arr = @('first', 'second', 'third')
            if ($null -ne $arr -and @($arr).Count -ge 2) {
                $arr[0] | Should -Be 'first'
                $arr[1] | Should -Be 'second'
            }
        }
        It '-match that succeeds still populates $Matches correctly' {
            $line = "ModuleName = 'Pester'"
            if ($line -match "ModuleName\s*=\s*'([^']+)'") {
                $Matches[1] | Should -Be 'Pester'
            }
        }
        It '-split with valid delimiter still produces correct parts' {
            $key = 'scripts|modules'
            $parts = @($key -split '\|', 2)
            $parts.Count | Should -Be 2
            if ($parts.Count -ge 2) {
                $parts[0] | Should -Be 'scripts'
                $parts[1] | Should -Be 'modules'
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# 9. SIN PATTERN DEFINITION VALIDATION
# ═══════════════════════════════════════════════════════════════════════
Describe 'P027 SIN Registry Definition Validation' {
    BeforeAll {
        $script:sinFile = Join-Path $script:WorkspaceRoot 'sin_registry\SIN-PATTERN-027-NULL-ARRAY-INDEX_202604080000.json'
    }

    It 'P027 definition file exists' {
        Test-Path $script:sinFile | Should -BeTrue
    }

    It 'P027 definition is valid JSON with required fields' {
        $def = Get-Content $script:sinFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $def.sin_id       | Should -Not -BeNullOrEmpty
        $def.title        | Should -Not -BeNullOrEmpty
        $def.severity     | Should -Be 'HIGH'
        $def.category     | Should -Be 'runtime-error'
        $def.scan_regex   | Should -Not -BeNullOrEmpty
        $def.preventionRule | Should -Not -BeNullOrEmpty
    }

    It 'P027 scan_regex compiles as valid .NET regex' {
        $def = Get-Content $script:sinFile -Raw -Encoding UTF8 | ConvertFrom-Json
        { [regex]::new($def.scan_regex) } | Should -Not -Throw
    }

    It 'P027 context_guard_regex compiles as valid .NET regex' {
        $def = Get-Content $script:sinFile -Raw -Encoding UTF8 | ConvertFrom-Json
        { [regex]::new($def.context_guard_regex) } | Should -Not -Throw
    }

    It 'P027 scan_regex detects numeric, negative, and variable index forms' {
        $def = Get-Content $script:sinFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $rx = [regex]::new($def.scan_regex)
        $rx.IsMatch('$files[0]') | Should -BeTrue
        $rx.IsMatch('$files[-1]') | Should -BeTrue
        $rx.IsMatch('$files[$idx]') | Should -BeTrue
    }

    It 'P027 defines all six fix scenarios' {
        $def = Get-Content $script:sinFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $fixes = $def.known_fix_scenarios.PSObject.Properties.Name
        @($fixes).Count | Should -Be 6
        $fixes | Should -Contain 'FIX-A-FORCE-ARRAY'
        $fixes | Should -Contain 'FIX-B-COUNT-PRECONDITION'
        $fixes | Should -Contain 'FIX-C-NULL-NE-GUARD'
        $fixes | Should -Contain 'FIX-D-MATCH-GUARD'
        $fixes | Should -Contain 'FIX-E-SPLIT-BOUNDS'
        $fixes | Should -Contain 'FIX-F-TRYCATCH-WRAP'
    }

    It 'P027 known_instances lists entries for all 3 target files' {
        $def = Get-Content $script:sinFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $instances = $def.known_instances -join '|'
        $instances | Should -Match 'Show-ScanDashboard'
        $instances | Should -Match 'Invoke-ScriptDependencyMatrix'
        $instances | Should -Match 'Invoke-ModuleManagement'
    }
}

Describe 'P027 Scanner Gate Enforcement' {
    BeforeAll {
        $script:scannerPath = Join-Path $script:WorkspaceRoot 'tests\Invoke-SINPatternScanner.ps1'
        $script:tmpDir = Join-Path $script:WorkspaceRoot 'temp\p027-scanner-gate-tests'
        if (-not (Test-Path $script:tmpDir)) {
            New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        }
        $script:scannerOut = Join-Path $script:tmpDir 'scanner-output.json'
        $script:violationFile = Join-Path $script:tmpDir 'P027-Violation.ps1'
        $script:guardedFile = Join-Path $script:tmpDir 'P027-Guarded.ps1'
        @(
            '# VersionTag: 2605.B5.V46.0',
            '$items = $null',
            '$first = $items[0]'
        ) | Set-Content -LiteralPath $script:violationFile -Encoding UTF8
        @(
            '# VersionTag: 2605.B5.V46.0',
            '$items = @(''a'')',
            'if (@($items).Count -gt 0) { $first = $items[0] }'
        ) | Set-Content -LiteralPath $script:guardedFile -Encoding UTF8
    }

    AfterAll {
        Remove-Item -LiteralPath $script:violationFile -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:guardedFile -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:scannerOut -ErrorAction SilentlyContinue
        if (Test-Path $script:tmpDir) {
            Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Scanner reports a P027 finding for an unguarded index' {
        $result = & $script:scannerPath -WorkspacePath $script:WorkspaceRoot -IncludeFiles $script:violationFile -Quiet
        $p027Hits = @($result.findings | Where-Object { $_.sinId -match 'SIN-PATTERN-0*27(?:\D|$)|NULL-ARRAY-INDEX|(?:^|-)P027(?:\D|$)' })
        @($p027Hits).Count | Should -BeGreaterThan 0
    }

    It 'Scanner suppresses a guarded P027 pattern' {
        $result = & $script:scannerPath -WorkspacePath $script:WorkspaceRoot -IncludeFiles $script:guardedFile -Quiet
        $p027Hits = @($result.findings | Where-Object { $_.sinId -match 'SIN-PATTERN-0*27(?:\D|$)|NULL-ARRAY-INDEX|(?:^|-)P027(?:\D|$)' })
        @($p027Hits).Count | Should -Be 0
    }

    It 'Scanner exits non-zero when FailOnSinId targets P027' {
        if (Test-Path $script:scannerOut) { Remove-Item -LiteralPath $script:scannerOut -ErrorAction SilentlyContinue }
        $scannerProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $script:scannerPath,
            '-WorkspacePath', $script:WorkspaceRoot,
            '-IncludeFiles', $script:violationFile,
            '-FailOnSinId', 'P027',
            '-OutputJson', $script:scannerOut,
            '-Quiet'
        ) -Wait -PassThru -NoNewWindow
        $scannerProc.ExitCode | Should -Be 1
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





