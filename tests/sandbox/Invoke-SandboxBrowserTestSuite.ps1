# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS
    Main orchestrator for sandbox browser test automation.
.DESCRIPTION
    Discovers all HTML/XHTML files and README.md files in the workspace,
    runs the full test suite across all available browsers (Edge, Chrome,
    Firefox), converts failures to Bugs2FIX and gaps to 2DO tasks, and
    produces consolidated test results.
.NOTES
    Author  : The Establishment
    Runs in : Windows Sandbox (WDAGUtilityAccount)
#>
param(
    [Parameter(Mandatory)]
    [string]$WorkspacePath,

    [string]$OutputPath = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output',

    [string]$ManifestPath,

    [switch]$IncludeReadme,

    [switch]$SkipDataState,

    [switch]$EdgeOnly,

    [switch]$HtmlOnly
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# ========================== LOGGING ==========================
$logFile = Join-Path $OutputPath 'browser-test-suite.log'
function Write-SuiteLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg"
    $color = switch ($Level) {
        'ERROR' { 'Red' }; 'WARN' { 'Yellow' }; 'OK' { 'Green' }; default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

# ========================== INIT ==========================
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$sessionId = "browsertest-$(Get-Date -Format 'yyyyMMddHHmmss')"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

Write-SuiteLog '=================================================================='
Write-SuiteLog '  Sandbox Browser Test Suite'
Write-SuiteLog "  Session: $sessionId"
Write-SuiteLog '=================================================================='

# Load config
$configPath = Join-Path $WorkspacePath 'config\browser-test-config.json'
$config = $null
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
$pollingConfig = @{
    phase1IntervalSeconds = 20
    phase1DurationMinutes = 5
    phase2IntervalSeconds = 60
    phase2DurationMinutes = 5
}
if ($config -and $config.dataStatePolling) {
    $pollingConfig.phase1IntervalSeconds = $config.dataStatePolling.phase1IntervalSeconds
    $pollingConfig.phase1DurationMinutes = $config.dataStatePolling.phase1DurationMinutes
    $pollingConfig.phase2IntervalSeconds = $config.dataStatePolling.phase2IntervalSeconds
    $pollingConfig.phase2DurationMinutes = $config.dataStatePolling.phase2DurationMinutes
}

# Load browser manifest
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $OutputPath 'browser-manifest.json'
}
if (-not (Test-Path $ManifestPath)) {
    Write-SuiteLog "Browser manifest not found: $ManifestPath" -Level 'ERROR'
    Write-SuiteLog 'Run Install-BrowserTestDependencies.ps1 first' -Level 'ERROR'
    exit 1
}
$manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Load test engine
$testEnginePath = Join-Path $WorkspacePath 'tests\sandbox\Invoke-BrowserPageTest.ps1'
if (-not (Test-Path $testEnginePath)) {
    # Fallback if running from local copy
    $testEnginePath = Join-Path (Split-Path $PSCommandPath -Parent) 'Invoke-BrowserPageTest.ps1'
}
. $testEnginePath -SeleniumDllPath $manifest.SeleniumDllPath

# ========================== FILE DISCOVERY ==========================
function Get-TestableFiles {
    param([string]$Root, [switch]$HtmlOnlyMode, [switch]$WithReadme)

    $skipDirs = @('.git', 'node_modules', '.venv', '.venv-pygame312', 'checkpoints', '~DOWNLOADS')
    $files = New-Object System.Collections.Generic.List[object]

    # HTML/XHTML files
    $htmlExts = @('*.html', '*.xhtml')
    foreach ($ext in $htmlExts) {
        $found = Get-ChildItem $Root -Recurse -Filter $ext -File -ErrorAction SilentlyContinue
        foreach ($f in $found) {
            $skip = $false
            foreach ($sd in $skipDirs) {
                if ($f.FullName -match [regex]::Escape($sd)) { $skip = $true; break }
            }
            if (-not $skip) {
                $files.Add([ordered]@{
                    path     = $f.FullName
                    type     = 'html'
                    fileName = $f.Name
                })
            }
        }
    }

    # README.md files
    if ($WithReadme -and -not $HtmlOnlyMode) {
        $readmeDir = Join-Path $Root '~README.md'
        if (Test-Path $readmeDir) {
            $mdFiles = Get-ChildItem $readmeDir -Filter '*.md' -File -ErrorAction SilentlyContinue
            foreach ($f in $mdFiles) {
                $files.Add([ordered]@{
                    path     = $f.FullName
                    type     = 'markdown'
                    fileName = $f.Name
                })
            }
        }
    }

    return ,$files
}

# ========================== MARKDOWN TO HTML ==========================
function ConvertTo-SimpleHtml {
    <#
    .SYNOPSIS Simple markdown-to-HTML converter for browser testing.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MarkdownPath,
        [string]$TempDir
    )

    $mdContent = Get-Content $MarkdownPath -Raw -Encoding UTF8
    $fileName  = [System.IO.Path]::GetFileNameWithoutExtension($MarkdownPath)
    $outPath   = Join-Path $TempDir "$fileName.html"

    # Simple regex-based conversion
    $html = $mdContent
    # Headers
    $html = $html -replace '(?m)^######\s+(.+)$', '<h6>$1</h6>'
    $html = $html -replace '(?m)^#####\s+(.+)$', '<h5>$1</h5>'
    $html = $html -replace '(?m)^####\s+(.+)$', '<h4>$1</h4>'
    $html = $html -replace '(?m)^###\s+(.+)$', '<h3>$1</h3>'
    $html = $html -replace '(?m)^##\s+(.+)$', '<h2>$1</h2>'
    $html = $html -replace '(?m)^#\s+(.+)$', '<h1>$1</h1>'
    # Bold / Italic
    $html = $html -replace '\*\*(.+?)\*\*', '<strong>$1</strong>'
    $html = $html -replace '\*(.+?)\*', '<em>$1</em>'
    # Links
    $html = $html -replace '\[([^\]]+)\]\(([^\)]+)\)', '<a href="$2">$1</a>'
    # Code blocks
    $html = $html -replace '(?ms)```(\w*)\r?\n(.+?)```', '<pre><code>$2</code></pre>'
    $html = $html -replace '`([^`]+)`', '<code>$1</code>'
    # Line breaks
    $html = $html -replace '(?m)^$', '</p><p>'

    $fullHtml = @"
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>$fileName</title>
<style>body{font-family:sans-serif;max-width:900px;margin:20px auto;padding:20px;color:#e0e0e0;background:#1a1a2e}
a{color:#4fc3f7}pre{background:#222;padding:10px;overflow-x:auto}code{background:#333;padding:2px 4px}</style>
</head><body><p>$html</p>
<footer><p><em>Source: $MarkdownPath</em></p></footer>
</body></html>
"@
    Set-Content -LiteralPath $outPath -Value $fullHtml -Encoding UTF8
    return $outPath
}

# ========================== BROWSER TEST LOOP ==========================
$testableFiles = Get-TestableFiles -Root $WorkspacePath -HtmlOnlyMode:$HtmlOnly -WithReadme:$IncludeReadme

Write-SuiteLog "Discovered $($testableFiles.Count) testable files"
$htmlCount = @($testableFiles | Where-Object { $_.type -eq 'html' }).Count
$mdCount   = @($testableFiles | Where-Object { $_.type -eq 'markdown' }).Count
Write-SuiteLog "  HTML/XHTML: $htmlCount | Markdown: $mdCount"

# Determine which browsers to test
$browsersToTest = New-Object System.Collections.Generic.List[string]
if ($manifest.Edge.Available) { $browsersToTest.Add('Edge') }
if (-not $EdgeOnly) {
    if ($manifest.Chrome.Available) { $browsersToTest.Add('Chrome') }
    if ($manifest.Firefox.Available) { $browsersToTest.Add('Firefox') }
}
Write-SuiteLog "Browsers to test: $($browsersToTest -join ', ')"

# Prepare temp dir for markdown conversions
$mdTempDir = Join-Path $OutputPath 'md-html-temp'
New-Item -ItemType Directory -Path $mdTempDir -Force | Out-Null

# Convert markdown files to HTML
$convertedMdFiles = @{}
foreach ($f in $testableFiles) {
    if ($f.type -eq 'markdown') {
        try {
            $htmlPath = ConvertTo-SimpleHtml -MarkdownPath $f.path -TempDir $mdTempDir
            $convertedMdFiles[$f.path] = $htmlPath
            Write-SuiteLog "  Converted: $($f.fileName) -> HTML"
        } catch {
            Write-SuiteLog "  Failed to convert $($f.fileName): $_" -Level 'WARN'
        }
    }
}

# Run tests
$allTestResults = New-Object System.Collections.Generic.List[object]
$totalFiles = $testableFiles.Count
$fileIndex = 0

foreach ($browserName in $browsersToTest) {
    Write-SuiteLog '=================================================================='
    Write-SuiteLog "  Testing with: $browserName"
    Write-SuiteLog '=================================================================='

    $browserInfo = switch ($browserName) {
        'Edge'    { @{ Available = $manifest.Edge.Available; DriverPath = $manifest.Edge.DriverPath; ExePath = $manifest.Edge.ExePath } }
        'Chrome'  { @{ Available = $manifest.Chrome.Available; DriverPath = $manifest.Chrome.DriverPath; ExePath = $manifest.Chrome.ExePath } }
        'Firefox' { @{ Available = $manifest.Firefox.Available; DriverPath = $manifest.Firefox.DriverPath; ExePath = $manifest.Firefox.ExePath } }
    }

    $driver = $null
    try {
        $driver = New-BrowserDriver -BrowserName $browserName -BrowserInfo $browserInfo -DriverDir $manifest.DriverDir -PageLoadTimeout 30
    } catch {
        Write-SuiteLog "Failed to create $browserName driver: $_" -Level 'ERROR'
        continue
    }

    if (-not $driver) {
        Write-SuiteLog "$browserName driver creation returned null" -Level 'ERROR'
        continue
    }

    $fileIndex = 0
    foreach ($f in $testableFiles) {
        $fileIndex++
        $testFilePath = $f.path
        if ($f.type -eq 'markdown' -and $convertedMdFiles.ContainsKey($f.path)) {
            $testFilePath = $convertedMdFiles[$f.path]
        }

        Write-SuiteLog "  [$fileIndex/$totalFiles] $($f.fileName) ($browserName)"

        try {
            $result = Invoke-FullPageTest -Driver $driver `
                -FilePath $testFilePath `
                -BrowserName $browserName `
                -WorkspacePath $WorkspacePath `
                -PollingConfig $pollingConfig `
                -SkipDataState:$SkipDataState

            # Attach original source path for markdown files
            if ($f.type -eq 'markdown') {
                $result['sourceMarkdown'] = $f.path
            }

            $allTestResults.Add($result)

            # Count results
            $passed = 0; $failed = 0; $todoCount = 0
            foreach ($catKey in $result.categories.Keys) {
                $catItems = $result.categories[$catKey]
                if ($catItems) {
                    foreach ($item in $catItems) {
                        switch ($item.status) {
                            'PASS' { $passed++ }
                            'FAIL' { $failed++ }
                            '2DO'  { $todoCount++ }
                        }
                    }
                }
            }
            $statusMsg = if ($failed -gt 0) { 'FAIL' } else { 'PASS' }
            $color = if ($failed -gt 0) { 'WARN' } else { 'OK' }
            Write-SuiteLog "    $statusMsg -- Pass:$passed Fail:$failed 2DO:$todoCount" -Level $color
        } catch {
            Write-SuiteLog "    ERROR testing $($f.fileName): $_" -Level 'ERROR'
            $allTestResults.Add(@{
                filePath   = $f.path
                browser    = $browserName
                testedAt   = (Get-Date -Format 'o')
                categories = @{ pageLoad = @(@{ element = 'page-load'; status = 'ERROR'; errorDetail = "$_"; testedAt = (Get-Date -Format 'o') }) }
            })
        }
    }

    # Dispose driver
    try {
        $driver.Quit()
        $driver.Dispose()
    } catch { <# best effort #> }
    Write-SuiteLog "$browserName testing complete" -Level 'OK'
}

# ========================== RESULTS & BUG CONVERSION ==========================
$sw.Stop()

# Write raw results
$resultsFile = Join-Path $OutputPath 'sandbox-browser-test-results.json'
$resultsOutput = [ordered]@{
    meta = [ordered]@{
        schema       = 'SandboxBrowserTest/1.0'
        sessionId    = $sessionId
        generatedAt  = (Get-Date -Format 'o')
        elapsedMs    = $sw.ElapsedMilliseconds
        workspace    = $WorkspacePath
        browsers     = @($browsersToTest)
        totalFiles   = $totalFiles
        totalResults = $allTestResults.Count
    }
    results = $allTestResults.ToArray()
}
ConvertTo-Json $resultsOutput -Depth 15 | Set-Content -LiteralPath $resultsFile -Encoding UTF8
Write-SuiteLog "Results written: $resultsFile" -Level 'OK'

# Convert to bugs/tasks
$bugConverterPath = Join-Path (Split-Path $PSCommandPath -Parent) 'ConvertTo-BugTask.ps1'
if (Test-Path $bugConverterPath) {
    Write-SuiteLog 'Converting failures to Bugs2FIX and Items2ADD...'
    $bugOutput = & $bugConverterPath -TestResults $allTestResults.ToArray() -OutputPath $OutputPath -SessionId $sessionId
    Write-SuiteLog "Bugs: $($bugOutput.summary.totalBugs) | Fixes: $($bugOutput.summary.totalFixes) | 2DO: $($bugOutput.summary.totalTodos)" -Level 'OK'
} else {
    Write-SuiteLog "Bug converter not found: $bugConverterPath" -Level 'WARN'
}

# ========================== SUMMARY ==========================
$totalPassed = 0; $totalFailed = 0; $totalTodo = 0; $totalError = 0
foreach ($r in $allTestResults) {
    if ($r.categories) {
        foreach ($catKey in $r.categories.Keys) {
            $catItems = $r.categories[$catKey]
            if ($catItems) {
                foreach ($item in $catItems) {
                    switch ($item.status) {
                        'PASS'  { $totalPassed++ }
                        'FAIL'  { $totalFailed++ }
                        '2DO'   { $totalTodo++ }
                        'ERROR' { $totalError++ }
                    }
                }
            }
        }
    }
}

Write-SuiteLog '=================================================================='
Write-SuiteLog '  Browser Test Suite Complete'
Write-SuiteLog '=================================================================='
Write-SuiteLog "  Session   : $sessionId"
Write-SuiteLog "  Duration  : $([Math]::Round($sw.Elapsed.TotalMinutes, 1)) minutes"
Write-SuiteLog "  Files     : $totalFiles"
Write-SuiteLog "  Browsers  : $($browsersToTest -join ', ')"
Write-SuiteLog "  PASS      : $totalPassed"
Write-SuiteLog "  FAIL      : $totalFailed"
Write-SuiteLog "  2DO       : $totalTodo"
Write-SuiteLog "  ERROR     : $totalError"
Write-SuiteLog '=================================================================='

# Write completion signal
$signalPath = Join-Path $OutputPath 'browser-test-complete.json'
$signal = [ordered]@{
    status    = if ($totalFailed -gt 0 -or $totalError -gt 0) { 'COMPLETED_WITH_FAILURES' } else { 'COMPLETED_ALL_PASS' }
    sessionId = $sessionId
    elapsed   = $sw.Elapsed.ToString()
    summary   = [ordered]@{ passed = $totalPassed; failed = $totalFailed; todo = $totalTodo; errors = $totalError }
    timestamp = (Get-Date -Format 'o')
}
ConvertTo-Json $signal -Depth 5 | Set-Content -LiteralPath $signalPath -Encoding UTF8

exit $(if ($totalFailed -gt 0 -or $totalError -gt 0) { 1 } else { 0 })
