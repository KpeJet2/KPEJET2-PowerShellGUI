# VersionTag: 2602.a.11
<#
.SYNOPSIS
    Patch: rewrites Update-VersionTags in Main-GUI.ps1

.DESCRIPTION
    Locates the Update-VersionTags function boundary in Main-GUI.ps1 and
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
        # NOTE: split string to avoid false-positive version tag detection
        ('        $tagLine = "$commentPrefix ' + 'Version' + 'Tag: $versionString$commentSuffix"'),
        '        $newText = $text',
        ('        if ($text -match "^(.*)' + 'Version' + 'Tag:\s*([\d\.a-z]+)(.*)$") {'),
        '            $existingVer = $Matches[2]',
        '            if ($existingVer -ne $versionString) {',
        ('                $newText = $text -replace "(?m)^\s*(#|<!--)\s*' + 'Version' + 'Tag:.*?(-->)?\s*$", $tagLine'),
        '            }',
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




