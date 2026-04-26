# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- Entry Point
    User-facing script that boots the kernel and enters the main run loop.

.DESCRIPTION
    Starts the Sovereign Kernel:
      1. Calls Initialize-SovereignKernel.ps1 to bootstrap all subsystems
      2. Runs an initial watchdog sweep
      3. Enters an interactive command loop (or exits after boot in headless mode)

.PARAMETER Headless
    If set, boots the kernel and exits without entering the interactive loop.
    Useful for testing and CI/CD.

.PARAMETER KernelRoot
    Override path to the sovereign-kernel directory.

.PARAMETER ConfigPath
    Override path to kernel-config.json.

.EXAMPLE
    .\Start-SovereignKernel.ps1
    .\Start-SovereignKernel.ps1 -Headless
    .\Start-SovereignKernel.ps1 -KernelRoot 'C:\MyKernel\sovereign-kernel'

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.start.1
#>

[CmdletBinding()]
param(
    [switch]$Headless,

    [string]$KernelRoot,

    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ========================== RESOLVE ROOT ==========================
if (-not $KernelRoot) {
    $KernelRoot = $PSScriptRoot
}
$KernelRoot = (Resolve-Path $KernelRoot).Path

# ========================== BOOTSTRAP ==========================
$initScript = Join-Path $KernelRoot 'Initialize-SovereignKernel.ps1'
if (-not (Test-Path $initScript)) {
    Write-Error "[SK-START] Bootstrap script not found: $initScript"
    exit 1
}

try {
    $kernelState = & $initScript -KernelRoot $KernelRoot -ConfigPath:$ConfigPath
}
catch {
    Write-Host "[SK-START] FATAL: Bootstrap failed -- $_" -ForegroundColor Red
    exit 1
}

# ========================== POST-BOOT SWEEP ==========================
Write-Host ''
Write-Host '[SK-START] Running initial watchdog sweep...' -ForegroundColor DarkGray
try {
    $sweepResult = Invoke-FullTribunalSweep
    $checkCount = 3  # caspar, melchior, balthazar
    $passCount  = @(
        $(if ($sweepResult.caspar.clean) { 1 } else { 0 }),
        $(if ($sweepResult.melchior.clean) { 1 } else { 0 }),
        $(if ($sweepResult.balthazar.clean) { 1 } else { 0 })
    ) | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    Write-Host "[SK-START] Watchdog sweep: $passCount/$checkCount passed." -ForegroundColor $(if ($passCount -eq $checkCount) { 'Green' } else { 'Yellow' })
}
catch {
    Write-Warning "[SK-START] Watchdog sweep error: $_"
}

# ========================== INITIAL HEAL CHECK ==========================
Write-Host '[SK-START] Running integrity scan...' -ForegroundColor DarkGray
try {
    $healStatus = Invoke-HealCycle
    if ($healStatus.clean) {
        Write-Host '[SK-START] Integrity: CLEAN' -ForegroundColor Green
    }
    else {
        Write-Host "[SK-START] Integrity: $($healStatus.violations) violations, $($healStatus.restored) restored, $($healStatus.failed) failed" -ForegroundColor Yellow
    }
}
catch {
    Write-Warning "[SK-START] Heal cycle error: $_"
}

# ========================== STATUS SUMMARY ==========================
Write-Host ''
Write-Host '  Version : ' -NoNewline; Write-Host $kernelState.version -ForegroundColor White
Write-Host '  Cycle   : ' -NoNewline; Write-Host $kernelState.cycle -ForegroundColor White
Write-Host '  Epoch   : ' -NoNewline; Write-Host $kernelState.epoch_seal.hash.Substring(0, 16) -ForegroundColor White
Write-Host '  Boot UTC: ' -NoNewline; Write-Host $kernelState.boot_utc -ForegroundColor White
Write-Host '  Modules : ' -NoNewline; Write-Host ($kernelState.modules -join ', ') -ForegroundColor White
Write-Host ''

if ($Headless) {
    Write-Host '[SK-START] Headless mode -- kernel booted successfully. Exiting.' -ForegroundColor Green
    return $kernelState
}

# ========================== INTERACTIVE LOOP ==========================
Write-Host '[SK-START] Entering interactive command loop. Type "help" for commands, "exit" to quit.' -ForegroundColor Cyan
Write-Host ''

$running = $true
while ($running) {
    Write-Host 'SK> ' -NoNewline -ForegroundColor Yellow
    $input = Read-Host

    switch -Regex ($input.Trim().ToLower()) {
        '^exit$|^quit$' {
            Write-Host '[SK] Shutting down...' -ForegroundColor Yellow
            try { Remove-AllSandboxes } catch { <# Intentional: best-effort cleanup during shutdown #> }
            Write-LedgerEntry -EventType 'SYSTEM' -Source 'SK-START' -Data @{
                event    = 'KERNEL_SHUTDOWN'
                utc      = [datetime]::UtcNow.ToString('o')
            }
            $running = $false
        }
        '^help$' {
            Write-Host '  status      - Kernel status summary'
            Write-Host '  health      - Module health report'
            Write-Host '  ledger      - Ledger statistics'
            Write-Host '  sweep       - Run watchdog tribunal sweep'
            Write-Host '  heal        - Run self-heal cycle'
            Write-Host '  cycle       - Cycle/version state'
            Write-Host '  sandbox     - Active sandbox summary'
            Write-Host '  compliance  - Compliance report'
            Write-Host '  cipher      - Cipher strength status'
            Write-Host '  exit        - Shut down kernel'
        }
        '^status$' {
            Write-Host "  Version : $($kernelState.version)"
            Write-Host "  Cycle   : $($kernelState.cycle)"
            Write-Host "  Degraded: $(Test-DegradedMode)"
            Write-Host "  Halted  : $(Test-KernelHalted)"
        }
        '^health$' {
            $score = Get-HealthScore
            Write-Host "  Health Score: $score" -ForegroundColor $(if ($score -ge 0.8) { 'Green' } elseif ($score -ge 0.6) { 'Yellow' } else { 'Red' })
            $failed = Get-FailedModules
            if ($failed.Count -gt 0) {
                Write-Host "  Failed modules: $($failed -join ', ')" -ForegroundColor Red
            }
        }
        '^ledger$' {
            $stats = Get-LedgerStats
            $stats.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key): $($_.Value)" }
        }
        '^sweep$' {
            $sw = Invoke-FullTribunalSweep
            $sw.votes | ForEach-Object {
                $color = if ($_.verdict -eq 'PASS') { 'Green' } else { 'Red' }
                Write-Host "  $($_.check_type): $($_.verdict)" -ForegroundColor $color
            }
        }
        '^heal$' {
            $h = Invoke-HealCycle
            Write-Host "  Clean: $($h.clean), Violations: $($h.violations), Restored: $($h.restored)"
        }
        '^cycle$' {
            $cs = Get-CycleState
            $cs.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key): $($_.Value)" }
        }
        '^sandbox$' {
            Write-Host "  Active sandboxes: $(Get-ActiveSandboxCount)"
            Get-SandboxStatus | ForEach-Object {
                if ($_) { Write-Host "    $($_.sandbox_id): $($_.name) [depth=$($_.depth)] ($($_.status))" }
            }
        }
        '^compliance$' {
            $cr = Get-ComplianceReport
            $cr.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key): $($_.Value)" }
        }
        '^cipher$' {
            $cu = Test-CipherUpgradeAvailable
            $cu.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key): $($_.Value)" }
            $compliant = Test-CipherStrengthCompliance
            Write-Host "  Compliant: $compliant" -ForegroundColor $(if ($compliant) { 'Green' } else { 'Red' })
        }
        default {
            if ($input.Trim()) {
                Write-Host "  Unknown command. Type 'help' for available commands." -ForegroundColor DarkGray
            }
        }
    }
}

Write-Host '[SK] Sovereign Kernel stopped.' -ForegroundColor Cyan


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




