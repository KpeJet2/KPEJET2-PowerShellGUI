/* PwShGUI Service Cluster Dashboard frontend
   VersionTag: 2605.B5.V46.0 */

(() => {
  'use strict';

  const bootToken = (() => {
    const el = document.querySelector('meta[name="cluster-token"]');
    return el ? String(el.getAttribute('content') || '').trim() : '';
  })();

  const state = {
    token: localStorage.getItem('dash.cluster.token') || bootToken || '',
    ws: null,
    wsConnected: false,
    refreshSec: Number(localStorage.getItem('dash.refresh.sec') || 3),
    menu: [],
    nodes: [],
    jobs: [],
    mcp: [],
    agents: [],
    pipeline: [],
    tools: [],
    sins: null,
  };

  const $ = (id) => document.getElementById(id);
  const fmt = {
    pct: (n) => `${Number(n || 0).toFixed(1)}%`,
    iso: (s) => s ? new Date(s).toLocaleString() : '-',
  };

  function authHeaders() {
    return state.token ? { 'X-Cluster-Token': state.token } : {};
  }

  async function api(path, opts = {}) {
    const init = { ...opts, headers: { ...(opts.headers || {}), ...authHeaders() } };
    let res = await fetch(path, init);
    if (res.status === 401 && bootToken && state.token !== bootToken) {
      state.token = bootToken;
      localStorage.setItem('dash.cluster.token', state.token);
      const tokenInput = $('tokenInput');
      if (tokenInput) { tokenInput.value = state.token; }
      const settingsToken = $('settingsToken');
      if (settingsToken) { settingsToken.value = state.token; }
      const retryInit = { ...opts, headers: { ...(opts.headers || {}), ...authHeaders() } };
      res = await fetch(path, retryInit);
    }
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`${res.status} ${res.statusText} :: ${text}`);
    }
    return res.json();
  }

  function toast(msg, isErr = false) {
    const el = $('toast');
    el.textContent = msg;
    el.classList.toggle('error', isErr);
    el.classList.add('show');
    setTimeout(() => el.classList.remove('show'), 2100);
  }

  function appendLive(msg) {
    const box = $('liveLog');
    const ts = new Date().toLocaleTimeString();
    if (box.textContent.trim() === '–') box.textContent = '';
    box.textContent += `[${ts}] ${msg}\n`;
    box.scrollTop = box.scrollHeight;
  }

  function setPill(el, text, ok) {
    el.textContent = text;
    el.classList.remove('ok', 'bad');
    el.classList.add(ok ? 'ok' : 'bad');
  }

  function setBar(id, pct) {
    const p = Math.max(0, Math.min(100, Number(pct || 0)));
    $(id).style.width = `${p}%`;
  }

  function switchBlade(name) {
    document.querySelectorAll('.blade-tab').forEach((b) => b.classList.toggle('active', b.dataset.blade === name));
    document.querySelectorAll('.blade').forEach((b) => b.classList.toggle('active', b.id === `blade-${name}`));
  }

  async function loadMenu() {
    const data = await api('/api/menu/maingui');
    state.menu = data.menu || [];
    const bar = $('menuBar');
    bar.innerHTML = '';

    state.menu.forEach((top) => {
      const node = document.createElement('div');
      node.className = 'menu-item';
      node.textContent = top.label;

      const sub = document.createElement('div');
      sub.className = 'submenu';

      (top.items || []).forEach((item) => {
        const it = document.createElement('div');
        it.className = 'submenu-item';
        it.textContent = item.label;
        it.addEventListener('click', async () => {
          node.classList.remove('open');
          await invokeMenuAction(item);
        });
        sub.appendChild(it);
      });

      node.appendChild(sub);
      node.addEventListener('mouseenter', () => node.classList.add('open'));
      node.addEventListener('mouseleave', () => node.classList.remove('open'));
      node.addEventListener('click', () => node.classList.toggle('open'));
      bar.appendChild(node);
    });
  }

  async function invokeMenuAction(item) {
    if (item.action === 'system' && item.tool === 'exit') {
      showFlyout('Exit', '<p>Close this browser tab to exit dashboard view.</p>');
      return;
    }
    if (item.action === 'open_folder') {
      showFlyout('Open Folder', `<p>Requested: ${item.path}</p><p>Use workspace explorer for local folder access.</p>`);
      return;
    }
    if (item.action === 'links_category') {
      showFlyout('Links Category', `<p>Category: <strong>${item.category}</strong></p><p>This mirrors MainGUI links menu categories.</p>`);
      return;
    }
    if (item.action === 'launch' && item.tool) {
      try {
        const r = await api('/api/tools/launch', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ tool: item.tool, params: {} }),
        });
        toast(`Launched ${item.tool} (pid ${r.pid})`);
        appendLive(`Menu launch: ${item.tool} pid=${r.pid}`);
      } catch (e) {
        toast(`Launch failed: ${item.tool}`, true);
        appendLive(`Menu launch failed: ${item.tool} :: ${e.message}`);
      }
      return;
    }
    showFlyout('Menu Action', `<pre>${JSON.stringify(item, null, 2)}</pre>`);
  }

  function showFlyout(title, html) {
    $('flyoutTitle').textContent = title;
    $('flyoutBody').innerHTML = html;
    $('flyout').classList.add('open');
  }

  function closeFlyout() {
    $('flyout').classList.remove('open');
  }

  async function refreshOverview() {
    const m = await api('/api/metrics/lite');
    $('mCpu').textContent = fmt.pct(m.cpu_pct);
    setBar('mCpuBar', m.cpu_pct);

    const ramPct = m.ram?.used_pct || 0;
    $('mRam').textContent = fmt.pct(ramPct);
    setBar('mRamBar', ramPct);

    const dPct = m.disk?.percent || 0;
    $('mDisk').textContent = fmt.pct(dPct);
    setBar('mDiskBar', dPct);

    const er = m.engine_running ? 'ONLINE' : 'OFFLINE';
    $('mEngine').textContent = er;
    $('mEngineSub').textContent = `PID ${m.engine_pid || '-'}`;

    const tbody = $('procTable').querySelector('tbody');
    tbody.innerHTML = '';
    (m.top_procs || []).forEach((p) => {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${p.pid ?? ''}</td><td>${p.name ?? ''}</td><td>${p.cpu_percent ?? 0}</td><td>${p.memory_mb ?? 0}</td><td>${p.status ?? ''}</td>`;
      tbody.appendChild(tr);
    });
  }

  async function refreshEngine() {
    const e = await api('/api/engine/status');
    $('engineInfo').textContent = JSON.stringify(e, null, 2);

    setPill($('engineStatusPill'), `Engine: ${e.running ? 'ONLINE' : 'OFFLINE'}${e.responding ? ' / RESPONDING' : ''}`, !!e.running);
    $('mEngine').textContent = e.running ? 'ONLINE' : 'OFFLINE';

    const nodeInfo = await api('/api/node/info');
    setPill($('nodeRolePill'), `ROLE: ${nodeInfo.role}`, nodeInfo.role === 'MASTER');
  }

  async function engineAction(action) {
    const r = await api('/api/engine/control', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action }),
    });
    toast(`Engine ${action} submitted (pid ${r.pid || '-'})`);
    appendLive(`Engine action: ${action} submitted`);
    await refreshEngine();
  }

  async function loadEngineLog() {
    const name = $('engineLogSelect').value;
    const d = await api(`/api/engine/log?name=${encodeURIComponent(name)}&lines=300`);
    $('engineLog').textContent = (d.lines || []).join('\n') || 'No log lines.';
  }

  async function refreshCluster() {
    const d = await api('/api/cluster/nodes');
    state.nodes = d.nodes || [];
    $('mNodes').textContent = String(state.nodes.length);

    const body = $('clusterTable').querySelector('tbody');
    body.innerHTML = '';
    state.nodes.forEach((n) => {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${n.id || ''}</td>
        <td>${n.host || ''}:${n.port || ''}</td>
        <td>${n.role || ''}</td>
        <td>${n.version || ''}</td>
        <td>${fmt.iso(n.last_seen)}</td>
        <td class="actions">
          <button class="btn" data-ctl="promote" data-id="${n.id}">Promote</button>
          <button class="btn" data-ctl="demote" data-id="${n.id}">Demote</button>
          <button class="btn btn-warn" data-ctl="restart" data-id="${n.id}">Restart</button>
          <button class="btn btn-danger" data-ctl="remove" data-id="${n.id}">Remove</button>
        </td>`;
      body.appendChild(tr);
    });

    body.querySelectorAll('button[data-ctl]').forEach((btn) => {
      btn.addEventListener('click', () => clusterControl(btn.dataset.ctl, btn.dataset.id));
    });
  }

  async function registerPeer() {
    const body = {
      id: $('peerId').value.trim() || `${$('peerHost').value.trim()}:${$('peerPort').value.trim()}`,
      host: $('peerHost').value.trim(),
      port: Number($('peerPort').value),
      role: $('peerRole').value,
      version: $('versionTag').textContent.trim(),
    };
    await api('/api/cluster/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    toast(`Peer registered: ${body.id}`);
    appendLive(`Cluster register ${body.id}`);
    await refreshCluster();
  }

  async function clusterControl(action, target_id) {
    await api('/api/cluster/control', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, target_id }),
    });
    toast(`Cluster ${action}: ${target_id}`);
    appendLive(`Cluster control ${action} -> ${target_id}`);
    await refreshCluster();
  }

  async function refreshJobs() {
    const d = await api('/api/jobs');
    state.jobs = d.jobs || [];
    $('mJobs').textContent = String(d.count || 0);

    const body = $('jobTable').querySelector('tbody');
    body.innerHTML = '';
    state.jobs.forEach((j) => {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${j.id}</td><td>${j.tool}</td><td>${j.label}</td><td>${j.status}</td><td>${fmt.iso(j.submitted)}</td>`;
      body.appendChild(tr);
    });
  }

  async function submitJob() {
    const tool = $('jobToolName').value.trim();
    if (!tool) {
      toast('Enter a tool name first', true);
      return;
    }
    await api('/api/jobs', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tool, label: tool, params: {} }),
    });
    toast(`Job queued: ${tool}`);
    appendLive(`Job queued: ${tool}`);
    $('jobToolName').value = '';
    await refreshJobs();
  }

  async function refreshMcp() {
    const d = await api('/api/mcp/servers');
    state.mcp = d.servers || [];
    const box = $('mcpCards');
    box.innerHTML = '';
    state.mcp.forEach((s) => {
      const c = document.createElement('article');
      c.className = 'svc-card';
      c.innerHTML = `<div class="name">${s.name}</div>
        <div class="meta">type=${s.type}</div>
        <span class="badge">${s.status}</span>`;
      box.appendChild(c);
    });
  }

  async function refreshAgents() {
    const d = await api('/api/agents');
    state.agents = d.agents || [];
    const box = $('agentCards');
    box.innerHTML = '';
    state.agents.forEach((a) => {
      const c = document.createElement('article');
      c.className = 'svc-card';
      c.innerHTML = `<div class="name">${a.name}</div><div class="meta">${a.file}</div><span class="badge">agent</span>`;
      box.appendChild(c);
    });
  }

  async function refreshPipeline() {
    const d = await api('/api/pipeline/tasks');
    state.pipeline = d.tasks || [];
    const body = $('pipelineTable').querySelector('tbody');
    body.innerHTML = '';
    state.pipeline.forEach((t) => {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${t.category || ''}</td><td>${t.id || ''}</td><td>${t.title || ''}</td><td>${t.status || ''}</td><td>${t.priority || ''}</td>`;
      body.appendChild(tr);
    });
  }

  async function refreshTools() {
    const d = await api('/api/tools/admin');
    state.tools = d.tools || [];
    const box = $('toolCards');
    box.innerHTML = '';
    state.tools.forEach((t) => {
      const c = document.createElement('article');
      c.className = 'svc-card';
      c.innerHTML = `<div class="name">${t.name}</div><div class="meta">${t.path}</div><span class="badge">${t.type}</span>`;
      c.addEventListener('click', async () => {
        try {
          const r = await api('/api/tools/launch', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ tool: t.name, params: {} }),
          });
          toast(`Launched ${t.name} (pid ${r.pid})`);
          appendLive(`Tool launch: ${t.name} pid=${r.pid}`);
        } catch (e) {
          toast(`Launch failed: ${t.name}`, true);
        }
      });
      box.appendChild(c);
    });
  }

  async function refreshSins() {
    const s = await api('/api/security/sins');
    state.sins = s;

    $('sinTotal').textContent = s.total ?? 0;
    $('sinCritical').textContent = s.critical ?? 0;
    $('sinHigh').textContent = s.high ?? 0;
    $('sinMedium').textContent = s.medium ?? 0;
    $('sinPenance').textContent = s.penance ?? 0;
    $('sinResolved').textContent = s.resolved ?? 0;

    $('mSins').textContent = String((s.total || 0) - (s.resolved || 0));
    $('mSinsSub').textContent = `critical ${s.critical || 0}, high ${s.high || 0}`;
  }

  function connectWs() {
    if (!state.token) {
      toast('Set cluster token first', true);
      return;
    }
    if (state.ws) {
      try { state.ws.close(); } catch (_) {}
    }
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const url = `${proto}://${location.host}/ws/metrics?token=${encodeURIComponent(state.token)}`;
    const ws = new WebSocket(url);
    state.ws = ws;

    ws.onopen = () => {
      state.wsConnected = true;
      $('mWs').textContent = 'CONNECTED';
      appendLive('WebSocket connected');
    };
    ws.onclose = () => {
      state.wsConnected = false;
      $('mWs').textContent = 'DISCONNECTED';
      appendLive('WebSocket disconnected');
    };
    ws.onerror = () => {
      appendLive('WebSocket error');
    };
    ws.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data);
        if (msg.type === 'metrics' && msg.data) {
          applyRealtimeMetrics(msg.data);
        }
      } catch (_) {}
    };
  }

  function applyRealtimeMetrics(m) {
    $('mCpu').textContent = fmt.pct(m.cpu_pct);
    setBar('mCpuBar', m.cpu_pct);

    const ramPct = m.ram?.used_pct || 0;
    $('mRam').textContent = fmt.pct(ramPct);
    setBar('mRamBar', ramPct);

    const dPct = m.disk?.percent || 0;
    $('mDisk').textContent = fmt.pct(dPct);
    setBar('mDiskBar', dPct);

    $('mEngine').textContent = m.engine_running ? 'ONLINE' : 'OFFLINE';
    $('mEngineSub').textContent = `PID ${m.engine_pid || '-'}`;
  }

  async function initialLoad() {
    await loadMenu();
    await refreshOverview();
  }

  async function refreshAll() {
    await Promise.allSettled([
      refreshOverview(),
      refreshEngine(),
      refreshCluster(),
      refreshJobs(),
      refreshMcp(),
      refreshAgents(),
      refreshPipeline(),
      refreshTools(),
      refreshSins(),
    ]);
  }

  function bindUi() {
    document.querySelectorAll('.blade-tab').forEach((btn) => {
      btn.addEventListener('click', () => switchBlade(btn.dataset.blade));
    });

    $('connectBtn').addEventListener('click', async () => {
      state.token = $('tokenInput').value.trim();
      if (!state.token) {
        toast('Token is required', true);
        return;
      }
      localStorage.setItem('dash.cluster.token', state.token);
      $('settingsToken').value = state.token;
      connectWs();
      try {
        await refreshAll();
        toast('Connected');
      } catch (e) {
        toast(`Auth/API failure: ${e.message}`, true);
      }
    });

    $('refreshAll').addEventListener('click', refreshAll);
    $('themeToggle').addEventListener('click', cycleTheme);
    $('flyoutClose').addEventListener('click', closeFlyout);

    document.querySelectorAll('[data-engine-action]').forEach((btn) => {
      btn.addEventListener('click', () => engineAction(btn.dataset.engineAction));
    });
    $('engineRefresh').addEventListener('click', refreshEngine);
    $('engineLogLoad').addEventListener('click', loadEngineLog);

    $('clusterRefresh').addEventListener('click', refreshCluster);
    $('peerSubmit').addEventListener('click', registerPeer);

    $('jobsRefresh').addEventListener('click', refreshJobs);
    $('jobSubmit').addEventListener('click', submitJob);

    $('mcpRefresh').addEventListener('click', refreshMcp);
    $('agentsRefresh').addEventListener('click', refreshAgents);
    $('pipelineRefresh').addEventListener('click', refreshPipeline);
    $('toolsRefresh').addEventListener('click', refreshTools);
    $('sinRefresh').addEventListener('click', refreshSins);

    $('logsClear').addEventListener('click', () => { $('liveLog').textContent = '–'; });

    $('themeSelect').addEventListener('change', (e) => setTheme(e.target.value));
    $('accentColor').addEventListener('input', (e) => {
      document.documentElement.style.setProperty('--accent', e.target.value);
      localStorage.setItem('dash.accent', e.target.value);
    });
    $('refreshInterval').addEventListener('change', (e) => {
      const sec = Math.max(2, Math.min(60, Number(e.target.value || 3)));
      state.refreshSec = sec;
      localStorage.setItem('dash.refresh.sec', String(sec));
      schedulePoll();
    });
    $('settingsToken').addEventListener('change', (e) => {
      state.token = e.target.value.trim();
      $('tokenInput').value = state.token;
      localStorage.setItem('dash.cluster.token', state.token);
    });
  }

  let pollTimer = null;
  function schedulePoll() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(async () => {
      if (!state.token) return;
      try {
        await Promise.allSettled([
          refreshOverview(),
          refreshCluster(),
          refreshJobs(),
          refreshSins(),
        ]);
      } catch (_) {}
    }, state.refreshSec * 1000);
  }

  function setTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('dash.theme', theme);
    $('themeSelect').value = theme;
  }

  function cycleTheme() {
    const cur = document.documentElement.getAttribute('data-theme') || 'dark';
    const seq = ['dark', 'light', 'amber'];
    setTheme(seq[(seq.indexOf(cur) + 1) % seq.length]);
  }

  function restoreSettings() {
    const theme = localStorage.getItem('dash.theme') || 'dark';
    setTheme(theme);

    const accent = localStorage.getItem('dash.accent');
    if (accent) {
      document.documentElement.style.setProperty('--accent', accent);
      $('accentColor').value = accent;
    }

    $('refreshInterval').value = String(state.refreshSec);
    $('tokenInput').value = state.token;
    $('settingsToken').value = state.token;
  }

  // bootstrap
  (async function main() {
    bindUi();
    restoreSettings();

    try {
      await initialLoad();
      appendLive('Dashboard initialized');
      if (state.token) {
        connectWs();
        await refreshAll();
      }
      schedulePoll();
    } catch (e) {
      toast(`Initialization error: ${e.message}`, true);
      appendLive(`Init error: ${e.message}`);
    }
  })();
})();
