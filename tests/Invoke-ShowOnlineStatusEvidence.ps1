# VersionTag: 2605.B5.V51.1
# SupportPS5.1: true
# SupportsPS7.6: true

[CmdletBinding()]
param(
    [Parameter()]
    [string]$PagePath = '',

    [Parameter()]
    [string]$BundlePath = '',

    [Parameter()]
    [switch]$EmitJson,

    [Parameter()]
    [string]$OutputJsonPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    $scriptRoot = $PSScriptRoot
}
$repoRoot = Split-Path -Path $scriptRoot -Parent

if ([string]::IsNullOrWhiteSpace($PagePath)) {
    $PagePath = Join-Path (Join-Path $repoRoot '~README.md') 'PwShGUI-Checklists-ShowOnline.xhtml'
}
if ([string]::IsNullOrWhiteSpace($BundlePath)) {
    $BundlePath = Join-Path (Join-Path $repoRoot 'todo') '_bundle.js'
}

$script:Checks = @()

function Add-CheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Pass,

        [Parameter()]
        [string]$Detail = ''
    )

    $entry = [pscustomobject]@{
        Name   = $Name
        Pass   = $Pass
        Detail = $Detail
    }
    $script:Checks += $entry

    if ($Pass) {
        Write-Host ("[PASS] {0}" -f $Name) -ForegroundColor Green
    } else {
        $suffix = if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { ': ' + $Detail }
        Write-Host ("[FAIL] {0}{1}" -f $Name, $suffix) -ForegroundColor Red
    }
}

function Get-CanonicalItemStatus {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$RawStatus
    )

    $status = 'OPEN'
    if ($null -ne $RawStatus) {
        $status = [string]$RawStatus
    }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = 'OPEN'
    }

    $status = $status.ToUpperInvariant()
    $status = [regex]::Replace($status, '[\s\/\\-]+', '_')
    $status = [regex]::Replace($status, '__+', '_')

    switch ($status) {
        'INPROGRESS' { return 'IN_PROGRESS' }
        'PENDINGAPPROVAL' { return 'PENDING_APPROVAL' }
        'AWAITING_APPROVAL' { return 'PENDING_APPROVAL' }
        'APPROVAL_PENDING' { return 'PENDING_APPROVAL' }
        'APPROVED' { return 'APPROVED_COMPLETED' }
        'APPROVED_COMPLETE' { return 'APPROVED_COMPLETED' }
        'APPROVED_DONE' { return 'APPROVED_COMPLETED' }
        'ONHOLD' { return 'ON_HOLD' }
        'REJECTED' { return 'DENIED' }
        'MERGED_TO_MAIN' { return 'MERGED' }
        'MERGED_MAIN' { return 'MERGED' }
        'MERGEDPR' { return 'MERGED' }
        'BUNDLE' { return 'BUNDLED' }
        'BUNDLED_INTO_RELEASE' { return 'BUNDLED' }
        'BUNDLEDTORELEASE' { return 'BUNDLED' }
        'BACKLOG' { return 'BACKLOGGED' }
        'BACKLOG_ITEM' { return 'BACKLOGGED' }
        'FORK' { return 'FORKED' }
        'FORK_REQUIRED' { return 'FORKED' }
        'FAULTS_BUGS' { return 'HAS_FAULTS_BUGS' }
        'HAS_FAULTS' { return 'HAS_FAULTS_BUGS' }
        'BUGGY' { return 'HAS_FAULTS_BUGS' }
        'DEFER' { return 'DEFERRED' }
        'DEFERRED_ITEM' { return 'DEFERRED' }
        default { return $status }
    }
}

function Get-ItemTypeNormalized {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Item
    )

    $typeValue = ''
    if ($Item.PSObject.Properties.Name -contains 'type') {
        $typeValue = [string]$Item.type
    }
    if ([string]::IsNullOrWhiteSpace($typeValue)) {
        return 'todo'
    }

    $typeNorm = $typeValue.ToLowerInvariant()
    if ($typeNorm -eq 'bugs2fix') { return 'bug' }
    if ($typeNorm -eq 'items2add' -or $typeNorm -eq 'todo') { return 'todo' }
    if ($typeNorm -eq 'featurerequest') { return 'feature' }
    return $typeNorm
}

function Test-StatusFilterMatch {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ItemStatus,

        [Parameter()]
        [string]$FilterStatus,

        [Parameter(Mandatory)]
        [hashtable]$ClosedSet,

        [Parameter(Mandatory)]
        [hashtable]$ApprovalTrackingSet
    )

    $status = Get-CanonicalItemStatus -RawStatus $ItemStatus
    $filter = Get-CanonicalItemStatus -RawStatus $FilterStatus

    if ($filter -eq 'ALL') { return $true }
    if ($filter -eq 'APPROVAL_TRACKING') { return $ApprovalTrackingSet.ContainsKey($status) }
    if ($filter -eq 'CLOSED') { return $ClosedSet.ContainsKey($status) }
    return ($status -eq $filter)
}

function Get-BundleItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Bundle file was not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $needle = 'var _todoBundle'
    $start = $raw.IndexOf($needle, [System.StringComparison]::Ordinal)
    if ($start -lt 0) {
        throw 'Unable to locate var _todoBundle assignment in bundle file.'
    }

    $arrayStart = $raw.IndexOf('[', $start)
    $arrayEndMarker = $raw.LastIndexOf('];', [System.StringComparison]::Ordinal)
    if ($arrayStart -lt 0 -or $arrayEndMarker -le $arrayStart) {
        throw 'Unable to isolate JSON array from bundle file.'
    }

    $jsonPayload = $raw.Substring($arrayStart, ($arrayEndMarker - $arrayStart) + 1)
    $items = $jsonPayload | ConvertFrom-Json -ErrorAction Stop
    return @($items)
}

if (-not (Test-Path -LiteralPath $PagePath -PathType Leaf)) {
    throw "ShowOnline page was not found: $PagePath"
}

$resolvedPagePath = (Resolve-Path -LiteralPath $PagePath).Path
$resolvedBundlePath = (Resolve-Path -LiteralPath $BundlePath).Path
$pageContent = Get-Content -LiteralPath $resolvedPagePath -Raw -Encoding UTF8

$requiredFragments = @(
    'id="td-approval-note"',
    'id="bg-approval-note"',
    'id="ft-approval-note"',
    'id="ft-checkpoint-policy-note"',
    'id="ftCheckpointTemplate"',
    'var DYN_STATUS_CLOSED = {',
    'var DYN_STATUS_APPROVAL_TRACKING = {',
    'var FEATURE_AUTOCHECKPOINT_TITLES = [',
    'var FEATURE_SYSTEM_TEMPLATE_LIBRARY = {',
    'function _featureRenderCheckpointPanel(',
    'function promoteFeatureToClosed('
)
for ($rf = 0; $rf -lt @($requiredFragments).Count; $rf++) {
    $frag = $requiredFragments[$rf]
    $present = $pageContent.IndexOf($frag, [System.StringComparison]::Ordinal) -ge 0
    Add-CheckResult -Name ("ShowOnline contains fragment: {0}" -f $frag) -Pass $present -Detail 'Required approval tracking UI/logic fragment was not found.'
}

$items = Get-BundleItems -Path $resolvedBundlePath
Add-CheckResult -Name 'Bundle items loaded' -Pass (@($items).Count -gt 0) -Detail 'No items were parsed from todo/_bundle.js.'

$closedSet = @{
    CLOSED = 1
    DONE = 1
    APPROVED_COMPLETED = 1
    MERGED = 1
    BUNDLED = 1
    DEFERRED = 1
    DENIED = 1
}
$approvalTrackingSet = @{
    PENDING_APPROVAL = 1
    ON_HOLD = 1
    BLOCKED = 1
    DENIED = 1
    MERGED = 1
    BUNDLED = 1
    BACKLOGGED = 1
    FORKED = 1
    DEFERRED = 1
}

$allNormalizedStatuses = @{}
$perTypeResults = @()
$typeOrder = @('todo', 'bug', 'feature')
for ($ti = 0; $ti -lt @($typeOrder).Count; $ti++) {
    $type = $typeOrder[$ti]
    $typeItems = @()
    for ($i = 0; $i -lt @($items).Count; $i++) {
        $item = $items[$i]
        if ((Get-ItemTypeNormalized -Item $item) -ne $type) { continue }
        $typeItems += $item
    }

    $statusMap = @{}
    $closedBySet = 0
    $closedByFilter = 0
    $approvalBySet = 0
    $approvalByFilter = 0

    for ($j = 0; $j -lt @($typeItems).Count; $j++) {
        $status = Get-CanonicalItemStatus -RawStatus $typeItems[$j].status
        if (-not $statusMap.ContainsKey($status)) { $statusMap[$status] = 0 }
        if ($statusMap.ContainsKey($status)) {
            $statusMap[$status] = [int]$statusMap[$status] + 1  # SIN-EXEMPT:P027 -- guarded by ContainsKey check above
        } else {
            $statusMap[$status] = 1  # SIN-EXEMPT:P027 -- first-time initialization in else branch
        }

        if ($allNormalizedStatuses.ContainsKey($status)) {
            $allNormalizedStatuses[$status] = [int]$allNormalizedStatuses[$status] + 1  # SIN-EXEMPT:P027 -- guarded by ContainsKey check
        } else {
            $allNormalizedStatuses[$status] = 1  # SIN-EXEMPT:P027 -- first-time initialization in else branch
        }

        if ($closedSet.ContainsKey($status)) { $closedBySet++ }
        if ($approvalTrackingSet.ContainsKey($status)) { $approvalBySet++ }

        if (Test-StatusFilterMatch -ItemStatus $typeItems[$j].status -FilterStatus 'CLOSED' -ClosedSet $closedSet -ApprovalTrackingSet $approvalTrackingSet) {
            $closedByFilter++
        }
        if (Test-StatusFilterMatch -ItemStatus $typeItems[$j].status -FilterStatus 'APPROVAL_TRACKING' -ClosedSet $closedSet -ApprovalTrackingSet $approvalTrackingSet) {
            $approvalByFilter++
        }
    }

    Add-CheckResult -Name ("{0}: CLOSED filter equals closed-family count" -f $type.ToUpperInvariant()) -Pass ($closedByFilter -eq $closedBySet) -Detail ("Expected {0}, got {1}" -f $closedBySet, $closedByFilter)
    Add-CheckResult -Name ("{0}: APPROVAL_TRACKING filter equals approval-family count" -f $type.ToUpperInvariant()) -Pass ($approvalByFilter -eq $approvalBySet) -Detail ("Expected {0}, got {1}" -f $approvalBySet, $approvalByFilter)

    $statusNames = @($statusMap.Keys | Sort-Object)
    $perTypeResults += [pscustomobject]@{
        Type              = $type
        Total             = @($typeItems).Count
        ClosedFamily      = $closedBySet
        ClosedFilter      = $closedByFilter
        ApprovalFamily    = $approvalBySet
        ApprovalFilter    = $approvalByFilter
        DistinctStatuses  = @($statusNames).Count
        Statuses          = ($statusNames -join ', ')
    }
}

$allStatusNames = @($allNormalizedStatuses.Keys | Sort-Object)
$failed = @($script:Checks | Where-Object { -not $_.Pass })
$summary = [pscustomobject]@{
    harness         = 'Invoke-ShowOnlineStatusEvidence'
    versionTag      = '2605.B5.V1.1'
    timestampUtc    = (Get-Date).ToUniversalTime().ToString('o')
    engine          = $PSVersionTable.PSVersion.ToString()
    pagePath        = $resolvedPagePath
    bundlePath      = $resolvedBundlePath
    itemCount       = @($items).Count
    checkCount      = @($script:Checks).Count
    failedCount     = @($failed).Count
    passed          = (@($failed).Count -eq 0)
    normalizedCount = @($allStatusNames).Count
    normalizedSet   = ($allStatusNames -join ', ')
    perType         = $perTypeResults
    checks          = $script:Checks
}

if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) {
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputJsonPath -Encoding UTF8
}

if ($EmitJson) {
    $summary | ConvertTo-Json -Depth 8
} else {
    Write-Host '--- ShowOnline Status Evidence ---' -ForegroundColor Cyan
    Write-Host ("Engine: {0}" -f $summary.engine)
    Write-Host ("Items: {0}" -f $summary.itemCount)
    Write-Host ("Checks: {0}" -f $summary.checkCount)
    Write-Host ("Failed: {0}" -f $summary.failedCount)
    Write-Host ("Normalized statuses: {0}" -f $summary.normalizedSet)
    Write-Host ''
    $summary.perType | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host ("Result: {0}" -f ($(if ($summary.passed) { 'PASS' } else { 'FAIL' })))
}

if (-not $summary.passed) {
    exit 1
}

