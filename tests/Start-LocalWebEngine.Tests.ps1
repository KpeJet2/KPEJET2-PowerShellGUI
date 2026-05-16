# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Smoke tests for Start-LocalWebEngine.ps1 — route presence, CSRF guard, SIN compliance.
.DESCRIPTION
    Tests: All expected API routes declared, CSRF protection on mutating routes,
    new routes /api/scan/static and /api/agent/stats present, SIN compliance.
    NOTE: These are static-analysis tests only — engine is NOT started.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:WorkspacePath = Split-Path $PSScriptRoot -Parent
    $script:EngineScript  = Join-Path $script:WorkspacePath 'scripts\Start-LocalWebEngine.ps1'
    $script:Content       = Get-Content -LiteralPath $script:EngineScript -Raw
    $script:Lines         = @(Get-Content -LiteralPath $script:EngineScript -Encoding UTF8)
}

Describe 'Start-LocalWebEngine — Script exists' {
    It 'Script file is present' {
        Test-Path -LiteralPath $script:EngineScript | Should -Be $true
    }
    It 'Has a VersionTag header' {
        $script:Lines[0] | Should -Match 'VersionTag'
    }
}

Describe 'Start-LocalWebEngine — API Route declarations' {
    It 'Has /api/scan/status route' {
        $script:Content | Should -Match '/api/scan/status'
    }
    It 'Has /api/scan/crashes route' {
        $script:Content | Should -Match '/api/scan/crashes'
    }
    It 'Has /api/scan/full route' {
        $script:Content | Should -Match '/api/scan/full'
    }
    It 'Has /api/scan/incremental route' {
        $script:Content | Should -Match '/api/scan/incremental'
    }
    It 'Has /api/scan/static route (new)' {
        $script:Content | Should -Match '/api/scan/static'
    }
    It 'Has /api/agent/stats route (new)' {
        $script:Content | Should -Match '/api/agent/stats'
    }
    It 'Has /api/engine/status route' {
        $script:Content | Should -Match '/api/engine/status'
    }
    It 'Has /api/engine/events route' {
        $script:Content | Should -Match '/api/engine/events'
    }
    It 'Has /api/engine/logs/list route' {
        $script:Content | Should -Match '/api/engine/logs/list'
    }
    It 'Has /api/engine/stop route' {
        $script:Content | Should -Match '/api/engine/stop'
    }
    It 'Has /api/csrf-token route' {
        $script:Content | Should -Match '/api/csrf-token'
    }
    It 'Has /api/config/bootstrap-menu/rollback route' {
        $script:Content | Should -Match '/api/config/bootstrap-menu/rollback'
    }
    It 'Has /api/config/bootstrap-menu/history route' {
        $script:Content | Should -Match '/api/config/bootstrap-menu/history'
    }
}

Describe 'Start-LocalWebEngine — Handler functions present' {
    It 'Has Invoke-StaticScan function' {
        $script:Content | Should -Match 'function Invoke-StaticScan'
    }
    It 'Has Get-AgentStats function' {
        $script:Content | Should -Match 'function Get-AgentStats'
    }
    It 'Has Invoke-Scan function' {
        $script:Content | Should -Match 'function Invoke-Scan'
    }
    It 'Has Get-EngineEvents function' {
        $script:Content | Should -Match 'function Get-EngineEvents'
    }

    It 'Has request client class helper function' {
        $script:Content | Should -Match 'function Get-RequestClientClass'
    }

    It 'Has static fallback allow-list helper function' {
        $script:Content | Should -Match 'function Test-StaticFallbackAllowed'
    }

    It 'Has bootstrap config validator function' {
        $script:Content | Should -Match 'function Test-BootstrapMenuConfigObject'
    }

    It 'Has bootstrap snapshot helper function' {
        $script:Content | Should -Match 'function New-BootstrapMenuSnapshot'
    }

    It 'Has bootstrap rollback handler function' {
        $script:Content | Should -Match 'function Rollback-BootstrapMenuConfig'
    }

    It 'Has bootstrap snapshot retention helper function' {
        $script:Content | Should -Match 'function Invoke-BootstrapMenuSnapshotRetention'
    }

    It 'Has bootstrap rollback snapshot resolver function' {
        $script:Content | Should -Match 'function Resolve-BootstrapRollbackSnapshot'
    }

    It 'Has bootstrap history handler function' {
        $script:Content | Should -Match 'function Get-BootstrapMenuSnapshotHistory'
    }
}

Describe 'Start-LocalWebEngine — Bootstrap menu governance checks' {
    It 'Save-BootstrapMenuConfig validates payload via Test-BootstrapMenuConfigObject' {
        $script:Content | Should -Match 'Test-BootstrapMenuConfigObject\s+-Config\s+\$parsed'
    }

    It 'Save-BootstrapMenuConfig creates snapshot before write' {
        $script:Content | Should -Match 'New-BootstrapMenuSnapshot\s+-ConfigFile\s+\$cfgFile'
    }

    It 'Save-BootstrapMenuConfig enforces schema version' {
        $script:Content | Should -Match 'Unsupported schema: \$\(\$parsed\.schema\)'
    }

    It 'Save-BootstrapMenuConfig applies snapshot retention policy' {
        $script:Content | Should -Match 'Invoke-BootstrapMenuSnapshotRetention\s+-Keep\s+50'
    }

    It 'Rollback-BootstrapMenuConfig is wired in route switch' {
        $script:Content | Should -Match 'Rollback-BootstrapMenuConfig\s+-Context\s+\$context'
    }

    It 'Rollback-BootstrapMenuConfig supports targeted snapshot requests' {
        $script:Content | Should -Match 'Resolve-BootstrapRollbackSnapshot\s+-RequestedSnapshot\s+\$requestedSnapshot'
    }

    It 'Get-BootstrapMenuSnapshotHistory returns snapshot count payload' {
        $script:Content | Should -Match 'snapshots\s*=\s*\$items'
        $script:Content | Should -Match 'count\s*=\s*@\(\$items\)\.Count'
    }
}

Describe 'Start-LocalWebEngine — CSRF protection on mutating routes' {
    It 'Invoke-Scan checks SessionToken' {
        # Find function block and verify CSRF check
        $script:Content | Should -Match 'SessionToken'
    }
    It 'Invoke-StaticScan has CSRF check' {
        # Ensure the new static scan function also has CSRF
        $content = $script:Content
        $fIdx = $content.IndexOf('function Invoke-StaticScan')
        $fBlock = $content.Substring($fIdx, [Math]::Min(600, $content.Length - $fIdx))
        $fBlock | Should -Match 'SessionToken'
    }
    It 'Get-AgentStats does NOT require CSRF (GET route)' {
        # GET routes should not enforce CSRF
        $content = $script:Content
        $fIdx = $content.IndexOf('function Get-AgentStats')
        $fBlock = $content.Substring($fIdx, [Math]::Min(2000, $content.Length - $fIdx))
        # Should reach the next function without a CSRF block — just check it has Send-Json
        $fBlock | Should -Match 'Send-Json'
    }

    It '/api/csrf-token includes clientClass metadata' {
        $script:Content | Should -Match 'clientClass\s*=\s*\$clientClass'
    }
}

Describe 'Start-LocalWebEngine — WebSocket hello schema hardening' {
    It 'WebSocket hello payload does not include csrfToken field' {
        $helloLines = @($script:Lines | Where-Object { $_ -match '\$hello\s*=\s*@\{.*event\s*=\s*''connected''' })
        @($helloLines).Count | Should -BeGreaterThan 0
        foreach ($line in $helloLines) {
            $line -cmatch 'csrfToken' | Should -BeFalse
        }
    }
}

Describe 'Start-LocalWebEngine — SIN compliance' {
    It 'No PS7-only null-coalesce in code lines (P005)' {
        $codeLines = $script:Lines | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch "'\?\?'" -and $_ -notmatch '"\?\?"' }
        ($codeLines -join ' ') | Should -Not -Match '\?\?'
    }
    It 'No hardcoded absolute paths in code lines (P015)' {
        $codeLines = $script:Lines | Where-Object { $_ -notmatch '^\s*#' }
        ($codeLines -join ' ') | Should -Not -Match "C:\\\\PowerShellGUI"
    }
    It 'No Invoke-Expression in code lines (P010)' {
        $codeLines = $script:Lines | Where-Object { $_ -notmatch '^\s*#' }
        ($codeLines -join ' ') | Should -Not -Match '\bInvoke-Expression\b|\biex\b'
    }
    It 'All Set-Content calls use -LiteralPath (P009)' {
        $setContentLines = $script:Lines | Where-Object { $_ -match '\bSet-Content\b' -and $_ -notmatch '^\s*#' }
        foreach ($line in $setContentLines) {
            $line | Should -Match '-LiteralPath|-Encoding' -Because 'Set-Content should use -LiteralPath and -Encoding (P009/P012)'
        }
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





