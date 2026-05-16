# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#!
.SYNOPSIS
Behavior tests for bootstrap rollback/retention governance in Start-LocalWebEngine.ps1.
.DESCRIPTION
Loads selected functions via AST extraction and validates retention, history payload,
and explicit rollback target behavior using isolated TestDrive fixtures.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:EngineScript = Join-Path $script:RepoRoot 'scripts\Start-LocalWebEngine.ps1'
    $script:EngineContent = Get-Content -LiteralPath $script:EngineScript -Raw -Encoding UTF8

    $tokens = $null
    $parseErrors = $null
    $script:EngineAst = [System.Management.Automation.Language.Parser]::ParseFile($script:EngineScript, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Parse errors in Start-LocalWebEngine.ps1: $($parseErrors[0].Message)"
    }

    function Import-EngineFunction {
        param([Parameter(Mandatory)] [string]$FunctionName)

        $found = $script:EngineAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
        }, $true)

        if (@($found).Count -eq 0) {
            throw "Function not found in engine script: $FunctionName"
        }

        $funcDef = @($found)[0]
        $bodyText = $funcDef.Body.Extent.Text
        $scopedDef = "function script:$FunctionName $bodyText"
        . ([scriptblock]::Create($scopedDef))
    }

    function Write-BootstrapLog {
        param([string]$Message, [string]$Level)
    }

    function Send-Json {
        param($Context, $Object)
        $script:LastJson = $Object
    }

    function Send-Error {
        param($Context, [int]$StatusCode, [string]$Message)
        $script:LastError = [ordered]@{ StatusCode = $StatusCode; Message = $Message }
    }

    function New-TestContext {
        param(
            [Parameter(Mandatory)] [string]$Token,
            [string]$Body = ''
        )

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $stream = New-Object System.IO.MemoryStream
        if (@($bytes).Count -gt 0) {
            $stream.Write($bytes, 0, $bytes.Length)
        }
        $stream.Position = 0

        return [pscustomobject]@{
            Request = [pscustomobject]@{
                Headers = @{ 'X-CSRF-Token' = $Token }
                InputStream = $stream
            }
        }
    }

    function New-SnapshotFile {
        param(
            [Parameter(Mandatory)] [string]$Name,
            [Parameter(Mandatory)] [string]$Json,
            [Parameter(Mandatory)] [datetime]$WriteTimeUtc
        )

        $historyDir = Join-Path (Join-Path $script:WorkspacePath 'config') 'bootstrap-menu.history'
        $path = Join-Path $historyDir $Name
        Set-Content -LiteralPath $path -Value $Json -Encoding UTF8 -Force
        $item = Get-Item -LiteralPath $path
        $item.LastWriteTimeUtc = $WriteTimeUtc
        return $path
    }

    foreach ($fn in @(
        'New-BootstrapMenuSnapshot',
        'Get-BootstrapMenuSnapshots',
        'Invoke-BootstrapMenuSnapshotRetention',
        'Resolve-BootstrapRollbackSnapshot',
        'Get-BootstrapMenuSnapshotHistory',
        'Rollback-BootstrapMenuConfig'
    )) {
        Import-EngineFunction -FunctionName $fn
    }
}

Describe 'Start-LocalWebEngine bootstrap governance behavior' {
    BeforeEach {
        $script:WorkspacePath = $TestDrive
        $script:SessionToken = 'unit-token'  # SIN-EXEMPT:P001 -- unit-test fixture, not a real credential
        $script:LastJson = $null
        $script:LastError = $null

        $configDir = Join-Path $script:WorkspacePath 'config'
        $historyDir = Join-Path $configDir 'bootstrap-menu.history'
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        New-Item -Path $historyDir -ItemType Directory -Force | Out-Null
        Get-ChildItem -LiteralPath $historyDir -File -Filter 'bootstrap-menu.config.*.json' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    It 'retention removes oldest snapshots beyond keep limit' {
        $json = '{"schema":"BootstrapMenuConfig/1.0","headings":[]}'
        New-SnapshotFile -Name 'bootstrap-menu.config.20260514-010101-001.json' -Json $json -WriteTimeUtc ([datetime]::Parse('2026-05-14T01:01:01Z')) | Out-Null
        New-SnapshotFile -Name 'bootstrap-menu.config.20260514-010102-002.json' -Json $json -WriteTimeUtc ([datetime]::Parse('2026-05-14T01:01:02Z')) | Out-Null
        New-SnapshotFile -Name 'bootstrap-menu.config.20260514-010103-003.json' -Json $json -WriteTimeUtc ([datetime]::Parse('2026-05-14T01:01:03Z')) | Out-Null
        New-SnapshotFile -Name 'bootstrap-menu.config.20260514-010104-004.json' -Json $json -WriteTimeUtc ([datetime]::Parse('2026-05-14T01:01:04Z')) | Out-Null

        $removed = Invoke-BootstrapMenuSnapshotRetention -Keep 2

        $removed | Should -Be 2
        @((Get-BootstrapMenuSnapshots)).Count | Should -Be 2
    }

    It 'history route returns snapshot metadata and count' {
        $json = '{"schema":"BootstrapMenuConfig/1.0","headings":[]}'
        New-SnapshotFile -Name 'bootstrap-menu.config.20260514-020101-001.json' -Json $json -WriteTimeUtc ([datetime]::Parse('2026-05-14T02:01:01Z')) | Out-Null
        New-SnapshotFile -Name 'bootstrap-menu.config.20260514-020102-002.json' -Json $json -WriteTimeUtc ([datetime]::Parse('2026-05-14T02:01:02Z')) | Out-Null

        $ctx = New-TestContext -Token 'unit-token'
        Get-BootstrapMenuSnapshotHistory -Context $ctx

        $script:LastError | Should -BeNullOrEmpty
        $script:LastJson.count | Should -Be 2
        @($script:LastJson.snapshots).Count | Should -Be 2
        @($script:LastJson.snapshots)[0].path | Should -Match '^config/bootstrap-menu\.history/bootstrap-menu\.config\.'
    }

    It 'rollback restores explicit requested snapshot when provided' {
        $cfgPath = Join-Path (Join-Path $script:WorkspacePath 'config') 'bootstrap-menu.config.json'
        $currentJson = '{"schema":"BootstrapMenuConfig/1.0","headings":[{"name":"Current","items":[{"type":"url","target":"http://current"}]}]}'
        Set-Content -LiteralPath $cfgPath -Value $currentJson -Encoding UTF8 -Force

        $oldJson = '{"schema":"BootstrapMenuConfig/1.0","headings":[{"name":"Old","items":[{"type":"url","target":"http://old"}]}]}'
        $newJson = '{"schema":"BootstrapMenuConfig/1.0","headings":[{"name":"New","items":[{"type":"url","target":"http://new"}]}]}'

        New-SnapshotFile -Name 'bootstrap-menu.config.20260514-030101-001.json' -Json $oldJson -WriteTimeUtc ([datetime]::Parse('2026-05-14T03:01:01Z')) | Out-Null
        New-SnapshotFile -Name 'bootstrap-menu.config.20260514-030102-002.json' -Json $newJson -WriteTimeUtc ([datetime]::Parse('2026-05-14T03:01:02Z')) | Out-Null

        $requestedRel = 'config/bootstrap-menu.history/bootstrap-menu.config.20260514-030101-001.json'
        $ctx = New-TestContext -Token 'unit-token' -Body ('{"snapshot":"' + $requestedRel + '"}')

        Rollback-BootstrapMenuConfig -Context $ctx

        $script:LastError | Should -BeNullOrEmpty
        $script:LastJson.rolledBack | Should -BeTrue
        $script:LastJson.requestedSnapshot | Should -Be $requestedRel
        $script:LastJson.restoredFrom | Should -Match 'bootstrap-menu\.config\.20260514-030101-001\.json$'

        $restoredObj = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
        @($restoredObj.headings)[0].name | Should -Be 'Old'
    }

    It 'rollback rejects unknown requested snapshot' {
        $cfgPath = Join-Path (Join-Path $script:WorkspacePath 'config') 'bootstrap-menu.config.json'
        Set-Content -LiteralPath $cfgPath -Value '{"schema":"BootstrapMenuConfig/1.0","headings":[]}' -Encoding UTF8 -Force

        New-SnapshotFile -Name 'bootstrap-menu.config.20260514-040101-001.json' -Json '{"schema":"BootstrapMenuConfig/1.0","headings":[]}' -WriteTimeUtc ([datetime]::Parse('2026-05-14T04:01:01Z')) | Out-Null

        $ctx = New-TestContext -Token 'unit-token' -Body '{"snapshot":"config/bootstrap-menu.history/bootstrap-menu.config.19990101-000000-000.json"}'
        Rollback-BootstrapMenuConfig -Context $ctx

        $script:LastJson | Should -BeNullOrEmpty
        $script:LastError.StatusCode | Should -Be 404
        $script:LastError.Message | Should -Match 'Requested snapshot not found or not eligible'
    }

    It 'rollback rejects malformed rollback payload JSON' {
        $cfgPath = Join-Path (Join-Path $script:WorkspacePath 'config') 'bootstrap-menu.config.json'
        Set-Content -LiteralPath $cfgPath -Value '{"schema":"BootstrapMenuConfig/1.0","headings":[]}' -Encoding UTF8 -Force

        $ctx = New-TestContext -Token 'unit-token' -Body '{broken'
        Rollback-BootstrapMenuConfig -Context $ctx

        $script:LastJson | Should -BeNullOrEmpty
        $script:LastError.StatusCode | Should -Be 400
        $script:LastError.Message | Should -Match 'Invalid rollback payload'
    }
}
