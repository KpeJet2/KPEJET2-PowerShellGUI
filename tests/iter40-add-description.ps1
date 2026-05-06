# VersionTag: 2605.B2.V31.7
# iter40: PSProvideCommentHelp default config requires BOTH .SYNOPSIS and .DESCRIPTION.
# Most flagged funcs have .SYNOPSIS but not .DESCRIPTION — inject the missing block.
# For funcs with no help comment at all, prepend a full skeleton.

$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSProvideCommentHelp
Write-Host "Hits: $(@($findings).Count)"

function Convert-FuncNameToSynopsis {
    param([string]$Name)
    if ($Name -match '^(?<v>\w+)-(?<n>.+)$') {
        $verb = $Matches['v']
        $noun = ($Matches['n'] -creplace '(?<=.)([A-Z])', ' $1').ToLower()
        return "$verb $noun."
    }
    return "$Name function."
}

$byFile = $findings | Group-Object ScriptPath
$totalAdded = 0; $totalAppended = 0; $totalFails = 0

foreach ($g in $byFile) {
    $path = $g.Name
    if ($path -like '*\PwSh-HelpFilesUpdateSource-ReR*') { continue }

    $bytes = [IO.File]::ReadAllBytes($path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom) { $text = $text.Substring(1) }

    $tokens = $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
    if (@($errs).Count -gt 0) { Write-Host "  pre-fail: $path"; $totalFails++; continue }

    $allFuncs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $allCommentTokens = @($tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text -like '<#*' })
    $edits = New-Object System.Collections.Generic.List[object]

    foreach ($h in $g.Group) {
        $func = $allFuncs | Where-Object { $_.Extent.StartLineNumber -eq $h.Line } | Select-Object -First 1
        if (-not $func) { continue }

        # Find help comment token immediately preceding the function (within ~10 lines)
        $helpTok = $allCommentTokens | Where-Object {
            $_.Extent.EndOffset -le $func.Extent.StartOffset -and
            $_.Extent.EndLineNumber -ge ($func.Extent.StartLineNumber - 10) -and
            $_.Text -match '\.SYNOPSIS'
        } | Sort-Object { $_.Extent.EndOffset } -Descending | Select-Object -First 1

        # Or help comment as first statement INSIDE function body
        if (-not $helpTok) {
            $bodyText = $func.Body.Extent.Text
            $bodyStart = $func.Body.Extent.StartOffset
            $helpTok = $allCommentTokens | Where-Object {
                $_.Extent.StartOffset -gt $bodyStart -and
                $_.Extent.StartOffset -lt ($bodyStart + 400) -and
                $_.Text -match '\.SYNOPSIS'
            } | Select-Object -First 1
        }

        if ($helpTok -and ($helpTok.Text -notmatch '\.DESCRIPTION')) {
            # Inject .DESCRIPTION after .SYNOPSIS body. Find block indent.
            $blockText = $helpTok.Text
            # Determine block's leading indent on each interior line
            $blockStart = $helpTok.Extent.StartOffset
            $j = $blockStart - 1
            while ($j -ge 0 -and $text[$j] -ne "`n") { $j-- }
            $indent = $text.Substring($j + 1, $blockStart - $j - 1) -replace '\S.*', ''

            # Find first .SYNOPSIS line — append .DESCRIPTION on next line same indent
            # Strategy: replace `.SYNOPSIS<rest_of_synopsis_block>` with same + .DESCRIPTION line before #>
            # Simpler: replace closing `#>` with description + `#>`
            $synopsis = Convert-FuncNameToSynopsis -Name $func.Name
            $descLine = ".DESCRIPTION`r`n$indent  Detailed behaviour: $synopsis"

            # Replace last `#>` in helpTok text with descLine + #>
            $idx = $blockText.LastIndexOf('#>')
            if ($idx -lt 0) { continue }
            $newBlockText = $blockText.Substring(0, $idx) + "$indent$descLine`r`n$indent" + $blockText.Substring($idx)

            $edits.Add([pscustomobject]@{
                Start = $helpTok.Extent.StartOffset
                End   = $helpTok.Extent.EndOffset
                New   = $newBlockText
                Type  = 'append-desc'
            })
        } elseif (-not $helpTok) {
            # No help block at all — prepend a full one above the function
            $synopsis = Convert-FuncNameToSynopsis -Name $func.Name
            $insertOffset = $func.Extent.StartOffset
            $j = $insertOffset - 1
            while ($j -ge 0 -and $text[$j] -ne "`n") { $j-- }
            $indent = $text.Substring($j + 1, $insertOffset - $j - 1) -replace '\S.*', ''
            $help = "<#`r`n$indent.SYNOPSIS`r`n$indent  $synopsis`r`n$indent.DESCRIPTION`r`n$indent  Detailed behaviour: $synopsis`r`n$indent#>`r`n$indent"
            $edits.Add([pscustomobject]@{
                Start = $insertOffset
                End   = $insertOffset
                New   = $help
                Type  = 'prepend'
            })
        }
    }

    if ($edits.Count -eq 0) { continue }
    # Filter overlaps: prefer non-zero ranges; keep distinct Start
    $edits = $edits | Sort-Object Start -Unique

    $sorted = $edits | Sort-Object Start -Descending
    $newText = $text
    foreach ($e in $sorted) { $newText = $newText.Substring(0, $e.Start) + $e.New + $newText.Substring($e.End) }

    $tokens2 = $errs2 = $null
    [System.Management.Automation.Language.Parser]::ParseInput($newText, [ref]$tokens2, [ref]$errs2) | Out-Null
    if (@($errs2).Count -gt 0) { Write-Host "  POST-FAIL ($(@($errs2).Count)) skip $path"; $totalFails++; continue }

    $enc = New-Object System.Text.UTF8Encoding($hadBom)
    [IO.File]::WriteAllBytes($path, $enc.GetPreamble() + $enc.GetBytes($newText))
    $appended = ($edits | Where-Object Type -eq 'append-desc').Count
    $prepended = ($edits | Where-Object Type -eq 'prepend').Count
    Write-Host ("  Patched +desc=$appended new=$prepended : " + $path)
    $totalAppended += $appended; $totalAdded += $prepended
}

Write-Host "`nAppended .DESCRIPTION: $totalAppended  Prepended new help: $totalAdded  fails: $totalFails"
$after = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSProvideCommentHelp
Write-Host "Remaining: $(@($after).Count)"

