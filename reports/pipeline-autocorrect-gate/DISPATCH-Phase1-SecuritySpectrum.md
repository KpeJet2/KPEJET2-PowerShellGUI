# Dispatch Handoff — Phase 1 (SecuritySpectrum)

## 1) Scope and Authorization

### Phase 1 Security Review Scope (Design-Focused)

- In scope:
  - Auto-correct gate decision logic, STOP conditions K1-K6, escalation flow, and governance enforcement.
  - PS5.1-safe compatibility behavior and SIN policy compliance checks.
  - Protected-path handling for config, governance, pipeline, and security-critical artifacts.
  - Approval payload generation, storage, and reviewer handoff.

- Out of scope:
  - Unrelated feature delivery, UX refactors, or non-gate automation.
  - Any direct production auto-remediation beyond approved protected-path policy.

- Authorization boundary:
  - Read/compare/assess artifacts only until stop/approve decision.
  - No automatic writes to protected paths without explicit human approval token.

### Phase 1 Checklist

- Confirm finding fingerprinting is deterministic across pass1/pass2/pass3.
- Confirm STOP logic executes before any protected-path write attempt.
- Confirm PS5.1-safe parser/lint guard runs pre-patch and post-patch.
- Confirm SIN rule mapping exists for each K-condition decision.
- Confirm escalation payload includes redacted evidence and reproducible context.
- Confirm audit trail captures who approved, what changed, and why.
- Confirm rollback pointer is generated for every approved protected-path mutation.

## 2) Threat Model Summary

- Assets:
  - Governance configs, canonical path registry, pipeline control files, security policy mappings.

- Trust boundaries:
  - Auto-correct engine output vs. protected repository assets.
  - Machine-generated recommendations vs. human approval authority.

- Entry points:
  - Auto-correct proposal ingestion, finding comparison artifacts, policy evaluation layer.

- Primary abuse/failure paths:
  - Infinite/no-progress correction loops.
  - Unsafe write attempts to governance-critical files.
  - Non-PS5.1-safe changes introduced by runtime drift.
  - Over-sharing sensitive evidence in escalation payloads.

- Current risk signal:
  - Stable 3 findings across staged passes; corrected=0 and escalated=3 indicates control plane is correctly resisting unsafe auto-write behavior but needs explicit stop/escalation tuning.

## 3) Findings (Critical to Low)

### High

- K5 loop-cap-no-progress condition is active for canonical-path governance file.
- Evidence: same staged finding set remains stable across three passes with zero correction progress.
- Impact: repeated compute cycles, delayed remediation, and potential policy fatigue without improved outcome.

### Medium

- Escalation behavior is functioning (escalated=3), but threshold tuning appears too permissive before stop.
- Impact: unnecessary pass churn before predictable escalation.

### Low

- No indication of unauthorized protected-path writes in current staged state.
- Residual concern: payload redaction rules must be strict to avoid leaking sensitive path/context metadata.

## 4) Recommended Fixes

### A) STOP-Condition Thresholds (K1-K6)

| Key | Recommended Threshold | Rationale |
| --- | ---: | --- |
| K1: Pass convergence stall | Stop after 2 consecutive passes with no net finding reduction | Prevents low-value repeat cycles while allowing one retry for transient variance |
| K2: Fingerprint stability | Escalate when >=90% finding fingerprints are unchanged across 3 passes | High-confidence non-progress signal for deterministic findings |
| K3: Auto-correct effectiveness floor | Stop and escalate if corrected=0 and escalated>=1 in same cycle | Immediate fail-fast when correction efficacy is null |
| K4: Protected-path touch attempt | Immediate stop on first unapproved write attempt | Enforces governance-first controls and least privilege |
| K5: Loop cap per finding/path | Max 3 attempts per finding-path per run; auto-escalate on cap hit | Bounded retries reduce churn and prevent endless loops |
| K6: Runtime safety gate (PS5.1) | Immediate stop if patch includes non-PS5.1-safe syntax/cmdlets/types | Prevents runtime incompatibility regressions and deployment breakage |

Recommended default policy: `K4/K6 hard-stop`, `K1/K2/K5 bounded-stop`, `K3 fail-fast`.

### B) Protected Path / Governance Policy

- Define path tiers:
  - Tier 0 (immutable without approval): governance configs, canonical path registry, security policies, pipeline gate logic.
  - Tier 1 (restricted): automation scripts that affect gate outcomes.
  - Tier 2 (standard): non-governance docs/reports.

- Enforce allow-list writes:
  - Auto-correct may write Tier 2 only by default.
  - Tier 0 and Tier 1 require signed approval state and reviewer identity.

- Require dual control for Tier 0:
  - One technical approver + one governance/security approver.

- Add mandatory intent label on each proposed change:
  - `format-only`, `policy-impacting`, `runtime-impacting`, `security-impacting`.

- Block downgrade operations:
  - Any proposal reducing validation strength or widening protected-path write scope must auto-escalate.

### C) Approval Escalation Payload (Minimum Required Fields + Redaction)

Minimum fields:

- `action_id` (unique)
- `timestamp_utc`
- `project_phase` (Phase 1)
- `run_id` / `pass_id`
- `runtime_target` (`PS5.1-safe`, optional `PS7.6-validated`)
- `finding_fingerprint_set` (stable IDs)
- `k_condition_triggered` (K1-K6 with reason)
- `artifact_refs` (report identifiers/paths)
- `proposed_change_summary` (no raw secrets)
- `protected_path_tier`
- `risk_rating` (severity + likelihood)
- `requested_approval_role(s)`
- `rollback_reference`
- `sin_rule_mapping`
- `decision_deadline`

Redaction guidance:

- Never include secrets, tokens, cert private keys, or raw credentials.
- Mask host/user identifiers where not required for approval decision.
- Hash sensitive snippets; include only minimal context lines.
- Keep absolute local paths out of external payloads; use normalized internal IDs.
- Attach full evidence only in restricted audit store, not in broad reviewer channels.

## 5) Validation Plan

- Run deterministic replay on staged pass data to verify K1/K2/K5 trigger consistency.
- Execute negative tests:
  - Simulate protected-path write without approval and verify K4 hard-stop.
  - Inject PS5.1-incompatible syntax and verify K6 hard-stop.
- Execute escalation payload schema validation and redaction checks.
- Verify SIN rule mapping is present for every stop/escalate outcome.
- Confirm audit log integrity: start event, stop/escalate decision, reviewer action, final resolution.
- Perform dual-runtime smoke check:
  - Primary enforcement in PS5.1-safe mode.
  - Optional parity validation in PS7.6 for forward compatibility.

## 6) Residual Risk and Next Controls

- Residual risk:
  - Continued non-progress on the same governance file until manual decision is made.
  - Human approval latency can delay remediation turnaround.

- Next controls:
  - Add automatic repeat-finding cooldown to suppress redundant retries after K5 hit.
  - Add mandatory justification template for approving Tier 0 changes.
  - Add weekly threshold review using observed precision/recall of escalations.

### Immediate Next Actions (Implementation Team)

1. Implement K1-K6 thresholds exactly as listed, with K4/K6 hard-stop precedence.
2. Add Tier 0/1/2 protected-path classification and enforce allow-list write policy.
3. Wire fail-fast on `corrected=0` + any escalation in cycle (K3).
4. Add per finding-path retry counter and cap at 3 attempts (K5).
5. Add PS5.1 compatibility validator as mandatory pre-merge gate check.
6. Implement escalation payload schema with required fields and validation.
7. Add redaction middleware before payload persistence/transmission.
8. Add dual-approval requirement for Tier 0 change requests.
9. Add deterministic fingerprint regression test for staged pass comparison logic.
10. Run a controlled dry-run on current staged artifacts and publish approval-ready escalation packet.
