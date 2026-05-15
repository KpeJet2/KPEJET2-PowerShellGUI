---
description: Comprehensive workspace instruction set for SOV-Sys-zero pipeline, code refinement services, secure integration, and iterative release improvement.
applyTo: '**/*.{ps1,psm1,psd1,bat,cmd,json,yaml,yml,md,xhtml,html,js,ts,css}'
featureTags:
	- workspace-template
	- sov-sys-zero
	- pipeline-methodology
	- secure-by-default
	- bug-prevention
	- tool-integration
	- data-visualization
	- release-iteration
	- self-reflection
modelProfile:
	name: utilitarian-engineering-model
	priority: reliability-security-maintainability-observability
	targetRuntime: powershell-5.1-strict
---
<!-- VersionTag: 2605.B5.V46.0 -->

# KPE Workspace Instructions (SOV-Sys-zero)

## 1) Purpose and Scope
Use this instruction set for all workspace pipeline operations, including code creation, code refinement, integration work, diagnostics, reporting, and release iteration.

SOV-Sys-zero defines a practical engineering method focused on:
- stable code generation and safe refactoring
- bug prevention before release
- security-first implementation
- integrated toolchain execution
- visual reporting of system and data structure behavior
- self-reflection and measurable improvement across versions

## 2) Workspace Template Feature Tags
Use these tags in plans, changelogs, PR notes, and checkpoints.

- `feature:core` for primary runtime behavior
- `feature:refine` for logic cleanup, simplification, and debt reduction
- `feature:security` for auth, secrets, validation, and hardening
- `feature:stability` for bug fixes and regression prevention
- `feature:pipeline` for build/test/release flow work
- `feature:integration` for cross-module or cross-tool orchestration
- `feature:observability` for logs, telemetry, metrics, diagnostics
- `feature:viz` for diagrams, schema views, and data structure reporting
- `feature:data` for parsing, transforms, model shaping, and validation
- `feature:release` for versioning, packaging, notes, and rollout
- `feature:self-review` for reflection, quality scoring, and lessons learned

Optional lifecycle tags:
- `phase:discover`
- `phase:design`
- `phase:implement`
- `phase:verify`
- `phase:release`
- `phase:reflect`

## 3) Operating Model
Follow this model in every change set.

1. Discover
- clarify intent, constraints, and expected outputs
- identify affected modules, scripts, tests, and docs
- identify security and compatibility boundaries

2. Design
- choose minimal-risk approach
- define validation strategy before editing
- document assumptions and fallback paths

3. Implement
- prefer small, reversible changes
- preserve public behavior unless explicitly changed
- update docs and metadata with code changes

4. Verify
- run tests/lint/checks relevant to modified paths
- validate runtime behavior and error paths
- check for regressions in connected components

5. Release
- apply version tags and release notes
- include migration notes if behavior changed
- ensure changelog and manifests are synchronized

6. Reflect
- summarize what worked and what failed
- capture root cause for defects
- add process improvements for next iteration

## 4) SOV-Sys-zero Quality Gates
All gates must pass before release acceptance.

1. Build/Execution Gate
- scripts and modules load without fatal errors
- commands execute in target runtime (PowerShell 5.1 strict)

2. Correctness Gate
- no known logic breakages in happy path or failure path
- bug fix includes deterministic reproduction and verification

3. Security Gate
- no hardcoded credentials, tokens, or secrets
- all external input validated before path/process/network usage
- no unsafe dynamic execution

4. Reliability Gate
- null/empty guards applied where needed
- encoding explicitly specified for write operations
- errors are logged and actionable

5. Observability Gate
- major operations emit structured logs
- failure context includes operation, target, and reason

6. Integration Gate
- cross-module calls validated for compatibility
- tool outputs mapped into manifest/report artifacts

## 5) Engineering Rules (Utilitarian Defaults)

### Runtime and Compatibility
- target PowerShell 5.1 strict-mode compatibility
- avoid PowerShell 7-only syntax/operators
- avoid platform assumptions not valid on Windows hosts

### Defensive Coding
- always guard nulls before member access and indexing
- prefer explicit condition checks before division and conversions
- avoid hidden failures; log and surface actionable errors

### Security by Design
- never embed credentials or secret material in source
- avoid SSL/TLS bypass patterns
- validate and normalize external paths before composition
- prefer least-privilege execution and explicit boundaries

### File/Content Safety
- set encoding explicitly on write operations
- avoid uncontrolled file growth from duplicated content
- keep files modular and maintainable

### Error Handling
- do not use empty catch blocks
- in catch blocks, log meaningful context and severity
- document intentional exception suppression when needed

## 6) Tool Integration Methodology
When integrating tools, maintain a clear contract per tool:

- input schema: accepted arguments and defaults
- execution contract: sync/async behavior, retries, timeout policy
- output schema: structured result fields and error shape
- artifact mapping: where outputs are persisted (logs/reports/manifests)
- failure handling: fallback or graceful degradation

For multi-tool orchestration:
- execute independent read operations in parallel
- serialize dependent write operations
- preserve deterministic order for state-changing actions

## 6.1) AI File-Change Logging Contract
Any AI or agent that creates, modifies, or deletes workspace files must write AI action log records around the change.

- write a `start` record before the first file edit
- write a `finish` record after the work completes, fails, or is cancelled
- include every touched file with `created`, `modified`, `deleted`, or `unknown`
- use `modules/PwShGUI-AiActionLog.psm1` as the canonical writer surface
- use `scripts/Invoke-AiActionLogReport.ps1` to refresh `~REPORTS/ai-actions/ai-actions-summary.json` when summary/report artifacts are required
- if logging itself fails, write a `logging-error` record with the failure reason

## 7) Data Structure Visualization and Reporting
Every significant data pipeline should include:

1. Structure Snapshot
- schema summary of key objects/arrays/maps
- required and optional fields

2. Flow View
- source -> transform -> output mapping
- mutation points and validation checkpoints

3. Health Metrics
- record counts, error counts, and drop/retry counts
- timing and throughput where available

4. Release Comparison
- compare current output shape against previous release
- highlight incompatible changes and migration impact

Prefer concise, machine-readable artifacts (JSON/CSV) plus human summaries (MD/XHTML).

## 8) Self-Reflection and Iterative Improvement
At the end of each implementation cycle, add a short reflection section:

- objective: what was intended
- outcome: what shipped
- defects prevented: what checks caught
- defects escaped: what was missed and why
- next safeguards: concrete rule/test/process added

Track across versions to improve trend quality:
- stability trend (bug recurrence)
- security trend (risk reductions)
- delivery trend (lead time, rollback frequency)

## 9) Release Generation Protocol
For each release generation:

1. verify version tags and manifest consistency
2. run targeted validation gates for changed areas
3. produce release summary with risk notes
4. include integration compatibility notes
5. include reflection notes for next cycle

If any gate fails, release is blocked until remediated or explicitly waived with rationale.

## 10) Minimum Deliverables Per Change
Every non-trivial change should include:

- updated code/scripts
- tests or validation evidence
- logging/observability updates if behavior changed
- changelog/release notes entry
- reflection note for future improvement

## 11) Review Checklist
Use this checklist in reviews:

- Is the change minimal, clear, and reversible?
- Are security risks reduced or at least not increased?
- Are null/error/edge paths handled?
- Are outputs observable and diagnosable?
- Is integration behavior documented and tested?
- Is release impact communicated?
- Is a reflection note added for iterative improvement?

## 12) Instruction Precedence
If multiple instruction sets apply, use this precedence order:

1. security and compliance constraints
2. runtime compatibility constraints
3. correctness and reliability constraints
4. local style and formatting preferences
5. convenience optimizations

When in conflict, choose the option that lowers operational risk and preserves system integrity.