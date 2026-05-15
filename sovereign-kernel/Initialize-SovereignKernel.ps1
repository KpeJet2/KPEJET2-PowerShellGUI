# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- Bootstrap Loader
    Validates manifest, loads modules in dependency order, initialises all subsystems.

.DESCRIPTION
    This script is the kernel bootstrap. It:
      1. Reads and parses kernel-config.json
      2. Validates the manifest against its JSON Schema (structural check)
      3. Loads all core modules in dependency order
      4. Initialises each subsystem sequentially:
         CryptoEngine -> LedgerWriter -> SovereignPolicy -> AgentRegistry
         -> CallProxy -> WatchdogSupervisor -> CycleManager
         -> SandboxManager -> SelfHealer
      5. Seals the boot epoch and writes it to the ledger
      6. Returns a kernel-state hashtable for the entry point

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.init.1
    Usage    : Invoked by Start-SovereignKernel.ps1; not called directly.
#>

param(
    [Parameter(Mandatory)]
    [string]$KernelRoot,

    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ========================== RESOLVE PATHS ==========================
$KernelRoot = (Resolve-Path $KernelRoot).Path

if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Join-Path $KernelRoot 'config') 'kernel-config.json'
}
if (-not (Test-Path $ConfigPath)) {
    throw "[SK-INIT] Config not found: $ConfigPath"
}

Write-Host '[SK-INIT] ============================================' -ForegroundColor Cyan
Write-Host '[SK-INIT]   Sovereign Kernel Bootstrap -- SK.v15.c8'     -ForegroundColor Cyan
Write-Host '[SK-INIT] ============================================' -ForegroundColor Cyan

# ========================== LOAD CONFIG ==========================
Write-Host '[SK-INIT] Loading kernel configuration...' -ForegroundColor DarkGray
$config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$configHT = @{}
$config.PSObject.Properties | ForEach-Object { $configHT[$_.Name] = $_.Value }

$manifestPath = Join-Path $KernelRoot $configHT.manifest_path
$schemaPath   = Join-Path $KernelRoot $configHT.schema_path

if (-not (Test-Path $manifestPath)) { throw "[SK-INIT] Manifest not found: $manifestPath" }

# ========================== VALIDATE MANIFEST ==========================
Write-Host '[SK-INIT] Validating manifest structure...' -ForegroundColor DarkGray
$manifestRaw = Get-Content -Path $manifestPath -Raw -Encoding UTF8
$manifestRoot = $manifestRaw | ConvertFrom-Json
$manifest     = $manifestRoot.sovereign_kernel

# Structural checks (PowerShell-native since full JSON-Schema validation requires external libs)
$requiredKeys = @('epoch_seal', 'sovereign_core', 'realms', 'spines', 'crypto_config', 'sandbox_config', 'redundancy', 'self_healing', 'versioning')
foreach ($key in $requiredKeys) {
    if (-not ($manifest.PSObject.Properties.Name -contains $key)) {
        throw "[SK-INIT] Manifest missing required key: $key"
    }
}
Write-Host '[SK-INIT] Manifest structure validated.' -ForegroundColor Green

# ========================== LOAD MODULES ==========================
Write-Host '[SK-INIT] Loading core modules...' -ForegroundColor DarkGray

$coreDir = Join-Path $KernelRoot 'core'
$moduleOrder = @(
    'CryptoEngine'
    'LedgerWriter'
    'SovereignPolicy'
    'AgentRegistry'
    'CallProxy'
    'WatchdogSupervisor'
    'CycleManager'
    'SandboxManager'
    'SelfHealer'
)

foreach ($modName in $moduleOrder) {
    $modPath = Join-Path $coreDir "${modName}.psm1"
    if (-not (Test-Path $modPath)) {
        throw "[SK-INIT] Core module missing: $modPath"
    }
    Import-Module $modPath -Force -Global -DisableNameChecking
    Write-Host "  [SK-INIT] Loaded: $modName" -ForegroundColor DarkGray
}

Write-Host "[SK-INIT] $($moduleOrder.Count) core modules loaded." -ForegroundColor Green

# ========================== INITIALISE SUBSYSTEMS ==========================
Write-Host '[SK-INIT] Initialising subsystems...' -ForegroundColor DarkGray

# --- 1. CryptoEngine ---
$cryptoCfg = @{}
$manifest.crypto_config.PSObject.Properties | ForEach-Object { $cryptoCfg[$_.Name] = $_.Value }
$pbkdf2Iter = if ($configHT.crypto -and $configHT.crypto.pbkdf2_iterations) {
    $configHT.crypto.pbkdf2_iterations
} else { 600000 }
$cryptoCfg['kdf_iterations'] = $pbkdf2Iter
$minCipherScore = if ($configHT.crypto -and $configHT.crypto.min_cipher_score) {
    $configHT.crypto.min_cipher_score
} else { 256 }
$cryptoCfg['min_cipher_score'] = $minCipherScore

Initialize-CryptoEngine -CryptoConfig $cryptoCfg

# Derive encryption keys from passphrase
$passEnvVar = if ($configHT.crypto -and $configHT.crypto.passphrase_env_var) {
    $configHT.crypto.passphrase_env_var
} else { 'SK_PASSPHRASE' }

$passphrasePlain = [System.Environment]::GetEnvironmentVariable($passEnvVar)
if (-not $passphrasePlain) {
    $passphrasePlain = 'sovereign-kernel-default-passphrase'
    Write-Warning "[SK-INIT] No passphrase in env var '$passEnvVar'. Using default (NOT for production)."
}
$secPassphrase = ConvertTo-SecureStringFromPlain -PlainText $passphrasePlain
$script:_KeySet = New-DerivedKeySet -Passphrase $secPassphrase -PurposeTag 'kernel'
Write-Host '  [SK-INIT] CryptoEngine ready.' -ForegroundColor DarkGray

# --- 2. LedgerWriter ---
$replicaCount = if ($configHT.ledger -and $configHT.ledger.replica_count) { $configHT.ledger.replica_count } else { 3 }
$quorum       = if ($configHT.ledger -and $configHT.ledger.quorum_required) { $configHT.ledger.quorum_required } else { 2 }
$ledgerDir    = if ($configHT.ledger -and $configHT.ledger.base_dir) { $configHT.ledger.base_dir } else { 'ledger' }
$ledgerPaths  = @()
for ($i = 0; $i -lt $replicaCount; $i++) { $ledgerPaths += "${ledgerDir}/replica-${i}" }

$redundancyCfg = @{ quorum_for_write = $quorum; ledger_paths = $ledgerPaths }
$loggingCfg    = @{ level = 'INFO'; format = 'JSON' }

Initialize-LedgerWriter -RedundancyConfig $redundancyCfg -LoggingConfig $loggingCfg -KernelRoot $KernelRoot -EncryptionKeySet $script:_KeySet
Write-Host '  [SK-INIT] LedgerWriter ready.' -ForegroundColor DarkGray

# --- 3. SovereignPolicy ---
$sovereignCoreCfg = @{}
$manifest.sovereign_core.PSObject.Properties | ForEach-Object { $sovereignCoreCfg[$_.Name] = $_.Value }
$spinesCfg = @{}
if ($manifest.spines) { $manifest.spines.PSObject.Properties | ForEach-Object { $spinesCfg[$_.Name] = $_.Value } }
Initialize-SovereignPolicy -SovereignCore $sovereignCoreCfg -Spines $spinesCfg
Write-Host '  [SK-INIT] SovereignPolicy ready.' -ForegroundColor DarkGray

# --- 4. AgentRegistry ---
$manifestHT = @{ sovereign_kernel = @{} }
$manifest.PSObject.Properties | ForEach-Object { $manifestHT.sovereign_kernel[$_.Name] = $_.Value }
Initialize-AgentRegistry -Manifest $manifestHT
Write-Host '  [SK-INIT] AgentRegistry ready.' -ForegroundColor DarkGray

# --- 5. CallProxy ---
$toolsCfg = @{
    method_call_monitor = @{
        max_call_depth = 12
        timeout_ms     = 30000
    }
    outbound_firewall = @{
        block_by_default    = $true
        log_all             = $true
        governance_required = @('sovereign_core', 'transcendent_ring')
        allowlist_path      = $null
    }
}
if ($manifest.tools_and_calls) {
    $tc = $manifest.tools_and_calls
    if ($tc.PSObject.Properties.Name -contains 'method_call_monitor') {
        $mcm = $tc.method_call_monitor
        if ($mcm.max_call_depth) { $toolsCfg.method_call_monitor.max_call_depth = $mcm.max_call_depth }
        if ($mcm.timeout_ms)     { $toolsCfg.method_call_monitor.timeout_ms     = $mcm.timeout_ms }
    }
}
Initialize-CallProxy -ToolsAndCallsConfig $toolsCfg -KernelRoot $KernelRoot
Write-Host '  [SK-INIT] CallProxy ready.' -ForegroundColor DarkGray

# --- 6. WatchdogSupervisor ---
$watchdogCfg = @{
    min_health_score    = if ($configHT.watchdog -and $configHT.watchdog.min_health_score) { $configHT.watchdog.min_health_score } else { 0.6 }
    auto_vote_on_sweep  = if ($configHT.watchdog -and $null -ne $configHT.watchdog.auto_vote_on_sweep) { $configHT.watchdog.auto_vote_on_sweep } else { $true }
}
Initialize-WatchdogSupervisor -WatchdogConfig $watchdogCfg
Write-Host '  [SK-INIT] WatchdogSupervisor ready.' -ForegroundColor DarkGray

# --- 7. CycleManager ---
$versionCfg = @{
    doctrine_version = 'v15'
    current_cycle    = 'cycle8'
    lineage          = @('v1', 'v5', 'v10', 'v15')
    branch_policy    = @{ rollback_depth = 3; max_drift_cycles = 2; allow_divergence = $false }
}
if ($manifest.versioning) {
    $v = $manifest.versioning
    $vProps = $v.PSObject.Properties.Name
    if ($vProps -contains 'doctrine_version') { $versionCfg.doctrine_version = $v.doctrine_version }
    if ($vProps -contains 'current_cycle')    { $versionCfg.current_cycle    = $v.current_cycle }
    if ($vProps -contains 'lineage')          { $versionCfg.lineage          = @($v.lineage) }
    if ($vProps -contains 'branch_policy') {
        $bp = @{}
        $v.branch_policy.PSObject.Properties | ForEach-Object { $bp[$_.Name] = $_.Value }
        $versionCfg.branch_policy = $bp
    }
}
Initialize-CycleManager -VersioningConfig $versionCfg -KernelRoot $KernelRoot
Write-Host '  [SK-INIT] CycleManager ready.' -ForegroundColor DarkGray

# --- 8. SandboxManager ---
$sandboxCfg = @{
    default_language_mode = 'ConstrainedLanguage'
    max_sandbox_depth     = 3
    para_virtualization   = @{
        isolation_layers = @('environment', 'runspace', 'filesystem', 'network')
        resource_limits  = @{ max_memory_mb = 512; max_cpu_percent = 25; max_threads = 8; max_execution_seconds = 300 }
    }
}
if ($manifest.sandbox_config) {
    $sc = $manifest.sandbox_config
    $scProps = $sc.PSObject.Properties.Name
    if ($scProps -contains 'default_language_mode') { $sandboxCfg.default_language_mode = $sc.default_language_mode }
    if ($scProps -contains 'max_sandbox_depth')     { $sandboxCfg.max_sandbox_depth     = $sc.max_sandbox_depth }
}
Initialize-SandboxManager -SandboxConfig $sandboxCfg
Write-Host '  [SK-INIT] SandboxManager ready.' -ForegroundColor DarkGray

# --- 9. SelfHealer ---
$healCfg = @{ auto_restart = $true; max_retries = 3; degraded_mode = 'continue_limited' }
if ($manifest.self_healing) {
    $sh = $manifest.self_healing
    $shProps = $sh.PSObject.Properties.Name
    if ($shProps -contains 'auto_restart')  { $healCfg.auto_restart  = $sh.auto_restart }
    if ($shProps -contains 'max_retries')   { $healCfg.max_retries   = $sh.max_retries }
    if ($shProps -contains 'degraded_mode') { $healCfg.degraded_mode = $sh.degraded_mode }
}
Initialize-SelfHealer -KernelRoot $KernelRoot -HealingConfig $healCfg
Write-Host '  [SK-INIT] SelfHealer ready.' -ForegroundColor DarkGray

Write-Host '[SK-INIT] All subsystems initialised.' -ForegroundColor Green

# ========================== SEAL BOOT EPOCH ==========================
Write-Host '[SK-INIT] Sealing boot epoch...' -ForegroundColor DarkGray
$manifestHash = Get-FileHash512 -Path $manifestPath
$epochSeal    = New-EpochSeal -DataHash $manifestHash -HmacKey $script:_KeySet.HmacKey

Write-LedgerEntry -EventType 'SYSTEM' -Source 'SK-INIT' -Data @{
    event      = 'KERNEL_BOOT'
    epoch_seal = $epochSeal
    version    = $versionCfg.doctrine_version
    cycle      = $versionCfg.current_cycle
    modules    = $moduleOrder
    boot_utc   = [datetime]::UtcNow.ToString('o')
}

Write-Host "[SK-INIT] Epoch sealed: $($epochSeal.hash.Substring(0, 16))..." -ForegroundColor Green
Write-Host '[SK-INIT] ============================================' -ForegroundColor Cyan
Write-Host '[SK-INIT]   SOVEREIGN KERNEL ONLINE'                     -ForegroundColor Green
Write-Host '[SK-INIT] ============================================' -ForegroundColor Cyan

# ── Self-Review Boot Score Log ─────────────────────────────────────────────
try {
    $srWorkspace = Split-Path $KernelRoot
    $srHistPath  = Join-Path (Join-Path $srWorkspace 'config') 'self-review-history.json'
    if (Test-Path $srHistPath) {
        $srHist  = Get-Content -Path $srHistPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $srRuns  = @($srHist.runs)
        if (@($srRuns).Count -gt 0) {
            $latest  = $srRuns[-1]
            $srScore = if ($null -ne $latest -and $latest.PSObject.Properties.Name -contains 'compositeScore') { [double]$latest.compositeScore } else { $null }
            if ($null -ne $srScore) {
                $srColor = if ($srScore -ge 0.7) { 'Green' } elseif ($srScore -ge 0.5) { 'Yellow' } else { 'Red' }
                Write-Host "[SK-INIT] Self-Review Score: $srScore" -ForegroundColor $srColor
                $srCfgPath   = Join-Path (Join-Path $srWorkspace 'config') 'self-review-config.json'
                $warnBelow   = 0.7
                if (Test-Path $srCfgPath) {
                    try {
                        $srCfg = Get-Content -Path $srCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ($null -ne $srCfg.thresholds -and $null -ne $srCfg.thresholds.kernelScoreWarningBelow) {
                            $warnBelow = [double]$srCfg.thresholds.kernelScoreWarningBelow
                        }
                    } catch { <# Intentional: non-fatal config read #> }
                }
                if ($srScore -lt $warnBelow) {
                    Write-Warning "[SK-INIT] Workspace health below $warnBelow -- score=$srScore. Run TASK-SelfReview to diagnose."
                }
            }
        } else {
            Write-Host '[SK-INIT] Self-Review: no prior runs on record.' -ForegroundColor DarkGray
        }
    }
} catch {
    Write-Verbose "[SK-INIT] Self-review boot score log error: $_"
}

# ========================== RETURN KERNEL STATE ==========================
return @{
    kernel_root   = $KernelRoot
    config        = $configHT
    manifest_hash = $manifestHash
    epoch_seal    = $epochSeal
    version       = $versionCfg.doctrine_version
    cycle         = $versionCfg.current_cycle
    modules       = $moduleOrder
    boot_utc      = [datetime]::UtcNow.ToString('o')
}


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





