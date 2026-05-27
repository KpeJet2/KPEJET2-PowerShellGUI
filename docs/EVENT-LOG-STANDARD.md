# VersionTag: 2605.B5.V46.0
# Event Log Standard — PowerShellGUI

> **VersionTag:** 2604.B2.V31.0  
> **Scope:** Mandatory across modules, scripts, pipelines, services, and XHTML viewers.  
> **Owner:** Cod-Rhi-Pear governance (gate runs pre-new-work).

---

## 1. Approved Emission Helpers

| Helper | Module | Use for | Severity vocab |
|---|---|---|---|
| `Write-AppLog` | `PwShGUICore` | App / module / GUI lifecycle | `Debug, Info, Warning, Error, Critical, Audit` |
| `Write-CronLog` | `CronAiAthon-EventLog` | Cron / pipeline / scheduler | `Emergency, Alert, Critical, Error, Warning, Notice, Informational, Debug` |
| `Write-ProcessBanner` | `PwShGUICore` | CLI banners (start / end of script) | n/a |
| `Write-EventLogNormalized` | `PwShGUI-EventLogAdapter` | **Viewer ingestion only** — emits canonical JSONL row | Canonical (see §3) |

**Forbidden in module code paths:** `Write-Host`, `[Console]::WriteLine`, raw `Add-Content` without `-Encoding UTF8`, `Out-File` without `-Encoding UTF8`. (See SS-003, SS-006, P012, P017.)  
**Permitted in interactive UI / banners only:** `Write-Host` (after Write-ProcessBanner pattern).

---

## 2. Severity Normalization (canonical → source mappings)

| Canonical | Write-AppLog | Write-CronLog | Legacy XHTML labels |
|---|---|---|---|
| `DEBUG` | Debug | Debug | DEBUG |
| `INFO` | Info | Informational, Notice | INFO, BOOT |
| `WARN` | Warning | Warning | WARN |
| `ERROR` | Error | Error, Alert | ERROR |
| `CRITICAL` | Critical | Critical, Emergency | CRASH |
| `AUDIT` | Audit | (none) | (none) |

The normalization adapter is the only place this mapping lives.

---

## 3. Canonical Viewer JSONL Row

One JSON object per line in `logs/eventlog-normalized/<scope>-<yyyyMMdd>.jsonl`:

```json
{
  "ts":      "2026-04-29T10:42:01.123Z",
  "severity":"WARN",
  "scope":   "pipeline | service | gui | sin | mcp | cron | engine | sec | net",
  "component":"CronAiAthon-Pipeline",
  "msg":     "Free-text message",
  "corrId":  "optional correlation id",
  "host":    "XPS15-MS",
  "pid":     12345,
  "source":  "logs/CronAiAthon-EventLog.log#L482"
}
```

---

## 4. Cache Resolution (multi-location)

When a viewer requests `/api/eventlog/<scope>` the adapter resolves in this order
and stamps `cache.tier` on the response so the UI can show staleness:

| Tier | Source | Freshness rule |
|---|---|---|
| `live` | Direct read of running-engine in-memory ring buffer | always |
| `disk` | `logs/eventlog-normalized/<scope>-<today>.jsonl` | `mtime` within last 5 min |
| `replay` | Yesterday's JSONL + tail of current `logs/*.log` re-normalized on demand | always — flagged `cache.tier=replay` |
| `stale` | Older than the rules above | flagged; UI shows "Refresh required" |

Failure mode "live data source cached offline contents in multiple locations
isn't working correctly" must be addressable by inspecting the response
`cache` block — every tier emits the same shape.

Response envelope:

```json
{
  "generatedAt":"2026-04-29T10:42:01Z",
  "scope":"pipeline",
  "cache": { "tier":"disk", "path":"logs/eventlog-normalized/pipeline-20260429.jsonl", "ageSec":42, "fresh":true },
  "items":[ /* canonical rows, newest first */ ]
}
```

---

## 5. Scopes (closed enumeration)

`pipeline | service | gui | sin | mcp | cron | engine | sec | net | root`

`root` is the aggregate (used by `PwShGUI-Checklists_V1-ROOT` Eventlog View tab).

---

## 6. Sweep Enforcement

`scripts/Invoke-EventLogStandardSweep.ps1` flags any source emission outside
this standard. It is **report-only**; remediation is logged to the SIN registry
when patterns recur (≥2 occurrences) per existing SIN promotion rule.

---

## 7. Shared XHTML Viewer Contract

Pages embed:

```html
<link rel="stylesheet" href="styles/eventlog-view.css" />
<script src="scripts/XHTML-Checker/_assets/eventlog-view.js"></script>
<div class="evlv-mount" data-scope="pipeline" data-title="Pipeline Events"></div>
<script>EvLV.mount(document.querySelector('.evlv-mount'));</script>
```

The JS bundle is responsible for: filter row, virtualized table, cache tier
indicator, refresh, severity multi-select, copy-corrId, export current view,
preset save/load via `localStorage`. All pages share one bundle; only
`data-scope` differs.

