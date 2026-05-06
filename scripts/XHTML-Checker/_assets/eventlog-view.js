/* eventlog-view.js -- shared XHTML EventLogView mountable bundle
   VersionTag: 2604.B2.V31.0
   Contract: docs/EVENT-LOG-STANDARD.md
   Mount:
     <div class="evlv-mount" data-scope="pipeline" data-title="Pipeline Events"></div>
     <script>EvLV.mount(document.querySelector('.evlv-mount'));</script>
   Pages already defining ENGINE_BASE / fetchSectionData (e.g. WorkspaceHub) will reuse them
   automatically; standalone pages fall back to ENGINE_BASE='' (relative) and a tiny
   fetch fallback chain mirroring fetchSectionData semantics.
*/
(function(global){
  'use strict';
  if (global.EvLV) { return; } /* idempotent */

  function _esc(s){ s = (s==null?'':String(s)); return s.replace(/[&<>"']/g, function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }

  function _engineBase(){
    if (typeof global.ENGINE_BASE !== 'undefined' && global.ENGINE_BASE) { return String(global.ENGINE_BASE).replace(/\/+$/, ''); }
    return '';
  }

  function _fetchScope(scope, tail){
    var url = _engineBase() + '/api/eventlog/' + encodeURIComponent(scope) + '?tail=' + (tail||500);
    /* Prefer host page's fetchSectionData (gives multi-source + offline cache fallback). */
    if (typeof global.fetchSectionData === 'function') {
      return global.fetchSectionData('eventlog_'+scope, '/api/eventlog/'+encodeURIComponent(scope)+'?tail='+(tail||500), { method: 'GET' }, false)
        .then(function(res){ var d = res && res.data; if (d && d.cache) { d.cache.fromCache = !!res.fromCache; } return d || _emptyEnvelope(scope); });
    }
    /* Standalone fallback: try fetch, then file:// JSON cache, then stale envelope. */
    return fetch(url).then(function(r){ if (!r.ok) throw new Error('http '+r.status); return r.json(); })
      .then(function(d){ try { localStorage.setItem('evlv_cache_'+scope, JSON.stringify(d)); } catch(e){} return d; })
      .catch(function(){
        var raw = null; try { raw = localStorage.getItem('evlv_cache_'+scope); } catch(e){}
        if (raw) { try { var d = JSON.parse(raw); if (d && d.cache) { d.cache.tier = 'stale'; d.cache.fromCache = true; d.cache.fresh = false; } return d; } catch(e){} }
        return _emptyEnvelope(scope);
      });
  }

  function _emptyEnvelope(scope){
    return { generatedAt: new Date().toISOString(), scope: scope, cache: { tier:'error', path:'', ageSec:-1, fresh:false }, items: [] };
  }

  function _renderShell(host, opts){
    var scope = opts.scope || 'root';
    var title = opts.title || ('Event Log: ' + scope);
    host.classList.add('evlv-root');
    host.innerHTML =
      '<div class="evlv-title">'+_esc(title)+
        '<span class="evlv-tier error" data-evlv="tier">offline</span>'+
        '<span class="evlv-count" data-evlv="count">0 / 0</span>'+
      '</div>'+
      '<div class="evlv-toolbar">'+
        '<input type="search" placeholder="Search messages..." data-evlv="search" />'+
        '<label>Sev:'+
          '<select data-evlv="sev" multiple="multiple" size="1" style="min-width:90px">'+
            '<option value="">All</option>'+
            '<option value="DEBUG">DEBUG</option>'+
            '<option value="INFO">INFO</option>'+
            '<option value="WARN">WARN</option>'+
            '<option value="ERROR">ERROR</option>'+
            '<option value="CRITICAL">CRITICAL</option>'+
            '<option value="AUDIT">AUDIT</option>'+
          '</select>'+
        '</label>'+
        '<label>Component:<input type="text" data-evlv="comp" placeholder="any" style="width:90px" /></label>'+
        '<button class="evlv-primary" data-evlv="refresh">Refresh</button>'+
        '<button data-evlv="export">Export</button>'+
        '<button data-evlv="preset-save">+ Preset</button>'+
        '<button data-evlv="copy">Copy</button>'+
        '<label><input type="checkbox" data-evlv="autorefresh" /> Auto 30s</label>'+
      '</div>'+
      '<div class="evlv-presets" data-evlv="presets"></div>'+
      '<div class="evlv-table-wrap"><table class="evlv-table">'+
        '<thead><tr><th style="width:160px">Time</th><th style="width:80px">Sev</th><th style="width:160px">Component</th><th>Message</th><th style="width:120px">CorrId</th></tr></thead>'+
        '<tbody data-evlv="body"><tr><td colspan="5" class="evlv-empty">Loading...</td></tr></tbody>'+
      '</table></div>';
  }

  function _q(host, sel){ return host.querySelector('[data-evlv="'+sel+'"]'); }

  function _filter(items, state){
    var s = (state.search||'').toLowerCase();
    var sev = state.sev || [];
    var comp = (state.comp||'').toLowerCase();
    var out = [];
    for (var i=0;i<items.length;i++){
      var it = items[i] || {};
      if (sev.length && sev.indexOf(String(it.severity||'')) === -1) continue;
      if (comp && String(it.component||'').toLowerCase().indexOf(comp) === -1) continue;
      if (s){
        var hay = (String(it.msg||'')+' '+String(it.component||'')+' '+String(it.corrId||'')).toLowerCase();
        if (hay.indexOf(s) === -1) continue;
      }
      out.push(it);
    }
    return out;
  }

  function _renderRows(host, items, total){
    var body = _q(host,'body');
    var cnt = _q(host,'count');
    if (cnt) cnt.textContent = items.length + ' / ' + total;
    if (!items.length){ body.innerHTML = '<tr><td colspan="5" class="evlv-empty">No matching events</td></tr>'; return; }
    var html = '';
    for (var i=0;i<items.length;i++){
      var r = items[i] || {};
      html += '<tr>'+
        '<td class="evlv-ts">'+_esc(r.ts||'')+'</td>'+
        '<td><span class="evlv-sev '+_esc(r.severity||'INFO')+'">'+_esc(r.severity||'INFO')+'</span></td>'+
        '<td class="evlv-comp">'+_esc(r.component||'')+'</td>'+
        '<td class="evlv-msg">'+_esc(r.msg||'')+'</td>'+
        '<td class="evlv-corr" data-corr="'+_esc(r.corrId||'')+'">'+_esc(r.corrId||'')+'</td>'+
      '</tr>';
    }
    body.innerHTML = html;
    /* corr-id click to copy */
    var cells = body.querySelectorAll('[data-corr]');
    for (var j=0;j<cells.length;j++){
      cells[j].addEventListener('click', function(ev){
        var v = ev.currentTarget.getAttribute('data-corr')||'';
        if (!v) return;
        try { navigator.clipboard.writeText(v); } catch(e){}
      });
    }
  }

  function _renderTier(host, env){
    var tierEl = _q(host,'tier');
    if (!tierEl || !env || !env.cache) return;
    var t = String(env.cache.tier||'error');
    tierEl.className = 'evlv-tier ' + t;
    var label = t;
    if (env.cache.ageSec >= 0) label += ' (' + env.cache.ageSec + 's)';
    if (env.cache.fromCache) label += ' [offline]';
    tierEl.textContent = label;
  }

  function _presetKey(scope){ return 'evlv_presets_'+scope; }

  function _loadPresets(scope){
    try { var raw = localStorage.getItem(_presetKey(scope)); if (raw) return JSON.parse(raw)||[]; } catch(e){}
    return [];
  }
  function _savePresets(scope, list){ try { localStorage.setItem(_presetKey(scope), JSON.stringify(list||[])); } catch(e){} }

  function _renderPresets(host, scope, applyFn){
    var wrap = _q(host,'presets');
    if (!wrap) return;
    var list = _loadPresets(scope);
    if (!list.length){ wrap.innerHTML = ''; return; }
    var html = '';
    for (var i=0;i<list.length;i++){
      html += '<span class="evlv-preset" data-idx="'+i+'">'+_esc(list[i].name)+'<span class="evlv-preset-x" data-idx="'+i+'">x</span></span>';
    }
    wrap.innerHTML = html;
    var els = wrap.querySelectorAll('.evlv-preset');
    for (var j=0;j<els.length;j++){
      els[j].addEventListener('click', function(ev){
        if (ev.target && ev.target.classList && ev.target.classList.contains('evlv-preset-x')) {
          var idx = parseInt(ev.target.getAttribute('data-idx'),10);
          var L = _loadPresets(scope); L.splice(idx,1); _savePresets(scope, L); _renderPresets(host, scope, applyFn);
          return;
        }
        var i2 = parseInt(ev.currentTarget.getAttribute('data-idx'),10);
        applyFn(_loadPresets(scope)[i2]);
      });
    }
  }

  function mount(host, optionsIn){
    if (!host) return null;
    var opts = optionsIn || {};
    var scope = host.getAttribute('data-scope') || opts.scope || 'root';
    var title = host.getAttribute('data-title') || opts.title || ('Event Log: ' + scope);
    var tail  = parseInt(host.getAttribute('data-tail') || opts.tail || 500, 10);
    _renderShell(host, { scope: scope, title: title });
    var state = { search:'', sev:[], comp:'', envelope:null };
    var timer = null;

    function applyState(p){
      if (p && p.search != null){ state.search = p.search; _q(host,'search').value = p.search; }
      if (p && p.sev   != null){ state.sev = p.sev||[]; var sel=_q(host,'sev'); for (var i=0;i<sel.options.length;i++){ sel.options[i].selected = state.sev.indexOf(sel.options[i].value)>=0; } }
      if (p && p.comp  != null){ state.comp = p.comp; _q(host,'comp').value = p.comp; }
      rerender();
    }

    function rerender(){
      var items = state.envelope && state.envelope.items ? state.envelope.items : [];
      var f = _filter(items, state);
      _renderRows(host, f, items.length);
    }

    function refresh(){
      var body = _q(host,'body');
      if (body) body.innerHTML = '<tr><td colspan="5" class="evlv-empty">Loading...</td></tr>';
      _fetchScope(scope, tail).then(function(env){
        state.envelope = env;
        _renderTier(host, env);
        rerender();
      });
    }

    _q(host,'search').addEventListener('input', function(e){ state.search = e.target.value||''; rerender(); });
    _q(host,'sev').addEventListener('change', function(e){
      var arr=[]; var s=e.target; for (var i=0;i<s.options.length;i++){ if (s.options[i].selected && s.options[i].value) arr.push(s.options[i].value); }
      state.sev = arr; rerender();
    });
    _q(host,'comp').addEventListener('input', function(e){ state.comp = e.target.value||''; rerender(); });
    _q(host,'refresh').addEventListener('click', refresh);
    _q(host,'autorefresh').addEventListener('change', function(e){
      if (timer) { clearInterval(timer); timer = null; }
      if (e.target.checked) { timer = setInterval(refresh, 30000); }
    });
    _q(host,'export').addEventListener('click', function(){
      var items = state.envelope && state.envelope.items ? _filter(state.envelope.items, state) : [];
      var blob = new Blob([JSON.stringify({ scope: scope, exportedAt: new Date().toISOString(), items: items }, null, 2)], { type:'application/json' });
      var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'eventlog-'+scope+'-'+(new Date().toISOString().replace(/[^0-9]/g,'').slice(0,14))+'.json'; a.click();
    });
    _q(host,'copy').addEventListener('click', function(){
      var items = state.envelope && state.envelope.items ? _filter(state.envelope.items, state) : [];
      var lines = items.map(function(r){ return [r.ts, r.severity, r.component, r.msg].join(' | '); });
      try { navigator.clipboard.writeText(lines.join('\n')); } catch(e){}
    });
    _q(host,'preset-save').addEventListener('click', function(){
      var name = global.prompt('Preset name:'); if (!name) return;
      var L = _loadPresets(scope); L.push({ name: name, search: state.search, sev: state.sev, comp: state.comp });
      _savePresets(scope, L); _renderPresets(host, scope, applyState);
    });
    _renderPresets(host, scope, applyState);

    refresh();
    return { refresh: refresh, applyState: applyState, getState: function(){ return state; } };
  }

  function mountAll(root){
    var els = (root||document).querySelectorAll('.evlv-mount');
    var instances = [];
    for (var i=0;i<els.length;i++){ instances.push(mount(els[i])); }
    return instances;
  }

  global.EvLV = { mount: mount, mountAll: mountAll, version: '2604.B2.V31.0' };
})(window);
