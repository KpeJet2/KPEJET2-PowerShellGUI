# VersionTag: 2608.B1.V1.0
# SupportPS5.1: YES
# SupportsPS7.6: YES
# FileRole: Pipeline
<##
.SYNOPSIS
    Alpha-only autonomous commit and optional push prototype with soft-fail diagnostics.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true)][string]$CommitMessage,
    [switch]$Push,
    [switch]$AlphaSoftFail
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$WorkspacePath = (Resolve-Path -LiteralPath $WorkspacePath).Path
$diagnostic = Join-Path $WorkspacePath 'scripts\Invoke-GitCommitDiagnostic.ps1'

function Invoke-GitStep {
    param([string[]]$Arguments, [string]$Gate)
    $output = @(& git -C $WorkspacePath @Arguments 2>&1)
    $rc = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    if ($rc -ne 0) {
        & $diagnostic -WorkspacePath $WorkspacePath -Gate $Gate -ExitCode $rc -Message (($output | Out-String).Trim()) -OutputText (($output | Out-String).Trim()) -CommitCommand ('git ' + ($Arguments -join ' ')) -CreateBug2Fix -AlphaSoftFail:$AlphaSoftFail
    }
    return $rc
}

$stageRc = Invoke-GitStep -Arguments @('add','-A') -Gate 'alpha-git-add'
if ($stageRc -ne 0 -and -not $AlphaSoftFail) { exit $stageRc }
$commitRc = Invoke-GitStep -Arguments @('commit','-m',$CommitMessage) -Gate 'alpha-git-commit'
if ($commitRc -ne 0 -and -not $AlphaSoftFail) { exit $commitRc }
if ($Push -and ($commitRc -eq 0 -or $AlphaSoftFail)) {
    $pushRc = Invoke-GitStep -Arguments @('push') -Gate 'alpha-git-push'
    if ($pushRc -ne 0 -and -not $AlphaSoftFail) { exit $pushRc }
}
Write-Host "[alpha-commit-sync] stage=$stageRc commit=$commitRc pushRequested=$Push softFail=$AlphaSoftFail"
if (($stageRc -ne 0 -or $commitRc -ne 0) -and -not $AlphaSoftFail) { exit 1 }
exit 0
