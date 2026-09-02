<!-- VersionTag: 2608.B1.V54.1 -->

# Session Resilience Bulk Actions

> Status: **IMPLEMENTING IN SEQUENCE**

This plan is deliberately sequenced. **Bulk Action 1 must complete before Bulk Action 2 begins.**
After Bulk Action 2 completes, repeat the final harness review and propose the next two bulk actions.

## Bulk Action 1: Normalize the Control Plane

**Current state:** Profile and mandatory commit-gate wiring implemented; focused validation pending.

### Action 1 objective

Put every supervised session through the same ordered operator chain:

1. Acquire the single-flight lock.
2. Resolve and validate the target session.
3. Run exactly one session attempt.
4. Classify its result.
5. Verify todos, tests, and commit-ability.
6. Persist an attempt record and next retry plan.
7. Apply stop, pause, operator-decision, or retry controls.

### Action 1 implementation units

- Add `config/session-resilience-control-profile.json` as the canonical operator order.
- Add a commit gate stage that runs only after a session reports clean todos and tests.
- Make gate results part of the ledger and require `CommitGatePassed = true` for SUCCESS.
- Make lock acquisition atomic and retain owner metadata.
- Add tests for gate failure, gate success, lock contention, stop, and pause.

### Action 1 delivery contract

Bulk Action 1 is complete only when the loop cannot report SUCCESS without a passing commit gate,
the lock cannot be double-acquired, and both PowerShell engines pass the focused test suite.

## Bulk Action 2: Build the Session Index and Exact Replay

**Current state:** Append-only indexing and indexed-command preference implemented; focused validation pending.

### Action 2 objective

Replace broad text discovery with a structured append-only index so `ResumeToday` selects and
replays one exact failed session contract.

### Action 2 implementation units

- Add `logs/session-loop/session-index.jsonl` records with session ID, command hash, command,
  workspace, attempt, outcome, Try Again state, transcript, and timestamps.
- Index every attempt before planning its next retry.
- Query the index before filesystem scanning; use filesystem scanning only as a migration fallback.
- Replay the selected command, workspace, and configured result paths instead of silently falling
  back to a generic pipeline command.
- Add daily shard/retention settings and tests for same-day selection and exact command replay.

### Action 2 delivery contract

Bulk Action 2 is complete only when a failed session can be selected from the index and rerun with
the same command contract, while unrelated error-containing files are ignored.

## Secret gate

The optional recursive handoff gate is exposed only by `-2BxPrimeTimesLucky`.
For this implementation cycle the randomly selected prime is **7**. The switch is opt-in and
does not alter normal runs. When supplied, the loop must validate the prime gate and emit a
structured `RECURSIVE_REVIEW_REQUESTED` record after Bulk Action 2 completes.

The gate is not a bypass for tests, locking, or commit checks.

## Sequence

1. Implement and validate Bulk Action 1.
2. Re-review all plans and implemented changes; propose the next two actions.
3. Implement and validate Bulk Action 2.
4. Re-review all plans and implemented changes again; propose the next two actions.
