# VersionTag: 2606.B5.V51.4
# SIN Chat Issue Batch (2026-05-23)

This short batch captures the failure modes observed in this chat session and maps each to a scan pattern plus a fast remediation path.

## Run Batch

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-ChatIssueSinBatch.ps1 -Runtime Both

# Fast scoped run (only changed files)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-ChatIssueSinBatch.ps1 -Runtime Both -IncludeFiles Main-GUI.ps1 scripts\Invoke-ChatIssueSinBatch.ps1
```

## Pattern Set and Quick Solutions

| Pattern | Why it is in this batch | Short solution |
| --- | --- | --- |
| P006 | BOM-less scripts with non-ASCII bytes can break PS5 parsing | Save file as UTF-8 with BOM when Unicode exists |
| P022 | Null-valued method call caused GUI creation failure | Add explicit null guards before method/property access |
| P023 | Mojibake byte sequences cause parser drift and bad tokens | Repair encoding path and validate parser after rewrite |
| P039 | BOM round-trip through Win-1252 can inject leading '?' | Strip BOM before legacy round-trip; restore BOM only at final write |
| P063 | Typed catch for PipelineStoppedException can bypass in delegates | Use bare catch with explicit type checks inside |
| P068 | Script-scope Controls.Add without nearby guard in closures | Capture local ref and guard ref + .Controls before Add() |
| P069 | Replacement char indicates source corruption | Restore known-good bytes and re-save with correct encoding |

## New Pattern Files Added

- sin_registry/SIN-PATTERN-068-SCRIPTSCOPE-CONTROLSADD-NOGUARD_20260523.json
- sin_registry/SIN-PATTERN-069-UNICODE-REPLACEMENT-CHAR-SOURCE_20260523.json

## Notes

- This batch is intentionally small and targeted for fast triage.
- Keep these scans in CI for regressions after bulk rewrites, GUI refactors, and codegen edits.

