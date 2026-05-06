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
$start = [Array]::IndexOf($lines,'function Update-VersionTags {')
$end = [Array]::IndexOf($lines,'function Generate-BuildManifest {')
if($start -lt 0 -or $end -lt 0){ Write-Host 'could not locate functions'; exit 1 }
$before = $lines[0..($start-1)]
$after = $lines[$end..($lines.Length-1)]
$newfunc = @(
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
'        # skip version build artifacts',
'        if ($file.Name -like ''PwShGUI-v-*'') { return }',
'        # remove version tags from JSON files and then skip',
'        if ($file.Extension -ieq ".json") {',
'            $txt = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue',
'            if ($txt) {',
'                $clean = $txt -replace "(?m)^\\s*#\\s*VersionTag:.*$\\r?\\n?", ""',
'                if ($clean -ne $txt) {',
'                    Set-Content -Path $file.FullName -Value $clean -Encoding UTF8 -ErrorAction SilentlyContinue',
'                }',
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
'            "\\.xml$" { $commentPrefix = "<!--"; $commentSuffix=" -->" }',
'            "\\.ps1$|\\.psm1$|\\.psd1$|\\.txt$|\\.md$" { $commentPrefix="#"; $commentSuffix="" }',
'            default { $commentPrefix="#"; $commentSuffix="" }',
'        }',
'        $tagLine = "$commentPrefix VersionTag: $versionString$commentSuffix"',
'        if ($text -match "(?m)^\\s*#\\s*VersionTag:.*$") {',
'            $newText = $text -replace "(?m)^\\s*#\\s*VersionTag:.*$", $tagLine',
'        } else {',
'            $newText = $tagLine + [Environment]::NewLine + $text',
'        }',
'        if ($newText -ne $text) {',
'            Set-Content -Path $file.FullName -Value $newText -Encoding UTF8 -ErrorAction SilentlyContinue',
'        }',
'    }',
'}'
)
$newContent = $before + $newfunc + $after
$newContent | Set-Content $path -Encoding UTF8
Write-Host 'Update-VersionTags rewritten'











<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





