# Dispatch Handoff — Phase 2 (Code-INspectre)

## 1) Build Scope and Acceptance Criteria

### Scope

- Phase 2 targets the staged no-progress convergence condition in `config/pipeline-canonical-paths.json` where `corrected=0`, `escalated=3`, and loop-cap tag `K5`.
- Deliver deterministic, file-targeted remediations that unblock staged convergence without weakening current precommit/orchestrator auto-correct integration.

### Acceptance Criteria

- Staged convergence run shows non-flat movement within next pass set (at least one actionable delta vs prior 3-pass plateau).
- `K5` no-progress loop-cap no longer triggers for `config/pipeline-canonical-paths.json`.
- No regression in precommit and orchestrator auto-correct behavior.
- Cross-engine checks pass in both `pwsh` and `powershell 5.1` for changed scripts and validation flow.
- All changes are rollback-safe and bounded to declared target files.

## 2) No-Progress Root Cause Hypotheses

1. **Canonicalization idempotency gap**

- Auto-correct computes a fix candidate but writes content that re-normalizes back to the same effective state on next pass, yielding `corrected=0`.

1. **Path comparator mismatch**

- Detection logic compares differently normalized forms (slash/case/root semantics), so drift is repeatedly detected but not considered patchable.

1. **Staged scope filtering conflict**

- File is detected in convergence reporting but excluded (or partially excluded) from correction eligibility in staged mode.

1. **Write-guard or safety gate short-circuit**

- Correction path exits due to safety controls (encoding/structure/guard checks), classifying as escalated without material write attempt.

1. **Baseline/profile expectation skew**

- Active staged profile or canonical registry assumptions are stale versus current file shape, causing repeated non-actionable escalations.

## 3) Ordered Code Action Plan (file-targeted)

1. **Instrument no-progress decision path**

- Target: `scripts/Invoke-PipelineContinuousRefine.ps1`
- Add explicit reason-coded logging for: detected drift, correction candidate generated, write attempted/skipped, and escalation cause for `config/pipeline-canonical-paths.json`.

1. **Harden canonical path normalization contract**

- Target: `scripts/Invoke-ValidateCanonicalPaths.ps1`
- Enforce single normalization routine for compare + correct (same casing/slash/root handling), and emit pre/post normalized values in debug logs.

1. **Align staged eligibility with convergence reporting**

- Target: `scripts/Invoke-PipelineContinuousRefine.ps1`
- Ensure staged selection logic used by detector and corrector is identical; remove split-path conditions that allow detect-but-not-correct behavior.

1. **Add explicit K5 guard-rail remediation path**

- Target: `scripts/Invoke-PipelineContinuousRefine.ps1`
- On repeated no-progress for same file/signature, trigger deterministic fallback action (single bounded rewrite or explicit terminal classification with actionable reason code).

1. **Protect canonical registry shape and encoding**

- Target: `config/pipeline-canonical-paths.json`
- Validate schema and canonical ordering assumptions used by auto-correct; apply minimal structural normalization only if required by comparator contract.

1. **Lock behavior with regression tests**

- Targets: `tests/` (new/updated Pester coverage for refine + canonical validation)
- Add tests for:
  - detect-and-correct path on staged mode
  - detect-but-skip reason codes
  - repeated-pass K5 reproduction and resolution
  - engine parity (`pwsh` vs `powershell 5.1`)

## 4) Verification Matrix (pwsh + powershell 5.1)

### Syntax Parse (Refine Orchestrator)

Command: `pwsh -NoProfile -ExecutionPolicy Bypass -Command "[System.Management.Automation.Language.Parser]::ParseFile('scripts/Invoke-PipelineContinuousRefine.ps1',[ref]$null,[ref]$null) | Out-Null; 'OK'"`

Expected: `OK`

### Syntax Parse (Canonical Validator)

Command: `pwsh -NoProfile -ExecutionPolicy Bypass -Command "[System.Management.Automation.Language.Parser]::ParseFile('scripts/Invoke-ValidateCanonicalPaths.ps1',[ref]$null,[ref]$null) | Out-Null; 'OK'"`

Expected: `OK`

### Staged Convergence Run

Command: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -WorkspacePath . -StagedOnly -BaselineProfile staged -BaselineJson .\config\pipeline-refine-baseline-staged.json -FailOnDrift`

Expected: no flat 3-pass plateau on target file; K5 not repeated

### Canonical Path Validation

Command: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-ValidateCanonicalPaths.ps1 -WorkspacePath . -RegistryPath .\config\pipeline-canonical-paths.json -FailOnMissing`

Expected: deterministic pass/fail with actionable output

### Pester Suite (pwsh)

Command: `pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path .\tests -Output Detailed"`

Expected: all relevant tests pass

### Pester Suite (PS 5.1)

Command: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path .\tests -Output Detailed"`

Expected: parity pass for touched behavior

### Staged Convergence Parity (PS 5.1)

Command: `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -WorkspacePath . -StagedOnly -BaselineProfile staged -BaselineJson .\config\pipeline-refine-baseline-staged.json -FailOnDrift`

Expected: same outcome class/reason codes as pwsh

## 5) Risk Controls and Rollback

### Risk Controls

- Restrict edits to declared targets only: refine orchestrator, canonical validator, canonical registry, and focused tests.
- Preserve current precommit/orchestrator integration points; do not alter external invocation contracts.
- Use reason-coded logging for every detect/correct/escalate branch to prevent opaque no-progress states.
- Keep normalization deterministic and idempotent; avoid broad rewrites of unrelated JSON fields.
- Validate in both engines before merge to prevent PS7-only drift.

### Rollback

- Revert only Phase 2 touched files if convergence worsens or cross-engine parity fails.
- Disable new fallback branch via guarded flag (if introduced) while retaining diagnostic logging.
- Restore prior baseline/profile files if behavior shift is attributable to baseline skew.
- Re-run staged refine + canonical validation to confirm return to pre-change behavior envelope.
