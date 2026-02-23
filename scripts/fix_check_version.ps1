# VersionTag: 2602.a.11
# VersionTag: 2602.a.10
# VersionTag: 2602.a.9
# VersionTag: 2602.a.8
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
'    $diffFile = Join-Path $workspace.Path ("pwshGUI-v-$major$minor-versionbuild~DIFFS.txt")',
'    $diffs | Out-File -FilePath $diffFile -Encoding UTF8',
'}'
)
$newContent = $before + $newfunc + $after
$newContent | Set-Content $path -Encoding UTF8
Write-Host 'Check-VersionTags rewritten'



