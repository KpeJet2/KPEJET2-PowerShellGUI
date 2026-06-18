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
