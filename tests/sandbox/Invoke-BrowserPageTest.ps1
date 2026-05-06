# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Core browser page test engine using Selenium WebDriver.
.DESCRIPTION
    Provides reusable test functions for link validation, tab testing,
    form state changes, tooltip verification, resource loading checks,
    invocation testing, and timed data-state polling. Each function
    returns structured test result objects for the orchestrator.
.NOTES
    Author  : The Establishment
    Runs in : Windows Sandbox (WDAGUtilityAccount)
#>
param(
    [Parameter(Mandatory)]
    [string]$SeleniumDllPath
)

$ErrorActionPreference = 'Continue'

# ========================== SELENIUM LOAD ==========================
if ($SeleniumDllPath -and (Test-Path $SeleniumDllPath)) {
    Add-Type -Path $SeleniumDllPath
    # Also load support DLL if present
    $supportDll = Join-Path (Split-Path $SeleniumDllPath -Parent) 'WebDriver.Support.dll'
    if (Test-Path $supportDll) {
        Add-Type -Path $supportDll -ErrorAction SilentlyContinue
    }
}

# ========================== DRIVER FACTORY ==========================
function New-BrowserDriver {
    param(
        [Parameter(Mandatory)]
        [string]$BrowserName,
        [Parameter(Mandatory)]
        [hashtable]$BrowserInfo,
        [string]$DriverDir,
        [int]$PageLoadTimeout = 30
    )

    $driver = $null
    try {
        switch ($BrowserName) {
            'Edge' {
                $svc = [OpenQA.Selenium.Edge.EdgeDriverService]::CreateDefaultService($DriverDir)
                $opts = New-Object OpenQA.Selenium.Edge.EdgeOptions
                $opts.AddArgument('--headless')
                $opts.AddArgument('--no-sandbox')
                $opts.AddArgument('--disable-gpu')
                $opts.AddArgument('--disable-dev-shm-usage')
                $opts.AddArgument('--window-size=1920,1080')
                $driver = New-Object OpenQA.Selenium.Edge.EdgeDriver($svc, $opts)
            }
            'Chrome' {
                $svc = [OpenQA.Selenium.Chrome.ChromeDriverService]::CreateDefaultService($DriverDir)
                $opts = New-Object OpenQA.Selenium.Chrome.ChromeOptions
                $opts.AddArgument('--headless')
                $opts.AddArgument('--no-sandbox')
                $opts.AddArgument('--disable-gpu')
                $opts.AddArgument('--disable-dev-shm-usage')
                $opts.AddArgument('--window-size=1920,1080')
                $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($svc, $opts)
            }
            'Firefox' {
                $svc = [OpenQA.Selenium.Firefox.FirefoxDriverService]::CreateDefaultService($DriverDir)
                $opts = New-Object OpenQA.Selenium.Firefox.FirefoxOptions
                $opts.AddArgument('--headless')
                $opts.AddArgument('--width=1920')
                $opts.AddArgument('--height=1080')
                $driver = New-Object OpenQA.Selenium.Firefox.FirefoxDriver($svc, $opts)
            }
        }
        if ($driver) {
            $driver.Manage().Timeouts().PageLoad = [TimeSpan]::FromSeconds($PageLoadTimeout)
            $driver.Manage().Timeouts().ImplicitWait = [TimeSpan]::FromSeconds(5)
        }
    } catch {
        Write-Warning "Failed to create $BrowserName driver: $_"
        return $null
    }
    return $driver
}

# ========================== TEST: PAGE LINKS ==========================
function Test-PageLinks {
    <#
    .SYNOPSIS Tests all <a href> links on a page for valid navigation.
    #>
    param(
        [Parameter(Mandatory)]$Driver,
        [string]$PageUrl,
        [string]$WorkspacePath
    )
    $results = New-Object System.Collections.Generic.List[object]
    try {
        $links = $Driver.FindElements([OpenQA.Selenium.By]::TagName('a'))
        foreach ($link in $links) {
            $href = $null
            try { $href = $link.GetAttribute('href') } catch { continue }
            if (-not $href -or $href -eq '#' -or $href.StartsWith('javascript:')) { continue }

            $testResult = @{
                element     = 'a'
                href        = $href
                text        = ''
                status      = 'PASS'
                errorDetail = ''
                testedAt    = (Get-Date -Format 'o')
            }
            try { $testResult.text = $link.Text.Substring(0, [Math]::Min(100, $link.Text.Length)) } catch { <# Intentional: fault-tolerant DOM probe #> }

            try {
                if ($href.StartsWith('file:///') -or $href -match '^[A-Za-z]:\\') {
                    # Local file link -- check existence
                    $localPath = $href -replace '^file:///', ''
                    $localPath = [System.Uri]::UnescapeDataString($localPath)
                    if (-not (Test-Path $localPath)) {
                        $testResult.status = 'FAIL'
                        $testResult.errorDetail = "Referenced file not found: $localPath"
                    }
                } elseif ($href.StartsWith('http://') -or $href.StartsWith('https://')) {
                    # External link -- HEAD request
                    try {
                        $resp = Invoke-WebRequest -Uri $href -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                        if ($resp.StatusCode -ge 400) {
                            $testResult.status = 'FAIL'
                            $testResult.errorDetail = "HTTP $($resp.StatusCode)"
                        }
                    } catch {
                        $testResult.status = 'FAIL'
                        $testResult.errorDetail = "HTTP error: $_"
                    }
                } else {
                    # Relative link -- try clicking
                    $originalUrl = $Driver.Url
                    try {
                        $link.Click()
                        Start-Sleep -Milliseconds 500
                        # Check for error page
                        $title = $Driver.Title
                        if ($title -match 'not found|404|error') {
                            $testResult.status = 'FAIL'
                            $testResult.errorDetail = "Page title suggests error: $title"
                        }
                    } catch {
                        $testResult.status = 'FAIL'
                        $testResult.errorDetail = "Click failed: $_"
                    } finally {
                        try { $Driver.Navigate().GoToUrl($originalUrl) } catch { <# Intentional: fault-tolerant DOM probe #> }
                    }
                }
            } catch {
                $testResult.status = 'FAIL'
                $testResult.errorDetail = "Unexpected error: $_"
            }
            $results.Add($testResult)
        }
    } catch {
        $results.Add(@{ element = 'links-scan'; status = 'ERROR'; errorDetail = "Link scan failed: $_"; testedAt = (Get-Date -Format 'o') })
    }
    return ,$results
}

# ========================== TEST: PAGE TABS ==========================
function Test-PageTabs {
    <#
    .SYNOPSIS Tests tab controls for proper panel switching.
    #>
    param(
        [Parameter(Mandatory)]$Driver,
        [string]$PageUrl
    )
    $results = New-Object System.Collections.Generic.List[object]
    try {
        # Look for common tab patterns
        $tabSelectors = @(
            "[data-tab]",
            ".tab-btn",
            ".tab-button",
            "[role='tab']",
            ".nav-tab",
            "button[onclick*='tab']",
            "button[onclick*='Tab']"
        )

        foreach ($selector in $tabSelectors) {
            try {
                $tabs = $Driver.FindElements([OpenQA.Selenium.By]::CssSelector($selector))
                foreach ($tab in $tabs) {
                    $tabId = ''
                    try { $tabId = $tab.GetAttribute('data-tab') } catch { <# Intentional: fault-tolerant DOM probe #> }
                    if (-not $tabId) { try { $tabId = $tab.GetAttribute('id') } catch { <# Intentional: fault-tolerant DOM probe #> } }
                    if (-not $tabId) { try { $tabId = $tab.Text.Substring(0, [Math]::Min(30, $tab.Text.Length)) } catch { <# Intentional: fault-tolerant DOM probe #> } }

                    $testResult = @{
                        element     = 'tab'
                        tabId       = $tabId
                        selector    = $selector
                        status      = 'PASS'
                        errorDetail = ''
                        testedAt    = (Get-Date -Format 'o')
                    }

                    try {
                        $tab.Click()
                        Start-Sleep -Milliseconds 300

                        # Check that clicking activated something
                        $isActive = $false
                        try {
                            $cls = $tab.GetAttribute('class')
                            $aria = $tab.GetAttribute('aria-selected')
                            if ($cls -match 'active|selected' -or $aria -eq 'true') {
                                $isActive = $true
                            }
                        } catch { <# Intentional: fault-tolerant DOM probe #> }

                        if (-not $isActive) {
                            # Not necessarily a failure -- some tabs use different activation patterns
                            $testResult.status = 'WARN'
                            $testResult.errorDetail = 'Tab clicked but active state not detected'
                        }

                        # Check associated panel visibility
                        if ($tabId) {
                            try {
                                $panel = $Driver.FindElement([OpenQA.Selenium.By]::Id($tabId))
                                $displayed = $panel.Displayed
                                if (-not $displayed) {
                                    $testResult.status = 'FAIL'
                                    $testResult.errorDetail = "Panel '$tabId' not visible after tab click"
                                }
                            } catch {
                                # Panel may use different ID scheme -- not a hard failure
                            }
                        }
                    } catch {
                        $testResult.status = 'FAIL'
                        $testResult.errorDetail = "Tab click failed: $_"
                    }
                    $results.Add($testResult)
                }
            } catch { <# selector not applicable to this page #> }
        }
    } catch {
        $results.Add(@{ element = 'tabs-scan'; status = 'ERROR'; errorDetail = "Tab scan failed: $_"; testedAt = (Get-Date -Format 'o') })
    }
    return ,$results
}

# ========================== TEST: PAGE FORMS ==========================
function Test-PageForms {
    <#
    .SYNOPSIS Tests form elements accept input and trigger state changes.
    #>
    param(
        [Parameter(Mandatory)]$Driver,
        [string]$PageUrl
    )
    $results = New-Object System.Collections.Generic.List[object]
    try {
        # Test input fields
        $inputs = $Driver.FindElements([OpenQA.Selenium.By]::TagName('input'))
        foreach ($inp in $inputs) {
            $inputType = ''
            $inputId = ''
            try { $inputType = $inp.GetAttribute('type') } catch { <# Intentional: fault-tolerant DOM probe #> }
            try { $inputId = $inp.GetAttribute('id') } catch { <# Intentional: fault-tolerant DOM probe #> }
            if (-not $inputId) { try { $inputId = $inp.GetAttribute('name') } catch { <# Intentional: fault-tolerant DOM probe #> } }

            if ($inputType -in @('hidden', 'submit', 'button', 'image')) { continue }

            $testResult = @{
                element     = 'input'
                inputType   = $inputType
                inputId     = $inputId
                status      = 'PASS'
                errorDetail = ''
                testedAt    = (Get-Date -Format 'o')
            }

            try {
                $beforeVal = $inp.GetAttribute('value')
                if ($inputType -eq 'checkbox') {
                    $inp.Click()
                    $afterChecked = $inp.GetAttribute('checked')
                } elseif ($inputType -eq 'text' -or $inputType -eq '' -or $inputType -eq 'search' -or $inputType -eq 'url') {
                    $inp.Clear()
                    $inp.SendKeys('TestInput123')
                    $afterVal = $inp.GetAttribute('value')
                    if ($afterVal -ne 'TestInput123') {
                        $testResult.status = 'FAIL'
                        $testResult.errorDetail = "Input did not accept text. Got: $afterVal"
                    }
                }
            } catch {
                $testResult.status = 'FAIL'
                $testResult.errorDetail = "Input test failed: $_"
            }
            $results.Add($testResult)
        }

        # Test select elements
        $selects = $Driver.FindElements([OpenQA.Selenium.By]::TagName('select'))
        foreach ($sel in $selects) {
            $selId = ''
            try { $selId = $sel.GetAttribute('id') } catch { <# Intentional: fault-tolerant DOM probe #> }

            $testResult = @{
                element     = 'select'
                inputId     = $selId
                status      = 'PASS'
                errorDetail = ''
                testedAt    = (Get-Date -Format 'o')
            }

            try {
                $options = $sel.FindElements([OpenQA.Selenium.By]::TagName('option'))
                if ($options.Count -gt 1) {
                    $selObj = New-Object OpenQA.Selenium.Support.UI.SelectElement($sel)
                    $selObj.SelectByIndex(1)
                }
            } catch {
                $testResult.status = 'FAIL'
                $testResult.errorDetail = "Select test failed: $_"
            }
            $results.Add($testResult)
        }
    } catch {
        $results.Add(@{ element = 'forms-scan'; status = 'ERROR'; errorDetail = "Form scan failed: $_"; testedAt = (Get-Date -Format 'o') })
    }
    return ,$results
}

# ========================== TEST: TOOLTIPS ==========================
function Test-PageTooltips {
    <#
    .SYNOPSIS Tests tooltip presence and flags missing tooltips as 2DO.
    #>
    param(
        [Parameter(Mandatory)]$Driver,
        [string]$PageUrl
    )
    $results = New-Object System.Collections.Generic.List[object]
    try {
        # Check elements with title attribute
        $titled = $Driver.FindElements([OpenQA.Selenium.By]::CssSelector('[title]'))
        foreach ($el in $titled) {
            $title = ''
            try { $title = $el.GetAttribute('title') } catch { <# Intentional: fault-tolerant DOM probe #> }
            $tag = ''
            try { $tag = $el.TagName } catch { <# Intentional: fault-tolerant DOM probe #> }

            $testResult = @{
                element     = 'tooltip'
                tag         = $tag
                title       = $title
                status      = if ($title) { 'PASS' } else { '2DO' }
                errorDetail = if (-not $title) { 'Empty title attribute -- needs tooltip text' } else { '' }
                testedAt    = (Get-Date -Format 'o')
            }
            $results.Add($testResult)
        }

        # Check interactive elements WITHOUT tooltips (flag as 2DO)
        $interactive = $Driver.FindElements([OpenQA.Selenium.By]::CssSelector('button, a[href], input[type="submit"], [onclick]'))
        foreach ($el in $interactive) {
            $hasTitle = $false
            try { $hasTitle = [bool]$el.GetAttribute('title') } catch { <# Intentional: fault-tolerant DOM probe #> }
            $hasAria = $false
            try { $hasAria = [bool]$el.GetAttribute('aria-label') } catch { <# Intentional: fault-tolerant DOM probe #> }

            if (-not $hasTitle -and -not $hasAria) {
                $tag = ''
                try { $tag = $el.TagName } catch { <# Intentional: fault-tolerant DOM probe #> }
                $text = ''
                try { $text = $el.Text.Substring(0, [Math]::Min(50, $el.Text.Length)) } catch { <# Intentional: fault-tolerant DOM probe #> }

                $results.Add(@{
                    element     = 'missing-tooltip'
                    tag         = $tag
                    text        = $text
                    status      = '2DO'
                    errorDetail = 'Interactive element has no title or aria-label -- add tooltip'
                    testedAt    = (Get-Date -Format 'o')
                })
            }
        }
    } catch {
        $results.Add(@{ element = 'tooltip-scan'; status = 'ERROR'; errorDetail = "Tooltip scan failed: $_"; testedAt = (Get-Date -Format 'o') })
    }
    return ,$results
}

# ========================== TEST: INVOCATIONS (JS HANDLERS) ==========================
function Test-PageInvocations {
    <#
    .SYNOPSIS Tests onclick/onload/oninput handlers for JavaScript errors.
    #>
    param(
        [Parameter(Mandatory)]$Driver,
        [string]$PageUrl
    )
    $results = New-Object System.Collections.Generic.List[object]
    try {
        # Inject console error catcher
        try {
            $Driver.ExecuteScript(@"
window.__testErrors = [];
window.addEventListener('error', function(e) { window.__testErrors.push(e.message); });
window.onerror = function(msg) { window.__testErrors.push(msg); };
"@)
        } catch { <# JS execution not supported or page has CSP #> }

        # Find elements with event handlers
        $handlerSelectors = @('[onclick]', '[onchange]', '[oninput]', '[onsubmit]', '[onmouseover]')
        foreach ($selector in $handlerSelectors) {
            try {
                $els = $Driver.FindElements([OpenQA.Selenium.By]::CssSelector($selector))
                foreach ($el in $els) {
                    $handler = ''
                    $attr = $selector.Trim('[', ']')
                    try { $handler = $el.GetAttribute($attr) } catch { <# Intentional: fault-tolerant DOM probe #> }
                    $tag = ''
                    try { $tag = $el.TagName } catch { <# Intentional: fault-tolerant DOM probe #> }

                    $testResult = @{
                        element     = 'invocation'
                        tag         = $tag
                        handler     = $attr
                        handlerCode = if ($handler.Length -gt 80) { $handler.Substring(0, 80) + '...' } else { $handler }
                        status      = 'PASS'
                        errorDetail = ''
                        testedAt    = (Get-Date -Format 'o')
                    }

                    if ($attr -eq 'onclick') {
                        try {
                            $Driver.ExecuteScript('window.__testErrors = [];')
                            $el.Click()
                            Start-Sleep -Milliseconds 300
                            $errors = $Driver.ExecuteScript('return window.__testErrors;')
                            if ($errors -and $errors.Count -gt 0) {
                                $testResult.status = 'FAIL'
                                $testResult.errorDetail = "JS errors: $($errors -join '; ')"
                            }
                        } catch {
                            $testResult.status = 'FAIL'
                            $testResult.errorDetail = "Invocation failed: $_"
                        }
                    }
                    $results.Add($testResult)
                }
            } catch { <# selector not applicable #> }
        }

        # Check browser console for any accumulated errors
        try {
            $consoleErrors = $Driver.ExecuteScript('return window.__testErrors || [];')
            if ($consoleErrors -and $consoleErrors.Count -gt 0) {
                $results.Add(@{
                    element     = 'console-errors'
                    status      = 'FAIL'
                    errorDetail = "Console errors: $($consoleErrors -join '; ')"
                    testedAt    = (Get-Date -Format 'o')
                })
            }
        } catch { <# no JS support #> }
    } catch {
        $results.Add(@{ element = 'invocation-scan'; status = 'ERROR'; errorDetail = "Invocation scan failed: $_"; testedAt = (Get-Date -Format 'o') })
    }
    return ,$results
}

# ========================== TEST: RESOURCE LINKS (SYMBOLIC) ==========================
function Test-PageResources {
    <#
    .SYNOPSIS Tests <link>, <script src>, <img src>, <iframe src> for valid loading.
    #>
    param(
        [Parameter(Mandatory)]$Driver,
        [string]$PageUrl,
        [string]$WorkspacePath
    )
    $results = New-Object System.Collections.Generic.List[object]
    $resourceSelectors = @(
        @{ Tag = 'link';   Attr = 'href' },
        @{ Tag = 'script'; Attr = 'src' },
        @{ Tag = 'img';    Attr = 'src' },
        @{ Tag = 'iframe'; Attr = 'src' }
    )

    foreach ($resSel in $resourceSelectors) {
        try {
            $els = $Driver.FindElements([OpenQA.Selenium.By]::TagName($resSel.Tag))
            foreach ($el in $els) {
                $src = $null
                try { $src = $el.GetAttribute($resSel.Attr) } catch { continue }
                if (-not $src -or $src -eq '') { continue }

                $testResult = @{
                    element     = "resource-$($resSel.Tag)"
                    src         = $src
                    status      = 'PASS'
                    errorDetail = ''
                    testedAt    = (Get-Date -Format 'o')
                }

                try {
                    if ($src.StartsWith('http://') -or $src.StartsWith('https://')) {
                        $resp = Invoke-WebRequest -Uri $src -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                        if ($resp.StatusCode -ge 400) {
                            $testResult.status = 'FAIL'
                            $testResult.errorDetail = "HTTP $($resp.StatusCode)"
                        }
                    } elseif ($src.StartsWith('data:') -or $src.StartsWith('blob:')) {
                        # Inline data -- always pass
                    } elseif ($resSel.Tag -eq 'img') {
                        # Check if image actually loaded via JS
                        try {
                            $loaded = $Driver.ExecuteScript('return arguments[0].complete && arguments[0].naturalWidth > 0;', $el)
                            if (-not $loaded) {
                                $testResult.status = 'FAIL'
                                $testResult.errorDetail = 'Image failed to load (naturalWidth=0)'
                            }
                        } catch { <# JS not supported #> }
                    }
                } catch {
                    $testResult.status = 'FAIL'
                    $testResult.errorDetail = "Resource check failed: $_"
                }
                $results.Add($testResult)
            }
        } catch { <# tag not found #> }
    }
    return ,$results
}

# ========================== TEST: DATA STATE CHANGES (TIMED POLLING) ==========================
function Test-DataStateChanges {
    <#
    .SYNOPSIS Monitors data-loading fields for content state changes over time.
    .DESCRIPTION
        Phase 1: Query data containers every 20 seconds for 5 minutes.
        Phase 2: Reload tabs every 60 seconds for 5 minutes, re-query.
        Flags fields that never change as 2DO tasks.
    #>
    param(
        [Parameter(Mandatory)]$Driver,
        [string]$PageUrl,
        [hashtable]$PollingConfig
    )

    if (-not $PollingConfig) {
        $PollingConfig = @{
            phase1IntervalSeconds  = 20
            phase1DurationMinutes  = 5
            phase2IntervalSeconds  = 60
            phase2DurationMinutes  = 5
        }
    }

    $results = New-Object System.Collections.Generic.List[object]

    # Identify data containers by common ID patterns
    $containerScript = @"
var containers = [];
var allEls = document.querySelectorAll('[id]');
for (var i = 0; i < allEls.length; i++) {
    var id = allEls[i].id;
    if (id.match(/(Body|Count|Ts|Summary|Data|Status|Result|Content|Output|List|Table)$/i)) {
        containers.push({ id: id, tag: allEls[i].tagName, initialText: allEls[i].innerText.substring(0, 200) });
    }
}
return JSON.stringify(containers);
"@

    $containersJson = $null
    try {
        $containersJson = $Driver.ExecuteScript($containerScript)
    } catch {
        $results.Add(@{ element = 'data-state'; status = 'ERROR'; errorDetail = "Failed to identify data containers: $_"; testedAt = (Get-Date -Format 'o') })
        return ,$results
    }

    if (-not $containersJson -or $containersJson -eq '[]') {
        $results.Add(@{ element = 'data-state'; status = 'SKIP'; errorDetail = 'No data container elements found on page'; testedAt = (Get-Date -Format 'o') })
        return ,$results
    }

    $containers = $containersJson | ConvertFrom-Json
    $snapshots = @{}
    foreach ($c in $containers) {
        $snapshots[$c.id] = New-Object System.Collections.Generic.List[string]
        $snapshots[$c.id].Add($c.initialText)
    }

    # Phase 1: Poll every N seconds
    $phase1End = (Get-Date).AddMinutes($PollingConfig.phase1DurationMinutes)
    $pollCount = 0
    while ((Get-Date) -lt $phase1End) {
        Start-Sleep -Seconds $PollingConfig.phase1IntervalSeconds
        $pollCount++
        foreach ($c in $containers) {
            try {
                $currentText = $Driver.ExecuteScript("return document.getElementById('$($c.id)').innerText.substring(0, 200);")
                $snapshots[$c.id].Add($currentText)
            } catch { <# Intentional: fault-tolerant DOM probe #> }
        }
    }

    # Phase 2: Reload tabs + poll every N seconds
    $phase2End = (Get-Date).AddMinutes($PollingConfig.phase2DurationMinutes)
    while ((Get-Date) -lt $phase2End) {
        # Click all tabs to force reload
        try {
            $tabEls = $Driver.FindElements([OpenQA.Selenium.By]::CssSelector("[data-tab], .tab-btn, [role='tab']"))
            foreach ($tab in $tabEls) {
                try { $tab.Click(); Start-Sleep -Milliseconds 200 } catch { <# Intentional: fault-tolerant DOM probe #> }
            }
        } catch { <# Intentional: fault-tolerant DOM probe #> }

        Start-Sleep -Seconds $PollingConfig.phase2IntervalSeconds
        $pollCount++
        foreach ($c in $containers) {
            try {
                $currentText = $Driver.ExecuteScript("return document.getElementById('$($c.id)').innerText.substring(0, 200);")
                $snapshots[$c.id].Add($currentText)
            } catch { <# Intentional: fault-tolerant DOM probe #> }
        }
    }

    # Analyze: which containers changed state?
    foreach ($c in $containers) {
        $snaps = $snapshots[$c.id]
        $uniqueValues = @($snaps | Sort-Object -Unique)
        $changed = $uniqueValues.Count -gt 1

        $testResult = @{
            element        = 'data-state'
            containerId    = $c.id
            tag            = $c.tag
            pollCount      = $pollCount
            uniqueStates   = $uniqueValues.Count
            initialValue   = if ($snaps.Count -gt 0) { $snaps[0] } else { '' }
            finalValue     = if ($snaps.Count -gt 0) { $snaps[$snaps.Count - 1] } else { '' }
            status         = if ($changed) { 'PASS' } else { '2DO' }
            errorDetail    = if (-not $changed) { "Container '$($c.id)' never changed during $pollCount polls over 10 minutes" } else { '' }
            testedAt       = (Get-Date -Format 'o')
        }
        $results.Add($testResult)
    }

    return ,$results
}

# ========================== TEST: FULL PAGE SUITE ==========================
function Invoke-FullPageTest {
    <#
    .SYNOPSIS Runs all test categories on a single page.
    #>
    param(
        [Parameter(Mandatory)]$Driver,
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string]$BrowserName,
        [string]$WorkspacePath,
        [hashtable]$PollingConfig,
        [switch]$SkipDataState
    )

    $pageUrl = "file:///$($FilePath -replace '\\', '/')"
    $allResults = @{
        filePath    = $FilePath
        pageUrl     = $pageUrl
        browser     = $BrowserName
        testedAt    = (Get-Date -Format 'o')
        categories  = @{}
    }

    try {
        $Driver.Navigate().GoToUrl($pageUrl)
        Start-Sleep -Seconds 2
    } catch {
        $allResults.categories['pageLoad'] = @(@{
            element = 'page-load'; status = 'FAIL'; errorDetail = "Failed to load: $_"; testedAt = (Get-Date -Format 'o')
        })
        return $allResults
    }

    # Run each test category
    $allResults.categories['links']       = @(Test-PageLinks -Driver $Driver -PageUrl $pageUrl -WorkspacePath $WorkspacePath)
    $allResults.categories['tabs']        = @(Test-PageTabs -Driver $Driver -PageUrl $pageUrl)
    $allResults.categories['forms']       = @(Test-PageForms -Driver $Driver -PageUrl $pageUrl)
    $allResults.categories['tooltips']    = @(Test-PageTooltips -Driver $Driver -PageUrl $pageUrl)
    $allResults.categories['invocations'] = @(Test-PageInvocations -Driver $Driver -PageUrl $pageUrl)
    $allResults.categories['resources']   = @(Test-PageResources -Driver $Driver -PageUrl $pageUrl -WorkspacePath $WorkspacePath)

    if (-not $SkipDataState) {
        $allResults.categories['dataState'] = @(Test-DataStateChanges -Driver $Driver -PageUrl $pageUrl -PollingConfig $PollingConfig)
    }

    return $allResults
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





