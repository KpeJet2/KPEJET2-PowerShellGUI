# Pipeline Continuous Refine Report

Scan: PIPE-REFINE-20260723-235038
Timestamp: 2026-07-23T23:50:15.1713544+08:00
Profile: staged
StagedOnly: True
Staged File Count: 0
Total Findings: 3
Severity Counts: CRITICAL=0, HIGH=0, MEDIUM=3, LOW=0
Duplicate Function Groups: 0
Allowlisted Duplicate Groups: 0
Deprecated Reference Hits: 3
VersionTag Issues: 0
Dotfile Placement Issues: 0
README Markers Present: True
Registry Loaded: True
Registry Missing Paths: 0
Baseline Applied: True
Regression Count: 1
Improvement Count: 0

## Top Findings
- [MEDIUM] deprecated-reference: Deprecated path literal referenced: config/pipeline-refine-baseline.json | config/pipeline-canonical-paths.json
- [MEDIUM] deprecated-reference: Deprecated path literal referenced: .\config\pipeline-refine-baseline.json | config/pipeline-canonical-paths.json
- [MEDIUM] deprecated-reference: Deprecated path literal referenced: ${workspaceFolder}\config\pipeline-refine-baseline.json | config/pipeline-canonical-paths.json

## Regressions
- MEDIUM:deprecated-reference baseline=1 current=3 delta=2
