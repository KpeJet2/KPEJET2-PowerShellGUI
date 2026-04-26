# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Converts browser test results into CronAiAthon-compatible Bugs2FIX and Items2ADD (2DO) entries.
.DESCRIPTION
    Takes structured test result objects from Invoke-BrowserPageTest and creates
    bug/task entries matching the CronAiAthon-BugTracker schema. FAIL results
    become Bugs2FIX, 2DO/WARN results become Items2ADD tasks.
.NOTES
    Author  : The Establishment
    Runs in : Windows Sandbox (WDAGUtilityAccount)
#>
param(
    [Parameter(Mandatory)]
    [object[]]$TestResults,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$SessionId = "browsertest-$(Get-Date -Format 'yyyyMMddHHmmss')"
)

$ErrorActionPreference = 'Continue'

function New-BugId {
    $ts = Get-Date -Format 'yyyyMMddHHmmss'
    $guid = [guid]::NewGuid().ToString().Substring(0, 8)
    return "Bug-$ts-$guid"
}

function New-Bugs2FixId {
    $ts = Get-Date -Format 'yyyyMMddHHmmss'
    $guid = [guid]::NewGuid().ToString().Substring(0, 8)
    return "Bugs2FIX-$ts-$guid"
}

function New-Items2AddId {
    $ts = Get-Date -Format 'yyyyMMddHHmmss'
    $guid = [guid]::NewGuid().ToString().Substring(0, 8)
    return "Items2ADD-$ts-$guid"
}

$bugs = New-Object System.Collections.Generic.List[object]
$fixes = New-Object System.Collections.Generic.List[object]
$todos = New-Object System.Collections.Generic.List[object]

foreach ($pageResult in $TestResults) {
    $filePath = $pageResult.filePath
    $browser  = $pageResult.browser

    if (-not $pageResult.categories) { continue }

    foreach ($catName in $pageResult.categories.Keys) {
        $catResults = $pageResult.categories[$catName]
        if (-not $catResults) { continue }

        foreach ($item in $catResults) {
            if (-not $item.status) { continue }

            switch ($item.status) {
                'FAIL' {
                    $bugId = New-BugId
                    $fixId = New-Bugs2FixId

                    # Determine category and priority
                    $category = switch ($catName) {
                        'links'       { 'navigation' }
                        'tabs'        { 'ui-interaction' }
                        'forms'       { 'form-validation' }
                        'tooltips'    { 'accessibility' }
                        'invocations' { 'javascript' }
                        'resources'   { 'resource-loading' }
                        'dataState'   { 'data-binding' }
                        'pageLoad'    { 'rendering' }
                        default       { 'general' }
                    }

                    $priority = switch ($catName) {
                        'pageLoad'    { 'CRITICAL' }
                        'links'       { 'HIGH' }
                        'resources'   { 'HIGH' }
                        'invocations' { 'HIGH' }
                        'forms'       { 'MEDIUM' }
                        'tabs'        { 'MEDIUM' }
                        'dataState'   { 'MEDIUM' }
                        'tooltips'    { 'LOW' }
                        default       { 'MEDIUM' }
                    }

                    # Build descriptive title
                    $elementDesc = if ($item.element) { $item.element } else { $catName }
                    $shortDetail = if ($item.errorDetail -and $item.errorDetail.Length -gt 80) {
                        $item.errorDetail.Substring(0, 80) + '...'
                    } elseif ($item.errorDetail) {
                        $item.errorDetail
                    } else {
                        'Test failed'
                    }

                    $bug = [ordered]@{
                        id              = $bugId
                        type            = 'Bug'
                        status          = 'OPEN'
                        priority        = $priority
                        category        = $category
                        created         = (Get-Date -Format 'o')
                        title           = "[$browser] $elementDesc failure in $(Split-Path $filePath -Leaf)"
                        description     = "Browser: $browser`nFile: $filePath`nCategory: $catName`nElement: $elementDesc`nDetail: $($item.errorDetail)"
                        source          = 'SandboxBrowserTest'
                        affectedFiles   = @($filePath)
                        sessionId       = $SessionId
                        browserTestData = $item
                    }
                    $bugs.Add($bug)

                    $fix = [ordered]@{
                        id          = $fixId
                        type        = 'Bugs2FIX'
                        parentId    = $bugId
                        status      = 'OPEN'
                        priority    = $priority
                        title       = "FIX: $shortDetail"
                        description = "Fix for $bugId -- $($item.errorDetail)"
                        suggestedBy = 'SandboxBrowserTest'
                        category    = $category
                        filePath    = $filePath
                        browser     = $browser
                    }
                    $fixes.Add($fix)
                }

                '2DO' {
                    $todoId = New-Items2AddId
                    $todoItem = [ordered]@{
                        id          = $todoId
                        type        = 'Items2ADD'
                        status      = 'OPEN'
                        priority    = 'LOW'
                        category    = 'enhancement'
                        created     = (Get-Date -Format 'o')
                        title       = "2DO: $($item.errorDetail)"
                        description = "File: $filePath`nBrowser: $browser`nElement: $($item.element)`nAction needed: $($item.errorDetail)"
                        source      = 'SandboxBrowserTest'
                        filePath    = $filePath
                        browser     = $browser
                    }
                    $todos.Add($todoItem)
                }

                'ERROR' {
                    $bugId = New-BugId
                    $bug = [ordered]@{
                        id            = $bugId
                        type          = 'Bug'
                        status        = 'OPEN'
                        priority      = 'HIGH'
                        category      = 'test-infrastructure'
                        created       = (Get-Date -Format 'o')
                        title         = "[$browser] Test engine error in $(Split-Path $filePath -Leaf)"
                        description   = "Test engine error during $catName scan.`nFile: $filePath`nDetail: $($item.errorDetail)"
                        source        = 'SandboxBrowserTest'
                        affectedFiles = @($filePath)
                        sessionId     = $SessionId
                    }
                    $bugs.Add($bug)
                }
            }
        }
    }
}

# Build output
$output = [ordered]@{
    meta = [ordered]@{
        schema      = 'CronAiAthon-BrowserTestBugs/1.0'
        sessionId   = $SessionId
        generatedAt = (Get-Date -Format 'o')
        source      = 'SandboxBrowserTest'
    }
    summary = [ordered]@{
        totalBugs    = $bugs.Count
        totalFixes   = $fixes.Count
        totalTodos   = $todos.Count
        totalEntries = $bugs.Count + $fixes.Count + $todos.Count
    }
    bugs     = $bugs.ToArray()
    fixes    = $fixes.ToArray()
    todos    = $todos.ToArray()
}

$outputFile = Join-Path $OutputPath 'sandbox-browser-test-bugs.json'
ConvertTo-Json $output -Depth 10 | Set-Content -LiteralPath $outputFile -Encoding UTF8

Write-Host "[OK] Generated $($bugs.Count) Bugs, $($fixes.Count) Bugs2FIX, $($todos.Count) Items2ADD (2DO)" -ForegroundColor Green
Write-Host "[OK] Output: $outputFile" -ForegroundColor Green

return $output

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




