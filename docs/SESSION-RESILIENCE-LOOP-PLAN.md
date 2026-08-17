# Session Resilience Loop — Implementation Plan

> Plan owner: `kpe-AiGent-Plan4Me` · Created 2026-08-18 · Status: **PROPOSED — awaiting go/no-go**
> Diagram: [docs/diagrams/session-resilience-loop.mmd](docs/diagrams/session-resilience-loop.mmd)

---

## 1. Objective

Build a VS Code–integrated tool that drives **one chat/agent session at a time** in a supervised
loop. The loop detects any session that ends in error, failure, quit, crash, hang, or with
**incomplete todo items**, and automatically re-runs the session under an escalating retry ladder
until either:

- **SUCCESS** — all planned todo items are DONE, all tests pass, and the working tree is
  commit-able (lint/SIN gates green); or
- **EXHAUSTED** — the full 48-hour ladder is consumed, at which point a final forensic report is
  written and the loop exits non-zero.

---

## 2. Deliverables

| # | Artifact | Purpose |
| --- | --- | --- |
| D1 | `scripts/Invoke-SessionResilienceLoop.ps1` | Core supervisor: single-flight lock, session launch, outcome classification, retry ladder, ledger. |
| D2 | `modules/SessionOutcomeClassifier.psm1` | Reusable classifier: exit code + transcript + todo state + Pester results → outcome enum. |
| D3 | `config/session-resilience-loop.json` | Declarative ladder config, steering comment text, session command template, thresholds. |
| D4 | `.vscode/tasks.json` entries | `Session Loop: Start`, `Session Loop: Dry Run`, `Session Loop: Stop`, `Session Loop: Status`. |
| D5 | `Launch-SessionResilienceLoop.bat` | Root launcher (chcp 65001, `-WorkspacePath` forwarded — ⸸ P081/P082 compliant). |
| D6 | `XHTML-SessionLoopDashboard.xhtml` | Live ladder/attempt/outcome dashboard fed by the JSON ledger. |
| D7 | `tests/Invoke-SessionResilienceLoop.Tests.ps1` | Pester coverage for ladder maths, classifier, lock, stop-signal. |
| D8 | `docs/SESSION-RESILIENCE-LOOP.md` | Operator runbook (start/stop/interpret/tune). |

---

## 3. Retry ladder specification

`ImmediateFailSeconds` (default **20 s**) defines a *near-immediate failure*. A failure that took
**longer** than this threshold is treated as genuine work-in-progress → ladder **resets to Phase 0**.
A failure **at or under** the threshold advances the ladder.

| Phase | Trigger | Interval | Window | Max attempts | Steering comment |
| --- | --- | --- | --- | --- | --- |
| P0 | Attempts 1–6 | immediate (0 s) | — | 6 | No |
| P1 | Attempt 7 | immediate (0 s) | — | 1 | **Yes** |
| P2 | P1 failed near-immediately | 15 s | 5 min | 20 | Yes |
| P3 | P2 exhausted | 60 s | 45 min | 45 | Yes |
| P4 | P3 exhausted | 120 s | 2 h | 60 | Yes |
| P5 | P4 exhausted | 180 s | 3 h | 60 | Yes |
| P6 | P5 exhausted | 300 s | 48 h | 576 | Yes |
| — | P6 exhausted | — | — | — | Final report, exit 1 |

**Steering comment** (verbatim, appended to the session prompt from attempt 7 onward):

> `get over the issues, fix or forge on to complete all todos and testing`

Total worst-case supervised runtime: **≈ 53 h 50 min**, **768 attempts**.

---

## 4. Outcome classification matrix

| Signal source | Detection | Outcome |
| --- | --- | --- |
| Process exit code `0` **and** todo file has zero non-DONE items **and** Pester `FailedCount = 0` | — | `SUCCESS` |
| Exit code `0` but non-DONE todos remain | todo/JSON scan | `INCOMPLETE_TODOS` |
| Pester `FailedCount > 0` | `testResults.xml` / Pester object | `TEST_FAIL` |
| Non-zero exit code | process | `ERROR_EXIT` |
| No stdout for `HangSeconds` (default 900 s) | idle timer | `HANG` → kill tree |
| Transcript matches crash/quit regex set | regex bank in D3 | `CRASH` / `QUIT` |
| Duration ≤ `ImmediateFailSeconds` | stopwatch | annotate `NEAR_IMMEDIATE` on any failure |

All non-`SUCCESS` outcomes feed the ladder. `SUCCESS` additionally runs the commit-ability gate
(SIN scan + pre-commit validation) before declaring completion.

---

## 5. Phased execution

### Phase 1 — Discover (blockers first)

**Goal:** confirm the headless session invocation contract before writing any loop code.

1. Decide + verify the session driver: Copilot CLI headless vs. an existing orchestrator
   (`scripts/Run-FullPipeline.ps1`, `scripts/Invoke-PipelineContinuousRefine.ps1`).
2. Confirm exit-code semantics and transcript location for that driver.
3. Locate authoritative todo state (`todo/`, `config/cron-aiathon-pipeline.json`) and its status enum.
4. Confirm Pester result surface (`testResults.xml`) is written on every run.

**Blockers:** ⛔ If no non-interactive session driver exists, the loop can only supervise *pipeline*
runs, not literal chat sessions — scope must be confirmed with the operator before Phase 3.
**Done when:** a single documented command line reproducibly runs one session and returns a
deterministic exit code.

### Phase 2 — Design

**Goal:** freeze contracts.

1. Author `config/session-resilience-loop.json` schema (ladder, thresholds, regex bank, steering text).
2. Define the JSON ledger record shape (attempt #, phase, start/end, duration, outcome, exit code,
   transcript path, steering applied, next-delay).
3. Define stop/pause signals: `logs/session-loop.stop`, `logs/session-loop.pause`.
4. Define single-flight lock: `logs/.session-loop.lock` with owning PID + liveness check.

**Done when:** schema files exist and are reviewed; no code written yet.

### Phase 3 — Implement

1. `modules/SessionOutcomeClassifier.psm1` — pure functions, no side effects.
2. `scripts/Invoke-SessionResilienceLoop.ps1` — lock → loop → classify → ladder → ledger → report.
   Params: `-WorkspacePath`, `-SessionCommand`, `-ConfigPath`, `-DryRun`, `-MaxWallClockHours`,
   `-ImmediateFailSeconds`, `-HangSeconds`, `-Status`, `-Stop`.
3. Ledger + rolling transcript retention under `logs/session-loop/`.
4. `Launch-SessionResilienceLoop.bat` + `.vscode/tasks.json` entries.
5. `XHTML-SessionLoopDashboard.xhtml` reading `logs/session-loop/ledger.json`.

**SIN guardrails to honour while coding:** ⸸ P004 `@().Count`, ⸸ P005 no PS7 operators,
⸸ P012/P017/P019 explicit `-Encoding UTF8`, ⸸ P014 `-Depth 6` on ConvertTo-Json,
⸸ P015 no absolute paths, ⸸ P021 divide-by-zero guards, ⸸ P027 null-index guards,
⸸ P032/P033 XHTML script escaping + single `var` assignment for the dashboard,
⸸ P082 `chcp 65001` in the `.bat`.

**Done when:** `-DryRun` completes a simulated 768-attempt ladder in under 10 s with a correct
delay schedule.

### Phase 4 — Verify

1. `tests/Invoke-SessionResilienceLoop.Tests.ps1`:
   - ladder maths (per-phase attempt counts + cumulative wall clock),
   - steering comment appears at attempt 7 and every attempt thereafter,
   - `NEAR_IMMEDIATE` advances phase; slow failure resets to P0,
   - lock prevents a second concurrent loop,
   - stop-signal exits within one poll interval,
   - each classifier branch returns the expected enum.
2. Fault-injection harness: a stub session script that fails on demand (instant / slow / hang / pass).
3. Dual-engine smoke: `pwsh` **and** `powershell 5.1`.
4. `tests/Invoke-SINPatternScanner.ps1` clean on all new files
   (invoke via `pwsh -Command "& ... -IncludeFiles @('a','b')"` — never `-File`).

**Done when:** all Pester green on both engines, SIN scan zero new violations.

### Phase 5 — Release

1. Runbook `docs/SESSION-RESILIENCE-LOOP.md`.
2. `CHANGELOG.md` + `~README.md/ENHANCEMENTS-LOG.md` entries; VersionTag `YYMM.B<n>.V<maj>.<min>`.
3. Register a SIN/Semi-SIN advisory if the loop can mask genuine failures (auto-retry hides root cause).
4. Add the loop to `Start-Menu_Service-n-Trays.bat` service menu.

**Done when:** pre-commit validation passes and the tool is launchable from the VS Code task list.

---

## 6. Agent allocation

| Phase | Primary agent | Hand-back to Plan4Me |
| --- | --- | --- |
| 1 Discover | `Explore` (thorough) — locate session driver, todo store, Pester surface | Findings summary + blocker call |
| 2 Design | `kpe-AiGent-Plan4Me` | — |
| 3 Implement | `kpe-AiGent_Code-INspectre` (PS 5.1 + SIN-governed) | After each deliverable D1/D2/D5/D6 |
| 3b Dashboard | `kpe-AiGent_Code-INspectre` (XHTML) — can run **concurrently** with D1/D2 | On D6 complete |
| 4 Verify | `kpe-AiGent_Code-INspectre` (Pester) + `SecuritySpectrum` (retry-abuse / lock review) | On green |
| 5 Release | `kpe-AiGent-Plan4Me` | — |

Concurrency: Phase 3 core loop (D1/D2) and Phase 3b dashboard (D6) run in parallel; both hand back
before Phase 4 begins.

---

## 7. Risks, assumptions, decisions

| ID | Type | Statement | Mitigation |
| --- | --- | --- | --- |
| R1 | Risk | No non-interactive chat-session driver exists → tool supervises pipeline runs only | Resolve in Phase 1 before coding |
| R2 | Risk | Infinite retry masks a deterministic bug for 48 h | Ledger fingerprints failure signature; abort early if last 20 attempts are byte-identical |
| R3 | Risk | Retry storm consumes API quota / CPU | `-MaxWallClockHours` cap + pause signal + dashboard visibility |
| R4 | Risk | Orphaned lock blocks all future runs | PID liveness check + `-Stop` force-clears |
| A1 | Assumption | Todo state is machine-readable with an UPPER_SNAKE_CASE status enum | Verify Phase 1 |
| A2 | Assumption | Pester writes `testResults.xml` on every run | Verify Phase 1 |
| D1 | Decision | Steering comment applies from attempt 7 **onward**, not attempt 7 only | Matches operator intent to keep forcing progress |
| D2 | Decision | Slow failures reset the ladder; only near-immediate failures escalate | Matches "if still near-immediate failures, back off" wording |

---

## 8. Immediate next action

Approve scope for **R1** (literal chat sessions vs. pipeline runs), then release Phase 1 to the
`Explore` agent.
