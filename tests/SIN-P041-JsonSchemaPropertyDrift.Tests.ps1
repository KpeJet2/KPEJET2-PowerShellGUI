# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:WorkspacePath = Split-Path $PSScriptRoot -Parent
    $script:ScannerPath = Join-Path $PSScriptRoot 'Invoke-SINPatternScanner.ps1'
    $script:TempDir = Join-Path $script:WorkspacePath 'temp\p041-scan-tests'
    if (-not (Test-Path -LiteralPath $script:TempDir)) {
        $null = New-Item -Path $script:TempDir -ItemType Directory -Force
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:TempDir) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'SIN Pattern P041' {
    It 'flags unguarded drift-prone JSON property access' {
        $unsafePath = Join-Path $script:TempDir 'Unsafe-P041.ps1'
        @'
$item = Get-Content -LiteralPath '.\todo.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$createdAt = $item.created_at
'@ | Set-Content -LiteralPath $unsafePath -Encoding UTF8

        $result = & $script:ScannerPath -WorkspacePath $script:WorkspacePath -IncludeFiles @($unsafePath) -TargetPattern '041' -Quiet
        @($result.findings | Where-Object { $_.sinId -match '041' }).Count | Should -BeGreaterThan 0
    }

    It 'suppresses guarded drift-prone JSON property access' {
        $safePath = Join-Path $script:TempDir 'Safe-P041.ps1'
        @'
$item = Get-Content -LiteralPath '.\todo.json' -Raw -Encoding UTF8 | ConvertFrom-Json
if (($null -ne $item) -and ($item.PSObject.Properties.Name -contains 'created_at')) {
    $createdAt = $item.created_at
}
'@ | Set-Content -LiteralPath $safePath -Encoding UTF8

        $result = & $script:ScannerPath -WorkspacePath $script:WorkspacePath -IncludeFiles @($safePath) -TargetPattern '041' -Quiet
        @($result.findings | Where-Object { $_.sinId -match '041' }).Count | Should -Be 0
    }
}
