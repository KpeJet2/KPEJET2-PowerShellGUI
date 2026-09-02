# VersionTag: 2607.B7.V53.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    Contract tests for Certificate Hub and approvals UX/API integration surfaces.
.DESCRIPTION
    Verifies static wiring between:
      - Start-LocalWebEngine route contracts
      - Workspace Hub tool registry and approvals normalization
      - Feature Requests submit-to-approvals action
    - Tracked menu/catalog exposure of cert hub
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot
    $script:EnginePath = Join-Path $script:WorkspaceRoot 'scripts\Start-LocalWebEngine.ps1'
    $script:HubPath = Join-Path $script:WorkspaceRoot 'XHTML-WorkspaceHub.xhtml'
    $script:FeaturePath = Join-Path $script:WorkspaceRoot 'scripts\XHTML-Checker\XHTML-FeatureRequests.xhtml'
    $script:CertHubPath = Join-Path $script:WorkspaceRoot 'scripts\XHTML-Checker\XHTML-CertificateManagementHub.xhtml'

    $script:EngineText = if (Test-Path -LiteralPath $script:EnginePath) { Get-Content -LiteralPath $script:EnginePath -Raw -Encoding UTF8 } else { '' }
    $script:HubText = if (Test-Path -LiteralPath $script:HubPath) { Get-Content -LiteralPath $script:HubPath -Raw -Encoding UTF8 } else { '' }
    $script:FeatureText = if (Test-Path -LiteralPath $script:FeaturePath) { Get-Content -LiteralPath $script:FeaturePath -Raw -Encoding UTF8 } else { '' }
    $script:CertHubText = if (Test-Path -LiteralPath $script:CertHubPath) { Get-Content -LiteralPath $script:CertHubPath -Raw -Encoding UTF8 } else { '' }
}

Describe 'Cert/Approvals surface files exist' {
    It 'Engine script exists' { Test-Path -LiteralPath $script:EnginePath | Should -BeTrue }
    It 'Workspace hub XHTML exists' { Test-Path -LiteralPath $script:HubPath | Should -BeTrue }
    It 'Feature requests XHTML exists' { Test-Path -LiteralPath $script:FeaturePath | Should -BeTrue }
    It 'Certificate management hub XHTML exists' { Test-Path -LiteralPath $script:CertHubPath | Should -BeTrue }
}

Describe 'Build marker progression (B7)' {
    It 'Engine VersionTag moved to 2607.B7 with V preserved' {
        $script:EngineText | Should -Match 'VersionTag:\s*2607\.B7\.V\d+(?:\.\d+)?'
    }
    It 'Workspace hub VersionTag moved to 2607.B7 with V preserved' {
        $script:HubText | Should -Match 'VersionTag:\s*2607\.B7\.V\d+(?:\.\d+)?'
    }
    It 'Feature requests VersionTag moved to 2607.B7 with V preserved' {
        $script:FeatureText | Should -Match 'VersionTag:\s*2607\.B7\.V\d+(?:\.\d+)?'
    }
    It 'Certificate hub VersionTag moved to 2607.B7 with V preserved' {
        $script:CertHubText | Should -Match 'VersionTag:\s*2607\.B7\.V\d+(?:\.\d+)?'
    }
}

Describe 'Approvals API and UI compatibility' {
    It 'Engine includes /api/pipeline/feature-submit route case' {
        $script:EngineText | Should -Match '\^/api/pipeline/feature-submit\$'
    }
    It 'Engine includes feature-submit handler function' {
        $script:EngineText | Should -Match 'function\s+New-PipelineFeatureSubmit'
    }
    It 'Engine emits approvals aliases for items and pending' {
        $script:EngineText | Should -Match 'items\s*=\s*\$sorted;\s*pending\s*=\s*\$sorted;\s*count\s*=\s*@\(\$sorted\)\.Count'
    }
    It 'Workspace hub normalization accepts payload.items for pipeline approvals' {
        $script:HubText | Should -Match 'if \(payload && Array\.isArray\(payload\.items\)\)\s*\{\s*return \{ pending: payload\.items, count: payload\.count \|\| payload\.items\.length \};'
    }
    It 'Workspace hub loader falls back to data.items when pending absent' {
        $script:HubText | Should -Match '_approvalItems\s*=\s*Array\.isArray\(data\.pending\)\s*\?\s*data\.pending\s*:\s*\(Array\.isArray\(data\.items\)\s*\?\s*data\.items\s*:\s*\[\]\)'
    }
}

Describe 'Feature requests submit wiring' {
    It 'Feature requests has send-to-approvals button' {
        $script:FeatureText | Should -Match 'id="btnSendToApprovals"'
    }
    It 'Feature requests obtains CSRF token from engine' {
        $script:FeatureText | Should -Match "ENGINE_BASE\s*\+\s*'/api/csrf-token'"
    }
    It 'Feature requests posts submit payload to engine route' {
        $script:FeatureText | Should -Match "ENGINE_BASE\s*\+\s*'/api/pipeline/feature-submit'"
    }
    It 'Feature requests triggers pipeline processing after submit' {
        $script:FeatureText | Should -Match "ENGINE_BASE\s*\+\s*'/api/pipeline/process'"
    }
}

Describe 'Certificate hub exposure and capabilities' {
    It 'Workspace hub tool registry includes Certificate Management Hub card' {
        $script:HubText | Should -Match 'Certificate Management Hub'
        $script:HubText | Should -Match 'scripts/XHTML-Checker/XHTML-CertificateManagementHub.xhtml'
    }
    It 'Certificate hub includes ACME discovery controls' {
        $script:CertHubText | Should -Match 'Discover ACME Endpoints'
        $script:CertHubText | Should -Match 'btnDiscoverAcme'
    }
    It 'Certificate hub includes secrets integration controls' {
        $script:CertHubText | Should -Match 'Build Secret Escrow Commands'
        $script:CertHubText | Should -Match 'btnBuildSecretsFlow'
    }
    It 'Certificate hub includes browser trust hook controls' {
        $script:CertHubText | Should -Match 'Browser trust hooks'
        $script:CertHubText | Should -Match 'btnBuildBrowserHooks'
    }
}

Describe 'Additional menu surface integration' {
    It 'Feature requests XHTML Tools list includes Certificate Management Hub link' {
        $script:FeatureText | Should -Match 'XHTML-CertificateManagementHub\.xhtml'
    }
}
