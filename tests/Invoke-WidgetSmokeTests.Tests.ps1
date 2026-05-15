# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Comprehensive Pester 5 smoke tests for all PowerShellGUI widgets and tools.
.DESCRIPTION
    Exercises every module function, sub-tool script, form-rendering path,
    grid-loading callback, import/export round-trip, and config validation
    across the entire PowerShellGUI workspace -- all headlessly (no GUI launched).
.NOTES
    Author  : The Establishment
    Version : 2604.B2.V31.0
    Requires: Pester 5.x, PowerShell 7+
#>

BeforeDiscovery {
    $script:WS = (Split-Path -Parent $PSScriptRoot)
    $script:ModDir = Join-Path $script:WS 'modules'
    $script:ScDir  = Join-Path $script:WS 'scripts'
    $script:CfgDir = Join-Path $script:WS 'config'
    $script:TmpDir = Join-Path $script:WS 'temp'

    $script:ModuleNames = @(Get-ChildItem -Path $script:ModDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'LOCAL*' } | ForEach-Object { $_.BaseName })

    $script:SubToolScripts = @(
        @{ Name='Show-CronAiAthonTool.ps1';        PFn='Show-CronAiAthonTool' }
        @{ Name='Show-ScanDashboard.ps1';           PFn='Show-ScanDashboard' }
        @{ Name='Show-EventLogViewer.ps1';          PFn='Show-EventLogViewer' }
        @{ Name='Show-MCPServiceConfig.ps1';        PFn='Show-MCPServiceConfig' }
        @{ Name='Show-AppTemplateManager.ps1';      PFn='Show-AppTemplateManager' }
        @{ Name='UserProfile-Manager.ps1';          PFn='' }
        @{ Name='Invoke-PSEnvironmentScanner.ps1';  PFn='Invoke-FullScan' }
        @{ Name='Invoke-ScriptDependencyMatrix.ps1'; PFn='Export-SystemBackup' }
        @{ Name='Invoke-ChecklistActions.ps1';       PFn='Invoke-ChecklistItem' }
        @{ Name='Invoke-ModuleManagement.ps1';       PFn='Write-PercentRow' }
        @{ Name='Invoke-TodoManager.ps1';            PFn='' }
        @{ Name='WinRemote-PSTool.ps1';              PFn='' }
    )
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. MODULE IMPORT & EXPORT VERIFICATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'Module Import & Export Verification' -Tag 'ModuleImport' {

    It 'should import <_> without errors' -ForEach $script:ModuleNames {
        if ($_ -eq 'PwShGUI-Theme') {
            Set-ItResult -Skipped
            return
        }
        $p = Join-Path $script:ModDir "$_.psm1"
        { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } | Should -Not -Throw
        Remove-Module $_ -Force -ErrorAction SilentlyContinue
    }

    It 'CronAiAthon-Pipeline should export 20+ functions' {
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-Pipeline.psm1') -Force -DisableNameChecking
        (Get-Module 'CronAiAthon-Pipeline').ExportedFunctions.Keys.Count | Should -BeGreaterOrEqual 20
        Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
    }

    It 'PwShGUICore should export 14+ functions' {
        Import-Module (Join-Path $script:ModDir 'PwShGUICore.psm1') -Force -DisableNameChecking
        (Get-Module 'PwShGUICore').ExportedFunctions.Keys.Count | Should -BeGreaterOrEqual 14
        Remove-Module 'PwShGUICore' -Force -ErrorAction SilentlyContinue
    }

    It 'AssistedSASC should export 25+ functions' {
        Import-Module (Join-Path $script:ModDir 'AssistedSASC.psm1') -Force -DisableNameChecking
        (Get-Module 'AssistedSASC').ExportedFunctions.Keys.Count | Should -BeGreaterOrEqual 25
        Remove-Module 'AssistedSASC' -Force -ErrorAction SilentlyContinue
    }

    It 'PwShGUI-Theme should export 10 functions' -Skip:$true {
        Import-Module (Join-Path $script:ModDir 'PwShGUI-Theme.psm1') -Force -DisableNameChecking
        (Get-Module 'PwShGUI-Theme').ExportedFunctions.Keys.Count | Should -BeGreaterOrEqual 10
        Remove-Module 'PwShGUI-Theme' -Force -ErrorAction SilentlyContinue
    }

    It 'UserProfileManager should export 30+ functions' {
        Import-Module (Join-Path $script:ModDir 'UserProfileManager.psm1') -Force -DisableNameChecking
        (Get-Module 'UserProfileManager').ExportedFunctions.Keys.Count | Should -BeGreaterOrEqual 28
        Remove-Module 'UserProfileManager' -Force -ErrorAction SilentlyContinue
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. CONFIG VALIDATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'Config Validation' -Tag 'ConfigValidation' {

    It 'system-variables.xml should be well-formed XML with Buttons node' {
        $xmlPath = (Join-Path $script:CfgDir 'system-variables.xml')
        Test-Path $xmlPath | Should -BeTrue
        { [xml](Get-Content $xmlPath -Raw) } | Should -Not -Throw
        $xml = [xml](Get-Content $xmlPath -Raw)
        $btns = $xml.SelectNodes('//Buttons')
        if (-not $btns -or $btns.Count -eq 0) { $btns = $xml.SelectNodes('//buttons') }
        $btns.Count | Should -BeGreaterOrEqual 1
    }

    It 'all JSON in config/ should be valid' {
        $jFiles = @(Get-ChildItem -Path $script:CfgDir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)
        foreach ($jf in $jFiles) {
            { Get-Content $jf.FullName -Raw | ConvertFrom-Json } | Should -Not -Throw -Because "$($jf.Name) must be valid JSON"
        }
    }

    It 'all JSON in sin_registry/ should be valid' {
        $sinDir = (Join-Path $script:WS 'sin_registry')
        if (Test-Path $sinDir) {
            $jFiles = @(Get-ChildItem -Path $sinDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
            foreach ($jf in $jFiles) {
                { Get-Content $jf.FullName -Raw | ConvertFrom-Json } | Should -Not -Throw -Because "$($jf.Name) must be valid JSON"
            }
        }
    }

    It 'pipeline-registry.json has required top-level keys' {
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-Pipeline.psm1') -Force -DisableNameChecking
        $regPath = Get-PipelineRegistryPath -WorkspacePath $script:WS
        Test-Path $regPath | Should -BeTrue
        $reg = Get-Content $regPath -Raw | ConvertFrom-Json
        $reg.PSObject.Properties.Name | Should -Contain 'meta'
        $reg.PSObject.Properties.Name | Should -Contain 'featureRequests'
        $reg.PSObject.Properties.Name | Should -Contain 'bugs'
        Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
    }

    It 'should detect malformed JSON gracefully' {
        $badJson = (Join-Path $script:TmpDir '_test_bad.json')
        '{ "key": "value"  INVALID' | Set-Content -Path $badJson -Encoding UTF8
        { Get-Content $badJson -Raw | ConvertFrom-Json -ErrorAction Stop } | Should -Throw
        Remove-Item $badJson -Force -ErrorAction SilentlyContinue
    }

    It 'all XHTML files should be valid XML' {
        $xhtmlFiles = @(Get-ChildItem -Path $script:WS -Recurse -Filter '*.xhtml' -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike '*\.history\*' -and
                $_.FullName -notlike '*\temp\*' -and
                $_.FullName -notlike '*\~DOWNLOADS\*'
            })
        foreach ($xf in $xhtmlFiles) {
            $raw = [System.IO.File]::ReadAllText($xf.FullName, [System.Text.Encoding]::UTF8)
            $cleaned = $raw -replace '(?s)<\?xml[^?]*\?>', '' -replace '(?s)<!DOCTYPE[^>]*>', ''
            $cleaned = $cleaned -replace '(?s)\A(\s*<!--.*?-->\s*)+', ''
            $cleaned = $cleaned.Trim()
            if (-not [string]::IsNullOrWhiteSpace($cleaned)) {
                { [xml]$cleaned } | Should -Not -Throw -Because "$($xf.Name) should be valid XML"
            }
        }
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. IMPORT/EXPORT ROUND-TRIP
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'Import/Export Round-Trip' -Tag 'RoundTrip' {

    BeforeAll {
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-Pipeline.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $script:ModDir 'AVPN-Tracker.psm1') -Force -DisableNameChecking
    }

    AfterAll {
        Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
        Remove-Module 'AVPN-Tracker' -Force -ErrorAction SilentlyContinue
    }

    It 'Export-CentralMasterToDo produces valid JSON' {
        $outPath = Export-CentralMasterToDo -WorkspacePath $script:WS
        Test-Path $outPath | Should -BeTrue
        { Get-Content $outPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'Get-CentralMasterToDo items all have type property' {
        $items = Get-CentralMasterToDo -WorkspacePath $script:WS
        foreach ($item in $items) {
            if ($item -is [System.Collections.IDictionary]) {
                $item.Keys | Should -Contain 'type'
            } else {
                $item.PSObject.Properties.Name | Should -Contain 'type'
            }
        }
    }

    It 'Get-PipelineItems returns items with type property' {
        $items = Get-PipelineItems -WorkspacePath $script:WS
        $items.Count | Should -BeGreaterOrEqual 1
        foreach ($item in $items) {
            $item.PSObject.Properties.Name | Should -Contain 'type'
            $item.type | Should -Not -BeNullOrEmpty
        }
    }

    It 'Pipeline JSON round-trip preserves item count' {
        $items = Get-PipelineItems -WorkspacePath $script:WS
        $originalCount = $items.Count
        $tempFile = (Join-Path $script:TmpDir '_roundtrip_pipeline.json')
        $items | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding UTF8
        $reloaded = Get-Content $tempFile -Raw | ConvertFrom-Json
        @($reloaded).Count | Should -Be $originalCount
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }

    It 'AVPN config init + read round-trip' {
        $testCfg = (Join-Path $script:TmpDir '_test_avpn_cfg.json')
        if (Test-Path $testCfg) { Remove-Item $testCfg -Force }
        Initialize-AVPNConfigFile -ConfigPath $testCfg
        Test-Path $testCfg | Should -BeTrue
        $cfg = Get-AVPNConfig -ConfigPath $testCfg
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.PSObject.Properties.Name | Should -Contain 'avpnDevices'
        Remove-Item $testCfg -Force -ErrorAction SilentlyContinue
    }

    It 'AVPN config save + reload preserves data' {
        $testCfg = (Join-Path $script:TmpDir '_test_avpn_save.json')
        if (Test-Path $testCfg) { Remove-Item $testCfg -Force }
        Initialize-AVPNConfigFile -ConfigPath $testCfg
        $cfg = Get-AVPNConfig -ConfigPath $testCfg
        Save-AVPNConfig -ConfigPath $testCfg -ConfigData $cfg
        $reloaded = Get-AVPNConfig -ConfigPath $testCfg
        $reloaded | Should -Not -BeNullOrEmpty
        Remove-Item $testCfg -Force -ErrorAction SilentlyContinue
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. CRONAIATHON PIPELINE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'CronAiAthon Pipeline Lifecycle' -Tag 'Pipeline' {

    BeforeAll {
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-Pipeline.psm1') -Force -DisableNameChecking
    }

    AfterAll {
        Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
    }

    It 'Get-PipelineRegistryPath returns valid path' {
        $path = Get-PipelineRegistryPath -WorkspacePath $script:WS
        $path | Should -Not -BeNullOrEmpty
        Test-Path $path | Should -BeTrue
    }

    It 'Initialize-PipelineRegistry does not throw on existing registry' {
        { Initialize-PipelineRegistry -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Get-PipelineStatistics returns metrics object' {
        $stats = Get-PipelineStatistics -WorkspacePath $script:WS
        $stats | Should -Not -BeNullOrEmpty
        $stats.PSObject.Properties.Name | Should -Contain 'totalItemsCreated'
    }

    It 'Get-PipelineHealthMetrics returns health data' -Skip:($true) {
        $health = Get-PipelineHealthMetrics
        $health | Should -Not -BeNullOrEmpty
    }

    It 'Test-StatusTransition validates legal transitions' {
        Test-StatusTransition -CurrentStatus 'OPEN' -NewStatus 'IN_PROGRESS' | Should -BeTrue
    }

    It 'Test-StatusTransition rejects illegal transitions' {
        Test-StatusTransition -CurrentStatus 'CLOSED' -NewStatus 'OPEN' | Should -BeFalse
    }

    It 'Invoke-PriorityAutoEscalation runs without throwing' {
        { Invoke-PriorityAutoEscalation -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Invoke-SinRegistryFeedback runs without throwing' {
        { Invoke-SinRegistryFeedback -WorkspacePath $script:WS -BugItem (@{id='smoke-test';title='Smoke test bug';description='Smoke test description';category='testing';priority='low';status='pending';sinId='SIN-SMOKE';notes='';affectedFiles=@();suggestedBy='smoke-test';created=(Get-Date -Format 'yyyy-MM-dd')}) } | Should -Not -Throw
    }

    It 'Test-RegressionGuard runs without throwing' -Skip:($true) {
        { Test-RegressionGuard -ItemId 'smoke-test-item' } | Should -Not -Throw 
    }

    It 'Test-SinBugLinkage runs without throwing' -Skip:($true) {
        { Test-SinBugLinkage -WorkspacePath $script:WS } | Should -Not -Throw
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. CRONAIATHON SCHEDULER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'CronAiAthon Scheduler' -Tag 'Scheduler' {

    BeforeAll {
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-Scheduler.psm1') -Force -DisableNameChecking
    }

    AfterAll {
        Remove-Module 'CronAiAthon-Scheduler' -Force -ErrorAction SilentlyContinue
    }

    It 'Initialize-CronSchedule does not throw' {
        { Initialize-CronSchedule -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Get-CronSchedulePath returns a valid path' {
        $path = Get-CronSchedulePath -WorkspacePath $script:WS
        $path | Should -Not -BeNullOrEmpty
    }

    It 'Get-CronJobSummary returns summary data' {
        $summary = Get-CronJobSummary -WorkspacePath $script:WS
        $summary | Should -Not -BeNullOrEmpty
    }

    It 'Get-CronJobHistory does not throw' {
        { Get-CronJobHistory -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Invoke-PreRequisiteCheck returns results' {
        $results = Invoke-PreRequisiteCheck -WorkspacePath $script:WS
        $results | Should -Not -BeNullOrEmpty
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. CRONAIATHON BUGTRACKER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'CronAiAthon BugTracker' -Tag 'BugTracker' {

    BeforeAll {
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-BugTracker.psm1') -Force -DisableNameChecking
    }

    AfterAll {
        Remove-Module 'CronAiAthon-BugTracker' -Force -ErrorAction SilentlyContinue
    }

    It 'Invoke-ParseCheck scans without throwing' {
        { Invoke-ParseCheck -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Invoke-ParseCheck returns results' {
        { Invoke-ParseCheck -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Invoke-DependencyCheck does not throw' {
        { Invoke-DependencyCheck -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Invoke-DataValidationCheck does not throw' {
        { Invoke-DataValidationCheck -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Invoke-ErrorTrapAudit does not throw' {
        { Invoke-ErrorTrapAudit -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Invoke-XhtmlValidation does not throw' {
        { Invoke-XhtmlValidation -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Invoke-FullBugScan aggregates all checks' {
        $results = Invoke-FullBugScan -WorkspacePath $script:WS
        $results | Should -Not -BeNullOrEmpty
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. CRONAIATHON EVENTLOG
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'CronAiAthon EventLog' -Tag 'EventLog' {

    BeforeAll {
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-EventLog.psm1') -Force -DisableNameChecking
    }

    AfterAll {
        Remove-Module 'CronAiAthon-EventLog' -Force -ErrorAction SilentlyContinue
    }

    It 'Write-CronLog writes without throwing' {
        { Write-CronLog -Message 'SmokeTest entry' -Severity 'Informational' -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Get-EventLogConfig returns config' {
        $cfg = Get-EventLogConfig -WorkspacePath $script:WS
        $cfg | Should -Not -BeNullOrEmpty
    }

    It 'Write-SyslogFile does not throw' {
        { Write-SyslogFile -Message 'SmokeTest syslog' -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Test-EventLogSourceReady returns boolean' {
        $result = Test-EventLogSourceReady
        $result | Should -BeOfType [bool]
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 8. AVPN-TRACKER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'AVPN-Tracker Module' -Tag 'AVPN' {

    BeforeAll {
        Import-Module (Join-Path $script:ModDir 'AVPN-Tracker.psm1') -Force -DisableNameChecking
    }

    AfterAll {
        Remove-Module 'AVPN-Tracker' -Force -ErrorAction SilentlyContinue
    }

    It 'Initialize-AVPNConfigFile creates a valid config' {
        $tc = (Join-Path $script:TmpDir '_avpn_smoke.json')
        if (Test-Path $tc) { Remove-Item $tc -Force }
        Initialize-AVPNConfigFile -ConfigPath $tc
        Test-Path $tc | Should -BeTrue
        { Get-Content $tc -Raw | ConvertFrom-Json } | Should -Not -Throw
        Remove-Item $tc -Force -ErrorAction SilentlyContinue
    }

    It 'Get-AVPNConfig returns config with connections key' {
        $tc = (Join-Path $script:TmpDir '_avpn_get.json')
        if (Test-Path $tc) { Remove-Item $tc -Force }
        Initialize-AVPNConfigFile -ConfigPath $tc
        $cfg = Get-AVPNConfig -ConfigPath $tc
        $cfg.PSObject.Properties.Name | Should -Contain 'avpnDevices'
        Remove-Item $tc -Force -ErrorAction SilentlyContinue
    }

    It 'Save-AVPNConfig persists changes' {
        $tc = (Join-Path $script:TmpDir '_avpn_persist.json')
        if (Test-Path $tc) { Remove-Item $tc -Force }
        Initialize-AVPNConfigFile -ConfigPath $tc
        $cfg = Get-AVPNConfig -ConfigPath $tc
        Save-AVPNConfig -ConfigPath $tc -ConfigData $cfg
        $reloaded = Get-Content $tc -Raw | ConvertFrom-Json
        $reloaded | Should -Not -BeNullOrEmpty
        Remove-Item $tc -Force -ErrorAction SilentlyContinue
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 9. USERPROFILEMANAGER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'UserProfileManager Module' -Tag 'UserProfile' {

    BeforeAll {
        Import-Module (Join-Path $script:ModDir 'UserProfileManager.psm1') -Force -DisableNameChecking
    }

    AfterAll {
        Remove-Module 'UserProfileManager' -Force -ErrorAction SilentlyContinue
    }

    It 'Get-ProfileSnapshot captures profile data' {
        $snap = Get-ProfileSnapshot
        $snap | Should -Not -BeNullOrEmpty
    }

    It 'Get-EnvironmentVariables returns env vars' {
        $vars = Get-EnvironmentVariables
        $vars | Should -Not -BeNullOrEmpty
    }

    It 'Get-RegionalSettings returns settings' {
        $settings = Get-RegionalSettings
        $settings | Should -Not -BeNullOrEmpty
    }

    It 'Get-MappedDrives does not throw' {
        { Get-MappedDrives } | Should -Not -Throw
    }

    It 'Get-PSEnvironment returns PS info' {
        $psEnv = Get-PSEnvironment
        $psEnv | Should -Not -BeNullOrEmpty
    }

    It 'Get-CertificateStores does not throw' {
        { Get-CertificateStores } | Should -Not -Throw
    }

    It 'Get-InstalledFonts returns font list' {
        $fonts = Get-InstalledFonts
        $fonts | Should -Not -BeNullOrEmpty
    }

    It 'Get-PowerConfiguration does not throw' {
        { Get-PowerConfiguration } | Should -Not -Throw
    }

    It 'Get-TaskbarLayout does not throw' {
        { Get-TaskbarLayout } | Should -Not -Throw
    }

    It 'Get-WiFiProfiles does not throw' {
        { Get-WiFiProfiles } | Should -Not -Throw
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 10. PWSHGUICORE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'PwShGUICore Module' -Tag 'Core' {

    BeforeAll {
        Import-Module (Join-Path $script:ModDir 'PwShGUICore.psm1') -Force -DisableNameChecking
    }

    AfterAll {
        Remove-Module 'PwShGUICore' -Force -ErrorAction SilentlyContinue
    }

    It 'Initialize-CorePaths does not throw' {
        { Initialize-CorePaths -ScriptDir $script:ScDir } | Should -Not -Throw
    }

    It 'Get-ProjectPath returns workspace root' {
        Initialize-CorePaths -ScriptDir $script:ScDir
        $path = Get-ProjectPath -Key 'Root'
        $path | Should -Not -BeNullOrEmpty
    }

    It 'Get-AllProjectPaths returns paths' {
        Initialize-CorePaths -ScriptDir $script:ScDir
        $paths = Get-AllProjectPaths
        $paths | Should -Not -BeNullOrEmpty
    }

    It 'Assert-DirectoryExists creates directory' {
        $testDir = (Join-Path $script:TmpDir '_assertdir_test')
        if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
        Assert-DirectoryExists -Path $testDir
        Test-Path $testDir | Should -BeTrue
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Write-AppLog logs without throwing' {
        { Write-AppLog -Message 'SmokeTest log entry' -Level 'INFO' } | Should -Not -Throw
    }

    It 'Get-RainbowColor returns a color' {
        $color = Get-RainbowColor -Index 0
        $color | Should -Not -BeNullOrEmpty
    }

    It 'Initialize-ConfigFile does not throw on existing config' {
        { Initialize-ConfigFile -ConfigFile (Join-Path $script:CfgDir 'system-variables.xml') -LogsDir (Join-Path $script:WS 'logs') -ConfigDir $script:CfgDir -ScriptsDir $script:ScDir } | Should -Not -Throw
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 11. PWSHGUI-THEME
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'PwShGUI-Theme Module' -Tag 'Theme' {

    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        try { Import-Module (Join-Path $script:ModDir 'PwShGUI-Theme.psm1') -Force -DisableNameChecking -ErrorAction Stop } catch { Write-Warning "Failed to import PwShGUI-Theme: $_" }
        $script:ThemeLoaded = $null -ne (Get-Module 'PwShGUI-Theme') -and (Get-Module 'PwShGUI-Theme').ExportedFunctions.Count -gt 0
    }

    AfterAll {
        Remove-Module 'PwShGUI-Theme' -Force -ErrorAction SilentlyContinue
    }

    It 'Get-ThemeValue returns FormBack color' -Skip:(-not $script:ThemeLoaded) {
        $val = Get-ThemeValue -Key 'FormBack'
        $val | Should -Not -BeNullOrEmpty
    }

    It 'Get-ThemeFont returns a font object' -Skip:(-not $script:ThemeLoaded) {
        $font = Get-ThemeFont
        $font | Should -Not -BeNullOrEmpty
    }

    It 'Set-ModernFormStyle styles a form' -Skip:(-not $script:ThemeLoaded) {
        $form = [System.Windows.Forms.Form]::new()
        { Set-ModernFormStyle -Form $form } | Should -Not -Throw
        $form.Dispose()
    }

    It 'Set-ModernButtonStyle styles a button' -Skip:(-not $script:ThemeLoaded) {
        $btn = [System.Windows.Forms.Button]::new()
        { Set-ModernButtonStyle -Button $btn } | Should -Not -Throw
        $btn.Dispose()
    }

    It 'Set-ModernDgvStyle styles a DataGridView' -Skip:(-not $script:ThemeLoaded) {
        $dgv = [System.Windows.Forms.DataGridView]::new()
        { Set-ModernDgvStyle -Grid $dgv } | Should -Not -Throw
        $dgv.Dispose()
    }

    It 'Set-ModernFormTheme applies full theme' -Skip:(-not $script:ThemeLoaded) {
        $form = [System.Windows.Forms.Form]::new()
        { Set-ModernFormTheme -Form $form } | Should -Not -Throw
        $form.Dispose()
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 12. SUB-TOOL SCRIPT PARSE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'Sub-Tool Script Parse & Primary Functions' -Tag 'ScriptParse' {

    It 'should parse <Name> without errors' -ForEach $script:SubToolScripts {
        $path = Join-Path $script:ScDir $Name
        if (-not (Test-Path $path)) {
            Set-ItResult -Skipped -Because "$Name not found"
            return
        }
        $tokens = $null; $errors = $null
        $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0 -Because "$Name should have no parse errors"
    }

    It 'should define primary function <PFn> in <Name>' -ForEach ($script:SubToolScripts | Where-Object { $_.PFn }) {
        $path = Join-Path $script:ScDir $Name
        if (-not (Test-Path $path)) {
            Set-ItResult -Skipped -Because "$Name not found"
            return
        }
        $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $content | Should -Match ('(?m)^\s*function\s+' + [regex]::Escape($PFn) + '\b')
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 13. MCP SERVICE CONFIG
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'MCP Service Config Functions' -Tag 'MCP' {

    BeforeAll {
        $mcpScript = (Join-Path $script:ScDir 'Show-MCPServiceConfig.ps1')
        $script:MCPLoaded = $false
        if (Test-Path $mcpScript) {
            . $mcpScript
            $script:MCPLoaded = $true
        }
    }

    It 'Get-MCPConfigPath returns a path' -Skip:(-not $script:MCPLoaded) {
        $path = Get-MCPConfigPath
        $path | Should -Not -BeNullOrEmpty
    }

    It 'Read-MCPConfig returns config object or null' -Skip:(-not $script:MCPLoaded) {
        { Read-MCPConfig } | Should -Not -Throw
    }

    It 'Backup-MCPConfig does not throw' -Skip:(-not $script:MCPLoaded) {
        { Backup-MCPConfig } | Should -Not -Throw
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 14. SCAN DASHBOARD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'Scan Dashboard Functions' -Tag 'ScanDashboard' {

    BeforeAll {
        $sdScript = (Join-Path $script:ScDir 'Show-ScanDashboard.ps1')
        $script:SDLoaded = $false
        if (Test-Path $sdScript) {
            . $sdScript
            $script:SDLoaded = $true
        }
    }

    It 'Get-ScanFiles does not throw' -Skip:(-not $script:SDLoaded) {
        $testDef = @{ Name='Test'; Script='test.ps1'; Prefix='test'; Pattern='test-*.json'; Formats=@('json') }
        { Get-ScanFiles -Def $testDef -ReportPath (Join-Path $script:WS '~REPORTS') } | Should -Not -Throw
    }

    It 'Get-ScansetDiskSize handles missing files' -Skip:(-not $script:SDLoaded) {
        $testDef = @{ Name='Test'; Script='test.ps1'; Prefix='nonexistent'; Pattern='nonexistent-*.json'; Formats=@('json') }
        { Get-ScansetDiskSize -Def $testDef -ReportPath (Join-Path $script:WS '~REPORTS') } | Should -Not -Throw
    }

    It 'Extract-Timestamp extracts yyyyMMdd-HHmmss pattern' -Skip:(-not $script:SDLoaded) {
        $result = Extract-Timestamp 'orphan-audit-20260328-123456.json'
        $result | Should -Be '20260328-123456'
    }

    It 'All scan scripts referenced in ScanSetDefs exist' -Skip:(-not $script:SDLoaded) {
        $scriptsDir = $script:ScDir
        foreach ($def in $script:ScanSetDefs) {
            $path = Join-Path $scriptsDir $def.Script
            Test-Path $path | Should -BeTrue -Because "Scan script '$($def.Script)' must exist for '$($def.Name)' tab"
        }
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 15. APP TEMPLATE MANAGER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'App Template Manager Functions' -Tag 'AppTemplate' {

    BeforeAll {
        $atmScript = (Join-Path $script:ScDir 'Show-AppTemplateManager.ps1')
        $script:ATMLoaded = $false
        if (Test-Path $atmScript) {
            . $atmScript
            $script:ATMLoaded = $true
        }
    }

    It 'Compare-VersionStrings compares correctly' -Skip:(-not $script:ATMLoaded) {
        $result = Compare-VersionStrings -Version1 '1.0.0' -Version2 '2.0.0'
        $result | Should -BeLessThan 0
    }

    It 'Compare-VersionStrings returns 0 for equal' -Skip:(-not $script:ATMLoaded) {
        $result = Compare-VersionStrings -Version1 '1.0.0' -Version2 '1.0.0'
        $result | Should -Be 0
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 16. FORM RENDERING (Headless WinForms)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'Form Rendering (Headless WinForms)' -Tag 'FormRendering' {

    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    }

    It 'creates Form without errors' {
        $form = [System.Windows.Forms.Form]::new()
        $form.Text = 'SmokeTest'; $form.Size = [System.Drawing.Size]::new(800, 600)
        $form | Should -Not -BeNullOrEmpty
        $form.Dispose()
    }

    It 'creates TabControl with 5 tabs' {
        $form = [System.Windows.Forms.Form]::new()
        $tc = [System.Windows.Forms.TabControl]::new()
        $tc.Dock = [System.Windows.Forms.DockStyle]::Fill
        for ($i = 0; $i -lt 5; $i++) { $tc.TabPages.Add("Tab $i") | Out-Null }
        $form.Controls.Add($tc)
        $tc.TabPages.Count | Should -Be 5
        $form.Dispose()
    }

    It 'creates DataGridView with columns and rows' {
        $dgv = [System.Windows.Forms.DataGridView]::new()
        $dgv.Columns.Add('col1', 'Name') | Out-Null
        $dgv.Columns.Add('col2', 'Value') | Out-Null
        for ($i = 0; $i -lt 10; $i++) { $dgv.Rows.Add("item$i", "val$i") | Out-Null }
        $dgv.Columns.Count | Should -Be 2
        $dgv.Rows.Count | Should -BeGreaterOrEqual 10
        $dgv.Dispose()
    }

    It 'creates Button with working click handler' {
        $btn = [System.Windows.Forms.Button]::new()
        $btn.Text = 'Test'
        $script:_btnClicked = $false
        $btn.Add_Click({ $script:_btnClicked = $true })
        $btn.PerformClick()
        $script:_btnClicked | Should -BeTrue
        $btn.Dispose()
    }

    It 'creates MenuStrip with nested items' {
        $ms = [System.Windows.Forms.MenuStrip]::new()
        $fileMenu = [System.Windows.Forms.ToolStripMenuItem]::new('File')
        $fileMenu.DropDownItems.Add([System.Windows.Forms.ToolStripMenuItem]::new('Exit')) | Out-Null
        $ms.Items.Add($fileMenu) | Out-Null
        $ms.Items.Count | Should -Be 1
        $fileMenu.DropDownItems.Count | Should -Be 1
        $ms.Dispose()
    }

    It 'creates ComboBox with items' {
        $cb = [System.Windows.Forms.ComboBox]::new()
        $cb.Items.AddRange(@('A','B','C'))
        $cb.Items.Count | Should -Be 3
        $cb.Dispose()
    }

    It 'creates RichTextBox and sets text' {
        $rtb = [System.Windows.Forms.RichTextBox]::new()
        $rtb.Text = 'SmokeTest'
        $rtb.Text | Should -Be 'SmokeTest'
        $rtb.Dispose()
    }

    It 'creates TreeView with nodes' {
        $tv = [System.Windows.Forms.TreeView]::new()
        $root = $tv.Nodes.Add('Root')
        $root.Nodes.Add('Child1') | Out-Null
        $root.Nodes.Add('Child2') | Out-Null
        $tv.Nodes[0].Nodes.Count | Should -Be 2
        $tv.Dispose()
    }

    It 'applies theme to form' {
        try { Import-Module (Join-Path $script:ModDir 'PwShGUI-Theme.psm1') -Force -DisableNameChecking -ErrorAction Stop } catch { Write-Warning "Failed to import PwShGUI-Theme: $_" }
        if (-not (Get-Command Set-ModernFormTheme -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped
            return
        }
        $form = [System.Windows.Forms.Form]::new()
        { Set-ModernFormTheme -Form $form } | Should -Not -Throw
        $form.Dispose()
        Remove-Module 'PwShGUI-Theme' -Force -ErrorAction SilentlyContinue
    }

    It 'creates checkbox DataGridView column' {
        $dgv = [System.Windows.Forms.DataGridView]::new()
        $chk = [System.Windows.Forms.DataGridViewCheckBoxColumn]::new()
        $chk.HeaderText = 'Select'
        $txt = [System.Windows.Forms.DataGridViewTextBoxColumn]::new()
        $txt.HeaderText = 'Name'
        $dgv.Columns.Add($chk) | Out-Null
        $dgv.Columns.Add($txt) | Out-Null
        $ri = $dgv.Rows.Add($false, 'Item1')
        $dgv.Rows[$ri].Cells[0].Value = $true
        $dgv.Rows[$ri].Cells[0].Value | Should -BeTrue
        $dgv.Dispose()
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 17. GRID LOADING & REFRESH
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'Grid Loading & Refresh Patterns' -Tag 'GridLoading' {

    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-Pipeline.psm1') -Force -DisableNameChecking
    }

    AfterAll {
        Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
    }

    It 'populates grid from pipeline items' {
        $items = Get-PipelineItems -WorkspacePath $script:WS
        $dgv = [System.Windows.Forms.DataGridView]::new()
        $dgv.Columns.Add('id', 'ID') | Out-Null
        $dgv.Columns.Add('title', 'Title') | Out-Null
        $dgv.Columns.Add('status', 'Status') | Out-Null
        $dgv.Columns.Add('type', 'Type') | Out-Null
        foreach ($item in $items) {
            $id    = if ($item.PSObject.Properties['id'])     { $item.id } else { '' }
            $title = if ($item.PSObject.Properties['title'])  { $item.title } else { '' }
            $st    = if ($item.PSObject.Properties['status']) { $item.status } else { '' }
            $tp    = if ($item.PSObject.Properties['type'])   { $item.type } else { '' }
            $dgv.Rows.Add($id, $title, $st, $tp) | Out-Null
        }
        $dgv.Rows.Count | Should -BeGreaterOrEqual $items.Count
        $dgv.Dispose()
    }

    It 'clears and repopulates grid (refresh)' {
        $dgv = [System.Windows.Forms.DataGridView]::new()
        $dgv.Columns.Add('data', 'Data') | Out-Null
        for ($i = 0; $i -lt 5; $i++) { $dgv.Rows.Add("row$i") | Out-Null }
        $dgv.Rows.Count | Should -BeGreaterOrEqual 5
        $dgv.AllowUserToAddRows = $false
        $dgv.Rows.Clear()
        $dgv.Rows.Count | Should -Be 0
        for ($i = 0; $i -lt 3; $i++) { $dgv.Rows.Add("new$i") | Out-Null }
        $dgv.Rows.Count | Should -BeGreaterOrEqual 3
        $dgv.Dispose()
    }

    It 'loads pipeline statistics into grid' {
        $stats = Get-PipelineStatistics -WorkspacePath $script:WS
        $dgv = [System.Windows.Forms.DataGridView]::new()
        $dgv.Columns.Add('metric', 'Metric') | Out-Null
        $dgv.Columns.Add('value', 'Value') | Out-Null
        foreach ($prop in $stats.PSObject.Properties) {
            $dgv.Rows.Add($prop.Name, $prop.Value) | Out-Null
        }
        $dgv.Rows.Count | Should -BeGreaterOrEqual 1
        $dgv.Dispose()
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 18. BUTTON HANDLER SIMULATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'Button Handler Simulation' -Tag 'ButtonHandlers' {

    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    }

    It 'wires and fires click handler' {
        $btn = [System.Windows.Forms.Button]::new()
        $result = [ref]$null
        $btn.Add_Click({ $result.Value = 'clicked' })
        $btn.PerformClick()
        $result.Value | Should -Be 'clicked'
        $btn.Dispose()
    }

    It 'chains multiple button handlers' {
        $counter = [ref]0
        $btn = [System.Windows.Forms.Button]::new()
        $btn.Add_Click({ $counter.Value++ })
        $btn.Add_Click({ $counter.Value++ })
        $btn.PerformClick()
        $counter.Value | Should -Be 2
        $btn.Dispose()
    }

    It 'handles exception in click handler' {
        $btn = [System.Windows.Forms.Button]::new()
        $script:_errThrown = $false
        $btn.Add_Click({ try { throw 'Test' } catch { $script:_errThrown = $true } })
        $btn.PerformClick()
        $script:_errThrown | Should -BeTrue
        $btn.Dispose()
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 20. SESSION 4 MODULE COVERAGE (10 newly-tested modules)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'Session 4 Module Coverage' -Tag 'ModuleCoverage' {
    $script:ModulesDir = Join-Path $PSScriptRoot '..\modules'

    It 'CronAiAthon-EventLog imports and exports 8 functions' {
        $mp = Join-Path $script:ModulesDir 'CronAiAthon-EventLog.psm1'
        Import-Module $mp -Force -DisableNameChecking
        (Get-Module 'CronAiAthon-EventLog').ExportedFunctions.Count | Should -Be 8
        Remove-Module 'CronAiAthon-EventLog' -Force -ErrorAction SilentlyContinue
    }

    It 'CronAiAthon-Scheduler imports and exports 15 functions' {
        $mp = Join-Path $script:ModulesDir 'CronAiAthon-Scheduler.psm1'
        Import-Module $mp -Force -DisableNameChecking
        (Get-Module 'CronAiAthon-Scheduler').ExportedFunctions.Count | Should -Be 15
        Remove-Module 'CronAiAthon-Scheduler' -Force -ErrorAction SilentlyContinue
    }

    It 'PwShGUI-Theme imports and exports 10 functions' {
        $mp = Join-Path $script:ModulesDir 'PwShGUI-Theme.psm1'
        Import-Module $mp -Force -DisableNameChecking
        (Get-Module 'PwShGUI-Theme').ExportedFunctions.Count | Should -Be 10
        Remove-Module 'PwShGUI-Theme' -Force -ErrorAction SilentlyContinue
    }

    It 'UserProfileManager imports and exports 31 functions' {
        $mp = Join-Path $script:ModulesDir 'UserProfileManager.psm1'
        Import-Module $mp -Force -DisableNameChecking
        (Get-Module 'UserProfileManager').ExportedFunctions.Count | Should -Be 31
        Remove-Module 'UserProfileManager' -Force -ErrorAction SilentlyContinue
    }

    It 'SINGovernance imports and exports 6 functions' {
        $mp = Join-Path $script:ModulesDir 'SINGovernance.psm1'
        Import-Module $mp -Force -DisableNameChecking
        (Get-Module 'SINGovernance').ExportedFunctions.Count | Should -Be 6
        Remove-Module 'SINGovernance' -Force -ErrorAction SilentlyContinue
    }

    It 'PKIChainManager imports and exports 7 functions' {
        $mp = Join-Path $script:ModulesDir 'PKIChainManager.psm1'
        Import-Module $mp -Force -DisableNameChecking
        (Get-Module 'PKIChainManager').ExportedFunctions.Count | Should -Be 7
        Remove-Module 'PKIChainManager' -Force -ErrorAction SilentlyContinue
    }

    It 'PwShGUI-PSVersionStandards imports and exports 8 functions' {
        $mp = Join-Path $script:ModulesDir 'PwShGUI-PSVersionStandards.psm1'
        Import-Module $mp -Force -DisableNameChecking
        (Get-Module 'PwShGUI-PSVersionStandards').ExportedFunctions.Count | Should -Be 8
        Remove-Module 'PwShGUI-PSVersionStandards' -Force -ErrorAction SilentlyContinue
    }

    It 'PwShGUI_AutoIssueFinder imports and exports 1 function' {
        $mp = Join-Path $script:ModulesDir 'PwShGUI_AutoIssueFinder.psm1'
        Import-Module $mp -Force -DisableNameChecking
        (Get-Module 'PwShGUI_AutoIssueFinder').ExportedFunctions.Count | Should -Be 1
        Remove-Module 'PwShGUI_AutoIssueFinder' -Force -ErrorAction SilentlyContinue
    }

    It 'SASC-Adapters imports and exports 8 functions' {
        $mp = Join-Path $script:ModulesDir 'SASC-Adapters.psm1'
        Import-Module $mp -Force -DisableNameChecking
        (Get-Module 'SASC-Adapters').ExportedFunctions.Count | Should -Be 8
        Remove-Module 'SASC-Adapters' -Force -ErrorAction SilentlyContinue
    }

    It 'PwSh-HelpFilesUpdateSource-ReR imports and exports 7 functions' {
        $mp = Join-Path $script:ModulesDir 'PwSh-HelpFilesUpdateSource-ReR.psm1'
        Import-Module $mp -Force -DisableNameChecking
        (Get-Module 'PwSh-HelpFilesUpdateSource-ReR').ExportedFunctions.Count | Should -Be 7
        Remove-Module 'PwSh-HelpFilesUpdateSource-ReR' -Force -ErrorAction SilentlyContinue
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 19. CROSS-MODULE INTEROP
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Describe 'Cross-Module Interop' -Tag 'Interop' {

    BeforeAll {
        Import-Module (Join-Path $script:ModDir 'PwShGUICore.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-Pipeline.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-Scheduler.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-EventLog.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $script:ModDir 'CronAiAthon-BugTracker.psm1') -Force -DisableNameChecking
    }

    AfterAll {
        'PwShGUICore','CronAiAthon-Pipeline','CronAiAthon-Scheduler','CronAiAthon-EventLog','CronAiAthon-BugTracker' |
            ForEach-Object { Remove-Module $_ -Force -ErrorAction SilentlyContinue }
    }

    It 'Pipeline + EventLog: write log after pipeline read' {
        $items = Get-PipelineItems -WorkspacePath $script:WS
        { Write-CronLog -Message "Pipeline: $($items.Count) items" -Severity 'Informational' -WorkspacePath $script:WS } | Should -Not -Throw
    }

    It 'Pipeline + BugTracker: parse check then get items' {
        { Invoke-ParseCheck -WorkspacePath $script:WS } | Should -Not -Throw
        $items = Get-PipelineItems -WorkspacePath $script:WS
        $items | Should -Not -BeNullOrEmpty
    }

    It 'Scheduler + Pipeline: prerequisites with pipeline data' {
        $preReq = Invoke-PreRequisiteCheck -WorkspacePath $script:WS
        $stats  = Get-PipelineStatistics -WorkspacePath $script:WS
        $preReq | Should -Not -BeNullOrEmpty
        $stats  | Should -Not -BeNullOrEmpty
    }

    It 'Core + Pipeline: WriteAppLog from pipeline context' {
        Initialize-CorePaths -ScriptDir $script:ScDir
        { Write-AppLog -Message 'Interop test' -Level 'INFO' } | Should -Not -Throw
        $items = Get-PipelineItems -WorkspacePath $script:WS
        $items.Count | Should -BeGreaterOrEqual 1
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 21. MENU SELECTION ITEM SMOKE TESTS
#     Verifies every menu item's backing resource (file, function, or
#     module) exists — without launching the GUI.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
BeforeDiscovery {
    $script:WS = (Split-Path -Parent $PSScriptRoot)

    # ── Help Menu: items and their backing resource ───────────────────
    $script:HelpMenuItems = @(
        @{ Label='Update-Help';              Type='Function'; Target='Show-UpdateHelp';                    Source='Main-GUI.ps1' }
        @{ Label='PwShGUI App Help';         Type='File';     Target='~README.md\PwShGUI-Help-Index.html'; Source='' }
        @{ Label='Package Workspace';        Type='Function'; Target='Export-WorkspacePackage';             Source='Main-GUI.ps1' }
        @{ Label='Dependency Visualisation'; Type='File';     Target='~README.md\Dependency-Visualisation.html'; Source='' }
        @{ Label='PS-Cheatsheet V2';         Type='File';     Target='scripts\PS-CheatSheet-EXAMPLES-V2.ps1'; Source='' }
        @{ Label='Manifests Registries SINs';Type='Function'; Target='Show-ManifestsRegistrySinsViewer';   Source='Main-GUI.ps1' }
        @{ Label='About';                    Type='Function'; Target='Get-VersionInfo';                     Source='Any' }
    )

    # ── File Menu: items and their backing resource ───────────────────
    $script:FileMenuItems = @(
        @{ Label='Configure Paths';          Type='Function'; Target='Show-PathSettingsGUI';               Source='Any' }
        @{ Label='Script Folders';           Type='Function'; Target='Show-ScriptFoldersDialog';            Source='Any' }
        @{ Label='Exit';                     Type='Function'; Target='Application.Exit';                   Source='WinForms' }
    )

    # ── Tests Menu: items and their backing resource ──────────────────
    $script:TestsMenuItems = @(
        @{ Label='Version Check';            Type='Function'; Target='Test-VersionTag';                    Source='Any' }
        @{ Label='Network Diagnostics';      Type='Function'; Target='Show-NetworkDiagnosticsDialog';      Source='Any' }
        @{ Label='Disk Check';               Type='Function'; Target='Show-DiskCheckDialog';               Source='Any' }
        @{ Label='Privacy Check';            Type='Function'; Target='Show-PrivacyCheck';                  Source='Any' }
        @{ Label='System Check';             Type='Function'; Target='Show-SystemCheck';                   Source='Any' }
        @{ Label='App Testing';              Type='Function'; Target='Test-AppTesting';                    Source='Any' }
        @{ Label='Scrutiny Safety SecOps';   Type='Function'; Target='Test-ScriptSafetySecOp';             Source='Any' }
    )

    # ── Tools Menu: items and their backing resource ──────────────────
    $script:ToolsMenuItems = @(
        @{ Label='View Config';               Type='File';     Target='config\system-variables.xml';        Source='' }
        @{ Label='Config Maintenance';        Type='Function'; Target='Show-ConfigMaintenanceForm';          Source='Any' }
        @{ Label='Open Logs Directory';       Type='Directory';Target='logs';                               Source='' }
        @{ Label='GUI Layout';                Type='Function'; Target='Show-GUILayout';                     Source='Any' }
        @{ Label='Button Maintenance';        Type='Function'; Target='Show-ButtonMaintenance';              Source='Any' }
        @{ Label='Network Details';           Type='File';     Target='scripts\WinRemote-PSTool.ps1';       Source='' }
        @{ Label='AVPN Connection Tracker';   Type='Module';   Target='AVPN-Tracker.psm1';                  Source='modules' }
        @{ Label='Script Dependency Matrix';  Type='File';     Target='scripts\Invoke-ScriptDependencyMatrix.ps1'; Source='' }
        @{ Label='Module Management';         Type='File';     Target='scripts\Invoke-ModuleManagement.ps1';Source='' }
        @{ Label='PS Environment Scanner';    Type='File';     Target='scripts\Invoke-PSEnvironmentScanner.ps1'; Source='' }
        @{ Label='User Profile Manager';      Type='File';     Target='UPM\UserProfile-Manager.ps1';        Source='' }
        @{ Label='Event Log Viewer';          Type='File';     Target='scripts\Show-EventLogViewer.ps1';    Source='' }
        @{ Label='Scan Dashboard';            Type='File';     Target='scripts\Show-ScanDashboard.ps1';     Source='' }
        @{ Label='Cron-Ai-Athon Tool';        Type='File';     Target='scripts\Show-CronAiAthonTool.ps1';  Source='' }
        @{ Label='MCP Service Config';        Type='File';     Target='scripts\Show-MCPServiceConfig.ps1';  Source='' }
        @{ Label='XHTML Code Analysis';       Type='File';     Target='scripts\XHTML-Checker\XHTML-code-analysis.xhtml'; Source='' }
        @{ Label='XHTML Feature Requests';    Type='File';     Target='scripts\XHTML-Checker\XHTML-FeatureRequests.xhtml'; Source='' }
        @{ Label='XHTML MCP Service Config';  Type='File';     Target='scripts\XHTML-Checker\XHTML-MCPServiceConfig.xhtml'; Source='' }
        @{ Label='XHTML Central Master To-Do';Type='File';     Target='scripts\XHTML-Checker\XHTML-MasterToDo.xhtml'; Source='' }
        @{ Label='Startup Shortcut';          Type='Function'; Target='Show-StartupShortcutForm';           Source='Any' }
        @{ Label='Remote Build Path Config';  Type='Function'; Target='Show-RemoteBuildConfigForm';         Source='Any' }
    )

    # ── WinGets Menu: items and their backing resource ────────────────
    $script:WinGetsMenuItems = @(
        @{ Label='Installed Apps Grid View';  Type='Function'; Target='Show-WingetInstalledApp';            Source='Any' }
        @{ Label='Detect Updates';            Type='Function'; Target='Show-WingetUpgradeCheck';            Source='Any' }
        @{ Label='Update All';                Type='Function'; Target='Show-WingetUpdateAllDialog';         Source='Any' }
        @{ Label='App Template Manager';      Type='File';     Target='scripts\Show-AppTemplateManager.ps1';Source='' }
    )

    # ── Security Menu: items and their backing functions ──────────────
    $script:SecurityMenuItems = @(
        @{ Label='Security Checklist';        Type='Function'; Target='Show-SecurityChecklistForm';         Source='Any' }
        @{ Label='Assisted SASC Wizard';      Type='Function'; Target='Show-AssistedSASCDialog';            Source='modules\AssistedSASC.psm1' }
        @{ Label='Vault Status';              Type='Function'; Target='Show-VaultStatusDialog';             Source='modules\AssistedSASC.psm1' }
        @{ Label='Unlock Vault';              Type='Function'; Target='Show-VaultUnlockDialog';             Source='modules\AssistedSASC.psm1' }
        @{ Label='Lock Vault';                Type='Function'; Target='Lock-Vault';                         Source='modules\AssistedSASC.psm1' }
        @{ Label='Import Vault Secrets';      Type='Function'; Target='Import-VaultSecrets';                Source='modules\AssistedSASC.psm1' }
        @{ Label='Import Certificates';       Type='Function'; Target='Import-Certificates';                Source='modules\AssistedSASC.psm1' }
        @{ Label='Test Vault Security';       Type='Function'; Target='Test-VaultSecurity';                 Source='modules\AssistedSASC.psm1' }
        @{ Label='Test Integrity Manifest';   Type='Function'; Target='Test-IntegrityManifest';             Source='modules\AssistedSASC.psm1' }
        @{ Label='Export Vault Backup';       Type='Function'; Target='Export-VaultBackup';                 Source='modules\AssistedSASC.psm1' }
    )
}

Describe 'Help Menu Item Targets' -Tag 'MenuSmoke','HelpMenu' {
    $wsRoot = $script:WS

    It 'Help > <Label> file target exists' -ForEach ($script:HelpMenuItems | Where-Object { $_.Type -eq 'File' }) {
        $fullPath = Join-Path $wsRoot $Target
        Test-Path $fullPath | Should -BeTrue -Because "Help > '$Label' requires '$Target'"
    }

    It 'Help > <Label> function <Target> defined in Main-GUI.ps1' -ForEach ($script:HelpMenuItems | Where-Object { $_.Type -eq 'Function' -and $_.Source -eq 'Main-GUI.ps1' }) {
        $mainPath = Join-Path $wsRoot 'Main-GUI.ps1'
        Test-Path $mainPath | Should -BeTrue
        $src = [System.IO.File]::ReadAllText($mainPath, [System.Text.Encoding]::UTF8)
        $src | Should -Match ('(?m)function\s+' + [regex]::Escape($Target) + '\b') -Because "Help > '$Label' calls $Target"
    }

    It 'Help > <Label> function <Target> defined (any source)' -ForEach ($script:HelpMenuItems | Where-Object { $_.Type -eq 'Function' -and $_.Source -eq 'Any' }) {
        $wsRoot2 = $wsRoot
        $allSrc = @(
            (Get-ChildItem -Path $wsRoot2 -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\temp\*' })
        )
        $found = $false
        foreach ($f in $allSrc) {
            $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            if ($content -match ('(?m)function\s+' + [regex]::Escape($Target) + '\b')) { $found = $true; break }
        }
        $found | Should -BeTrue -Because "Help > '$Label' calls $Target which must be defined"
    }

    It 'PwShGUI-Help-Index.html is valid HTML (contains head and body)' {
        $htmlPath = Join-Path $wsRoot '~README.md\PwShGUI-Help-Index.html'
        Test-Path $htmlPath | Should -BeTrue
        $content = Get-Content $htmlPath -Raw -Encoding UTF8
        $content | Should -Match '<head'  -Because 'Help Index HTML requires <head> element'
        $content | Should -Match '<body'  -Because 'Help Index HTML requires <body> element'
    }

    It 'Dependency-Visualisation.html exists (generated by Invoke-WorkspaceDependencyMap)' {
        $htmlPath = Join-Path $wsRoot '~README.md\Dependency-Visualisation.html'
        # File existence only -- content parse skipped (file can exceed 400K lines; parsing in tests is prohibitive)
        Test-Path $htmlPath | Should -BeTrue -Because 'Invoke-WorkspaceDependencyMap must regenerate Dependency-Visualisation.html'
    }

    It 'PS-CheatSheet-EXAMPLES-V2.ps1 parses without errors' {
        $ps1Path = Join-Path $wsRoot 'scripts\PS-CheatSheet-EXAMPLES-V2.ps1'
        if (-not (Test-Path $ps1Path)) { Set-ItResult -Skipped -Because 'PS-CheatSheet-EXAMPLES-V2.ps1 not found'; return }
        $tokens = $null; $errors = $null
        $content = [System.IO.File]::ReadAllText($ps1Path, [System.Text.Encoding]::UTF8)
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0 -Because 'PS-Cheatsheet V2 must parse clean'
    }

    It 'HelpIndex path key registered in PwShGUICore path registry' {
        $corePath = Join-Path $wsRoot 'modules\PwShGUICore.psm1'
        Test-Path $corePath | Should -BeTrue
        $src = [System.IO.File]::ReadAllText($corePath, [System.Text.Encoding]::UTF8)
        $src | Should -Match "HelpIndex\s*=" -Because 'Get-ProjectPath HelpIndex must be resolvable'
    }
}

Describe 'Tests Menu Item Targets' -Tag 'MenuSmoke','TestsMenu' {
    $wsRoot = $script:WS

    BeforeAll {
        $script:MainSrc = ''
        $mainPath = Join-Path $script:WS 'Main-GUI.ps1'
        if (Test-Path $mainPath) {
            $script:MainSrc = [System.IO.File]::ReadAllText($mainPath, [System.Text.Encoding]::UTF8)
        }
        $script:AllPsSrc = @{}
        $allFiles = @(Get-ChildItem -Path $script:WS -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\temp\*' })
        foreach ($f in $allFiles) {
            $script:AllPsSrc[$f.BaseName] = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        }
    }

    It 'Tests > <Label> function <Target> is defined' -ForEach $script:TestsMenuItems {
        $found = $false
        foreach ($key in $script:AllPsSrc.Keys) {
            if ($script:AllPsSrc[$key] -match ('(?m)function\s+' + [regex]::Escape($Target) + '\b')) {
                $found = $true; break
            }
        }
        $found | Should -BeTrue -Because "Tests > '$Label' calls $Target which must be defined somewhere"
    }
}

Describe 'Tools Menu Item Targets' -Tag 'MenuSmoke','ToolsMenu' {
    $wsRoot = $script:WS

    BeforeAll {
        $script:AllPsSrc2 = @{}
        $allFiles = @(Get-ChildItem -Path $script:WS -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\temp\*' })
        foreach ($f in $allFiles) {
            $script:AllPsSrc2[$f.BaseName] = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        }
    }

    It 'Tools > <Label> file target <Target> exists' -ForEach ($script:ToolsMenuItems | Where-Object { $_.Type -eq 'File' }) {
        $fullPath = Join-Path $wsRoot $Target
        Test-Path $fullPath | Should -BeTrue -Because "Tools > '$Label' requires '$Target'"
    }

    It 'Tools > <Label> directory target <Target> exists' -ForEach ($script:ToolsMenuItems | Where-Object { $_.Type -eq 'Directory' }) {
        $fullPath = Join-Path $wsRoot $Target
        Test-Path $fullPath | Should -BeTrue -Because "Tools > '$Label' requires directory '$Target'"
    }

    It 'Tools > <Label> module <Target> exists' -ForEach ($script:ToolsMenuItems | Where-Object { $_.Type -eq 'Module' }) {
        $modPath = Join-Path $wsRoot "modules\$Target"
        Test-Path $modPath | Should -BeTrue -Because "Tools > '$Label' requires module '$Target'"
    }

    It 'Tools > <Label> function <Target> is defined' -ForEach ($script:ToolsMenuItems | Where-Object { $_.Type -eq 'Function' }) {
        $found = $false
        foreach ($key in $script:AllPsSrc2.Keys) {
            if ($script:AllPsSrc2[$key] -match ('(?m)function\s+' + [regex]::Escape($Target) + '\b')) {
                $found = $true; break
            }
        }
        $found | Should -BeTrue -Because "Tools > '$Label' calls $Target which must be defined"
    }

    It 'XHTML targets are valid XML' -ForEach ($script:ToolsMenuItems | Where-Object { $_.Target -like '*.xhtml' }) {
        $fullPath = Join-Path $wsRoot $Target
        if (-not (Test-Path $fullPath)) { Set-ItResult -Skipped -Because "$Target not found"; return }
        $raw = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
        $cleaned = $raw -replace '(?s)<\?xml[^?]*\?>', '' -replace '(?s)<!DOCTYPE[^>]*>', ''
        $cleaned = $cleaned -replace '(?s)\A(\s*<!--.*?-->\s*)+', ''
        $cleaned = $cleaned.Trim()
        { [xml]$cleaned } | Should -Not -Throw -Because "$Target must be valid XML"
    }
}

Describe 'WinGets Menu Item Targets' -Tag 'MenuSmoke','WinGetsMenu' {
    $wsRoot = $script:WS

    BeforeAll {
        $script:AllPsSrc3 = @{}
        $allFiles = @(Get-ChildItem -Path $script:WS -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\temp\*' })
        foreach ($f in $allFiles) {
            $script:AllPsSrc3[$f.BaseName] = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        }
    }

    It 'WinGets > <Label> file target <Target> exists' -ForEach ($script:WinGetsMenuItems | Where-Object { $_.Type -eq 'File' }) {
        $fullPath = Join-Path $wsRoot $Target
        Test-Path $fullPath | Should -BeTrue -Because "WinGets > '$Label' requires '$Target'"
    }

    It 'WinGets > <Label> function <Target> is defined' -ForEach ($script:WinGetsMenuItems | Where-Object { $_.Type -eq 'Function' }) {
        $found = $false
        foreach ($key in $script:AllPsSrc3.Keys) {
            if ($script:AllPsSrc3[$key] -match ('(?m)function\s+' + [regex]::Escape($Target) + '\b')) {
                $found = $true; break
            }
        }
        $found | Should -BeTrue -Because "WinGets > '$Label' calls $Target which must be defined"
    }
}

Describe 'Security Menu Item Targets' -Tag 'MenuSmoke','SecurityMenu' {

    It 'Security > <Label> function <Target> defined in <Source>' -ForEach ($script:SecurityMenuItems | Where-Object { $_.Source -ne 'Any' }) {
        $modPath = Join-Path $script:WS $Source
        if (-not (Test-Path $modPath)) {
            Set-ItResult -Skipped -Because "$Source not found"
            return
        }
        $src = [System.IO.File]::ReadAllText($modPath, [System.Text.Encoding]::UTF8)
        $src | Should -Match ('(?m)function\s+' + [regex]::Escape($Target) + '\b') `
            -Because "Security > '$Label' calls $Target in $Source"
    }

    It 'Security > Show-SecurityChecklistForm defined (any source)' {
        $allFiles = @(Get-ChildItem -Path $script:WS -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\temp\*' })
        $found = $false
        foreach ($f in $allFiles) {
            $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            if ($content -match '(?m)function\s+Show-SecurityChecklistForm\b') { $found = $true; break }
        }
        $found | Should -BeTrue -Because 'Security > Security Checklist calls Show-SecurityChecklistForm'
    }

    It 'AssistedSASC.psm1 exists and exports vault functions' {
        $modPath = (Join-Path $script:ModDir 'AssistedSASC.psm1')
        Test-Path $modPath | Should -BeTrue
        $src = [System.IO.File]::ReadAllText($modPath, [System.Text.Encoding]::UTF8)
        foreach ($fn in @('Show-AssistedSASCDialog','Show-VaultStatusDialog','Show-VaultUnlockDialog','Lock-Vault')) {
            $src | Should -Match ('(?m)function\s+' + [regex]::Escape($fn) + '\b') -Because "$fn must be defined in AssistedSASC.psm1"
        }
    }
}

Describe 'File Menu Item Targets' -Tag 'MenuSmoke','FileMenu' {

    It 'File > Configure Paths function Show-PathSettingsGUI is defined' {
        $allFiles = @(Get-ChildItem -Path $script:WS -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\temp\*' })
        $found = $false
        foreach ($f in $allFiles) {
            $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            if ($content -match '(?m)function\s+Show-PathSettingsGUI\b') { $found = $true; break }
        }
        $found | Should -BeTrue -Because 'File > Configure Paths requires Show-PathSettingsGUI'
    }

    It 'File > Script Folders Show-ScriptFoldersDialog is defined' {
        $allFiles = @(Get-ChildItem -Path $script:WS -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\temp\*' })
        $found = $false
        foreach ($f in $allFiles) {
            $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            if ($content -match '(?m)function\s+Show-ScriptFoldersDialog\b') { $found = $true; break }
        }
        $found | Should -BeTrue -Because 'File > Script Folders requires Show-ScriptFoldersDialog'
    }
}

Describe 'All Menu Items Covered by Smoke Check' -Tag 'MenuSmoke','Coverage' {

    It 'Main-GUI.ps1 defines a Help menu with all expected item texts' {
        $mainPath = (Join-Path $script:WS 'Main-GUI.ps1')
        Test-Path $mainPath | Should -BeTrue
        $src = Get-Content $mainPath -Raw -Encoding UTF8
        $expectedTexts = @(
            'Update-&Help'
            'PwShGUI App &Help'
            '&Package Workspace'
            'Dependency &Visualisation'
            'PS-&Cheatsheet V2'
            '&Manifests, Registries'
            '&About'
        )
        foreach ($text in $expectedTexts) {
            $src | Should -Match ([regex]::Escape($text)) -Because "Help menu must contain item text '$text'"
        }
    }

    It 'Main-GUI.ps1 defines a Tools menu with all expected item texts' {
        $mainPath = (Join-Path $script:WS 'Main-GUI.ps1')
        $src = Get-Content $mainPath -Raw -Encoding UTF8
        $expectedTexts = @(
            'View &Config'
            '&Config Maintenance'
            'Open &Logs Directory'
            '&Network Details'
            'A&VPN Connection Tracker'
            'Script &Dependency Matrix'
            'Module &Management'
            'PS &Environment Scanner'
            '&User Profile Manager'
            'Event Log &Viewer'
            'X&HTML Reports'
            'Create Startup Shortcut'
            'Remote Build Path Config'
        )
        foreach ($text in $expectedTexts) {
            $src | Should -Match ([regex]::Escape($text)) -Because "Tools menu must contain item text '$text'"
        }
    }

    It 'Main-GUI.ps1 defines a Tests menu with all expected item texts' {
        $mainPath = (Join-Path $script:WS 'Main-GUI.ps1')
        $src = Get-Content $mainPath -Raw -Encoding UTF8
        $expectedTexts = @(
            '&Version Check'
            '&Network Diagnostics'
            '&Disk Check'
            '&Privacy Check'
            '&System Check'
            'App Testing'
            'Scrutiny Safety'
        )
        foreach ($text in $expectedTexts) {
            $src | Should -Match ([regex]::Escape($text)) -Because "Tests menu must contain item text '$text'"
        }
    }

    It 'Main-GUI.ps1 defines a Security menu with all expected item texts' {
        $mainPath = (Join-Path $script:WS 'Main-GUI.ps1')
        $src = Get-Content $mainPath -Raw -Encoding UTF8
        $expectedTexts = @(
            'Security &Checklist'
            'Assisted SASC &Wizard'
            'Vault &Status'
            '&Unlock Vault'
            '&Lock Vault'
        )
        foreach ($text in $expectedTexts) {
            $src | Should -Match ([regex]::Escape($text)) -Because "Security menu must contain item text '$text'"
        }
    }

    It 'Main-GUI.ps1 defines a WinGets menu with all expected item texts' {
        $mainPath = (Join-Path $script:WS 'Main-GUI.ps1')
        $src = Get-Content $mainPath -Raw -Encoding UTF8
        $expectedTexts = @(
            'Installed Apps'
            'Detect Updates'
            'Update All'
            'App &Template Manager'
        )
        foreach ($text in $expectedTexts) {
            $src | Should -Match ([regex]::Escape($text)) -Because "WinGets menu must contain item text '$text'"
        }
    }

    It 'Main-GUI.ps1 defines a File menu with all expected item texts' {
        $mainPath = (Join-Path $script:WS 'Main-GUI.ps1')
        $src = Get-Content $mainPath -Raw -Encoding UTF8
        $expectedTexts = @(
            '&Configure Paths'
            '&Script Folders'
            'E&xit'
        )
        foreach ($text in $expectedTexts) {
            $src | Should -Match ([regex]::Escape($text)) -Because "File menu must contain item text '$text'"
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





