# VersionTag: 2605.B2.V31.7
$path = 'C:\PowerShellGUI\~REPORTS\SIN-Scoreboard.xhtml'
$lines = [System.IO.File]::ReadAllLines($path)
# Keep through line 869 (index 868)
$head = $lines[0..868]

$tail = @'
        <!-- ============== SECTION 9: TOOLS REGISTRY (rebuilt v28.0) ============== -->
        </details>
        <details class="sin-section" id="sec9" open="open"><summary>9. Tools Registry &amp; Backlog (18 entries)</summary>
        <div class="section-box">
            <p style="color: var(--muted); font-size: 0.85em; margin-bottom: 10px;">All 6 originally-missing tools are now BUILT (v2604.B3.V28.0). Backlog of 12 additional candidates listed below.</p>
            <h3>Built tools (Iteration 1 - 2026-04-30)</h3>
            <table>
                <thead><tr><th>Tool</th><th>Module</th><th>Purpose</th><th>Priority</th><th>Status</th></tr></thead>
                <tbody>
                    <tr><td><code>Invoke-DependencyGraph</code></td><td>PwShGUI-DependencyMap</td><td>Auto-generate module dependency DAG (Mermaid + JSON)</td><td class="sev-MEDIUM">MEDIUM</td><td><span class="tag tag-built">&#x2713; Built</span></td></tr>
                    <tr><td><code>Export-TestCoverage</code></td><td>PwShGUI-CoverageReport</td><td>Per-module Pester coverage % (HTML + JSON + JaCoCo XML)</td><td class="sev-MEDIUM">MEDIUM</td><td><span class="tag tag-built">&#x2713; Built</span></td></tr>
                    <tr><td><code>New-SINFromScan</code></td><td>PwShGUI-SinFromScan</td><td>Materialise SIN JSON files from scan findings (idempotent)</td><td class="sev-MEDIUM">MEDIUM</td><td><span class="tag tag-built">&#x2713; Built</span></td></tr>
                    <tr><td><code>Invoke-AutoRemediate</code></td><td>PwShGUI-AutoRemediate</td><td>Batch-fix P002/P017/P018/P019 with -WhatIf and BOM preservation</td><td class="sev-HIGH">HIGH</td><td><span class="tag tag-built">&#x2713; Built</span></td></tr>
                    <tr><td><code>Invoke-BreakingChangeDetector</code></td><td>PwShGUI-BreakingChange</td><td>AST-diff exported function signatures across snapshots</td><td class="sev-HIGH">HIGH</td><td><span class="tag tag-built">&#x2713; Built</span></td></tr>
                    <tr><td><code>Invoke-PSScriptAnalyzerScan</code></td><td>PwShGUI-PSScriptAnalyzerScan</td><td>PSSA wrapper with normalised JSON output (soft-fails if module missing)</td><td class="sev-LOW">LOW</td><td><span class="tag tag-built">&#x2713; Built</span></td></tr>
                </tbody>
            </table>

            <h3>Backlog candidates (12 - to evaluate / build next)</h3>
            <table>
                <thead><tr><th>Tool</th><th>Purpose</th><th>Priority</th><th>Integration Point</th><th>Status</th></tr></thead>
                <tbody>
                    <tr><td><code>Invoke-SinDriftScan</code></td><td>Nightly re-scan; flag any P-pattern that re-emerged after RESOLVED status</td><td class="sev-HIGH">HIGH</td><td>CronAiAthon-Scheduler</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>Get-SinHeatmap</code></td><td>Per-file SIN density heatmap (SVG)</td><td class="sev-MEDIUM">MEDIUM</td><td>Scoreboard Sec 5</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>Test-XhtmlReports</code></td><td>Pester suite that XML-parses every ~REPORTS/*.xhtml and asserts no P032 / P033 violations</td><td class="sev-HIGH">HIGH</td><td>tests/</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>Invoke-SecretScan</code></td><td>Regex sweep for accidental keys/tokens (extends P001)</td><td class="sev-HIGH">HIGH</td><td>Invoke-SyntaxGuard</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>Convert-LegacyEncoding</code></td><td>Detect &amp; repair P006 (no-BOM) and P023 (double-encoded UTF-8) in bulk</td><td class="sev-MEDIUM">MEDIUM</td><td>Repair toolkit</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>Invoke-EventLogReplay</code></td><td>Replay sovereign-kernel/events/*.json into adapter for regression diff</td><td class="sev-LOW">LOW</td><td>EventLogAdapter</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>Get-AgentScorecard</code></td><td>Per-agent KPI export feeding Scoreboard Sec 1</td><td class="sev-MEDIUM">MEDIUM</td><td>Scoreboard data layer</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>Invoke-PesterParallel</code></td><td>Parallel Pester runner with per-module isolation (PS7 only)</td><td class="sev-MEDIUM">MEDIUM</td><td>Run-AllTests</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>Compare-ModuleManifest</code></td><td>Diff .psd1 versions to surface silent metadata drift</td><td class="sev-LOW">LOW</td><td>VersionManager</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>Invoke-CheckpointPrune</code></td><td>Retention policy for checkpoints/ (currently unbounded)</td><td class="sev-MEDIUM">MEDIUM</td><td>Maintenance</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>Get-LaunchTimingProfile</code></td><td>Aggregate Launch-GUI*.bat start-up timings into trend chart</td><td class="sev-LOW">LOW</td><td>GUI-PERFORMANCE-GUIDE</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                    <tr><td><code>New-SinFixBranch</code></td><td>Auto-create checkpoint &amp; mark SIN status when starting a fix</td><td class="sev-LOW">LOW</td><td>SINGovernance</td><td><span class="tag tag-gap">&#x2717; Backlog</span></td></tr>
                </tbody>
            </table>

            <h3>Newly-discovered SIN patterns (registered this session)</h3>
            <table>
                <thead><tr><th>Pattern ID</th><th>Title</th><th>Severity</th><th>Status</th></tr></thead>
                <tbody>
                    <tr><td><code>P034</code></td><td>Assignment to PowerShell automatic variable ($matches, $args, $input...)</td><td class="sev-MEDIUM">MEDIUM</td><td><span class="tag tag-built">&#x2713; Registered</span></td></tr>
                    <tr><td><code>P035</code></td><td>Nested block-comment closer inside &lt;# .SYNOPSIS #&gt; help block</td><td class="sev-HIGH">HIGH</td><td><span class="tag tag-built">&#x2713; Registered</span></td></tr>
                    <tr><td><code>P036</code></td><td>Multi-line PowerShell pasted via 'powershell -Command' loses newlines</td><td class="sev-LOW">LOW</td><td><span class="tag tag-built">&#x2713; Registered</span></td></tr>
                    <tr><td><code>P037</code></td><td>@($dict.Keys).Count inside [PSCustomObject]@{} literal throws 'Argument types do not match'</td><td class="sev-MEDIUM">MEDIUM</td><td><span class="tag tag-built">&#x2713; Registered</span></td></tr>
                </tbody>
            </table>
        </div>
        </details>

        <div class="meta" style="margin-top: 24px; text-align: center; border-top: 1px solid var(--border); padding-top: 12px;">
            SIN Scoreboard v2604.B3.V28.0 | Auto-generated from sin_registry/*.json | 37 SINs tracked | 6 tools built | 12 backlog
        </div>
    </div>
    <!-- ============== Drilldown pane (V28.0) ============== -->
    <aside id="drillPane" aria-hidden="true">
        <header><h3 id="drillTitle">Drilldown</h3><button type="button" class="close" id="drillClose" aria-label="Close">&#x2715;</button></header>
        <div class="body" id="drillBody">Select a stat-card or underlined value to view details.</div>
    </aside>
<!-- EvLV-AUTOMOUNT V31.0 (PwShGUI-EventLogAdapter contract: docs/EVENT-LOG-STANDARD.md) -->
<link rel="stylesheet" href="../styles/eventlog-view.css"/>
<script src="../scripts/XHTML-Checker/_assets/eventlog-view.js"></script>
<div class="evlv-mount" data-scope="sin" data-title="SIN Events" data-tail="500"></div>
<script><![CDATA[
(function(){
  var pane=document.getElementById('drillPane');
  var title=document.getElementById('drillTitle');
  var body=document.getElementById('drillBody');
  function open(t,html){title.textContent=t;body.innerHTML=html;pane.classList.add('open');pane.setAttribute('aria-hidden','false');}
  function close(){pane.classList.remove('open');pane.setAttribute('aria-hidden','true');}
  document.getElementById('drillClose').addEventListener('click',close);
  document.addEventListener('keydown',function(e){if(e.key==='Escape')close();});
  // Stat-card click handler
  document.querySelectorAll('.stat-card').forEach(function(c){
    c.addEventListener('click',function(){
      var label=c.querySelector('.label');var val=c.querySelector('.value');
      var t=label?label.textContent:'Metric';
      var v=val?val.textContent:'';
      open(t,'<p><b>Value:</b> '+v+'</p><p style="color:var(--muted);font-size:0.85em">Per-metric drilldown manifests live in <code>~REPORTS\\scoreboard-data\\</code> (Phase 2 generator). Until then this pane shows the headline value plus the section context.</p><p>Section: '+(c.closest('details')?c.closest('details').querySelector('summary').textContent:'')+'</p>');
    });
  });
  // Expand/Collapse all
  function setAll(open){document.querySelectorAll('details.sin-section').forEach(function(d){d.open=open;});}
  document.getElementById('btnExpandAll').addEventListener('click',function(){setAll(true);});
  document.getElementById('btnCollapseAll').addEventListener('click',function(){setAll(false);});
  // Persist open/closed state
  try{
    var KEY='sin-scoreboard.openSections';
    var saved=JSON.parse(localStorage.getItem(KEY)||'null');
    if(saved){document.querySelectorAll('details.sin-section').forEach(function(d){if(saved.hasOwnProperty(d.id))d.open=!!saved[d.id];});}
    document.querySelectorAll('details.sin-section').forEach(function(d){
      d.addEventListener('toggle',function(){
        try{var s={};document.querySelectorAll('details.sin-section').forEach(function(x){s[x.id]=x.open;});localStorage.setItem(KEY,JSON.stringify(s));}catch(e){}
      });
    });
  }catch(e){/* localStorage may be unavailable under file:// (P035 anticipation) */}
  // EvLV mount
  if(window.EvLV){window.EvLV.mountAll();}
})();
]]></script>
</body>
</html>
'@

$final = New-Object System.Collections.Generic.List[string]
$final.AddRange([string[]]$head)
$final.Add($tail)
[System.IO.File]::WriteAllText($path, ($final -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
"Written. Re-validating..."
$xml = New-Object System.Xml.XmlDocument
try { $xml.Load($path); 'XHTML-OK' } catch [System.Xml.XmlException] { "XmlException line {0} col {1}: {2}" -f $_.Exception.LineNumber, $_.Exception.LinePosition, $_.Exception.Message }

