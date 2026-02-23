# VersionTag: 2602.a.11
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
    ~README.md/VERSIONS-UPDATE-1.1.0.md
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
'    $major = Get-ConfigSubValue "Version/Major"',
'    $minor = Get-ConfigSubValue "Version/Minor"',
'    $build = Get-ConfigSubValue "Version/Build"',
'    $expected = "$major.$minor.$build"',
'    $workspace = Get-Location',
'    $diffs = @()',
'    Write-Log "Checking version tags against expected $expected" "Info"',
'    Get-ChildItem -File -Recurse | Where-Object {',
'        $rel = $_.FullName.Substring($workspace.Path.Length).TrimStart("\\")',
'        $exclude = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"',
'        foreach($ex in $exclude) { if ($rel -like "${ex}*") { return $false } }',
'        return $true',
'    } | ForEach-Object {',
'        $file = $_',
'        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue',
'        if ($null -eq $content) { return }',
# VersionTag: 2602.a.7
'            $tag = $Matches[1]',
'            if ($tag -ne $expected) {',
'                $diffs += "$($file.FullName) - tag $tag expected $expected"',
'                Write-Host "[$file] version tag mismatch: $tag vs $expected" -ForegroundColor Red',
'            }',
'        } else {',
'            $diffs += "$($file.FullName) - missing tag"',
'            Write-Host "[$file] missing version tag" -ForegroundColor Yellow',
'        }',
'    }',
'    Compare-ExcludedFolders -workspace $workspace -diffs ([ref]$diffs)',
'    $tempDir  = Join-Path $workspace.Path "temp"',
'    $logsDir  = Join-Path $workspace.Path "logs"',
'    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }',
'    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }',
'    $buildTag  = "$major$minor-$build"',
'    $fileName  = "pwshGUI-v-$buildTag-versionbuild~DIFFS.txt"',
'    $tempFile  = Join-Path $tempDir $fileName',
'    $diffs | Out-File -FilePath $tempFile -Encoding UTF8',
'    Write-Log "Version diff written to temp: $fileName" "Info"',
'    if ($diffs.Count -gt 0) {',
'        $logFile = Join-Path $logsDir $fileName',
'        Move-Item -Path $tempFile -Destination $logFile -Force',
'        Write-Log "Diffs detected ($($diffs.Count)) - moved to logs: $fileName" "Warning"',
'        Write-Host "Diff log saved to logs\$fileName" -ForegroundColor Yellow',
'    } else {',
'        Write-Log "No diffs detected - temp file retained: $fileName" "Info"',
'        Write-Host "No diffs detected. Snapshot in temp\$fileName" -ForegroundColor Green',
'    }',
'}'
)
$newContent = $before + $newfunc + $after
$newContent | Set-Content $path -Encoding UTF8
Write-Host 'Check-VersionTags rewritten'




