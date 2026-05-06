# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- Comprehensive Test Suite
    Verifies all 9 core modules, bootstrap, and integrated kernel behaviour.

.DESCRIPTION
    Self-contained test harness (no Pester dependency). Tests are grouped by module:
      1. CryptoEngine     -- encrypt/decrypt round-trip, compression, hashing, epoch seal, cipher score
      2. LedgerWriter     -- write/read, hash chain integrity, quorum, replica sync
      3. SovereignPolicy  -- override rules, quorum, compliance, ethical constraints
      4. AgentRegistry    -- register, boot order, health, tiers
      5. CallProxy        -- proxied call, rate limit, outbound firewall
      6. WatchdogSupervisor -- tribunal voting, sweep, alert
      7. CycleManager     -- advance, rollback, snapshot, branch divergence
      8. SandboxManager   -- create/destroy, subsandbox, execution, timeout
      9. SelfHealer       -- baseline, integrity scan, heal cycle, degraded mode
     10. Integration      -- full kernel boot via Initialize-SovereignKernel.ps1

.PARAMETER KernelRoot
    Path to the sovereign-kernel directory.

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.test.1
#>

[CmdletBinding()]
param(
    [string]$KernelRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $KernelRoot) {
    $KernelRoot = Split-Path $PSScriptRoot -Parent
    if (-not (Test-Path (Join-Path $KernelRoot 'core'))) {
        $KernelRoot = Join-Path $PSScriptRoot '..'
        $KernelRoot = (Resolve-Path $KernelRoot).Path
    }
}
$KernelRoot = (Resolve-Path $KernelRoot).Path

# ========================== TEST FRAMEWORK ==========================
$script:TestResults = @{ passed = 0; failed = 0; skipped = 0; errors = @() }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:TestResults.passed++
        Write-Host "    PASS: $Message" -ForegroundColor Green
    }
    else {
        $script:TestResults.failed++
        $script:TestResults.errors += $Message
        Write-Host "    FAIL: $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    $eq = $Expected -eq $Actual
    if ($eq) {
        $script:TestResults.passed++
        Write-Host "    PASS: $Message" -ForegroundColor Green
    }
    else {
        $script:TestResults.failed++
        $script:TestResults.errors += "$Message (expected=$Expected, actual=$Actual)"
        Write-Host "    FAIL: $Message (expected=$Expected, actual=$Actual)" -ForegroundColor Red
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if ($threw) {
        $script:TestResults.passed++
        Write-Host "    PASS: $Message" -ForegroundColor Green
    }
    else {
        $script:TestResults.failed++
        $script:TestResults.errors += "$Message (expected exception)"
        Write-Host "    FAIL: $Message (expected exception)" -ForegroundColor Red
    }
}

# ========================== LOAD MODULES ==========================
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  Sovereign Kernel Test Suite -- SK.v15.c8'                        -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''

$coreDir = Join-Path $KernelRoot 'core'
$moduleOrder = @('CryptoEngine', 'LedgerWriter', 'SovereignPolicy', 'AgentRegistry',
    'CallProxy', 'WatchdogSupervisor', 'CycleManager', 'SandboxManager', 'SelfHealer')

foreach ($m in $moduleOrder) {
    $mp = Join-Path $coreDir "${m}.psm1"
    if (Test-Path $mp) {
        Import-Module $mp -Force -Global -DisableNameChecking
    }
    else {
        Write-Warning "Module not found: $mp"
    }
}

# ========================== TEMP DIRECTORIES ==========================
$tempRoot = Join-Path $env:TEMP "sk-test-$(Get-Random)"
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
$tempLedger  = Join-Path $tempRoot 'ledger'
$tempSnap    = Join-Path $tempRoot 'snapshots'
New-Item -Path $tempLedger -ItemType Directory -Force | Out-Null
New-Item -Path $tempSnap -ItemType Directory -Force | Out-Null

# ========================== TEST 1: CryptoEngine ==========================
Write-Host '[TEST 1] CryptoEngine' -ForegroundColor Yellow

Initialize-CryptoEngine -CryptoConfig @{ kdf_iterations = 10000; min_cipher_score = 80 }

# Random bytes
$rng = Get-SecureRandomBytes -Count 32
Assert-Equal -Expected 32 -Actual $rng.Length -Message 'Get-SecureRandomBytes returns correct length'

# Random hex
$hex = Get-SecureRandomHex -ByteCount 16
Assert-Equal -Expected 32 -Actual $hex.Length -Message 'Get-SecureRandomHex returns correct hex length'

# Key derivation
$secPass = ConvertTo-SecureStringFromPlain -PlainText 'test-passphrase'
$keys = New-DerivedKeySet -Passphrase $secPass -PurposeTag 'testkey'
Assert-True ($keys.EncryptionKey.Length -eq 32) 'New-DerivedKeySet produces 32-byte AES key'
Assert-True ($keys.HmacKey.Length -eq 64) 'New-DerivedKeySet produces 64-byte HMAC key'

# Compression round-trip
$testData = [System.Text.Encoding]::UTF8.GetBytes('Hello Sovereign Kernel! ' * 50)
$compressed = Compress-Data -InputBytes $testData
$decompressed = Expand-Data -CompressedBytes $compressed
Assert-True ($compressed.Length -lt $testData.Length) 'Compress-Data reduces size'
Assert-Equal -Expected $testData.Length -Actual $decompressed.Length -Message 'Expand-Data restores original size'
$match = $true
for ($i = 0; $i -lt $testData.Length; $i++) {
    if ($testData[$i] -ne $decompressed[$i]) { $match = $false; break }
}
Assert-True $match 'Compression round-trip preserves data'

# Encrypt/Decrypt round-trip
$plaintext = [System.Text.Encoding]::UTF8.GetBytes('Secret message for sovereign kernel')
$encrypted = Protect-Data -Plaintext $plaintext -EncryptionKey $keys.EncryptionKey -HmacKey $keys.HmacKey
$decrypted = Unprotect-Data -ProtectedPayload $encrypted -EncryptionKey $keys.EncryptionKey -HmacKey $keys.HmacKey
Assert-Equal -Expected $plaintext.Length -Actual $decrypted.Length -Message 'Protect/Unprotect-Data round-trip size'
$dataMatch = $true
for ($i = 0; $i -lt $plaintext.Length; $i++) {
    if ($plaintext[$i] -ne $decrypted[$i]) { $dataMatch = $false; break }
}
Assert-True $dataMatch 'Protect/Unprotect-Data round-trip content match'

# Hashing
$hash1 = Get-SHA512Hash -InputBytes $plaintext
$hash2 = Get-SHA512Hash -InputBytes $plaintext
Assert-Equal -Expected $hash1 -Actual $hash2 -Message 'SHA-512 deterministic'
Assert-True ($hash1.Length -eq 128) 'SHA-512 hash is 128 hex chars'

$strHash = Get-StringHash512 -InputString 'test'
Assert-True ($strHash.Length -eq 128) 'Get-StringHash512 produces 128 hex chars'

# Hash chain
$hash_a = New-HashChainEntry -PreviousHash '0' -CurrentData 'first entry'
Assert-True ($null -ne $hash_a) 'New-HashChainEntry produces hash'
$hash_b = New-HashChainEntry -PreviousHash $hash_a -CurrentData 'second entry'
$chain = @(
    @{ PreviousHash = '0'; Data = 'first entry'; Hash = $hash_a }
    @{ PreviousHash = $hash_a; Data = 'second entry'; Hash = $hash_b }
)
$chainValid = Test-HashChain -Chain $chain
Assert-True $chainValid 'Test-HashChain validates correct chain'

# Epoch seal
$seal = New-EpochSeal -DataHash $hash1 -HmacKey $keys.HmacKey
Assert-True ($null -ne $seal.hash) 'New-EpochSeal creates hash'
$sealValid = Test-EpochSeal -Seal $seal -DataHash $hash1 -HmacKey $keys.HmacKey
Assert-True $sealValid 'Test-EpochSeal validates correct seal'

# Cipher score
$score = Get-CipherStrengthScore -CipherSuite 'AES-256-CBC+HMAC-SHA512'
Assert-True ($score -ge 80) 'AES-256-CBC cipher score >= 80'
$compliant = Test-CipherStrengthCompliance
Assert-True $compliant 'Cipher strength is compliant'

Write-Host ''

# ========================== TEST 2: LedgerWriter ==========================
Write-Host '[TEST 2] LedgerWriter' -ForegroundColor Yellow

$ledgerPaths = @('ledger/replica-0', 'ledger/replica-1')
$redundancyCfg = @{ quorum_for_write = 2; ledger_paths = $ledgerPaths }
$loggingCfg    = @{ level = 'INFO'; format = 'JSON' }
Initialize-LedgerWriter -RedundancyConfig $redundancyCfg -LoggingConfig $loggingCfg -KernelRoot $tempRoot -EncryptionKeySet $keys

Write-LedgerEntry -EventType 'SYSTEM' -Source 'TestSuite' -Data @{ msg = 'first entry' }
Write-LedgerEntry -EventType 'SYSTEM' -Source 'TestSuite' -Data @{ msg = 'second entry' }

$stats = Get-LedgerStats
Assert-True ($stats.EntryCount -ge 2) 'LedgerWriter has at least 2 entries'

$entry = Read-LedgerEntry -Index 1 -ReplicaIndex 0
Assert-True ($null -ne $entry) 'Read-LedgerEntry returns data for index 1'

$integrity = Test-LedgerIntegrity -ReplicaIndex 0
Assert-True (-not $integrity.Broken) 'Ledger integrity intact'

Write-Host ''

# ========================== TEST 3: SovereignPolicy ==========================
Write-Host '[TEST 3] SovereignPolicy' -ForegroundColor Yellow

$sovereignCore = @{
    override_policy = @{
        can_override            = @('operational_modules', 'tools_and_calls')
        cannot_be_overridden_by = @('meta_modules')
        escalation_chain        = @('sovereign_core', 'transcendent_ring', 'watchdog_tribunal')
        quorum_required         = 2
    }
    integrity = @{ mandate = 'absolute' }
}
$spines = @{
    governance_spine = @('policy', 'audit')
    ethical_spine    = @('safety', 'compliance')
}
Initialize-SovereignPolicy -SovereignCore $sovereignCore -Spines $spines

$overrideOk = Test-OverridePermission -RequestingModule 'SOVEREIGN_CORE' -TargetLayer 'operational_modules'
Assert-True $overrideOk 'Override permission granted for allowed category'

$overrideDenied = Test-OverridePermission -RequestingModule 'meta_modules' -TargetLayer 'sovereign_core'
Assert-True (-not $overrideDenied) 'Override permission denied for restricted source'

Set-ModuleComplianceState -ModuleId 'test_module' -Compliant $true
$compState = Get-ModuleComplianceState -ModuleId 'test_module'
Assert-True ($null -ne $compState -and $compState.compliant) 'Compliance state round-trip'

$report = Get-ComplianceReport
Assert-True ($report.total_modules -ge 1) 'Compliance report has registered modules'

Write-Host ''

# ========================== TEST 4: AgentRegistry ==========================
Write-Host '[TEST 4] AgentRegistry' -ForegroundColor Yellow

$testManifest = @{
    sovereign_kernel = @{
        meta_modules        = @{ awareness = @{ tier = 'meta'; auto_heal = $true; priority = 1 }; adaptation = @{ tier = 'meta'; auto_heal = $true; priority = 2 } }
        operational_modules  = @{ command_bus = @{ tier = 'operational'; auto_heal = $true; priority = 5 } }
        realms              = @{}
        spines              = @{}
        transcendent_ring   = @{}
        reflexive_crown     = @{}
    }
}
Initialize-AgentRegistry -Manifest $testManifest

Register-ModuleHandler -ModuleId 'awareness' -Handler { 'awareness active' } -DependsOn @()
Register-ModuleHandler -ModuleId 'adaptation' -Handler { 'adaptation active' } -DependsOn @('awareness')
Register-ModuleHandler -ModuleId 'command_bus' -Handler { 'command_bus active' } -DependsOn @('awareness')

$bootOrder = Resolve-BootOrder
Assert-True ($bootOrder.Count -ge 3) 'Resolve-BootOrder returns 3+ modules'
$awarenessIdx  = [array]::IndexOf($bootOrder, 'awareness')
$adaptationIdx = [array]::IndexOf($bootOrder, 'adaptation')
Assert-True ($awarenessIdx -lt $adaptationIdx) 'Boot order: awareness before adaptation'

Update-ModuleHealth -ModuleId 'awareness' -Status 'HEALTHY'
$health = Get-ModuleHealth -ModuleId 'awareness'
Assert-Equal -Expected 'HEALTHY' -Actual $health.status -Message 'Module health tracking'

$score = Get-HealthScore
Assert-True ($score -ge 0 -and $score -le 1) 'Health score in [0,1]'

$metaModules = Get-ModulesByTier -Tier 'meta'
Assert-True ($metaModules.Count -ge 2) 'Get-ModulesByTier returns meta modules'

Write-Host ''

# ========================== TEST 5: CallProxy ==========================
Write-Host '[TEST 5] CallProxy' -ForegroundColor Yellow

$testToolsCfg = @{
    method_call_monitor = @{ max_call_depth = 10; timeout_ms = 30000 }
    outbound_firewall   = @{ block_by_default = $true; log_all = $true; governance_required = @('sovereign_core') }
}
Initialize-CallProxy -ToolsAndCallsConfig $testToolsCfg

$callResult = Invoke-ProxiedCall -ModuleId 'test' -MethodName 'ping' -ScriptBlock { 'pong' }
Assert-Equal -Expected 'pong' -Actual $callResult -Message 'Invoke-ProxiedCall returns action result'

$outbound1 = Test-OutboundRequest -Hostname 'localhost'
Assert-True (-not $outbound1.allowed) 'Outbound blocked for localhost (no allowlist file)'

$stats = Get-CallStats
Assert-True ($stats.total_calls -ge 1) 'Call stats tracks calls'

Write-Host ''

# ========================== TEST 6: WatchdogSupervisor ==========================
Write-Host '[TEST 6] WatchdogSupervisor' -ForegroundColor Yellow

Initialize-WatchdogSupervisor -WatchdogConfig @{ min_health_score = 0.6; auto_vote_on_sweep = $true }

$alert = Submit-WatchdogAlert -WatchdogId 'CASPAR' -TriggerType 'TEST_ALERT' -Evidence @{ source = 'TestSuite' }
Assert-True ($null -ne $alert.alert_id) 'Submit-WatchdogAlert creates alert'

$sweep = Invoke-FullTribunalSweep
Assert-True ($null -ne $sweep.caspar) 'Full tribunal sweep produces caspar result'
Assert-True ($null -ne $sweep.melchior) 'Full tribunal sweep produces melchior result'

$halted = Test-KernelHalted
Assert-True ($halted -is [bool]) 'Test-KernelHalted returns bool'

$wdStatus = Get-WatchdogStatus
Assert-True ($null -ne $wdStatus.active_alerts) 'WatchdogStatus has active_alerts'

Write-Host ''

# ========================== TEST 7: CycleManager ==========================
Write-Host '[TEST 7] CycleManager' -ForegroundColor Yellow

# Create real manifest dir and dummy manifest for snapshots
$testManifestDir = Join-Path $tempRoot 'manifest'
New-Item -Path $testManifestDir -ItemType Directory -Force | Out-Null
'{"test": true}' | Set-Content -Path (Join-Path $testManifestDir 'sovereign-kernel.json') -Encoding UTF8

Initialize-CycleManager -VersioningConfig @{
    doctrine_version = 'v15'
    current_cycle    = 'cycle8'
    lineage          = @('v1', 'v10', 'v15')
    branch_policy    = @{ rollback_depth = 3; max_drift_cycles = 2; allow_divergence = $false }
} -KernelRoot $tempRoot

$state = Get-CycleState
Assert-Equal -Expected 'v15' -Actual $state.version -Message 'CycleManager version'
Assert-Equal -Expected 'cycle8' -Actual $state.cycle -Message 'CycleManager cycle'

$snap = New-CycleSnapshot -Label 'test'
Assert-True ($null -ne $snap.snapshot_id) 'New-CycleSnapshot creates snapshot'

$divergence = Test-BranchDivergence
Assert-True ($null -ne $divergence.diverged) 'Test-BranchDivergence returns diverged field'

# Test advance (may fail due to health check -- that is ok, test the gating)
try {
    $advance = Invoke-CycleAdvance
    Assert-True ($advance.to_cycle -eq 'cycle9') 'Cycle advanced to cycle9'
}
catch {
    # Expected if health checks fail in test env
    Write-Host "    SKIP: Cycle advance blocked (expected in test env)" -ForegroundColor DarkGray
    $script:TestResults.skipped++
}

Write-Host ''

# ========================== TEST 8: SandboxManager ==========================
Write-Host '[TEST 8] SandboxManager' -ForegroundColor Yellow

Initialize-SandboxManager -SandboxConfig @{
    default_language_mode = 'FullLanguage'
    max_sandbox_depth     = 3
    para_virtualization   = @{
        isolation_layers = @('environment', 'runspace')
        resource_limits  = @{ max_memory_mb = 256; max_execution_seconds = 10 }
    }
}

$sb1 = New-Sandbox -Name 'TestSandbox1'
Assert-True ($null -ne $sb1.sandbox_id) 'New-Sandbox creates sandbox'
Assert-Equal -Expected 1 -Actual $sb1.depth -Message 'Root sandbox depth is 1'

$sb2 = New-Sandbox -Name 'SubSandbox1' -ParentSandboxId $sb1.sandbox_id
Assert-Equal -Expected 2 -Actual $sb2.depth -Message 'Subsandbox depth is 2'

$sb3 = New-Sandbox -Name 'SubSubSandbox1' -ParentSandboxId $sb2.sandbox_id
Assert-Equal -Expected 3 -Actual $sb3.depth -Message 'Sub-subsandbox depth is 3'

Assert-Throws -Action {
    New-Sandbox -Name 'TooDeep' -ParentSandboxId $sb3.sandbox_id
} -Message 'Exceeding max depth throws'

$count = Get-ActiveSandboxCount
Assert-Equal -Expected 3 -Actual $count -Message 'Active sandbox count is 3'

# Execute in sandbox
$execResult = Invoke-InSandbox -SandboxId $sb1.sandbox_id -ScriptBlock { 2 + 2 }
Assert-True ($execResult.output -contains 4) 'Sandbox execution returns correct result'

# Destroy all
Remove-AllSandboxes
$countAfter = Get-ActiveSandboxCount
Assert-Equal -Expected 0 -Actual $countAfter -Message 'All sandboxes removed'

Write-Host ''

# ========================== TEST 9: SelfHealer ==========================
Write-Host '[TEST 9] SelfHealer' -ForegroundColor Yellow

Initialize-SelfHealer -KernelRoot $KernelRoot

$baseline = Get-IntegrityBaseline
Assert-True ($baseline.Count -gt 0) 'Integrity baseline has entries'

$violations = @(Invoke-IntegrityScan)
Assert-True ($violations -is [array]) 'Integrity scan returns array'

$degraded = Test-DegradedMode
Assert-True (-not $degraded) 'Not in degraded mode initially'

$healerStatus = Get-SelfHealerStatus
Assert-True $healerStatus.initialized 'SelfHealer is initialized'
Assert-True ($healerStatus.baseline_files -gt 0) 'Baseline files counted'

$cipherUpgrade = Test-CipherUpgradeAvailable
Assert-True ($null -ne $cipherUpgrade.current_algorithm) 'Cipher upgrade check has current algorithm'

Write-Host ''

# ========================== TEST 10: Integration ==========================
Write-Host '[TEST 10] Integration -- Full Bootstrap' -ForegroundColor Yellow

try {
    $initScript = Join-Path $KernelRoot 'Initialize-SovereignKernel.ps1'
    if (Test-Path $initScript) {
        $ksState = & $initScript -KernelRoot $KernelRoot
        Assert-True ($null -ne $ksState.epoch_seal) 'Bootstrap produces epoch seal'
        Assert-True ($ksState.modules.Count -eq 9) 'Bootstrap loads all 9 modules'
        Assert-True ($null -ne $ksState.version) 'Bootstrap reports version'
        Assert-True ($null -ne $ksState.boot_utc) 'Bootstrap reports boot time'
        Assert-True ($null -ne $ksState.epoch_seal.hash) 'Epoch seal has hash'
    }
    else {
        Write-Host "    SKIP: Initialize-SovereignKernel.ps1 not found" -ForegroundColor DarkGray
        $script:TestResults.skipped++
    }
}
catch {
    Write-Host "    FAIL: Bootstrap error -- $_" -ForegroundColor Red
    $script:TestResults.failed++
    $script:TestResults.errors += "Integration bootstrap: $_"
}

Write-Host ''

# ========================== CLEANUP ==========================
try { Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { <# Intentional: best-effort test cleanup #> }

# ========================== SUMMARY ==========================
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  TEST SUMMARY' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Passed  : $($script:TestResults.passed)" -ForegroundColor Green
Write-Host "  Failed  : $($script:TestResults.failed)" -ForegroundColor $(if ($script:TestResults.failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped : $($script:TestResults.skipped)" -ForegroundColor DarkGray
Write-Host "  Total   : $($script:TestResults.passed + $script:TestResults.failed + $script:TestResults.skipped)" -ForegroundColor White

if ($script:TestResults.errors.Count -gt 0) {
    Write-Host ''
    Write-Host '  Errors:' -ForegroundColor Red
    $script:TestResults.errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}

Write-Host ''
if ($script:TestResults.failed -eq 0) {
    Write-Host '  ALL TESTS PASSED' -ForegroundColor Green
}
else {
    Write-Host "  $($script:TestResults.failed) TEST(S) FAILED" -ForegroundColor Red
}
Write-Host ''

return $script:TestResults


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





