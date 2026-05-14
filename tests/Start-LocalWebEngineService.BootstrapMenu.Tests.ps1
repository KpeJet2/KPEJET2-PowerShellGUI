# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS
Focused tests for bootstrap menu loading and action dispatch in Start-LocalWebEngineService.ps1.
.DESCRIPTION
Uses AST function extraction to unit-test bootstrap config loading and action dispatch behavior
without launching the tray host UI.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:ServiceScript = Join-Path $script:RepoRoot 'scripts\Start-LocalWebEngineService.ps1'
    $script:ServiceContent = Get-Content -LiteralPath $script:ServiceScript -Raw -Encoding UTF8

    $tokens = $null
    $parseErrors = $null
    $script:ServiceAst = [System.Management.Automation.Language.Parser]::ParseFile($script:ServiceScript, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Parse errors in Start-LocalWebEngineService.ps1: $($parseErrors[0].Message)"
    }

    function Import-ServiceFunction {
        param([Parameter(Mandatory)] [string]$FunctionName)

        $found = $script:ServiceAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
        }, $true)

        $funcDef = $null
        if (@($found).Count -gt 0) {
            $funcDef = @($found)[0]
        }
        if ($null -eq $funcDef) {
            throw "Function not found in service script: $FunctionName"
        }

        $bodyText = $funcDef.Body.Extent.Text
        $scopedDef = "function script:$FunctionName $bodyText"
        . ([scriptblock]::Create($scopedDef))
    }

    # Minimal placeholders used by Invoke-BootstrapMenuAction and mocked in tests.
    function Write-ServiceLog {
        param([string]$Level, [string]$Message)
    }
    function Invoke-ConfiguredScript {
        param([string]$ScriptRelative, [AllowNull()] [object]$ScriptArgs)
    }
    function Invoke-EngineAction {
        param([string]$EngineAction)
    }

    $requiredFunctions = @(
        'ConvertTo-StringArray',
        'Resolve-WorkspaceChildPath',
        'Resolve-BootstrapTokens',
        'Get-BootstrapMenuConfigPath',
        'Get-DefaultBootstrapMenuConfig',
        'Get-BootstrapMenuConfig',
        'Test-EngineProcessIdentity',
        'Invoke-BootstrapMenuAction'
    )

    foreach ($fnName in $requiredFunctions) {
        Import-ServiceFunction -FunctionName $fnName
    }
}

Describe 'Start-LocalWebEngineService bootstrap tray wiring' {
    It 'contains a live reload menu action label' {
        $script:ServiceContent | Should -Match 'Reload Bootstrap Menu'
    }

    It 'clears and rebuilds bootstrap menu items during reload' {
        $script:ServiceContent | Should -Match '\$bootstrapRoot\.DropDownItems\.Clear\(\)'
        $script:ServiceContent | Should -Match 'Add-BootstrapQuickAccessMenu\s+-RootMenu\s+\$bootstrapRoot'
    }
}

Describe 'Start-LocalWebEngineService bootstrap config loading' {
    BeforeEach {
        $script:WorkspacePath = $TestDrive
        $script:Port = 8042

        $cfgDir = Join-Path $script:WorkspacePath 'config'
        New-Item -Path $cfgDir -ItemType Directory -Force | Out-Null
    }

    It 'returns defaults when config file is missing' {
        $result = Get-BootstrapMenuConfig
        $result.schema | Should -Be 'BootstrapMenuConfig/1.0'

        @($result.headings).Count | Should -BeGreaterThan 0
        $headingNames = @($result.headings | ForEach-Object { $_.name })
        $headingNames | Should -Contain 'Services'
        $headingNames | Should -Contain 'WebPage-SCRIPTs'
    }

    It 'loads heading data from config/bootstrap-menu.config.json when present' {
        $cfgPath = Join-Path (Join-Path $script:WorkspacePath 'config') 'bootstrap-menu.config.json'
        $payload = [ordered]@{
            schema = 'BootstrapMenuConfig/1.0'
            headings = @(
                [ordered]@{
                    name = 'UnitHeading'
                    items = @(
                        [ordered]@{ label = 'UnitUrl'; type = 'url'; target = 'http://127.0.0.1:{port}/' }
                    )
                }
            )
        }

        Set-Content -LiteralPath $cfgPath -Value ($payload | ConvertTo-Json -Depth 8) -Encoding UTF8 -Force

        $result = Get-BootstrapMenuConfig
        @($result.headings).Count | Should -Be 1
        @($result.headings)[0].name | Should -Be 'UnitHeading'
    }
}

Describe 'Start-LocalWebEngineService bootstrap action dispatch' {
    BeforeEach {
        $script:WorkspacePath = $TestDrive
        $script:Port = 8042
        $script:DispatchScriptCalls = @()
        New-Item -Path (Join-Path $script:WorkspacePath 'config') -ItemType Directory -Force | Out-Null

        if (Test-Path -Path 'function:Invoke-ConfiguredScript') {
            Remove-Item -Path 'function:Invoke-ConfiguredScript' -Force
        }
        Set-Item -Path 'function:Invoke-ConfiguredScript' -Value {
            param([string]$ScriptRelative, [AllowNull()] [object]$ScriptArgs)
            $script:DispatchScriptCalls += [pscustomobject]@{
                ScriptRelative = $ScriptRelative
                ScriptArgs = @($ScriptArgs)
            }
        }

        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Invoke-EngineAction -MockWith { }
        Mock -CommandName Wait-Process -MockWith { }
        Mock -CommandName Get-Process -MockWith { throw 'process not found' }
        Mock -CommandName Stop-Process -MockWith { }
        Mock -CommandName Write-ServiceLog -MockWith { }
    }

    It 'dispatches url items to Start-Process with token-expanded port' {
        $entry = [pscustomobject]@{
            type = 'url'
            target = 'http://127.0.0.1:{port}/pages/bootstrap-menu-config'
        }

        Invoke-BootstrapMenuAction -Entry $entry

        Assert-MockCalled -CommandName Start-Process -Exactly -Times 1 -ParameterFilter {
            $FilePath -eq 'http://127.0.0.1:8042/pages/bootstrap-menu-config'
        }
    }

    It 'dispatches script items through Invoke-ConfiguredScript' {
        $entry = [pscustomobject]@{
            type = 'script'
            target = 'tests\unit.ps1'
            args = @('-CI')
        }

        Invoke-BootstrapMenuAction -Entry $entry

        @($script:DispatchScriptCalls).Count | Should -Be 1
        @($script:DispatchScriptCalls)[0].ScriptRelative | Should -Be 'tests\unit.ps1'
        @(@($script:DispatchScriptCalls)[0].ScriptArgs).Count | Should -Be 1
        @($script:DispatchScriptCalls)[0].ScriptArgs[0] | Should -Be '-CI'
    }

    It 'dispatches allowed engine actions via Invoke-EngineAction' {
        $entry = [pscustomobject]@{
            type = 'engineAction'
            target = 'Restart'
        }

        Invoke-BootstrapMenuAction -Entry $entry

        Assert-MockCalled -CommandName Invoke-EngineAction -Exactly -Times 1 -ParameterFilter {
            $EngineAction -eq 'Restart'
        }
    }

    It 'blocks command entries not in the allow-list' {
        $entry = [pscustomobject]@{
            type = 'command'
            target = 'notepad.exe'
            args = @()
        }

        Invoke-BootstrapMenuAction -Entry $entry

        Assert-MockCalled -CommandName Start-Process -Exactly -Times 0
        Assert-MockCalled -CommandName Write-ServiceLog -Exactly -Times 1 -ParameterFilter {
            $Level -eq 'WARN' -and $Message -like '*not allowed by policy*'
        }
    }

    It 'blocks command entries when target is empty' {
        $entry = [pscustomobject]@{
            type = 'command'
            target = ''
            args = @()
        }

        Invoke-BootstrapMenuAction -Entry $entry

        Assert-MockCalled -CommandName Start-Process -Exactly -Times 0
        Assert-MockCalled -CommandName Write-ServiceLog -Exactly -Times 1 -ParameterFilter {
            $Level -eq 'WARN' -and $Message -like '*empty target*'
        }
    }

    It 'blocks enginekill when process identity validation fails' {
        $logsDir = Join-Path $script:WorkspacePath 'logs'
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $logsDir 'engine.pid') -Value '12345' -Encoding UTF8 -Force

        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Id = 12345; ProcessName = 'pwsh' } } -ParameterFilter { $Id -eq 12345 }
        Mock -CommandName Test-EngineProcessIdentity -MockWith { $false } -ParameterFilter { $ProcessId -eq 12345 }

        $entry = [pscustomobject]@{
            type = 'engineKill'
            target = 'force'
        }

        Invoke-BootstrapMenuAction -Entry $entry

        Assert-MockCalled -CommandName Stop-Process -Exactly -Times 0
        Assert-MockCalled -CommandName Write-ServiceLog -Exactly -Times 1 -ParameterFilter {
            $Level -eq 'WARN' -and $Message -like '*identity validation failed*'
        }
    }

    It 'allows enginekill when process identity validation succeeds' {
        $logsDir = Join-Path $script:WorkspacePath 'logs'
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $logsDir 'engine.pid') -Value '22334' -Encoding UTF8 -Force

        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Id = 22334; ProcessName = 'pwsh' } } -ParameterFilter { $Id -eq 22334 }
        Mock -CommandName Test-EngineProcessIdentity -MockWith { $true } -ParameterFilter { $ProcessId -eq 22334 }

        $entry = [pscustomobject]@{
            type = 'engineKill'
            target = 'force'
        }

        Invoke-BootstrapMenuAction -Entry $entry

        Assert-MockCalled -CommandName Stop-Process -Exactly -Times 1 -ParameterFilter {
            $Id -eq 22334 -and $Force
        }
    }

    It 'uses graceful stop and skips force-kill when engine stops' {
        $logsDir = Join-Path $script:WorkspacePath 'logs'
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $logsDir 'engine.pid') -Value '33445' -Encoding UTF8 -Force

        Mock -CommandName Invoke-EngineAction -MockWith {
            [pscustomobject]@{ Success = $true; ExitCode = 0; ProcessId = $null }
        } -ParameterFilter { $EngineAction -eq 'Stop' }
        Mock -CommandName Wait-Process -MockWith { } -ParameterFilter { $Id -eq 33445 }
        Mock -CommandName Get-Process -MockWith { throw 'process not found' } -ParameterFilter { $Id -eq 33445 }

        $entry = [pscustomobject]@{
            type = 'engineKill'
            target = 'force'
        }

        Invoke-BootstrapMenuAction -Entry $entry

        Assert-MockCalled -CommandName Invoke-EngineAction -Exactly -Times 1 -ParameterFilter {
            $EngineAction -eq 'Stop'
        }
        Assert-MockCalled -CommandName Stop-Process -Exactly -Times 0
        Assert-MockCalled -CommandName Write-ServiceLog -Exactly -Times 1 -ParameterFilter {
            $Level -eq 'ACTION' -and $Message -like '*stopped gracefully*'
        }
    }

    It 'blocks file entries that escape workspace boundaries' {
        $entry = [pscustomobject]@{
            type = 'file'
            target = '..\outside.txt'
        }

        Invoke-BootstrapMenuAction -Entry $entry

        Assert-MockCalled -CommandName Start-Process -Exactly -Times 0
        Assert-MockCalled -CommandName Write-ServiceLog -Exactly -Times 1 -ParameterFilter {
            $Level -eq 'WARN' -and $Message -like '*not found or denied*'
        }
    }
}
