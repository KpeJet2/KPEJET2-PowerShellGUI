# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# Show-Objectives: Patch Main-GUI version check logic predictably and produce clear mismatch reporting artifacts.
<#
.SYNOPSIS
    Patch: rewrites Check-VersionTags in Main-GUI.ps1

.DESCRIPTION
    Locates the Check-VersionTags function boundary in Main-GUI.ps1 and
    replaces its body with the updated implementation defined in this script.
    Run once after a version update to apply the patch.

.NOTES
    Author   : The Establishment
    Version  : 2602.a.11
    Target   : Main-GUI.ps1 (located relative to this script automatically)
    Modified : 22nd February 2026

.LINK
    ~README.md/VERSION-UPDATES.md
#>
$path = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Main-GUI.ps1'
$lines=Get-Content $path
$start=[Array]::IndexOf($lines,'function Check-VersionTags {')
$end=[Array]::IndexOf($lines,'function Compare-ExcludedFolders {')
if($start -lt 0 -or $end -lt 0){ Write-Host 'could not locate functions'; exit 1 }
$before=$lines[0..($start-1)]
$after=$lines[$end..($lines.Length-1)]
$newfunc=@(
'function Check-VersionTags {',
'    $major    = Get-ConfigSubValue "Version/Major"',
'    $minor    = Get-ConfigSubValue "Version/Minor"',
'    $build    = Get-ConfigSubValue "Version/Build"',
'    $expected = "$major.$minor.$build"',
'    $workspace = Get-Location',
'    $diffs    = @()',
'    $xmlRows  = @()',
'    Write-Log "Checking version tags against expected $expected" "Info"',
'    $exclude = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"',
'    Get-ChildItem -File -Recurse | Where-Object {',
'        $rel = $_.FullName.Substring($workspace.Path.Length).TrimStart("\\")',
'        $skip = $false',
'        foreach ($ex in $exclude) { if ($rel -like "${ex}*") { $skip = $true; break } }',
'        -not $skip',
'    } | ForEach-Object {',
'        $file = $_',
'        try {',
'            $content = Get-Content $file.FullName -Raw -ErrorAction Stop',
'            if ($null -eq $content -or $content.Trim() -eq "") { return }',
'            if ($content -match "VersionTag:\s*([\d\.a-z]+)") {',
'                $tag = $Matches[1]',
'                if ($tag -ne $expected) {',
'                    $msg = "MISMATCH  | File: $($file.FullName)`n           Expected : $expected`n           Found    : $tag"',
'                    $diffs  += $msg',
'                    $xmlRows += [pscustomobject]@{ Status="Mismatch"; File=$file.FullName; Expected=$expected; Found=$tag }',
'                    Write-Host $msg -ForegroundColor Red',
'                }',
'            } else {',
'                $msg = "MISSING   | File: $($file.FullName)`n           Expected : $expected`n           Found    : <no tag>"',
'                $diffs  += $msg',
'                $xmlRows += [pscustomobject]@{ Status="Missing"; File=$file.FullName; Expected=$expected; Found="" }',
'                Write-Host $msg -ForegroundColor Yellow',
'            }',
'        } catch {',
'            $msg = "READ-ERR  | File: $($file.FullName)`n           Error    : $($_.Exception.Message)"',
'            $diffs  += $msg',
'            $xmlRows += [pscustomobject]@{ Status="ReadError"; File=$file.FullName; Expected=$expected; Found=$_.Exception.Message }',
'            Write-Host $msg -ForegroundColor DarkYellow',
'        }',
'    }',
'    Compare-ExcludedFolders -workspace $workspace -diffs ([ref]$diffs)',
'',
'    # ---- directory setup ----',
'    $tempDir    = Join-Path $workspace.Path "temp"',
'    $logsDir    = Join-Path $workspace.Path "logs"',
'    $reportsDir = Join-Path $workspace.Path "~REPORTS"',
'    foreach ($d in @($tempDir, $logsDir, $reportsDir)) {',
'        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }',
'    }',
'',
'    # ---- filenames keyed on build tag ----',
'    $buildTag   = "$major$minor-$build"',
'    $baseName   = "pwshGUI-v-$buildTag-versionbuild~DIFFS"',
'    $txtFile    = Join-Path $tempDir  "$baseName.txt"',
'    $xmlReport  = Join-Path $reportsDir "$baseName.xml"',
'',
'    # ---- write txt snapshot to temp ----',
'    $diffs | Out-File -FilePath $txtFile -Encoding UTF8',
'    Write-Log "Version diff snapshot written to temp: $baseName.txt" "Info"',
'',
'    # ---- always write XML report to ~REPORTS ----',
'    try {',
'        $xmlDoc  = [System.Xml.XmlDocument]::new()',
'        $decl    = $xmlDoc.CreateXmlDeclaration("1.0","UTF-8",$null)',
'        $xmlDoc.AppendChild($decl) | Out-Null',
'        $root    = $xmlDoc.CreateElement("VersionCheckReport")',
'        $root.SetAttribute("Generated", (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))',
'        $root.SetAttribute("Expected",  $expected)',
'        $root.SetAttribute("DiffCount", $xmlRows.Count)',
'        $xmlDoc.AppendChild($root) | Out-Null',
'        foreach ($row in $xmlRows) {',
'            $entry = $xmlDoc.CreateElement("Entry")',
'            $entry.SetAttribute("Status",   $row.Status)',
'            $entry.SetAttribute("Expected", $row.Expected)',
'            $entry.SetAttribute("Found",    $row.Found)',
'            $fileNode = $xmlDoc.CreateElement("File")',
'            $fileNode.InnerText = $row.File',
'            $entry.AppendChild($fileNode) | Out-Null',
'            $root.AppendChild($entry) | Out-Null',
'        }',
'        $xmlDoc.Save($xmlReport)',
'        Write-Log "XML report written to ~REPORTS: $baseName.xml" "Info"',
'    } catch {',
'        Write-Log "Failed to write XML report: $($_.Exception.Message)" "Warning"',
'    }',
'',
'    # ---- move txt to logs if diffs found, otherwise keep in temp ----',
'    if ($diffs.Count -gt 0) {',
'        $logFile = Join-Path $logsDir "$baseName.txt"',
'        Move-Item -Path $txtFile -Destination $logFile -Force',
'        Write-Log "Diffs detected ($($diffs.Count)) - txt moved to logs: $baseName.txt" "Warning"',
'        Write-Host "Diff log : logs\$baseName.txt" -ForegroundColor Yellow',
'        Write-Host "XML report: ~REPORTS\$baseName.xml" -ForegroundColor Yellow',
'    } else {',
'        Write-Log "No diffs detected - temp snapshot retained: $baseName.txt" "Info"',
'        Write-Host "No diffs detected." -ForegroundColor Green',
'        Write-Host "Snapshot  : temp\$baseName.txt" -ForegroundColor Green',
'        Write-Host "XML report: ~REPORTS\$baseName.xml" -ForegroundColor Green',
'    }',
'}'
)
$newContent = $before + $newfunc + $after
$newContent | Set-Content $path -Encoding UTF8
Write-Host 'Check-VersionTags rewritten'







<# Outline:
    Rewrites the Check-VersionTags function in Main-GUI.ps1 with deterministic reporting behavior.
#>

<# Objectives-Review:
    Objective is met for mismatch detection and report persistence.
    Improvement recommendation: add optional strict mode that fails fast on read errors.
#>

<# Problems:
    Boundary discovery relies on exact function names in Main-GUI.ps1.
#>





