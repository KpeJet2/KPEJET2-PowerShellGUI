# VersionTag: 2606.B5.V51.4
# Qik-GU-ide Cheat Sheet (Single Page)

Purpose: Fast copy-paste snippets for nine iterative upgrades matching the recent metric integrity work.

## Iteration 1: Add Metric Note Placeholders

Use in each tab that needs parity status.

```html
<div class="metric-note" id="td-metric-note">Metric validation pending: loading dynamic todo bundle.</div>
<div class="metric-note" id="bg-metric-note">Metric validation pending: loading dynamic bug bundle.</div>
<div class="metric-note" id="ft-metric-note">Metric validation pending: loading dynamic feature bundle.</div>
```

## Iteration 2: Compute Expected Pipeline Counts

JS helper to centralize expected counts by item type.

```javascript
function getPipelineExpectedForType(type) {
  if (!pipeData) return null;
  if (type === 'bug') {
    return Number((pipeData.bugs || []).length) + Number((pipeData.bugs2FIX || []).length);
  }
  if (type === 'feature') {
    return Number((pipeData.featureRequests || []).length);
  }
  if (type === 'todo') {
    return Number((pipeData.todos || []).length) + Number((pipeData.items2ADD || []).length);
  }
  return null;
}
```

## Iteration 3: Render Dynamic Parity Notes

Inject pass/warn parity directly into tab notes.

```javascript
var noteEl = document.getElementById(pfx + '-metric-note');
if (noteEl) {
  var expected = getPipelineExpectedForType(type);
  if (expected === null) {
    noteEl.innerHTML = '<strong>Metric Validation:</strong> dynamic total=' + total + '. Pipeline source is not loaded yet for parity check.';
  } else {
    var delta = total - expected;
    var color = (delta === 0) ? '#4ec9b0' : '#f0a500';
    noteEl.innerHTML = '<strong>Metric Validation:</strong> dynamic total=' + total + ', pipeline expected=' + expected + ', delta=<span style="color:' + color + ';">' + delta + '</span>.';
  }
}
```

## Iteration 4: Refresh Dynamic Tabs After Pipeline Load

Ensure note values update once source data is loaded.

```javascript
if (dynLoaded) {
  renderDynamic('todo');
  renderDynamic('bug');
  renderDynamic('feature');
}
```

## Iteration 5: Parse Delta From Existing Notes

Reusable parser for a unified integrity panel.

```javascript
function metricDeltaFromNote(noteId) {
  var el = document.getElementById(noteId);
  if (!el) return null;
  var txt = String(el.textContent || '').replace(/\s+/g, ' ');
  var m = txt.match(/delta\s*=\s*([+-]?\d+)/i);
  if (!m) return null;
  return Number(m[1]);
}
```

## Iteration 6: Add Dashboard Integrity Panel Markup

Single section summarizing all tab parity outcomes.

```html
<div class="dd-section-title">Tab Metric Integrity</div>
<div class="dd-grid" id="dd-integrity">
  <div class="empty-msg">Loading integrity checks...</div>
</div>
```

## Iteration 7: Render Integrity Summary Cards

Build pass/warn/pending cards from tab note deltas.

```javascript
function renderMetricIntegrity(totalItems) {
  var checks = [
    { label:'Pipeline', delta:pipelineDelta, src:'auto-pipeline' },
    { label:'Scripts', delta:metricDeltaFromNote('ws-metric-note'), src:'workspace-scripts' },
    { label:'Agents', delta:metricDeltaFromNote('ag-metric-note'), src:'agents' },
    { label:'Scan Tools', delta:metricDeltaFromNote('sc-metric-note'), src:'scan-tools' },
    { label:'Items2Do', delta:metricDeltaFromNote('td-metric-note'), src:'todo/_bundle.js' },
    { label:'Bugs2FIX', delta:metricDeltaFromNote('bg-metric-note'), src:'todo/_bundle.js' },
    { label:'Feature2ADD', delta:metricDeltaFromNote('ft-metric-note'), src:'todo/_bundle.js' }
  ];
  // Render cards and totals: pass / warn / pending
}
```

## Iteration 8: Startup Validation Hook

Run validation early so users see trust state immediately.

```javascript
try { loadScriptVersions(); } catch (e) { /* non-fatal */ }
try { renderScanToolsValidation(); } catch (e) { /* non-fatal */ }
```

## Iteration 9: CI Harness Gate for Metric Drift

Use this in CI or local smoke runs to enforce no drift.

```powershell
pwsh -NoProfile -File .\tests\Invoke-PipelineMetricHarness.ps1
if ($LASTEXITCODE -ne 0) {
  throw "Pipeline metric harness failed."
}
```

## Quick CLI Usage

```bat
@echo off
set ROOT=%~dp0..
start "" "%ROOT%\docs\Qik-GU-ide-CheatSheet.xhtml"
```

## Verification Checklist

- Dynamic tabs show note with delta.
- Dashboard integrity panel shows pass/warn/pending.
- Startup load triggers script + scan metric validation.
- Harness returns exit code 0 for clean parity.


