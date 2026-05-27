# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-05-02
# SupportsPS7.6TestedDate: 2026-05-02
# FileRole: Tests
<#
.SYNOPSIS
    Pester v5 standardised tests for the nine module-environment / manifest scripts:
        scripts/Validate-ModuleImports.ps1
        scripts/Publish-WorkspaceModules.ps1
        scripts/Build-AgenticManifest.ps1
        modules/PwShGUI-VersionTag.psm1
        modules/PwShGUI-HistoryZip.psm1
        modules/Import-WorkspaceModule.psm1
        scripts/Script-F - LinkToConfigJson.ps1
        scripts/Set-WorkspaceModulePath.ps1
        scripts/Setup-ModuleEnvironment.ps1
.DESCRIPTION
    Validates: file existence, parser cleanliness, required headers
    (VersionTag / SupportPS5.1 / SupportsPS7.6 / FileRole), function-level
    contracts for the two single-function modules, the path-traversal guard
    in PwShGUI-HistoryZip, and that every file is registered in
    config/agentic-manifest.json.
#>

BeforeAll {
    $script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot
    $script:Targets = @(
        @{ Rel = 'scripts\Validate-ModuleImports.ps1';        Kind = 'script' }
        @{ Rel = 'scripts\Publish-WorkspaceModules.ps1';      Kind = 'script' }
        @{ Rel = 'scripts\Build-AgenticManifest.ps1';         Kind = 'script' }
        @{ Rel = 'modules\PwShGUI-VersionTag.psm1';           Kind = 'module' }
        @{ Rel = 'modules\PwShGUI-HistoryZip.psm1';           Kind = 'module' }
        @{ Rel = 'modules\Import-WorkspaceModule.psm1';       Kind = 'module' }
        @{ Rel = 'scripts\Script-F - LinkToConfigJson.ps1';   Kind = 'script' }
        @{ Rel = 'scripts\Set-WorkspaceModulePath.ps1';       Kind = 'script' }
        @{ Rel = 'scripts\Setup-ModuleEnvironment.ps1';       Kind = 'script' }
    )

    $script:ManifestPath = Join-Path $WorkspaceRoot 'config\agentic-manifest.json'
}

Describe 'Nine-Script Suite: existence and parser cleanliness' {
    It 'every target file exists' {
        foreach ($t in $script:Targets) {
            $full = Join-Path $script:WorkspaceRoot $t.Rel
            Test-Path -LiteralPath $full | Should -BeTrue -Because "missing: $($t.Rel)"
        }
    }

    It 'every target file parses without errors' {
        foreach ($t in $script:Targets) {
            $full = Join-Path $script:WorkspaceRoot $t.Rel
            $errs = $null; $tokens = $null
            [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errs) | Out-Null
            (@($errs).Count) | Should -Be 0 -Because "parser errors in $($t.Rel)"
        }
    }
}

Describe 'Nine-Script Suite: required header tags' {
    It 'every target file declares VersionTag, SupportPS5.1, SupportsPS7.6, FileRole' {
        foreach ($t in $script:Targets) {
            $full = Join-Path $script:WorkspaceRoot $t.Rel
            $head = Get-Content -LiteralPath $full -TotalCount 30 -Encoding UTF8
            $joined = ($head -join "`n")
            $joined | Should -Match '#\s*VersionTag:\s*\d{4}\.B\d+\.V\d+\.\d+'   -Because "VersionTag missing in $($t.Rel)"
            $joined | Should -Match '#\s*SupportPS5\.1:\s*true'                  -Because "SupportPS5.1 missing in $($t.Rel)"
            $joined | Should -Match '#\s*SupportsPS7\.6:\s*true'                 -Because "SupportsPS7.6 missing in $($t.Rel)"
            $joined | Should -Match '#\s*FileRole:\s*\S+'                        -Because "FileRole missing in $($t.Rel)"
        }
    }
}

Describe 'PwShGUI-VersionTag module' {
    BeforeAll {
        $script:VtPath = Join-Path $script:WorkspaceRoot 'modules\PwShGUI-VersionTag.psm1'
        Import-Module $script:VtPath -Force -DisableNameChecking
    }
    AfterAll { Remove-Module PwShGUI-VersionTag -Force -ErrorAction SilentlyContinue }

    It 'returns the supplied default when no path is given' {
        Get-VersionTag -Default '2605.B1.V99.0' | Should -Be '2605.B1.V99.0'
    }

    It 'parses a canonical VersionTag header from a file' {
        $tmp = New-TemporaryFile
        try {
            "# VersionTag: 2605.B5.V46.0`r`n# Other" | Set-Content -LiteralPath $tmp.FullName -Encoding UTF8
            Get-VersionTag -Path $tmp.FullName | Should -Be '2605.B1.V42.7'
        } finally { Remove-Item -LiteralPath $tmp.FullName -Force }
    }
}

Describe 'PwShGUI-HistoryZip module: path-traversal guard' {
    BeforeAll {
        $script:HzPath = Join-Path $script:WorkspaceRoot 'modules\PwShGUI-HistoryZip.psm1'
        Import-Module $script:HzPath -Force -DisableNameChecking
    }
    AfterAll { Remove-Module PwShGUI-HistoryZip -Force -ErrorAction SilentlyContinue }

    It 'rejects FileName containing a path separator' {
        { Get-HistoryFileFromZip -MajorVersion 'V31' -FileName '..\evil.json' } |
            Should -Throw -ExpectedMessage '*Invalid FileName*'
    }

    It 'rejects FileName containing parent-directory tokens' {
        { Get-HistoryFileFromZip -MajorVersion 'V31' -FileName '..evil' } |
            Should -Throw -ExpectedMessage '*Invalid FileName*'
    }

    It 'rejects an invalid MajorVersion pattern (parameter validation)' {
        { Get-HistoryFileFromZip -MajorVersion 'not-a-version' -FileName 'x.json' } |
            Should -Throw
    }
}

Describe 'Import-WorkspaceModule module' {
    BeforeAll {
        $script:IwPath = Join-Path $script:WorkspaceRoot 'modules\Import-WorkspaceModule.psm1'
        Import-Module $script:IwPath -Force -DisableNameChecking
    }
    AfterAll { Remove-Module Import-WorkspaceModule -Force -ErrorAction SilentlyContinue }

    It 'rejects an invalid module name (path-traversal guard)' {
        { Import-WorkspaceModule -Name '..\evil' } | Should -Throw -ExpectedMessage '*Invalid module name*'
    }

    It 'throws a descriptive error when the module is not found' {
        { Import-WorkspaceModule -Name 'NoSuchWorkspaceModule_ZZZ' } |
            Should -Throw -ExpectedMessage '*Module not found*'
    }
}

Describe 'Build-AgenticManifest script: structural integrity' {
    BeforeAll {
        $script:BamPath = Join-Path $script:WorkspaceRoot 'scripts\Build-AgenticManifest.ps1'
        $script:BamContent = Get-Content -LiteralPath $script:BamPath -Raw -Encoding UTF8
    }

    It 'has exactly one Extract-FunctionDefs definition (no P011 dup)' {
        $matches = [regex]::Matches($script:BamContent, '(?m)^\s*function\s+Extract-FunctionDefs\b')
        $matches.Count | Should -Be 1
    }

    It 'has no leftover stub footer markers' {
        $script:BamContent | Should -Not -Match 'Stub:\s+describe module/script purpose here'
    }
}

Describe 'Agentic manifest registration' {
    BeforeAll {
        $script:ManifestPathLocal = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agentic-manifest.json'
    }

    It 'all nine targets are referenced in agentic-manifest.json' {
        if (-not (Test-Path -LiteralPath $script:ManifestPathLocal)) {
            Set-ItResult -Skipped -Because 'agentic-manifest.json not present'
            return
        }
        $raw = Get-Content -LiteralPath $script:ManifestPathLocal -Raw -Encoding UTF8
        foreach ($t in $script:Targets) {
            $leaf = Split-Path -Leaf $t.Rel
            ($raw.IndexOf($leaf) -ge 0) | Should -BeTrue -Because "manifest does not reference $leaf"
        }
    }
}

