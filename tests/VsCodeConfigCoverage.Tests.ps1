# VersionTag: 2608.B1.V1.0
# SupportPS5.1: YES
# SupportsPS7.6: YES
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\VsCodeConfigCoverage.psm1'
Import-Module $modulePath -Force -ErrorAction Stop

Describe 'VsCodeConfigCoverage' {
    BeforeEach {
        $fixtureRoot = Join-Path $TestDrive 'vscode-fixture'
        $programFiles = Join-Path $fixtureRoot 'ProgramFiles'
        $localAppData = Join-Path $fixtureRoot 'LocalAppData'
        $userData = Join-Path $fixtureRoot 'AppData'
        $workspace = Join-Path $fixtureRoot 'workspace'
        $defaultDir = Join-Path (Join-Path (Join-Path (Join-Path $programFiles 'Microsoft VS Code') 'resources') 'app') 'defaults'
        $userDir = Join-Path $userData 'Code'
        $workspaceDir = Join-Path $workspace '.vscode'
        foreach ($path in @($defaultDir, $userDir, $workspaceDir)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        $default = @'
{
  // Install baseline
  "editor.fontSize": 12,
  "editor.tabSize": 4,
  "security.workspace.trust.enabled": true,
  "secret.token": "baseline-token",
}
'@
        $current = @'
{
  /* Current user settings */
  "editor.fontSize": 14,
  "security.workspace.trust.enabled": true,
  "workbench.colorTheme": "Default Dark+",
  "secret.token": "current-token",
}
'@
        $workspaceSettings = @'
    { "files.exclude": { "**/*.tmp": true, }, "editor.tabSize": 2 }
'@
        Set-Content -LiteralPath (Join-Path $defaultDir 'settings.json') -Value $default -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $userDir 'settings.json') -Value $current -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $workspaceDir 'settings.json') -Value $workspaceSettings -Encoding UTF8
        $discovery = Get-VsCodePathDiscovery -UserDataRoot $userData -ProgramFilesRoot $programFiles -LocalAppDataRoot $localAppData -WorkspacePath $workspace
    }

    It 'discovers stable install, user, and workspace paths' {
        $discovery.Stable.InstallDefaultPath | Should -Be (Join-Path $fixtureRoot 'ProgramFiles\Microsoft VS Code\resources\app\defaults\settings.json')
        $discovery.Stable.CurrentUserPath | Should -Be (Join-Path $fixtureRoot 'AppData\Code\settings.json')
        $discovery.Stable.CurrentWorkspacePath | Should -Be (Join-Path $fixtureRoot 'workspace\.vscode\settings.json')
        $discovery.Insiders.CurrentUserPath | Should -Match 'Code - Insiders'
    }

    It 'parses JSONC comments and trailing commas' {
        $jsonc = "{ `"editor`": { `"fontSize`": 12, }, // comment`n `"enabled`": true }"
        (Remove-VsCodeJsonComments -Content $jsonc) | Should -Not -Match '//'
        $document = ConvertFrom-VsCodeJsonc -Content $jsonc
        $document.editor.fontSize | Should -Be 12
        $document.enabled | Should -BeTrue
    }

    It 'normalizes paths and redacts secret values' {
        $document = ConvertFrom-VsCodeJsonc -Content '{ "editor.fontSize": 14, "auth": { "apiKey": "do-not-persist" } }'
        $records = @(ConvertTo-VsCodeNormalizedRecords -Document $document)
        ($records | Where-Object KeyPath -eq 'auth.apiKey').Value | Should -Be '[REDACTED]'
        ($records | Where-Object KeyPath -eq 'editor.fontSize').Value | Should -Be '14'
        ($records | Where-Object KeyPath -eq 'auth.apiKey').Redacted | Should -BeTrue
    }

    It 'captures install defaults and current user/workspace sources' {
        $snapshot = Get-VsCodeConfigSnapshot -WorkspacePath $workspace -Discovery $discovery
        @($snapshot.Sources | Where-Object { $_.Available }).Count | Should -Be 4
        @($snapshot.Sources | Where-Object { $_.BaselineKind -eq 'install-default' -and $_.Available }).Count | Should -Be 1
        @($snapshot.Sources | Where-Object { $_.Scope -eq 'workspace' -and $_.Available }).Count | Should -Be 2
    }

    It 'reports unchanged, added, removed, changed, and unavailable statuses' {
        $snapshot = Get-VsCodeConfigSnapshot -WorkspacePath $workspace -Discovery $discovery
        $reference = $snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $report = Compare-VsCodeConfigSnapshot -ReferenceSnapshot $reference -CurrentSnapshot $snapshot -Scope combined
        @($report.Rows | Where-Object Status -eq 'UNCHANGED').Count | Should -BeGreaterThan 0

        $currentUser = @($snapshot.Sources | Where-Object { $_.Scope -eq 'user' -and $_.BaselineKind -eq 'current' })[0]
        $currentUser.Records = @($currentUser.Records | Where-Object KeyPath -ne 'editor.tabSize')
        $currentUser.Records += [ordered]@{ KeyPath = 'new.setting'; Value = 'true'; ValueType = 'Boolean'; Redacted = $false }
        $currentUser.Records = @($currentUser.Records | ForEach-Object { if ($_.KeyPath -eq 'editor.fontSize') { $_.Value = '99' }; $_ })
        $currentUser.Available = $true
        $report = Compare-VsCodeConfigSnapshot -ReferenceSnapshot $reference -CurrentSnapshot $snapshot -Scope user
        @($report.Rows | Where-Object Status -eq 'ADDED').Count | Should -BeGreaterThan 0
        @($report.Rows | Where-Object Status -eq 'REMOVED').Count | Should -BeGreaterThan 0
        @($report.Rows | Where-Object Status -eq 'CHANGED').Count | Should -BeGreaterThan 0

        $currentUser.Available = $false
        $report = Compare-VsCodeConfigSnapshot -ReferenceSnapshot $reference -CurrentSnapshot $snapshot -Scope user
        @($report.Rows | Where-Object Status -eq 'UNAVAILABLE').Count | Should -Be 2
    }

    It 'filters Config AiNge recommendations by category and text' {
        $snapshot = Get-VsCodeConfigSnapshot -WorkspacePath $workspace -Discovery $discovery
        $reference = $snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $currentUser = @($snapshot.Sources | Where-Object { $_.Scope -eq 'user' -and $_.BaselineKind -eq 'current' })[0]
        $currentUser.Records += [ordered]@{ KeyPath = 'security.proxy.token'; Value = '[REDACTED]'; ValueType = 'Secret'; Redacted = $true }
        $comparison = Compare-VsCodeConfigSnapshot -ReferenceSnapshot $reference -CurrentSnapshot $snapshot -Scope combined
        $security = Get-VsCodeConfigRecommendations -Report $comparison -Category 'security hardening'
        @($security | Where-Object Category -eq 'security hardening').Count | Should -BeGreaterThan 0
        (Get-VsCodeConfigRecommendations -Report $comparison -Category all -Filter 'proxy').Count | Should -BeGreaterThan 0
        $report = New-VsCodeConfigCoverageReport -Snapshot $snapshot -InstallBaseline $reference -Scope combined -FilterCategory all -Filter 'security'
        $report.Scope | Should -Be 'combined'
    }
}
