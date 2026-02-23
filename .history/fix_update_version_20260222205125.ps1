# VersionTag: 2602.a.11
# VersionTag: 2602.a.10
# VersionTag: 2602.a.9
# VersionTag: 2602.a.8
$path = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Main-GUI.ps1'
$lines=Get-Content $path
$start=[Array]::IndexOf($lines,'function Update-VersionTags {')
$end=[Array]::IndexOf($lines,'function Generate-BuildManifest {')
if($start -lt 0 -or $end -lt 0){ Write-Host 'could not locate functions'; exit 1 }
$before=$lines[0..($start-1)]
$after=$lines[$end..($lines.Length-1)]
$newfunc=@(
'# update files in workspace with a version comment tag',
'function Update-VersionTags {',
'    $major = Get-ConfigSubValue "Version/Major"',
'    $minor = Get-ConfigSubValue "Version/Minor"',
'    $build = Get-ConfigSubValue "Version/Build"',
'    $versionString = "$major.$minor.$build"',
'    $exclude = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"',
'',
'    Write-Log "Updating version tags to $versionString" "Info"',
'    $workspace = Get-Location',
'    Get-ChildItem -File -Recurse | Where-Object {',
'        $rel = $_.FullName.Substring($workspace.Path.Length).TrimStart("\\")',
'        $skip = $false',
'        foreach($ex in $exclude) {',
'            if ($rel -like "${ex}*") { $skip = $true; break }',
'        }',
'        -not $skip',
'    } | ForEach-Object {',
'        $file = $_',
'        # remove version tags from JSON files and then skip',
'        if ($file.Extension -ieq ".json") {',
'            $txt = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue',
        # NOTE: split string to avoid false-positive version tag detection
        '        if ($null -ne $txt -and $txt -match "' + 'Version' + 'Tag:") {',
        '            $clean = $txt -replace "(?m)^\\s*#\\s*' + 'Version' + 'Tag:.*$\\r?\\n?", ""',
'            }',
'            return',
'        }',
'        # skip other binaries',
'        if ($file.Extension -ieq ".exe" -or $file.Extension -ieq ".dll") { return }',
'        $text = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue',
'        if ($null -eq $text) { return }',
'        $commentPrefix = "#"',
'        $commentSuffix = ""',
'        switch -Regex ($file.Extension) {',
'            "\.xml$" { $commentPrefix = "<!--"; $commentSuffix=" -->" }',
'            "\.ps1$|\.psm1$|\.psd1$|\.txt$|\.md$" { $commentPrefix="#"; $commentSuffix="" }',
'            default { $commentPrefix="#"; $commentSuffix="" }',
'        }',
# VersionTag: 2602.a.7
# VersionTag: 2602.a.7
# VersionTag: 2602.a.7
'        } else {',
'            $newText = $tagLine + [Environment]::NewLine + $text',
'        }',
'        if ($newText -ne $text) {',
'            Set-Content -Path $file.FullName -Value $newText -ErrorAction SilentlyContinue',
'        }',
'    }',
'}'
)
$newContent = $before + $newfunc + $after
$newContent | Set-Content $path -Encoding UTF8
Write-Host 'Update-VersionTags rewritten'




