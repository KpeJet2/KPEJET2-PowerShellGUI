/* VersionTag: 2605.B5.V46.0 */
/* dep-vis-client.js
   Client-side logic for the Dependency Visualiser:
     - WebSocket connection with auto-reconnect (falls back to fetch polling)
     - Status bar freshness pills (green/yellow/red/grey)
     - Scan Control tab population
     - Collapsible data log panel
     - Scan trigger functions
*/
(function(global) {
  'use strict';

  var ENGINE_BASE   = 'http://127.0.0.1:8042';
  var WS_URL        = 'ws://127.0.0.1:8042/ws';
  var POLL_INTERVAL = 5000;
  var RECONNECT_MS  = 4000;
  var PHASE_IDS     = ['folders','modules','scripts','configs','urls_ips','dns_resolution'];
  var PHASE_LABELS  = { folders:'Folders', modules:'Modules', scripts:'Scripts', configs:'Configs', urls_ips:'URLs/IPs', dns_resolution:'DNS' };

  var _ws          = null;
  var _pollTimer   = null;
  var _reconnTimer = null;
  var _csrfToken   = '';
  var _online      = false;
  var _logEntries  = [];
  var _maxLog      = 120;

  /* ── Utility ──────────────────────────────────────────────────────────── */
  function fmt(t) { return t < 10 ? '0' + t : '' + t; }

  function nowStr() {
    var d = new Date();
    return fmt(d.getHours()) + ':' + fmt(d.getMinutes()) + ':' + fmt(d.getSeconds());
  }

  function ageMinutes(isoStr) {
    if (!isoStr) return 99999;
    var d = new Date(isoStr);
    if (isNaN(d.getTime())) return 99999;
    return Math.floor((Date.now() - d.getTime()) / 60000);
  }

  function ageColour(mins) {
    if (mins === 99999) return 'grey';
    if (mins <= 60)     return 'green';
    if (mins <= 1440)   return 'yellow';
    return 'red';
  }

  function ageLabel(mins) {
    if (mins === 99999) return 'no data';
    if (mins < 1)       return 'just now';
    if (mins < 60)      return mins + 'm ago';
    var h = Math.floor(mins / 60);
    if (h < 24)         return h + 'h ago';
    return Math.floor(h / 24) + 'd ago';
  }

  /* ── Data Log ─────────────────────────────────────────────────────────── */
  function addLog(msg, cls) {
    _logEntries.push({ t: nowStr(), msg: msg, cls: cls || '' });
    if (_logEntries.length > _maxLog) _logEntries.shift();
    renderLog();
  }

  function renderLog() {
    var body = document.getElementById('logPanelBody');
    if (!body) return;
    var html = '';
    for (var i = _logEntries.length - 1; i >= 0; i--) {
      var e = _logEntries[i];
      html += '<div class="log-entry"><span class="log-time">' + e.t + '</span>' +
              '<span class="log-msg ' + e.cls + '">' + e.msg.replace(/</g,'&lt;').replace(/>/g,'&gt;') + '</span></div>';
    }
    body.innerHTML = html;
  }

  global.clearLog = function(ev) {
    if (ev) ev.stopPropagation();
    _logEntries = [];
    renderLog();
  };

  global.toggleLogPanel = function() {
    var panel = document.getElementById('logPanel');
    if (!panel) return;
    if (panel.classList.contains('collapsed')) {
      panel.classList.remove('collapsed');
      panel.style.height = '204px';
    } else {
      panel.classList.add('collapsed');
      panel.style.height = '';
    }
  };

  /* ── Status Bar ───────────────────────────────────────────────────────── */
  function updateStatusBar(phasesData, fromStatic) {
    PHASE_IDS.forEach(function(pid) {
      var pill = document.getElementById('sbp-' + pid);
      if (!pill) return;
      var dot  = pill.querySelector('.sb-dot');
      var age  = pill.querySelector('.sb-age');
      if (!dot || !age) return;

      if (fromStatic) {
        /*
         * Static mode: all phases share the same generated timestamp from rawdata.
         * We derive age from the document's embedded data.
         */
        dot.className = 'sb-dot ' + ageColour(fromStatic);
        age.textContent = ageLabel(fromStatic);
      } else {
        var ts   = null;
        var st   = null;
        if (phasesData && phasesData[pid]) {
          ts = phasesData[pid].timestamp;
          st = phasesData[pid].status;
        }
        var mins = ageMinutes(ts);
        var col  = (st === 'error') ? 'red' : ageColour(mins);
        dot.className = 'sb-dot ' + col;
        age.textContent = (st === 'error') ? 'error' : ageLabel(mins);
      }
    });
  }

  function setEngineOnline(online, label) {
    _online = online;
    var dot = document.getElementById('sbEngineDot');
    var lbl = document.getElementById('sbEngineLabel');
    if (dot) dot.className = 'sb-engine-dot' + (online ? ' online' : '');
    if (lbl) lbl.textContent = label || (online ? 'LocalEngine: online' : 'LocalEngine: offline');
  }

  /* ── Scan Control tab ─────────────────────────────────────────────────── */
  function buildScanControlCards(checkpoint) {
    var body = document.getElementById('sc2Body');
    if (!body) return;
    if (!checkpoint || !checkpoint.phases) {
      body.innerHTML = '<div class="sc2-empty">No checkpoint data. Run a scan to begin.</div>';
      return;
    }
    var html = '';
    PHASE_IDS.forEach(function(pid) {
      var p   = checkpoint.phases[pid] || {};
      var st  = p.status || 'pending';
      var ts  = p.timestamp;
      var err = p.error;
      var cnt = p.itemCount || 0;
      var dur = p.durationMs || 0;
      var mins = ageMinutes(ts);
      var col  = (st === 'error') ? 'red' : (st === 'done' ? ageColour(mins) : 'grey');

      html += '<div class="phase-card">';
      html += '<h4><span class="sb-dot ' + col + '"></span>' + PHASE_LABELS[pid] +
              '<span class="phase-age">' + (ts ? ageLabel(mins) : '—') + '</span></h4>';
      html += '<div class="phase-meta">';
      html += '<b>Status:</b> ' + st + '<br/>';
      if (cnt > 0)  html += '<b>Items:</b> '    + cnt + '<br/>';
      if (dur > 0)  html += '<b>Duration:</b> ' + (dur/1000).toFixed(1) + 's<br/>';
      if (err)      html += '<b>Error:</b> <span style="color:#f87171">' + String(err).replace(/</g,'&lt;').substring(0,120) + '</span><br/>';
      html += '</div>';
      html += '<div class="phase-bar"><div class="phase-bar-fill" style="width:' + (st==='done'?'100':'0') + '%;background:var(--' + col + '-bar,#334)"></div></div>';
      html += '</div>';
    });
    body.innerHTML = html;
  }

  function buildCrashTable(crashes) {
    var body = document.getElementById('sc2Body');
    if (!body) return;
    if (!crashes || crashes.length === 0) {
      body.innerHTML += '<div class="crash-section"><h4 style="color:#e94560;font-size:11px">No crash dumps found.</h4></div>';
      return;
    }
    var html = '<div class="crash-section"><table class="crash-table"><thead><tr>' +
               '<th>Time</th><th>Phase</th><th>Message</th><th>Occ.</th></tr></thead><tbody>';
    for (var i = 0; i < crashes.length; i++) {
      var c = crashes[i];
      var rep = c.isRepeating ? '<span class="rep-badge">REP</span>' : '';
      html += '<tr><td>' + (c.timestamp || '?') + '</td><td>' +
              String(c.phase||'').replace(/</g,'&lt;') + '</td><td>' +
              String(c.errorMessage||'').replace(/</g,'&lt;').substring(0,100) + '</td><td>' +
              (c.occurrences || 1) + rep + '</td></tr>';
    }
    html += '</tbody></table></div>';
    body.innerHTML += html;
  }

  /* ── Scan trigger ─────────────────────────────────────────────────────── */
  global.triggerScan = function(mode) {
    if (!_online) {
      addLog('LocalEngine offline — cannot trigger scan', 'warn');
      return;
    }
    var btn = document.getElementById(mode === 'full' ? 'btnFullScan' : 'btnIncScan');
    if (btn) btn.disabled = true;
    var msg = document.getElementById('scanStatusMsg');
    if (msg) msg.textContent = 'Starting ' + mode + ' scan...';
    addLog('Triggering ' + mode + ' scan via LocalEngine', '');
    var bar = document.getElementById('scanProgressBar');
    if (bar) bar.style.width = '5%';

    var xhr = new XMLHttpRequest();
    xhr.open('POST', ENGINE_BASE + '/api/scan/' + mode, true);
    xhr.setRequestHeader('X-CSRF-Token', _csrfToken);
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== 4) return;
      if (btn) btn.disabled = false;
      if (xhr.status === 202) {
        if (msg) msg.textContent = 'Scan started (' + mode + ')';
        addLog('Scan started: ' + mode, 'ok');
      } else {
        if (msg) msg.textContent = 'Scan trigger failed (' + xhr.status + ')';
        addLog('Scan trigger failed: ' + xhr.status + ' ' + xhr.responseText, 'err');
      }
    };
    xhr.send('{}');
  };

  /* ── Fetch scan status (polling fallback) ──────────────────────────────── */
  function fetchStatus() {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', ENGINE_BASE + '/api/scan/status', true);
    xhr.timeout = 3000;
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== 4) return;
      if (xhr.status === 200) {
        try {
          var data = JSON.parse(xhr.responseText);
          onStatusData(data);
        } catch(e) {
          addLog('Status parse error: ' + e, 'err');
        }
      }
    };
    xhr.onerror = function() { setEngineOnline(false, 'LocalEngine: offline'); };
    xhr.ontimeout = function() { setEngineOnline(false, 'LocalEngine: timeout'); };
    try { xhr.send(); } catch(e) { setEngineOnline(false, 'LocalEngine: offline'); }
  }

  function fetchCrashes() {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', ENGINE_BASE + '/api/scan/crashes', true);
    xhr.timeout = 3000;
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== 4 || xhr.status !== 200) return;
      try {
        var data = JSON.parse(xhr.responseText);
        buildCrashTable(data.crashes);
      } catch(e) { /* non-fatal */ }
    };
    try { xhr.send(); } catch(e) { /* non-fatal */ }
  }

  function onStatusData(data) {
    setEngineOnline(true, 'LocalEngine: online');
    var cp = data.checkpoint;
    if (cp && cp.phases) {
      updateStatusBar(cp.phases, null);
      buildScanControlCards(cp);
    }
    var pg = data.progress;
    if (pg) {
      var bar = document.getElementById('scanProgressBar');
      var msg = document.getElementById('scanStatusMsg');
      if (pg.status === 'running' && pg.totalPhases > 0) {
        var pct = Math.floor((pg.completedPhases / pg.totalPhases) * 100);
        if (bar) bar.style.width = pct + '%';
        if (msg) msg.textContent = 'Scanning... ' + pg.completedPhases + '/' + pg.totalPhases + ' phases';
      } else if (pg.status === 'running' && typeof pg.progress === 'number') {
        if (bar) bar.style.width = Math.max(0, Math.min(100, pg.progress)) + '%';
        if (msg) msg.textContent = pg.statusMessage || ('Scanning... ' + pg.progress + '%');
      } else if (pg.status === 'done') {
        if (bar) bar.style.width = '100%';
        if (msg) msg.textContent = 'Scan complete';
        fetchCrashes();
      } else if (pg.status === 'partial') {
        if (bar) bar.style.width = '100%';
        if (msg) msg.textContent = 'Scan complete with warnings';
        addLog('Scan completed with warnings: ' + (pg.error || 'partial result'), 'warn');
        fetchCrashes();
      } else if (pg.status === 'error') {
        if (bar) bar.style.width = '0';
        if (msg) msg.textContent = 'Scan error: ' + (pg.error || '');
      }
    }
  }

  /* ── WebSocket ─────────────────────────────────────────────────────────── */
  var _wsRetries = 0;

  function connectWs() {
    if (_ws && (_ws.readyState === 0 || _ws.readyState === 1)) return;
    try {
      _ws = new WebSocket(WS_URL);

      _ws.onopen = function() {
        _wsRetries = 0;
        setEngineOnline(true, 'LocalEngine: online (ws)');
        addLog('WebSocket connected', 'ok');
        if (_pollTimer) { clearInterval(_pollTimer); _pollTimer = null; }
        fetchStatus();
      };

      _ws.onmessage = function(ev) {
        try {
          var msg = JSON.parse(ev.data);
          if (msg.event === 'connected') {
            _csrfToken = msg.csrfToken || '';
          } else if (msg.event === 'scan_progress' && msg.data) {
            onStatusData({ progress: msg.data });
          } else if (msg.event === 'scan_started') {
            addLog('Scan started by server: ' + msg.mode, 'ok');
            var bar = document.getElementById('scanProgressBar');
            if (bar) bar.style.width = '5%';
          }
        } catch(e) { /* non-fatal */ }
      };

      _ws.onerror = function() {
        addLog('WebSocket error — falling back to polling', 'warn');
        startPolling();
      };

      _ws.onclose = function() {
        setEngineOnline(false, 'LocalEngine: disconnected');
        addLog('WebSocket closed', 'warn');
        startPolling();
        _reconnTimer = setTimeout(function() { connectWs(); }, RECONNECT_MS * Math.min(++_wsRetries, 5));
      };
    } catch(e) {
      addLog('WebSocket init error: ' + e, 'err');
      startPolling();
    }
  }

  function startPolling() {
    if (_pollTimer) return;
    _pollTimer = setInterval(function() {
      fetchStatus();
    }, POLL_INTERVAL);
    // Also fetch CSRF token via REST
    var xhr = new XMLHttpRequest();
    xhr.open('GET', ENGINE_BASE + '/api/csrf-token', true);
    xhr.timeout = 2000;
    xhr.onreadystatechange = function() {
      if (xhr.readyState === 4 && xhr.status === 200) {
        try { _csrfToken = JSON.parse(xhr.responseText).csrfToken || ''; } catch(e) {}
      }
    };
    try { xhr.send(); } catch(e) {}
  }

  /* ── Static mode init (no local engine) ──────────────────────────────── */
  function initStaticMode() {
    var rawEl = document.getElementById('rawdata');
    if (!rawEl) return;
    try {
      var data = JSON.parse(rawEl.textContent || rawEl.innerText || '{}');
      if (data.generated) {
        var mins = ageMinutes(data.generated);
        updateStatusBar(null, mins);
        addLog('Static mode: data generated ' + ageLabel(mins) + ' (start LocalWebEngine for live status)', '');
        addLog('Scan data: ' + (data.summary ? JSON.stringify(data.summary) : 'present'), 'ok');
      }
    } catch(e) { /* non-fatal */ }
    setEngineOnline(false, 'LocalEngine: offline');
    // Show static scan control message
    var sc2 = document.getElementById('sc2Body');
    if (sc2) {
      sc2.innerHTML = '<div style="grid-column:1/-1;color:#2a5080;font-size:11px;text-align:center;padding:20px">' +
        'Start <b style="color:#4a9eff">LocalWebEngine</b> for live scan control.<br/>' +
        'Run: <code style="color:#7dd3fc">scripts\\Start-LocalWebEngine.ps1</code><br/><br/>' +
        'Static checkpoint data shown below.</div>';
    }
  }

  /* ── Boot ─────────────────────────────────────────────────────────────── */
  function boot() {
    addLog('dep-vis-client init', '');
    // Always init static mode first for immediate visual feedback
    initStaticMode();

    // Try to reach the local engine
    var testXhr = new XMLHttpRequest();
    testXhr.open('GET', ENGINE_BASE + '/api/csrf-token', true);
    testXhr.timeout = 1500;
    testXhr.onreadystatechange = function() {
      if (testXhr.readyState !== 4) return;
      if (testXhr.status === 200) {
        try { _csrfToken = JSON.parse(testXhr.responseText).csrfToken || ''; } catch(e) {}
        connectWs();
        fetchStatus();
        fetchCrashes();
      } else {
        addLog('LocalEngine not reachable — static mode only', 'warn');
      }
    };
    testXhr.onerror = function() {
      addLog('LocalEngine not reachable — static mode only', 'warn');
    };
    testXhr.ontimeout = function() {
      addLog('LocalEngine timeout — static mode only', 'warn');
    };
    try { testXhr.send(); } catch(e) {
      addLog('LocalEngine offline — static mode', 'warn');
    }
  }

  /* Export scan trigger for inline onclick usage */
  global.depVisClient = { triggerScan: global.triggerScan };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

}(window));
