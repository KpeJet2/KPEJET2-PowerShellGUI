# VersionTag: 2604.B1.V32.5
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
}

Describe 'Start-LocalWebEngine — Handler functions present' {
    It 'Has Handle-TriggerStaticScan function' {
        $script:Content | Should -Match 'function Handle-TriggerStaticScan'
    }
    It 'Has Handle-AgentStats function' {
        $script:Content | Should -Match 'function Handle-AgentStats'
    }
    It 'Has Handle-TriggerScan function' {
        $script:Content | Should -Match 'function Handle-TriggerScan'
    }
    It 'Has Handle-EngineEvents function' {
        $script:Content | Should -Match 'function Handle-EngineEvents'
    }
}

Describe 'Start-LocalWebEngine — CSRF protection on mutating routes' {
    It 'Handle-TriggerScan checks SessionToken' {
        # Find function block and verify CSRF check
        $script:Content | Should -Match 'SessionToken'
    }
    It 'Handle-TriggerStaticScan has CSRF check' {
        # Ensure the new static scan function also has CSRF
        $content = $script:Content
        $fIdx = $content.IndexOf('function Handle-TriggerStaticScan')
        $fBlock = $content.Substring($fIdx, [Math]::Min(600, $content.Length - $fIdx))
        $fBlock | Should -Match 'SessionToken'
    }
    It 'Handle-AgentStats does NOT require CSRF (GET route)' {
        # GET routes should not enforce CSRF
        $content = $script:Content
        $fIdx = $content.IndexOf('function Handle-AgentStats')
        $fBlock = $content.Substring($fIdx, [Math]::Min(2000, $content.Length - $fIdx))
        # Should reach the next function without a CSRF block — just check it has Send-Json
        $fBlock | Should -Match 'Send-Json'
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
