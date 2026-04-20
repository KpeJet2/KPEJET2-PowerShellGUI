# VersionTag: 2604.B2.V31.0
# FileRole: Module
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 8 entries)
#Requires -Version 5.1
# TODO: HelpMenu | Show-AutoIssueFinderHelp | Actions: Scan|Report|Fix|Help | Spec: config/help-menu-registry.json

function Write-AIFLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("Info", "Warning", "Error")][string]$Level = "Info",
        [string]$LogPath
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    if ($LogPath) {
        $logDir = Split-Path $LogPath -Parent
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -Path $LogPath -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    }

    if ($Level -eq "Warning") {
        Write-Warning $entry
    } elseif ($Level -eq "Error") {
        Write-Error $entry -ErrorAction Continue
    } else {
        Write-Information $entry -InformationAction Continue
    }
}

function Save-AIFCheckpoint {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)][string]$CheckpointPath
    )
    $checkpointDir = Split-Path $CheckpointPath -Parent
    if (-not (Test-Path $checkpointDir)) { New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null }
    $json = $Data | ConvertTo-Json -Depth 6
    Set-Content -Path $CheckpointPath -Value $json -Encoding ascii
}

function Get-AIFCheckpoint {
    param([Parameter(Mandatory = $true)][string]$CheckpointPath)
    if (-not (Test-Path $CheckpointPath)) { return $null }
    try {
        $raw = Get-Content -Path $CheckpointPath -Raw
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-AIFDefaultPathList {
    param([string]$ModuleRoot)
    $root = if ($ModuleRoot) { Split-Path $ModuleRoot -Parent } else { Get-Location }.Path
    $paths = @($root)
    $scripts = Join-Path $root "scripts"
    $modules = Join-Path $root "modules"
    if (Test-Path $scripts) { $paths += $scripts }
    if (Test-Path $modules) { $paths += $modules }
    return @($paths | Select-Object -Unique)
}

function Get-AIFPriority {
    param(
        [string]$RuleName,
        [string]$Severity
    )
    $topRules = @(
        "PSAvoidUsingInvokeExpression",
        "PSAvoidUsingPlainTextForPassword",
        "PSAvoidUsingConvertToSecureStringWithPlainText",
        "PSAvoidUsingBrokenHashAlgorithms",
        "PSAvoidUsingWMICmdlet",
        "PSAvoidOverwritingBuiltInCmdlets",
        "PSUseShouldProcessForStateChangingFunctions"
    )
    $midRules = @(
        "PSAvoidAssignmentToAutomaticVariable",
        "PSAvoidUsingEmptyCatchBlock",
        "PSUseApprovedVerbs",
        "PSUseSingularNouns",
        "PSAvoidUsingWriteHost"
    )

    if ($topRules -contains $RuleName) { return 1 }
    if ($midRules -contains $RuleName) { return 2 }
    if ($Severity -eq "Error") { return 1 }
    if ($Severity -eq "Warning") { return 3 }
    return 4
}

function Get-AIFScanFileList {
    param(
        [string[]]$Paths,
        [switch]$IncludeSubfolders
    )

    $files = @()
    foreach ($path in $Paths) {
        if (-not (Test-Path $path)) { continue }
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($item -and $item.PSIsContainer) {
            $files += Get-ChildItem -Path $path -File -Recurse:$IncludeSubfolders -Include *.ps1,*.psm1,*.psd1 -ErrorAction SilentlyContinue
        } else {
            $files += $item
        }
    }

    return @($files | Where-Object { $_ -and $_.FullName } | Select-Object -ExpandProperty FullName -Unique)
}

function Save-AIFBaseline {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [switch]$IncludeSubfolders,
        [Parameter(Mandatory = $true)][string]$BaselinePath
    )

    $baselineDir = Split-Path $BaselinePath -Parent
    if (-not (Test-Path $baselineDir)) { New-Item -ItemType Directory -Path $baselineDir -Force | Out-Null }

    $snapshotRoot = Join-Path $baselineDir "baseline-files"
    if (-not (Test-Path $snapshotRoot)) { New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null }

    $files = Get-AIFScanFileList -Paths $Paths -IncludeSubfolders:$IncludeSubfolders
    $entries = @()
    foreach ($file in $files) {
        $snapshotPath = Get-AIFSnapshotPath -Path $file -SnapshotRoot $snapshotRoot
        $lines = Get-Content -LiteralPath $file -ErrorAction SilentlyContinue
        $lines | Set-Content -Path $snapshotPath -Encoding utf8
        $entries += [pscustomobject]@{
            Path = $file
            Snapshot = $snapshotPath
            LineCount = $lines.Count
        }
    }

    $baseline = [pscustomobject]@{
        created = (Get-Date).ToString("s")
        snapshotRoot = $snapshotRoot
        files = $entries
    }

    $json = $baseline | ConvertTo-Json -Depth 4
    Set-Content -Path $BaselinePath -Value $json -Encoding utf8
}

function Get-AIFBaseline {
    param([Parameter(Mandatory = $true)][string]$BaselinePath)
    if (-not (Test-Path $BaselinePath)) { return $null }
    try {
        $raw = Get-Content -Path $BaselinePath -Raw
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-AIFSnapshotPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SnapshotRoot
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path)
        $hash = $sha.ComputeHash($bytes)
        $hashText = ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
        return (Join-Path $SnapshotRoot ($hashText + ".txt"))
    } finally {
        $sha.Dispose()
    }
}

function Export-AIFDeltaXhtmlReport {
    param(
        [Parameter(Mandatory = $true)]$Delta,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$BaselinePath
    )

    $dateStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $summaryRows = @()
    $detailBlocks = @()

    foreach ($file in $Delta) {
        $summaryRows += "<tr><td>" + $file.Status + "</td><td>" + $file.Path + "</td><td>" + $file.ChangeCount + "</td></tr>"

        if ($file.ChangeCount -gt 0) {
            $detailRows = @()
            foreach ($line in $file.Changes) {
                $detailRows += "<tr><td>" + $line.Line + "</td><td>" + $line.Old + "</td><td>" + $line.New + "</td></tr>"
            }
            $block = "<h3>" + $file.Path + "</h3>" +
                "<table><thead><tr><th>Line</th><th>Old</th><th>New</th></tr></thead><tbody>" +
                ($detailRows -join "") + "</tbody></table>"
            $detailBlocks += $block
        }
    }

    $html = @()
    $html += "<?xml version='1.0' encoding='UTF-8'?>"
    $html += "<!DOCTYPE html PUBLIC '-//W3C//DTD XHTML 1.0 Strict//EN' 'http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd'>"
    $html += "<html xmlns='http://www.w3.org/1999/xhtml'>"
    $html += "<head><title>PwShGUI Line Delta Report</title>"
    $html += "<style type='text/css'>"
    $html += "body{font-family:Segoe UI, Arial, sans-serif;margin:20px;color:#222}"
    $html += "h1{font-size:20px;margin-bottom:6px}"
    $html += "h2{font-size:16px;margin-top:20px}"
    $html += "table{border-collapse:collapse;width:100%;font-size:12px;margin-bottom:16px}"
    $html += "th,td{border:1px solid #ccc;padding:6px;text-align:left;vertical-align:top}"
    $html += "th{background:#f2f2f2}"
    $html += ".meta{font-size:12px;color:#555}"
    $html += "</style></head><body>"
    $html += "<h1>PwShGUI Line Delta Report</h1>"
    $html += "<div class='meta'>Generated: $dateStr</div>"
    $html += "<div class='meta'>Baseline: $BaselinePath</div>"
    $html += "<h2>Summary</h2>"
    $html += "<table><thead><tr><th>Status</th><th>File</th><th>Changed Lines</th></tr></thead><tbody>"
    $html += ($summaryRows -join "")
    $html += "</tbody></table>"
    $html += "<h2>Details</h2>"
    $html += ($detailBlocks -join "")
    $html += "</body></html>"

    $reportDir = Split-Path $ReportPath -Parent
    if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    $html -join [Environment]::NewLine | Set-Content -Path $ReportPath -Encoding utf8
}

function Export-AIFXhtmlReport {
    param(
        [Parameter(Mandatory = $true)]$Issues,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string[]]$ScanPaths,
        [Parameter(Mandatory = $true)][string]$CheckpointPath
    )

    $total = $Issues.Count
    $dateStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $rows = foreach ($i in $Issues) {
        "<tr><td>" + $i.Priority + "</td><td>" + $i.RuleName + "</td><td>" + $i.Severity + "</td><td>" +
        $i.ScriptName + "</td><td>" + $i.Line + "</td><td>" + $i.Message + "</td></tr>"
    }

    $pathList = ($ScanPaths | ForEach-Object { "<li>" + $_ + "</li>" }) -join ""

    $html = @()
    $html += "<?xml version='1.0' encoding='UTF-8'?>"
    $html += "<!DOCTYPE html PUBLIC '-//W3C//DTD XHTML 1.0 Strict//EN' 'http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd'>"
    $html += "<html xmlns='http://www.w3.org/1999/xhtml'>"
    $html += "<head><title>PwShGUI AutoIssueFinder Schedule</title>"
    $html += "<style type='text/css'>"
    $html += "body{font-family:Segoe UI, Arial, sans-serif;margin:20px;color:#222}"
    $html += "h1{font-size:20px;margin-bottom:6px}"
    $html += "h2{font-size:16px;margin-top:20px}"
    $html += "table{border-collapse:collapse;width:100%;font-size:12px}"
    $html += "th,td{border:1px solid #ccc;padding:6px;text-align:left;vertical-align:top}"
    $html += "th{background:#f2f2f2}"
    $html += ".meta{font-size:12px;color:#555}"
    $html += "</style></head><body>"
    $html += "<h1>PwShGUI AutoIssueFinder Schedule</h1>"
    $html += "<div class='meta'>Generated: $dateStr</div>"
    $html += "<div class='meta'>Issue Count: $total</div>"
    $html += "<div class='meta'>Checkpoint: $CheckpointPath</div>"
    $html += "<h2>Scan Paths</h2><ul>$pathList</ul>"
    $html += "<h2>Prioritized Issues</h2>"
    $html += "<table><thead><tr><th>Priority</th><th>Rule</th><th>Severity</th><th>File</th><th>Line</th><th>Message</th></tr></thead><tbody>"
    $html += ($rows -join "")
    $html += "</tbody></table></body></html>"

    $reportDir = Split-Path $ReportPath -Parent
    if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    $html -join [Environment]::NewLine | Set-Content -Path $ReportPath -Encoding utf8
}

function Invoke-PwShGUIAutoIssueFinder {
    [CmdletBinding()]
    param(
        [string[]]$Paths,
        [switch]$IncludeSubfolders,
        [string]$OutputRoot,
        [string]$CheckpointPath,
        [string]$ReportPath,
        [switch]$Resume,
        [switch]$GenerateDeltaReport,
        [string]$BaselinePath,
        [string]$DeltaReportPath
    )

    $moduleRoot = $PSScriptRoot
    if (-not $Paths -or $Paths.Count -eq 0) {
        $defaultPaths = Get-AIFDefaultPathList -ModuleRoot $moduleRoot
        $prompt = Read-Host "Enter scan paths separated by ';' (Enter for defaults)"
        if ([string]::IsNullOrWhiteSpace($prompt)) {
            $Paths = $defaultPaths
        } else {
            $Paths = $prompt.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
    }
    if (-not $OutputRoot) {
        $root = Split-Path $moduleRoot -Parent
        $defaultRoot = Join-Path $root "logs\AutoIssueFinder-Logs"
        $promptRoot = Read-Host "Enter output root for logs/reports (Enter for $defaultRoot)"
        $OutputRoot = if ([string]::IsNullOrWhiteSpace($promptRoot)) { $defaultRoot } else { $promptRoot }
    }
    if (-not $CheckpointPath) { $CheckpointPath = Join-Path $OutputRoot "checkpoint.json" }
    if (-not $BaselinePath) { $BaselinePath = Join-Path $OutputRoot "baseline.json" }

    if (-not $IncludeSubfolders.IsPresent) {
        $promptRecurse = Read-Host "Include subfolders? (Y/n)"
        if ([string]::IsNullOrWhiteSpace($promptRecurse) -or $promptRecurse -match '^(y|yes)$') {
            $IncludeSubfolders = $true
        }
    }

    if (-not $Resume.IsPresent -and (Test-Path $CheckpointPath)) {
        $promptResume = Read-Host "Checkpoint found. Resume? (Y/n)"
        if ([string]::IsNullOrWhiteSpace($promptResume) -or $promptResume -match '^(y|yes)$') {
            $Resume = $true
        }
    }

    $dateStamp = Get-Date -Format "yyMMdd"
    $issues = @()

    if ($Resume) {
        $checkpoint = Get-AIFCheckpoint -CheckpointPath $CheckpointPath
        if ($checkpoint -and $null -ne $checkpoint.stage) {
            Write-AIFLog -Message "Resuming from checkpoint stage: $($checkpoint.stage)" -LogPath (Join-Path $OutputRoot "progress.log")
        }
    }

    Write-AIFLog -Message "Scanning paths: $($Paths -join ', ')" -LogPath (Join-Path $OutputRoot "progress.log")
    $recurse = $IncludeSubfolders.IsPresent

    $resolvedPaths = @()
    foreach ($p in $Paths) {
        if (Test-Path $p) { $resolvedPaths += (Resolve-Path $p).Path }
    }
    $resolvedPaths = @($resolvedPaths | Select-Object -Unique)

    $rootPath = Split-Path $moduleRoot -Parent
    foreach ($path in $resolvedPaths) {
        if (-not (Test-Path $path)) { continue }
        Write-AIFLog -Message "Scanning path: $path" -LogPath (Join-Path $OutputRoot "progress.log")
        $pathRecurse = $recurse
        if ($path -ieq $rootPath -and $resolvedPaths.Count -gt 1) {
            $pathRecurse = $false
        }
        try {
            $result = Invoke-ScriptAnalyzer -Path $path -Recurse:$pathRecurse -Severity Warning,Error
            foreach ($item in $result) {
                $priority = Get-AIFPriority -RuleName $item.RuleName -Severity $item.Severity
                $issues += [pscustomobject]@{
                    Priority = $priority
                    RuleName = $item.RuleName
                    Severity = $item.Severity
                    ScriptName = $item.ScriptName
                    Line = $item.Line
                    Message = $item.Message
                }
            }
        } catch {
            Write-AIFLog -Message "ScriptAnalyzer failed on ${path}: $($_.Exception.Message)" -Level "Warning" -LogPath (Join-Path $OutputRoot "progress.log")
        }

        $checkpointData = [pscustomobject]@{
            stage = "scan-path"
            scanPath = $path
            issueCount = $issues.Count
            scanPaths = $resolvedPaths
            timestamp = (Get-Date).ToString("s")
        }
        Save-AIFCheckpoint -Data $checkpointData -CheckpointPath $CheckpointPath
    }

    $issues = $issues | Sort-Object Priority,Severity,ScriptName,Line

    $checkpointData = [pscustomobject]@{
        stage = "scan-complete"
        issueCount = $issues.Count
        scanPaths = $Paths
        timestamp = (Get-Date).ToString("s")
    }
    Save-AIFCheckpoint -Data $checkpointData -CheckpointPath $CheckpointPath

    if (-not $ReportPath) {
        $reportName = "PwShGUI_AutoIssueFinder-$dateStamp-AutoFixing_Schedule" + $issues.Count + ".xhtml"
        $ReportPath = Join-Path $OutputRoot $reportName
    }

    Export-AIFXhtmlReport -Issues $issues -ReportPath $ReportPath -ScanPaths $Paths -CheckpointPath $CheckpointPath

    $checkpointData = [pscustomobject]@{
        stage = "report-generated"
        issueCount = $issues.Count
        scanPaths = $Paths
        timestamp = (Get-Date).ToString("s")
        reportPath = $ReportPath
    }
    Save-AIFCheckpoint -Data $checkpointData -CheckpointPath $CheckpointPath

    Write-AIFLog -Message "Report written to $ReportPath" -LogPath (Join-Path $OutputRoot "progress.log")

    $deltaReportPathValue = $null
    if ($GenerateDeltaReport) {
        if (-not (Test-Path $BaselinePath)) {
            Write-AIFLog -Message "Baseline not found. Creating baseline at $BaselinePath" -Level "Warning" -LogPath (Join-Path $OutputRoot "progress.log")
            Save-AIFBaseline -Paths $Paths -IncludeSubfolders:$IncludeSubfolders -BaselinePath $BaselinePath
        }

        $baseline = Get-AIFBaseline -BaselinePath $BaselinePath
        if (-not $baseline) {
            Write-AIFLog -Message "Baseline invalid or unreadable. Recreating baseline at $BaselinePath" -Level "Warning" -LogPath (Join-Path $OutputRoot "progress.log")
            Save-AIFBaseline -Paths $Paths -IncludeSubfolders:$IncludeSubfolders -BaselinePath $BaselinePath
            $baseline = Get-AIFBaseline -BaselinePath $BaselinePath
        }
        if ($baseline) {
            $currentFiles = Get-AIFScanFileList -Paths $Paths -IncludeSubfolders:$IncludeSubfolders
            $baselineFiles = @($baseline.files | ForEach-Object { $_.Path })
            $allFiles = @($currentFiles + $baselineFiles | Select-Object -Unique)
            $delta = @()
            foreach ($file in $allFiles) {
                $oldEntry = $baseline.files | Where-Object { $_.Path -eq $file } | Select-Object -First 1
                $oldLines = @()
                if ($oldEntry) {
                    if ($oldEntry.PSObject.Properties.Name -contains "Lines") {
                        $oldLines = @($oldEntry.Lines)
                    } elseif ($oldEntry.PSObject.Properties.Name -contains "Snapshot" -and (Test-Path $oldEntry.Snapshot)) {
                        $oldLines = @(Get-Content -LiteralPath $oldEntry.Snapshot -ErrorAction SilentlyContinue)
                    }
                }
                $newLines = if (Test-Path $file) { @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue) } else { @() }

                $status = "Unchanged"
                if (-not $oldEntry -and (Test-Path $file)) { $status = "Added" }
                elseif ($oldEntry -and -not (Test-Path $file)) { $status = "Removed" }

                $changes = @()
                $max = [Math]::Max($oldLines.Count, $newLines.Count)
                for ($i = 0; $i -lt $max; $i++) {
                    $oldLine = if ($i -lt $oldLines.Count) { $oldLines[$i] } else { "" }
                    $newLine = if ($i -lt $newLines.Count) { $newLines[$i] } else { "" }
                    if ($oldLine -ne $newLine) {
                        $changes += [pscustomobject]@{
                            Line = $i + 1
                            Old = $oldLine
                            New = $newLine
                        }
                    }
                }

                if ($status -eq "Unchanged" -and $changes.Count -gt 0) { $status = "Changed" }

                if ($changes.Count -gt 0 -or $status -ne "Unchanged") {
                    $delta += [pscustomobject]@{
                        Path = $file
                        Status = $status
                        ChangeCount = $changes.Count
                        Changes = $changes
                    }
                }
            }

            if (-not $DeltaReportPath) {
                $deltaName = "PwShGUI_AutoIssueFinder-$dateStamp-LineDeltaReport.xhtml"
                $DeltaReportPath = Join-Path $OutputRoot $deltaName
            }
            Export-AIFDeltaXhtmlReport -Delta $delta -ReportPath $DeltaReportPath -BaselinePath $BaselinePath
            $deltaReportPathValue = $DeltaReportPath
            Write-AIFLog -Message "Delta report written to $DeltaReportPath" -LogPath (Join-Path $OutputRoot "progress.log")
        }
    }

    return [pscustomobject]@{
        ReportPath = $ReportPath
        CheckpointPath = $CheckpointPath
        IssueCount = $issues.Count
        Issues = $issues
        BaselinePath = $BaselinePath
        DeltaReportPath = $deltaReportPathValue
    }
}

Export-ModuleMember -Function Invoke-PwShGUIAutoIssueFinder











