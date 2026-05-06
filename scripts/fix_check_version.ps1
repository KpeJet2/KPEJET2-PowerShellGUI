# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Maintenance
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 8 entries)
$rootPath = Split-Path -Parent $PSScriptRoot
$path = Join-Path $rootPath 'Main-GUI.ps1'
$lines = Get-Content $path
$start = [Array]::IndexOf($lines,'function Check-VersionTags {')
$end = [Array]::IndexOf($lines,'function Compare-ExcludedFolders {')
if($start -lt 0 -or $end -lt 0){ Write-Host 'could not locate functions'; exit 1 }
$before = $lines[0..($start-1)]
$after = $lines[$end..($lines.Length-1)]
$newfunc = @(
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
'        if ($content -match "(?m)^#\\s*VersionTag:\\s*(.+)$") {',
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
'    $stamp = Get-Date -Format ''yyyyMMdd-HHmm''',
'    $diffFile = Join-Path $versionsDir "PwShGUI-v-$expected~DIFFS-$stamp.txt"',
'    $diffs | Out-File -FilePath $diffFile -Encoding UTF8',
'    return $diffFile',
'}'
)
$newContent = $before + $newfunc + $after
$newContent | Set-Content $path -Encoding UTF8
Write-Host 'Check-VersionTags rewritten'











<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





