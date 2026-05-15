# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-29)
# SupportsPS7.6: YES(As of: 2026-04-29)
# FileRole: Test
# Schema: ChangelogViewerTest/1.0
# Name Alias: Test-ViewerChangeTracker
# Agent-FirstCreator: GitHub-Copilot
# Agent-LastEditor: GitHub-Copilot
# Show-Objectives: 3-cycle headless verification of changelog viewer's incrementing change-tracker.
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ViewerPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'XHTML-ChangelogViewer.xhtml'),
    [int]$Cycles = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ViewerPath)) { throw "Viewer not found: $ViewerPath" }

$content = [System.IO.File]::ReadAllText($ViewerPath)
$scriptMatch = [regex]::Match($content, '(?s)<script[^>]*>(.*?)</script>')
if (-not $scriptMatch.Success) { throw 'No script block found.' }
$js = $scriptMatch.Groups[1].Value -replace '^\s*//<!\[CDATA\[', '' -replace '//\]\]>\s*$',''

# Write a small Node harness with localStorage + DOM stubs around the extracted JS,
# call loadChangelog three times, and emit JSON of {cycle, count, source, versions}.
$harnessPath = Join-Path $env:TEMP "viewer-tracker-harness-$([Guid]::NewGuid().ToString('N')).js"
$jsPath = Join-Path $env:TEMP "viewer-extracted-$([Guid]::NewGuid().ToString('N')).js"
[System.IO.File]::WriteAllText($jsPath, $js, [System.Text.UTF8Encoding]::new($false))
$jsPathEsc = $jsPath.Replace('\','\\')

$harness = @"
const fs = require('fs');
const _store = {};
global.localStorage = {
  getItem: (k) => Object.prototype.hasOwnProperty.call(_store,k) ? _store[k] : null,
  setItem: (k,v) => { _store[k] = String(v); },
  removeItem: (k) => { delete _store[k]; },
  clear: () => { for (const k of Object.keys(_store)) delete _store[k]; }
};
const _elements = {};
function makeEl(id){ return { id:id, innerHTML:'', textContent:'', value:'', style:{}, appendChild:function(c){return c;}, options:[] }; }
global.document = {
  getElementById: (id) => { if (!_elements[id]) _elements[id]=makeEl(id); return _elements[id]; },
  createElement: (tag) => makeEl(tag),
  querySelectorAll: () => [],
  addEventListener: () => {}
};
global.window = global; global.console = console;
// Stub the dropdown selection to CHANGELOG
_elements['logSelect'] = { id:'logSelect', value:'CHANGELOG' };
_elements['browseContent'] = makeEl('browseContent');
_elements['changeCounter'] = makeEl('changeCounter');
const captured = [];
const origLog = console.log;
console.log = function(){ const m = Array.prototype.slice.call(arguments).join(' '); captured.push(m); };
const code = fs.readFileSync('$jsPathEsc','utf8');
try { eval(code); } catch(e) { origLog('LOAD_FAIL', e.message); process.exit(2); }
const _loadFn = (typeof loadChangelog === 'function') ? loadChangelog : global.loadChangelog;
if (typeof _loadFn !== 'function') { origLog('NO_LOAD_FN'); process.exit(2); }
// Reset counter so cycle N maps to count N
localStorage.setItem('cv_change_count', '0');
captured.length = 0;
const results = [];
for (let i = 1; i <= ${Cycles}; i++) {
  try { _loadFn(); } catch(e) { origLog('CYCLE_FAIL '+i, e.message); }
  const counter = parseInt(localStorage.getItem('cv_change_count') || '0', 10);
  const lastLog = captured[captured.length-1] || '';
  results.push({cycle:i, count:counter, lastConsole:lastLog});
}
console.log = origLog;
console.log(JSON.stringify(results, null, 2));
"@
[System.IO.File]::WriteAllText($harnessPath, $harness, [System.Text.UTF8Encoding]::new($false))

Write-Host "Running $Cycles-cycle headless tracker test..." -ForegroundColor Cyan
$out = & node $harnessPath 2>&1
$exitCode = $LASTEXITCODE
Remove-Item $harnessPath -Force -ErrorAction SilentlyContinue
Remove-Item $jsPath -Force -ErrorAction SilentlyContinue

if ($exitCode -ne 0) {
    Write-Host "FAIL (exit=$exitCode):" -ForegroundColor Red
    $out | ForEach-Object { Write-Host $_ }
    exit $exitCode
}

# Parse trailing JSON (last [...] block in output) — find the LAST array that begins with '[\n  {'
$text = ($out -join "`n")
$rxArr = [regex]::Matches($text, '(?s)\[\s*\{.*\}\s*\]')
if ($rxArr.Count -eq 0) {
    Write-Host "FAIL: no JSON in output" -ForegroundColor Red
    Write-Host $text
    exit 3
}
$jsonText = $rxArr[$rxArr.Count - 1].Value
$results = $jsonText | ConvertFrom-Json

Write-Host "" 
Write-Host "=== Change-Tracker 3-Cycle Test Results ===" -ForegroundColor Green
foreach ($r in $results) {
    $status = if ($r.count -eq $r.cycle) { 'PASS' } else { 'FAIL' }
    $color = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ("  Cycle {0}: count={1}  [{2}]" -f $r.cycle, $r.count, $status) -ForegroundColor $color
    Write-Host ("    console: {0}" -f $r.lastConsole) -ForegroundColor DarkGray
}

$allPass = @($results | Where-Object { $_.count -ne $_.cycle }).Count -eq 0
if ($allPass) {
    Write-Host "`nALL CYCLES PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`nFAILED: counter did not increment as expected" -ForegroundColor Red
    exit 1
}

