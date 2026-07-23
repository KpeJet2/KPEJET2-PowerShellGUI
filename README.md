# PowerShellGUI Documentation Hub

VersionTag: 2605.B5.V51.1

This workspace now includes a dedicated list generation and regeneration system with Mermaid vector diagrams, functional mapping, iconography catalogs, and scheduled list runs.

## Quick Links

- docs/README-LISTGENE.md
- docs/LISTS-SYSTEMATIC-INDEX.md
- docs/LISTS-SYSTEM-OBSERVED.md
- docs/LISTS-GLOBAL-SEQUENTIAL.md
- docs/LISTS-UNIVERSAL-LIST-GENE.md

## ListGene Runtime Assets

- scripts/Invoke-UniversalListGene.ps1
- config/listgene/global-list-set.json
- config/listgene/queries/
- reports/listgene/

## Core Commands

```powershell
pwsh -NoProfile -File .\scripts\Invoke-UniversalListGene.ps1 -Build -OutputFormat Markdown -OutputPath docs/LISTS-SYSTEMATIC-INDEX.md
```

```powershell
pwsh -NoProfile -File .\scripts\Invoke-UniversalListGene.ps1 -RunQuery -Query "icon|emoji|rune" -UseRegex -SaveQuery -QueryName symbols-scan -OutputFormat Markdown -OutputPath docs/LISTS-UNIVERSAL-LIST-GENE.md
```

```powershell
pwsh -NoProfile -File .\scripts\Invoke-UniversalListGene.ps1 -RegisterSchedule -TaskName "PwShGUI-ListRun-Scheduler" -DailyAt "02:00" -ScheduledOutputFormat Markdown -ScheduledOutputPath reports/listgene/listgene-nightly.md
```

## Continuous Refinement Loop

- Path reconciliation and drift scan:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -WorkspacePath . -UpdateReadme -BaselineProfile full -BaselineJson .\config\pipeline-refine-baseline-full.json -FailOnDrift
```

- Fast pre-commit drift scan (staged files only):

```powershell
pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -WorkspacePath . -StagedOnly -BaselineProfile staged -BaselineJson .\config\pipeline-refine-baseline-staged.json -FailOnDrift
```

- Baseline refresh after intentional improvement:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -WorkspacePath . -BaselineProfile full -UpdateBaseline -BaselineJson .\config\pipeline-refine-baseline-full.json
```

- README managed index refresh only:

```powershell
pwsh -NoProfile -File .\scripts\Sync-ReadmeFeatureIndex.ps1 -WorkspacePath .
```

- Canonical registry validation:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-ValidateCanonicalPaths.ps1 -WorkspacePath . -RegistryPath .\config\pipeline-canonical-paths.json -FailOnMissing
```

- SIN scanner canonical path (restored):

```powershell
pwsh -NoProfile -File .\tests\Invoke-SINPatternScanner.ps1 -WorkspacePath . -Runtime Both -OutputJson .\reports\sin-scan-permissive.json
```

- JUnit converter canonical path (restored):

```powershell
pwsh -NoProfile -File .\tests\Convert-SinScanToJUnit.ps1 -ScanJson .\reports\sin-scan-permissive.json -OutputXml .\reports\sin-scan-junit.xml
```

The README now contains a managed auto-generated section delimited by markers.
Do not hand-edit text between markers; run Sync-ReadmeFeatureIndex to refresh it.

## Log Layout

- Runtime script-execution logs are written under logs/script-exec/.
- Historical root-level logs are migrated into logs/script-exec/legacy-root/.
- Pipeline and engine logs remain under logs/ subfolders such as logs/archive/, logs/engine-instances/, and logs/automated-pipe/.
- The pre-commit pipeline includes a log-drift guard that blocks new root-level .log files and stale viewer log references.

<!-- AUTO-GENERATED:FEATURE-INDEX:START -->

## Managed Feature Index

Generated: 2026-07-23 23:40:14 +08:00

### Workspace Metrics

- Scripts (.ps1): 171
- Modules (.psm1): 55
- Tests (.ps1): 57
- Pages (.xhtml/.html): 3

### Canonical Pipeline Paths

- tests/Invoke-SINPatternScanner.ps1
- tests/Convert-SinScanToJUnit.ps1
- scripts/Invoke-PipelineContinuousRefine.ps1
- scripts/Invoke-ValidateCanonicalPaths.ps1
- scripts/Sync-ReadmeFeatureIndex.ps1
- scripts/Invoke-ReferenceIntegrityCheck.ps1
- scripts/Invoke-VersionAlignmentTool.ps1
- config/pipeline-canonical-paths.json
- config/pipeline-refine-allowlist.json
- config/pipeline-refine-severity-policy.json
- config/pipeline-refine-baseline-full.json
- config/pipeline-refine-baseline-staged.json
- config/pipeline-refine-baseline-nightly.json

### Continuous Refinement Commands

```powershell
pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -UpdateReadme -BaselineProfile full -BaselineJson .\config\pipeline-refine-baseline-full.json -FailOnDrift
pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -StagedOnly -BaselineProfile staged -BaselineJson .\config\pipeline-refine-baseline-staged.json -FailOnDrift
pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -BaselineProfile nightly -BaselineJson .\config\pipeline-refine-baseline-nightly.json -FailOnDrift
pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -BaselineProfile full -UpdateBaseline -BaselineJson .\config\pipeline-refine-baseline-full.json
pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -StagedOnly -BaselineProfile staged -UpdateBaseline -BaselineJson .\config\pipeline-refine-baseline-staged.json
pwsh -NoProfile -File .\scripts\Invoke-PipelineContinuousRefine.ps1 -BaselineProfile nightly -UpdateBaseline -BaselineJson .\config\pipeline-refine-baseline-nightly.json
pwsh -NoProfile -File .\scripts\Invoke-ValidateCanonicalPaths.ps1 -FailOnMissing -RegistryPath .\config\pipeline-canonical-paths.json
pwsh -NoProfile -File .\tests\Invoke-SINPatternScanner.ps1 -WorkspacePath . -Runtime Both -OutputJson .\reports\sin-scan-permissive.json
pwsh -NoProfile -File .\scripts\Invoke-ReferenceIntegrityCheck.ps1
```

### Governance Tightening Notes

- Duplicate-function allowlist now supports metadata entries with name, owner, expiresOn, and reason.
- Expired allowlist entries are raised as HIGH findings in refinement scans.
- Refinement trend outputs include a 7-day rollup file: reports/pipeline-refine/pipeline-refine-weekly-rollup.md.
- CI includes refine script smoke coverage on both pwsh and powershell engines.

<!-- AUTO-GENERATED:FEATURE-INDEX:END -->

