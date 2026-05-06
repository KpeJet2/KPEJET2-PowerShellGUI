# VersionTag: 2605.B2.V31.7
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.0 -Force

# Run the most stable Pester suites - the SIN-pattern tests which are self-contained.
$tests = @(
    'C:\PowerShellGUI\tests\SIN-P027-NullArrayIndex.Tests.ps1',
    'C:\PowerShellGUI\tests\SIN-P041-JsonSchemaPropertyDrift.Tests.ps1'
)
$cfg = New-PesterConfiguration
$cfg.Run.Path = $tests
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Normal'
$res = Invoke-Pester -Configuration $cfg
"---"
"Passed:  $($res.PassedCount)"
"Failed:  $($res.FailedCount)"
"Skipped: $($res.SkippedCount)"
"Total:   $($res.TotalCount)"
if ($res.FailedCount -gt 0) { exit 1 } else { exit 0 }

