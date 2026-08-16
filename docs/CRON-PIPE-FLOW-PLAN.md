<!-- VersionTag: 2608.B1.V54.1 -->
<!-- FileRole: PlanHandoff -->
<!-- SchemaVersion: CronPipeFlow/1.0 -->

# Cron-Pipe-Flow Implementation Plan and Handoff

## Goal

Add a Pipeline Flow Graph gate that generates a canonical process-flow model from the current workspace state, blocks completion and commit when drift or gate failures exist, and publishes the result to a new viewer page named `XHTML-Cron-Pipe-Flow.xhtml`.

The new tool must include:

- Nested menu blades.
- A collapsible process tree.
- Search and filters for process functions, terms, and flow paths.
- Dynamic generation after test gates pass and issues are resolved.
- Cross-links to README, tool pages, standards, manifests, history, logging, and glossary/index entries.

## Verified Source Grounding

- Orchestrated pipeline runner with fail-fast behavior exists in [scripts/Run-FullPipeline.ps1](scripts/Run-FullPipeline.ps1#L147).
- Full test gate already blocks progress in [scripts/Run-FullPipeline.ps1](scripts/Run-FullPipeline.ps1#L196).
- Nested gate contract pattern (`-AsObject`, `Checks`, PASS/FAIL rollup) exists in [scripts/Run-FullPipeline.ps1](scripts/Run-FullPipeline.ps1#L93).
- Pre-commit gate architecture and findings rollup exist in [tests/Invoke-PreCommitValidation.ps1](tests/Invoke-PreCommitValidation.ps1#L1142).
- Canonical path registry is active in [config/pipeline-canonical-paths.json](config/pipeline-canonical-paths.json).
- Drift and baseline pattern is established via refine scripts and tasks in [config/pipeline-refine-baseline-full.json](config/pipeline-refine-baseline-full.json) and [.vscode/tasks.json](.vscode/tasks.json).
- XHTML payload injection and JS-safe escaping pattern exists in [scripts/Sync-ChangelogViewerData.ps1](scripts/Sync-ChangelogViewerData.ps1#L28).
- Tool registration pattern exists in [XHTML-WorkspaceHub.xhtml](XHTML-WorkspaceHub.xhtml#L1009).

## Existing Diagrams

- Architecture diagram: [docs/diagrams/cron-pipe-flow-architecture.mmd](docs/diagrams/cron-pipe-flow-architecture.mmd)
- Gate sequence diagram: [docs/diagrams/cron-pipe-flow-gate-sequence.mmd](docs/diagrams/cron-pipe-flow-gate-sequence.mmd)

## Architecture Summary

Flow chain:

1. Source scripts, config, manifests, and SIN registry are parsed.
2. Extractor module builds a canonical graph model.
3. Flow gate compares graph output to baseline and viewer sync state.
4. On pass, generator injects data into the XHTML tool.
5. On drift with strict mode, completion and commit are blocked.

Gate position:

- Add main pipeline flow-gate after blocking test gates pass and before completion/commit path.
- Add pre-commit verify-only gate that confirms generated artifacts are current.

## Canonical Data Model

Primary artifact:

- `config/pipeline-flow-graph.json`

Supporting artifacts:

- `config/pipeline-flow-baseline.json`
- `config/pipeline-flow-sources.json`

Schema design:

- `SchemaVersion`, `VersionTag`, `generatedAtUtc`, `generatedBy`
- `graphHash` (deterministic hash excluding volatile fields)
- `sourceHashes`
- `blades[]` for nested menu structure
- `nodes[]` for scripts, gates, stages, functions, artifacts
- `edges[]` for execution and linkage semantics
- `glossary[]` for searchable index terms
- `crossRefs` for canonical paths, baselines, task links
- `stats` for counts and orphan tracking

Node conventions:

- Stable deterministic IDs, for example `node.runfullpipeline.step5`.
- Every node must include at least one cross-link entry.
- Search corpus includes label, id, source file, function, and terms.

## Deliverables

Core implementation deliverables:

- `modules/PwShGUI-PipelineFlowGraph.psm1`
- `scripts/Invoke-PipelineFlowGraphGate.ps1`
- `scripts/Sync-CronPipeFlowViewerData.ps1`
- `XHTML-Cron-Pipe-Flow.xhtml`
- `config/pipeline-flow-graph.json`
- `config/pipeline-flow-baseline.json`
- `config/pipeline-flow-sources.json`

Pipeline and governance wiring:

- Edit `scripts/Run-FullPipeline.ps1` to add post-test flow gate and viewer sync step.
- Edit `tests/Invoke-PreCommitValidation.ps1` to add FlowGraph verify-only gate.
- Edit `config/pipeline-canonical-paths.json` to register new required paths.
- Edit `.vscode/tasks.json` for flow-gate run and baseline update tasks.

Tool discoverability and documentation:

- Edit `XHTML-WorkspaceHub.xhtml` with a new tool card entry.
- Edit `README.md` with a Cron-Pipe-Flow section and run instructions.
- Edit `~README.md/CHANGELOG.md` and `~README.md/ENHANCEMENTS-LOG.md`.

Validation:

- Add `tests/PipelineFlowGraph.Tests.ps1`.
- Add `tests/CronPipeFlowViewer.Tests.ps1`.

## Implementation Phases

### Phase 0: Scaffold and checkpoint

- Create source config and baseline placeholders.
- Checkpoint before edits and after scaffold.
- Confirm canonical path validation still passes.

### Phase 1: Extractor module

- Implement AST-based discovery of pipeline steps, gate functions, and script invocations.
- Build deterministic node and edge lists.
- Export canonical graph JSON and hash.

### Phase 2: Flow gate script

- Implement gate modes: normal, verify-only, fail-on-drift, update-baseline.
- Return `Checks[]` object contract for nested-gate integration.
- Write report artifact and gate log.

### Phase 3: Viewer sync generator

- Inject `FLOW_GRAPH_DATA` and `FLOW_GRAPH_HASH` into XHTML safely.
- Reuse one-pass escape strategy and control-byte sanitization pattern.
- Do no-op when payload is unchanged.

### Phase 4: XHTML tool

- Build nested blade navigation, collapsible process tree, and node details pane.
- Add search with token filters:
  - `kind:<value>`
  - `blade:<id>`
  - `status:<value>`
  - `blocking:true|false`
  - `term:<value>`
- Add glossary blade with term-to-node navigation.

### Phase 5: Pipeline and pre-commit wiring

- Insert flow gate after successful test gates in full pipeline script.
- Add pre-commit stale-artifact check as a blocking gate.
- Register new paths and tasks.

### Phase 6: Testing and hardening

- Validate schema, determinism, drift detection, and hash consistency.
- Validate XHTML parseability and payload/hash synchronization.
- Run Pester and SIN scans across PS7 and PS5.1 paths.

### Phase 7: Docs and release handoff

- Update hub entry, README, changelog, and enhancements log.
- Confirm acceptance criteria and checkpoint logs.

## Cross-Link Coverage Matrix

Each graph node should provide explicit links in `links[]` for at least one of the following categories:

- `readme`: `README.md`
- `tool`: `XHTML-PipelineManager.xhtml`, `XHTML-SIN-Scoreboard-LIVE.xhtml`, `XHTML-DependencyMapR2-CORTIX.xhtml`, `XHTML-ChangelogViewer.xhtml`
- `standard`: `~README.md/DOC-ICON-STANDARD.md` and related standards documents
- `manifest`: `config/dynamic-manifest.json`, `config/agentic-manifest.json`
- `history`: `~README.md/CHANGELOG.md`, `~README.md/ENHANCEMENTS-LOG.md`
- `log`: `logs/pipeline-flow-gate.log`, `reports/pipeline-flow-gate/latest.json`
- `sin`: `sin_registry/`

The glossary blade must index terms and back-link to all related nodes.

## Risks and Mitigations

- Drift false positives from non-deterministic output.
  - Mitigation: canonical sort order and stable hashing rules.
- Viewer payload breakage from escaping defects.
  - Mitigation: reuse proven escape path and validate JSON round-trip.
- Gate blocks legitimate evolution.
  - Mitigation: explicit `-UpdateBaseline` flow and audited bypass switch.
- PS version regressions.
  - Mitigation: dual-engine test routine in gating acceptance.

## Acceptance Criteria

All criteria must be true before completion:

- Flow gate passes with all checks in PASS state.
- Two consecutive generation runs produce identical `graphHash`.
- Intentional drift triggers expected block in strict mode.
- Baseline update clears intentional drift cleanly.
- Viewer renders nested blades, tree collapse, and search/filter correctly.
- Viewer payload hash matches canonical graph hash.
- Canonical path validation includes all new files.
- SIN scan reports no new blocking patterns.
- Pester suite passes in both PS7 path and PS5.1 fallback path.
- README, hub tool listing, changelog, and enhancements entries are present.

## Agent Handoff Contract

Execution ownership:

1. `FocalPoint-null-00`: orchestration and acceptance.
2. `Code-A-planR`: source config and execution map curation.
3. `Code-B-iSmuth`: module/script/XHTML implementation.
4. `Code-B-Tsted`: dual-engine tests, trace, and evidence.
5. `ProxySecurity`: security review for injection and path/input boundaries.

Phase evidence requirements:

- Every phase writes a checkpoint.
- Every phase includes proving command output.
- Any repeated failure (same root cause twice) escalates to orchestrator with gate report and failing checks.

## Proving Commands for Completion

Run and attach outputs for:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/Invoke-ValidateCanonicalPaths.ps1 -WorkspacePath . -RegistryPath config/pipeline-canonical-paths.json -FailOnMissing`
- `pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path './tests' -Output Detailed"`
- `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path './tests' -Output Detailed"`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-SINPatternScanner.ps1 -WorkspacePath . -Runtime Both`

Completion is blocked until all proving commands pass and artifacts are synchronized.
