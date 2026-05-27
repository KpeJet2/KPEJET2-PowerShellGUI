---
description: "Use when working in PowerShellGUI to enforce PS7.6-first engineering, PS5.1-safe fallback patterns, dual-engine smoke testing, and SIN governance with integrity audit controls."
applyTo: "**/*.{ps1,psm1,psd1,bat,cmd,json,yaml,yml,md,xhtml,html,js,ts,css}"
---
<!-- VersionTag: 2605.B5.V46.0 -->
# Sin-Ai-Voidance (PS7.6 Primary, PS5.1 Fallback)

Follow these hard rules whenever creating or editing files in this workspace.

## Runtime Baseline

- Primary support target is PowerShell 7.6+ for all new and refactored code.
- Backward compatibility target is PowerShell 5.1 using explicit fallback patterns.
- Modules may require PS7.6+ for optimal behavior; when PS7.6+ is not present, recommend installation and continue with best-effort PS5.1-safe behavior.
- Do not ship engine-specific behavior without an explicit compatibility guard or documented minimum runtime.

## Dual-Engine Test Gate

- Smoke tests must pass on both engines: PS7.6+ (primary) and PS5.1 (fallback).
- Test output should identify engine version and highlight any fallback path activation.
- A change is not release-ready if PS7.6 passes but PS5.1 fallback smoke tests regress without documented exemption.

## Core SIN Rules (Blocking)

- P001: No hardcoded credentials, tokens, or secrets.
- P002: No empty catch blocks; always log or provide intentional non-fatal rationale.
- P003: No Import-Module with SilentlyContinue; use try/catch with explicit logging.
- P004: Wrap Count access with @() to avoid null enumeration failures.
- P005: PS7-first allowed, but every PS7-only construct must have a PS5.1-safe fallback path or compatibility gate.
- P006: Files with non-ASCII content must be UTF-8 with BOM.
- P007: Scripts and modules must include VersionTag metadata.
- P009: Validate paths before Join-Path or manual path composition.
- P010: No Invoke-Expression for dynamic execution.
- P011: No duplicate function names across loaded modules.
- P012/P017/P019: Always specify -Encoding on Set-Content, Out-File, and Add-Content.
- P014: Always use ConvertTo-Json -Depth when serializing nested data.
- P015: No hardcoded absolute workspace paths.
- P016: No stale TODO/FIXME/HACK markers in finalized changes.
- P018: Keep Join-Path usage PS5.1-safe (max 2 args; nest where needed).
- P020: No SSL certificate validation bypass.
- P021: Guard all division operations against zero.
- P022/P027: Guard nulls before method calls and array indexing.
- P028: Avoid inline switch-expression usage that breaks PS5.1 parsing without guarded alternatives.
- P029: Protect event handlers against null and scope bleed failure modes.
- P030: Avoid unapproved verb aliases in exported/public module commands.

## SIN Definition Lifecycle (Severity + Frequency Driven)

- New SIN patterns must be derived from assessed changelog issues and scanner output.
- Prioritize new SIN definitions by combined severity and occurrence frequency.
- Promote repeat offenders from advisory to blocking when recurrence remains high.
- Retire or merge low-value overlapping SIN patterns to reduce scan overhead and false positives.

## Performance, Storage, and Redundancy

- Optimize SIN registry payload size: avoid duplicated large fields, normalize repeated metadata, and keep concise canonical records.
- Preserve integrity redundancy with lightweight manifest summaries rather than full duplicate payload copies.
- Keep audit artifacts compact but reproducible: deterministic field order, stable identifiers, and minimal noise fields.

## Integrity Assurance for SIN Manifests

- Every manifested SIN item should be hash-tracked (for example SHA-256) and included in integrity verification.
- Where signing is configured, sign SIN manifests and verify signatures in audit mode.
- Integrate SIN manifest verification into the workspace security integrity assessment flow.
- Audit mode must report hash/signature verification status and mismatches as actionable findings.

## Enforcement

- If a rule requires exception handling, document the reason, scope, and expiration, then request approval before merge.

## AI Action Logging

- Before any AI or agent changes workspace files, write a `start` record by using `Write-AiActionStart` from `modules/PwShGUI-AiActionLog.psm1`.
- After the change completes, fails, or is cancelled, write a `finish` record by using `Write-AiActionFinish` and include the final touched-file list.
- If AI-action logging fails, write a `logging-error` record with the failure reason.
- Touched files must be logged with change kinds `created`, `modified`, `deleted`, or `unknown`.
- Canonical live logs are `logs/ai-actions/live/*.jsonl`, test logs are `logs/ai-actions/test/*.jsonl`, and the viewer summary source is `~REPORTS/ai-actions/ai-actions-summary.json`.
