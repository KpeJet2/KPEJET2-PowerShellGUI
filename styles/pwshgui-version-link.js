/* VersionTag: 2605.B5.V46.0 */
/* FileRole: BrowserAsset
 * pwshgui-version-link.js
 *   Replaces static version strings on any XHTML page with a live link to the
 *   workspace version feed (~REPORTS/xhtml-version-feed.json). Designed so that
 *   the page works under both file:// and the local web engine.
 *
 *   Activation:
 *     <meta name="pwshgui-version-tag"  content="2605.B5.V46.0" />
 *     <meta name="pwshgui-version-feed" content="~REPORTS/xhtml-version-feed.json" />
 *     <script type="text/javascript" src="styles/pwshgui-version-link.js"></script>
 *
 *   The script targets:
 *     - any element with [data-pwshgui-version]
 *     - elements with class .pwshgui-version | .ver-badge | .ft-version |
 *       .hdr-ver | .ver | .version
 *     - elements with id #hdrVer | #headerVersion
 *   Inside each, the canonical token  v?YYMM.B<n>.V<n>(.<n>)?  is wrapped in
 *   an <a> linking to the feed JSON; if no token is present the element text
 *   is replaced with the page meta-tag value.
 */
(function () {
  'use strict';

  function $$(sel) { return Array.prototype.slice.call(document.querySelectorAll(sel)); }
  function getMeta(name) {
    var el = document.querySelector('meta[name="' + name + '"]');
    return el ? el.getAttribute('content') || '' : '';
  }

  var PAGE_TAG  = getMeta('pwshgui-version-tag');
  var FEED_HREF = getMeta('pwshgui-version-feed') || '~REPORTS/xhtml-version-feed.json';
  if (!PAGE_TAG) { return; }

  var TOKEN_RE  = /v?\d{4}\.B\d+\.V\d+(?:\.\d+)?/i;
  var SELECTOR  = '[data-pwshgui-version],.pwshgui-version,.ver-badge,.ft-version,.hdr-ver,span.ver,span.version,#hdrVer,#headerVersion';

  function buildLink(tag, title) {
    var a = document.createElement('a');
    a.className = 'pwshgui-ver-link';
    a.href      = FEED_HREF;
    a.title     = title || ('PwShGUI version feed -- page tag: ' + PAGE_TAG);
    a.target    = '_blank';
    a.rel       = 'noopener noreferrer';
    a.textContent = (tag.charAt(0) === 'v' || tag.charAt(0) === 'V') ? tag : ('v' + tag);
    a.style.cssText = 'color:#58a6ff;text-decoration:none;border-bottom:1px dotted #58a6ff;font-family:Consolas,monospace;';
    return a;
  }

  function applyTo(el, tag, statusClass) {
    if (!el) return;
    el.setAttribute('data-pwshgui-version', tag);
    if (statusClass) { el.classList.add(statusClass); }
    var html = el.innerHTML;
    if (TOKEN_RE.test(html)) {
      // wrap the in-place token, preserve surrounding text
      var re = new RegExp(TOKEN_RE.source, 'i');
      var idx = html.search(re);
      var match = html.match(re);
      if (match) {
        var before = html.substring(0, idx);
        var after  = html.substring(idx + match[0].length);
        el.innerHTML = '';
        if (before) { el.appendChild(document.createTextNode(decodeText(before))); }
        el.appendChild(buildLink(tag));
        if (after)  { el.appendChild(document.createTextNode(decodeText(after))); }
        return;
      }
    }
    // no token found - set entire content
    el.innerHTML = '';
    el.appendChild(buildLink(tag));
  }

  function decodeText(html) {
    var t = document.createElement('textarea');
    t.innerHTML = html;
    return t.value;
  }

  function applyAll(displayTag, statusClass, title) {
    $$(SELECTOR).forEach(function (el) { applyTo(el, displayTag, statusClass); });
    // Refresh tooltips when title supplied
    if (title) {
      $$('.pwshgui-ver-link').forEach(function (a) { a.title = title; });
    }
  }

  // Initial render uses page meta tag.
  applyAll(PAGE_TAG, null, null);

  // Try to upgrade with live feed (mismatch -> red, current -> green).
  if (typeof fetch === 'function') {
    var url = FEED_HREF + (FEED_HREF.indexOf('?') === -1 ? '?' : '&') + 't=' + Date.now();
    fetch(url, { cache: 'no-store' })
      .then(function (r) { if (!r.ok) { throw new Error('HTTP ' + r.status); } return r.json(); })
      .then(function (feed) {
        if (!feed || !feed.files) { return; }
        var here = (location.pathname.split('/').pop() || '').toLowerCase();
        var entry = feed.files.find(function (f) {
          return f && typeof f.path === 'string' && f.path.toLowerCase().split(/[\\/]/).pop() === here;
        });
        var liveTag  = entry && entry.versionTag ? entry.versionTag : (feed.currentRelease || PAGE_TAG);
        var stale    = (liveTag && liveTag !== PAGE_TAG);
        var title    = 'Live feed: ' + liveTag
                     + '\nPage tag: ' + PAGE_TAG
                     + '\nWorkspace current: ' + (feed.currentRelease || '?')
                     + '\nGenerated: ' + (feed.generatedUtc || '?')
                     + (stale ? '\n[!] Page version differs from feed - rebuild needed' : '');
        applyAll(liveTag, stale ? 'pwshgui-ver-stale' : 'pwshgui-ver-current', title);
        if (stale) {
          $$('.pwshgui-ver-link').forEach(function (a) {
            a.style.color = '#d29922';
            a.style.borderBottomColor = '#d29922';
          });
        }
      })
      .catch(function () { /* offline / file:// - keep page meta tag */ });
  }
})();
