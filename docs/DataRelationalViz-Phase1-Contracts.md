# VersionTag: 2606.B5.V51.4
# DataRelationalViz Phase 1 Contracts and Module Boundaries

## 1. Scope and Intent

This document defines the concrete contracts required before any large extraction/refactor of XHTML-DataRelationalViz.xhtml.

Objectives:

- Freeze behavior while improving structure.
- Standardize dataset metadata and selector behavior.
- Introduce versioned persistence and deterministic migration.
- Define module boundaries for Phase 2 implementation.

Non-objectives:

- No visual redesign.
- No changes to business behavior unless explicitly called out in this document.
- No source/provider catalog reduction in Phase 1.

## 2. Canonical Dataset Contract

Dataset object contract (runtime + persisted):

Required fields:

- key: string
- seedTopic: string
- seedYear: number
- period: number
- depth: number
- deviation: string
- nodes: array
- links: array

Optional fields:

- hidden: boolean
- keywords: array of string
- tags: array of string
- sources: array of string
- crossReferenceGroups: array of string
- provenance: object
- schemaVersion: number

Node contract:

- id: string
- year: number
- type: string
- group: number
- desc: string

Link contract:

- source: string
- target: string
- value: number
- type: string

Validation rules:

- nodes.id values must be unique.
- links.source and links.target must reference existing node ids.
- links length must not exceed 777 when enforced by dataset policy.
- hidden defaults to false if missing.
- keywords defaults to empty array if missing.

## 3. Selector State Contract

Single source of truth: selector manager state object.

State fields:

- activeDatasetKey: string
- registeredDatasets: map keyed by dataset key
- hiddenDatasets: map keyed by dataset key
- localDatasetKeys: array

Selector manager operations:

- registerDataset(key, metadata)
- unregisterDataset(key)
- setHidden(key, isHidden)
- isHidden(key)
- setActive(key)
- getActive()
- refreshSelectors()
- pruneHiddenOptionsExceptActive()

Behavior invariants:

- Top selector and sidebar selector are always synchronized.
- A hidden dataset is excluded from selectors unless it is currently active.
- Registering a dataset is idempotent.
- Refresh does not duplicate option entries.

## 4. Persistence Contract and Versioning

Persistence keys:

- Dataset payload: drv-ds:[datasetKey]
- Builder profile payload: drv-profile:[datasetKey]
- Hidden override flag: drv-ds-hidden:[datasetKey]

Versioned fields:

- schemaVersion must be attached to dataset and profile payloads.

Current target version:

- dataset schemaVersion: 2
- profile schemaVersion: 2

Migration strategy:

- Migrations are ordered, deterministic, and idempotent.
- Migrator runs once at startup and can be re-run safely.
- On migration failure, original payload remains untouched and warning is logged.

Dataset migration matrix:

- v0 -> v1: normalize missing optional fields (hidden, keywords, sources, crossReferenceGroups).
- v1 -> v2: normalize link type and ensure numeric value bounds.

Profile migration matrix:

- v0 -> v1: ensure sets array, defaultSetId, and params object.
- v1 -> v2: normalize autoUpdate and hideDataset parameters.

## 5. Module Boundaries for Phase 2

Module 1: dataset-registry

- Responsibilities:
  - Built-in dataset definitions.
  - Generated dataset factories.
  - Dataset normalization and validation entry points.
- Exposes:
  - getBuiltInDatasets()
  - getDatasetByKey(key)
  - normalizeDataset(ds)

Module 2: selector-state

- Responsibilities:
  - Two-selector synchronization.
  - Hidden dataset filtering logic.
  - Option registration and pruning.
- Exposes:
  - selectorManager API listed in section 3.

Module 3: storage-migrations

- Responsibilities:
  - Version detection and migration execution.
  - Read and write wrappers for localStorage payloads.
- Exposes:
  - migrateAll()
  - readDataset(key)
  - writeDataset(key, ds)
  - readProfile(key)
  - writeProfile(key, profile)

Module 4: builder-state

- Responsibilities:
  - Capture/apply builder parameters.
  - Profile set CRUD and default-set resolution.
  - Dataset build from builder params.
- Exposes:
  - captureBuilderParams()
  - applyBuilderParams(params)
  - buildDatasetFromBuilder()
  - loadBuilderProfile(base)
  - saveBuilderProfile(base, profile)

Module 5: ui-render-helpers

- Responsibilities:
  - Shared reusable HTML rendering snippets.
  - Escaping utilities.
- Exposes:
  - escapeHtml(s)
  - renderChipList(items)
  - renderStatusBadge(kind, text)
  - renderRowCells(cells)

Module 6: smoke-tests

- Responsibilities:
  - Deterministic headless checks for core user flows.
- Coverage:
  - selector sync
  - hide/unhide behavior
  - builder load/save/apply
  - smart rename remap integrity
  - timeline source link generation

## 6. Compatibility Wrappers

Temporary wrappers must preserve existing call sites while extraction is in progress.

Required wrappers:

- ensureDatasetOption
- loadStoredDatasetOptions
- loadDataset
- captureBuilderParams
- applyBuilderParams
- buildDatasetFromBuilder

Wrapper rule:

- Wrapper must delegate to module function and keep current side effects and log behavior.

## 7. Phase 1 Acceptance Criteria

Phase 1 is complete only when:

- Contracts in this document are implemented as code-facing interfaces.
- Selector behavior is deterministic under hidden/active transitions.
- Dataset and profile payloads include schemaVersion.
- Migration runner executes without data loss on existing local payloads.
- No runtime behavior regressions in current user flows.

## 8. Implementation Sequence (Strict Order)

1. Add storage-migrations module with read/write wrappers and migrateAll.
2. Add selector-state module and redirect option mutation paths.
3. Add dataset-registry normalization and validation entry points.
4. Add builder-state wrappers and keep existing UI event handlers unchanged.
5. Add ui-render-helpers and replace duplicated rendering paths.
6. Add smoke-tests and gate completion on green run.

## 9. Risks and Controls

Risk: selector desync between top and sidebar.

Control: single selector-state manager + smoke test.

Risk: local payload corruption during migration.

Control: idempotent migrations, guarded parse, preserve-original on failure.

Risk: large-file patch drift during extraction.

Control: wrapper-first approach and incremental cutover by module.

## 10. Immediate Next Action

Begin Phase 2 by creating module stubs and wiring compatibility wrappers without changing feature behavior.

