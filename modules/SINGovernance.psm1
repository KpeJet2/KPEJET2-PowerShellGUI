# VersionTag: 2604.B2.V31.0
# FileRole: Module
<#
.SYNOPSIS  SINGovernance - SIN review, approval, and SINeProofed workflow.
.DESCRIPTION
    Provides interactive Chief review of SIN registry entries with
    SHA-512 sealed approval (SINeProofed), ledger integration, and
    XHTML report generation.
# TODO: HelpMenu | Show-SINGovernanceHelp | Actions: Scan|Register|Audit|Report|Help | Spec: config/help-menu-registry.json
    
    Workflow:
    1. Get-SINReviewQueue   - list pending SINs
    2. Start-SINReview      - interactive per-SIN review
    3. Approve-SIN          - seal approval with SHA-512 hash + reviewer ID
    4. Deny-SIN             - mark as denied with reason
    5. Export-SINReviewReport - dark-themed XHTML report
#>
#Requires -Version 5.1

# ── Module state ─────────────────────────────────────────────
$script:_SINRegistryPath = $null
$script:_ReviewerID      = $null

function Initialize-SINGovernance {
    <#
    .SYNOPSIS  Set up the SIN governance module.
    .PARAMETER RegistryPath  Path to the sin_registry folder.
    .PARAMETER ReviewerID    Human-readable reviewer identifier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RegistryPath,

        [Parameter(Mandatory)]
        [string]$ReviewerID
    )
    if (-not (Test-Path $RegistryPath)) { throw "SIN registry not found: $RegistryPath" }
    $script:_SINRegistryPath = $RegistryPath
    $script:_ReviewerID      = $ReviewerID
    Write-Verbose "[SINGovernance] Initialized - Registry: $RegistryPath  Reviewer: $ReviewerID"
}

function Get-SINReviewQueue {
    <#
    .SYNOPSIS  List SINs pending review (not yet SINeProofed).
    .PARAMETER IncludeResolved  Also list resolved but un-approved SINs.
    #>
    [CmdletBinding()]
    param([switch]$IncludeResolved)
    if (-not $script:_SINRegistryPath) { throw '[SINGovernance] Not initialized.' }

    $queue = @()
    foreach ($file in (Get-ChildItem $script:_SINRegistryPath -Filter '*.json')) {
        $sin = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $approved = [bool]($sin.PSObject.Properties.Name -contains 'sineproofed')
        if ($approved) { continue }
        if (-not $IncludeResolved -and $sin.is_resolved -eq $true) { continue }
        $queue += [PSCustomObject]@{
            SIN_ID     = $sin.sin_id
            Title      = $sin.title
            Severity   = $sin.severity
            IsResolved = [bool]$sin.is_resolved
            CreatedAt  = $sin.created_at
            File       = $file.Name
        }
    }
    $queue | Sort-Object @{Expression='Severity';Descending=$true}, CreatedAt
}

function Approve-SIN {
    <#
    .SYNOPSIS  Seal a SIN as SINeProofed with SHA-512 hash.
    .PARAMETER SinId       The SIN identifier.
    .PARAMETER ReviewNotes Free-text review notes from the Chief.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SinId,

        [string]$ReviewNotes = ''
    )
    if (-not $script:_SINRegistryPath) { throw '[SINGovernance] Not initialized.' }
    if (-not $script:_ReviewerID)      { throw '[SINGovernance] ReviewerID not set.' }

    $file = Get-ChildItem $script:_SINRegistryPath -Filter '*.json' |
            Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).sin_id -eq $SinId } |
            Select-Object -First 1
    if (-not $file) { throw "SIN not found: $SinId" }

    $sin = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $ts  = (Get-Date).ToUniversalTime().ToString('o')

    # Build seal payload
    $sealPayload = "$SinId|$($script:_ReviewerID)|$ts|APPROVED|$ReviewNotes"

    # SHA-512 hash of the seal
    $sha = [System.Security.Cryptography.SHA512]::Create()
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sealPayload))
    $sealHash  = [BitConverter]::ToString($hashBytes).Replace('-', '').ToLower()

    # Apply SINeProofed stamp
    $seal = @{
        status     = 'APPROVED'
        reviewer   = $script:_ReviewerID
        timestamp  = $ts
        hash       = $sealHash
        notes      = $ReviewNotes
    }
    $sin | Add-Member -NotePropertyName 'sineproofed' -NotePropertyValue $seal -Force
    $sin | Add-Member -NotePropertyName 'status' -NotePropertyValue 'SINeProofed' -Force

    $sin | ConvertTo-Json -Depth 5 | Set-Content $file.FullName -Encoding UTF8
    Write-Verbose "[SINGovernance] APPROVED: $SinId by $($script:_ReviewerID)"

    # Write to ledger if available
    if (Get-Command Write-LedgerEntry -ErrorAction SilentlyContinue) {
        Write-LedgerEntry -EventType 'AUDIT' -Source 'SINGovernance' -Data @{
            action   = 'SINeProofed'
            sin_id   = $SinId
            reviewer = $script:_ReviewerID
            hash     = $sealHash
        }
    }

    [PSCustomObject]@{
        SIN_ID   = $SinId
        Status   = 'SINeProofed'
        Reviewer = $script:_ReviewerID
        Hash     = $sealHash.Substring(0, 32) + '...'
    }
}

function Deny-SIN {
    <#
    .SYNOPSIS  Mark a SIN as denied with reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SinId,

        [Parameter(Mandatory)]
        [string]$Reason
    )
    if (-not $script:_SINRegistryPath) { throw '[SINGovernance] Not initialized.' }

    $file = Get-ChildItem $script:_SINRegistryPath -Filter '*.json' |
            Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).sin_id -eq $SinId } |
            Select-Object -First 1
    if (-not $file) { throw "SIN not found: $SinId" }

    $sin = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $ts  = (Get-Date).ToUniversalTime().ToString('o')

    $denial = @{
        status    = 'DENIED'
        reviewer  = $script:_ReviewerID
        timestamp = $ts
        reason    = $Reason
    }
    $sin | Add-Member -NotePropertyName 'sineproofed' -NotePropertyValue $denial -Force
    $sin | Add-Member -NotePropertyName 'status' -NotePropertyValue 'Denied' -Force

    $sin | ConvertTo-Json -Depth 5 | Set-Content $file.FullName -Encoding UTF8
    Write-Verbose "[SINGovernance] DENIED: $SinId - $Reason"

    [PSCustomObject]@{ SIN_ID = $SinId; Status = 'Denied'; Reason = $Reason }
}

function Start-SINReview {
    <#
    .SYNOPSIS  Interactive per-SIN review session for the Chief.
    .DESCRIPTION
        Presents each pending SIN one at a time with details.
        Chief can Approve (A), Deny (D), Skip (S), or Quit (Q).
    #>
    [CmdletBinding()]
    param([switch]$IncludeResolved)
    if (-not $script:_SINRegistryPath) { throw '[SINGovernance] Not initialized.' }

    $queue = Get-SINReviewQueue -IncludeResolved:$IncludeResolved
    if ($queue.Count -eq 0) { Write-Host 'No SINs pending review.'; return }

    Write-Host "`n=== SIN Governance Review Session ===" -ForegroundColor Cyan
    Write-Host "Reviewer: $($script:_ReviewerID)  |  Queue: $($queue.Count) SINs`n"

    $reviewed = 0; $approved = 0; $denied = 0
    foreach ($entry in $queue) {
        $file = Get-ChildItem $script:_SINRegistryPath -Filter $entry.File
        $sin  = Get-Content $file.FullName -Raw | ConvertFrom-Json

        Write-Host ('=' * 60) -ForegroundColor DarkGray
        Write-Host "SIN:       $($sin.sin_id)" -ForegroundColor Yellow
        Write-Host "Title:     $($sin.title)"
        Write-Host "Severity:  $($sin.severity)" -ForegroundColor $(
            switch ($sin.severity) { 'CRITICAL' { 'Red' } 'HIGH' { 'Magenta' } 'MEDIUM' { 'Yellow' } default { 'Gray' } }
        )
        Write-Host "Category:  $($sin.category)"
        Write-Host "File:      $($sin.file_path)"
        Write-Host "Resolved:  $($sin.is_resolved)"
        if ($sin.description) { Write-Host "Desc:      $($sin.description)" }
        Write-Host ""

        $choice = ''
        while ($choice -notin @('A','D','S','Q')) {
            Write-Host '[A]pprove  [D]eny  [S]kip  [Q]uit: ' -ForegroundColor Green -NoNewline
            $choice = (Read-Host).ToUpper()
        }

        switch ($choice) {
            'A' {
                $notes = Read-Host 'Review notes (optional)'
                Approve-SIN -SinId $sin.sin_id -ReviewNotes $notes
                $approved++; $reviewed++
                Write-Host "  >> SINeProofed" -ForegroundColor Green
            }
            'D' {
                $reason = Read-Host 'Denial reason'
                Deny-SIN -SinId $sin.sin_id -Reason $reason
                $denied++; $reviewed++
                Write-Host "  >> Denied" -ForegroundColor Red
            }
            'S' { Write-Host "  >> Skipped" -ForegroundColor DarkYellow }
            'Q' {
                Write-Host "`nSession ended early." -ForegroundColor Yellow
                break
            }
        }
        Write-Host ""
    }

    Write-Host "`n=== Review Summary ===" -ForegroundColor Cyan
    Write-Host "Reviewed: $reviewed  Approved: $approved  Denied: $denied"
}

function Export-SINReviewReport {
    <#
    .SYNOPSIS  Generate dark-themed XHTML report of SIN review status.
    .PARAMETER OutputPath  Path for the XHTML file.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputPath = (Join-Path (Split-Path $script:_SINRegistryPath -Parent) '~REPORTS\SIN-Review-Report.xhtml')
    )
    if (-not $script:_SINRegistryPath) { throw '[SINGovernance] Not initialized.' }

    $sins = @()
    foreach ($file in (Get-ChildItem $script:_SINRegistryPath -Filter '*.json' | Sort-Object Name)) {
        $sins += Get-Content $file.FullName -Raw | ConvertFrom-Json
    }

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $rows = ''
    foreach ($s in $sins) {
        $statusClass = 'pending'
        $statusLabel = 'Pending'
        if ($s.PSObject.Properties.Name -contains 'sineproofed') {
            if ($s.sineproofed.status -eq 'APPROVED') { $statusClass = 'approved'; $statusLabel = 'SINeProofed' }
            else { $statusClass = 'denied'; $statusLabel = 'Denied' }
        }
        $sevClass = switch ($s.severity) { 'CRITICAL' { 'sev-critical' } 'HIGH' { 'sev-high' } 'MEDIUM' { 'sev-medium' } default { 'sev-low' } }
        $rows += "        <tr class=`"$statusClass`"><td>$([System.Security.SecurityElement]::Escape($s.sin_id))</td><td class=`"$sevClass`">$($s.severity)</td><td>$([System.Security.SecurityElement]::Escape($s.title))</td><td>$statusLabel</td><td>$($s.created_at)</td></tr>`n"
    }

    $xhtml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>SIN Governance Review Report</title>
    <style type="text/css">
        body { background: #1E1E1E; color: #D4D4D4; font-family: 'Cascadia Code', 'Consolas', monospace; margin: 2em; }
        h1 { color: #007ACC; border-bottom: 2px solid #007ACC; padding-bottom: 0.3em; }
        h2 { color: #4EC9B0; }
        table { border-collapse: collapse; width: 100%; margin-top: 1em; }
        th { background: #2D2D30; color: #007ACC; padding: 8px; text-align: left; border-bottom: 2px solid #007ACC; }
        td { padding: 6px 8px; border-bottom: 1px solid #3E3E42; }
        tr:hover { background: #264F78; }
        .approved td:first-child { border-left: 3px solid #4EC9B0; }
        .denied td:first-child { border-left: 3px solid #F44747; }
        .pending td:first-child { border-left: 3px solid #CE9140; }
        .sev-critical { color: #F44747; font-weight: bold; }
        .sev-high { color: #CE9140; }
        .sev-medium { color: #DCDCAA; }
        .sev-low { color: #608B4E; }
        .meta { color: #808080; font-size: 0.85em; margin-top: 2em; }
    </style>
</head>
<body>
    <h1>SIN Governance Review Report</h1>
    <p>Generated: $ts | Total SINs: $($sins.Count)</p>
    <table>
        <tr><th>SIN ID</th><th>Severity</th><th>Title</th><th>Status</th><th>Created</th></tr>
$rows
    </table>
    <p class="meta">PwShGUI SIN Governance System | SINeProofed Approval Workflow</p>
</body>
</html>
"@

    $dir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    Set-Content -Path $OutputPath -Value $xhtml -Encoding UTF8
    Write-Host "Report saved: $OutputPath"
    $OutputPath
}

# ── Exports ──────────────────────────────────────────────────
Export-ModuleMember -Function @(
    'Initialize-SINGovernance'
    'Get-SINReviewQueue'
    'Approve-SIN'
    'Deny-SIN'
    'Start-SINReview'
    'Export-SINReviewReport'
)

