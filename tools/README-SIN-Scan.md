# PowerShellGUI CI: SIN Pattern Scan

> VersionTag: 2605.B5.V50.2

## Purpose

Run SIN scanners consistently in local and CI workflows to block regressions, track advisories, and keep reports aligned with Show-Online scan views.

## Primary Commands

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ./tools/Invoke-SINPatternScanner.ps1
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ./tools/Invoke-SemiSinPenanceScanner.ps1
```

## Related Scan Surfaces

- `scripts/Invoke-FullSystemsScan.ps1` orchestrates broad workspace scan coverage.
- `scripts/Invoke-DependencyScanManager.ps1` drives dependency-focused scanning.
- `scripts/Invoke-StaticWorkspaceScan.ps1` performs static workspace checks.
- `scripts/Invoke-SecretLeakScanner.ps1` performs secret-leak scans.
- `scripts/Invoke-OrphanedFileAudit.ps1` covers orphaned-file detection.
- `tests/Invoke-SecurityCodeScan.ps1` and `tests/Invoke-UIEventSafetyScan.ps1` provide test-scope security/safety scans.

## CI Example (GitHub Actions)

```yaml
- name: Run SIN Pattern Scanner
  run: pwsh -NoProfile -ExecutionPolicy Bypass -File ./tools/Invoke-SINPatternScanner.ps1

- name: Run Semi-SIN Scanner
  run: pwsh -NoProfile -ExecutionPolicy Bypass -File ./tools/Invoke-SemiSinPenanceScanner.ps1
```

## Report Paths

- `~REPORTS/SINScanner/`
- `~REPORTS/SIN-Scan/`
- `~REPORTS/sin-scan-bridge/`
- `~REPORTS/FullSystemsScan/`

Use these paths for scan trend review and Show-Online parity checks.
