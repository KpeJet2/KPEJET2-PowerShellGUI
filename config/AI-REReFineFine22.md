# VersionTag: 2605.B5.V46.0
# AI-REReFineFine22 — Iterative Refinement Pipeline Process

> Version: 2604.B1.V32.5
> Tags: pipeline, refinement, audit-loop, CI, quality

---

## Purpose

This document defines the **AI-REReFineFine22** iterative refinement pipeline — the standard
process executed by AI agents (Copilot, subagents) to continuously improve the PowerShellGUI
workspace from any state to a fully clean, tested, and documented baseline.

---

## Pipeline Phases

### Phase 1 — Audit Uncompleted Elements
1. Read config/agentic-manifest.json — note meta.counts vs actual scripts/*.ps1 count
2. Scan scripts/, modules/, 	ests/ for files not in manifest
3. Check for TODO/FIXME/HACK markers in source (SIN-P016)
4. Note missing engine routes declared in UI but absent in Start-LocalWebEngine.ps1
5. Deliverable: gap list with severity tagging

### Phase 2 — Fix Incomplete References and Calls
1. For every route referenced in XHTML UI (/api/*): confirm handler function exists in engine
2. For every agent card in PwShGUI-Checklists.xhtml (Agents tab): confirm backing script exists
3. For every Import-Module in scripts: confirm module file exists in modules/
4. Fix gaps found in Phase 1: create missing scripts, add missing routes, add missing modules
5. Deliverable: all references resolved, no dead links

### Phase 3 — Process Pending Todos
1. Read all 	odo/IMPL-YYYYMMDD-*.json files with status = 'OPEN' or 'IN_PROGRESS'
2. Process highest-priority items first (HIGH > MEDIUM > LOW)
3. Mark completed items with status = 'DONE', completedAt, completedBy
4. Deliverable: todo backlog reduced by at least 3 actionable items per run

### Phase 4 — Smoke Tests for New Elements
1. For every new script created in Phase 2-3: create corresponding 	ests/*.Tests.ps1
2. Test file must cover: script exists, VersionTag present, output schema valid, SIN compliance
3. Run all new tests: target 0 failures (skips acceptable for long-running operations)
4. Fix any test failures iteratively
5. Deliverable: 100% pass rate (or skip) on all new test files

### Phase 5 — Cross-Check Manifests + SIN Scan
1. Update config/agentic-manifest.json with all new scripts (schema: name, path, version, fileRole, sizeKB, functionCount, functions[], agenticActions[])
2. Bump meta.version minor number; update meta.counts.scripts
3. Run SIN pattern scanner at CRITICAL severity; fix any REAL violations (not false positives — see memory notes for FP rate)
4. Fix P006 (UTF-8 BOM), P002 (empty catch), P012 (Set-Content encoding), P014 (-Depth) on all new files
5. Deliverable: manifest accurate, 0 real SIN violations in new code

### Phase 6 — Bug Check Iteration
1. Run 	ests/Invoke-SINPatternScanner.ps1 again after Phase 5 fixes
2. Re-read manifest; confirm all scripts accounted for
3. Repeat Phases 1-5 until: no new gaps found AND no real SIN violations remain
4. Stop condition: two consecutive passes with 0 actionable items
5. Deliverable: stable baseline confirmed

### Phase 7 — 10-Point Improvement Plan
1. Review current functional baseline
2. Identify 10 improvements ordered by: Impact/Effort ratio
3. Cover categories: quality tooling, security, UX, automation, observability
4. Document in ~README.md/IMPROVEMENT-PLAN-10POINT.md
5. Deliverable: plan document with priority matrix

### Phase 8 — Chief Approval Todo Items
1. For each item in improvement plan: create 	odo/IMPR-NNN-YYYYMMDD.json
2. Schema: id, title, description, status='PENDING_APPROVAL', priority, effort, affectedFiles, createdBy='AI-REReFineFine22-Pipeline'
3. Do NOT execute improvements until chief approval
4. Deliverable: 10 PENDING_APPROVAL todo files in todo/

### Phase 9 — Pipeline Storage
1. Update this document (config/AI-REReFineFine22.md) with run summary
2. Append execution record to logs/ai-rerefinefine22-runs.jsonl
3. Deliverable: pipeline trace for audit

---

## Stop Criteria

The pipeline terminates when ALL of the following are true:
- [ ] Manifest script count matches scripts/*.ps1 disk count (within ±3 for test/temp files)
- [ ] 0 real SIN violations in new or modified files
- [ ] All new scripts have passing smoke tests
- [ ] All engine routes referenced by UI are implemented
- [ ] Improvement plan filed and todos created

---

## Run Log

| Run | Date | Agent | Phase Completed | Notes |
|-----|------|-------|----------------|-------|
| S14-001 | 2026-04-08 | GitHub Copilot (Claude Sonnet 4.6) | 1-9 | Added routes /api/scan/static, /api/agent/stats; created Invoke-AgentCallStats.ps1; 4 test files; manifest 79→85 scripts; 10-point plan filed |

---

*This process is the canonical AI improvement loop for the PowerShellGUI workspace.*
