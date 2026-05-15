# VersionTag: 2605.B5.V46.0
# iter39: bulk-add comment-based help skeleton to functions missing it.
# PSSA PSProvideCommentHelp fires on functions without .SYNOPSIS.
# We inject minimal <# .SYNOPSIS  Auto-generated stub: derived from function name. #>
# Above the function definition (proper PowerShell convention).
$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSProvideCommentHelp
Write-Host "Hits: $(@($findings).Count)"

function Convert-FuncNameToSynopsis {
    param([string]$Name)
    # Split on hyphens: Verb-NounPart -> "Verb noun part"
    if ($Name -match '^(?<v>\w+)-(?<n>.+)$') {
        $verb = $Matches['v']
        $noun = $Matches['n']
        # Insert space before each cap (not first char) in noun
        $nounSp = ($noun -creplace '(?<=.)([A-Z])', ' $1').ToLower()
        return "$verb $nounSp."
    }
    return "$Name function."
}

$byFile = $findings | Group-Object ScriptPath
$totalPatched = 0
$totalFails = 0

foreach ($g in $byFile) {
    $path = $g.Name
    if ($path -like '*\PwSh-HelpFilesUpdateSource-ReR*') { continue }

    $bytes = [IO.File]::ReadAllBytes($path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom) { $text = $text.Substring(1) }

    $tokens = $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
    if (@($errs).Count -gt 0) { Write-Host "  pre-fail: $path"; $totalFails++; continue }

    $allFuncs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $edits = New-Object System.Collections.Generic.List[object]

    foreach ($h in $g.Group) {
        # Findings reference the function on $h.Line (the 'function X {' line). Find that func.
        $func = $allFuncs | Where-Object { $_.Extent.StartLineNumber -eq $h.Line } | Select-Object -First 1
        if (-not $func) {
            # fallback: function spanning that line
            $func = $allFuncs | Where-Object {
                $_.Extent.StartLineNumber -le $h.Line -and $_.Extent.EndLineNumber -ge $h.Line
            } | Sort-Object { $_.Extent.EndOffset - $_.Extent.StartOffset } | Select-Object -First 1
        }
        if (-not $func) { continue }

        # Skip if function body already has a CommentHelp comment as first statement OR there's a help block above
        $bodyText = $func.Body.Extent.Text
        if ($bodyText -match '\.SYNOPSIS') { continue }

        # Check 200 chars before the function start for an existing help comment
        $preStart = [Math]::Max(0, $func.Extent.StartOffset - 400)
        $preChunk = $text.Substring($preStart, $func.Extent.StartOffset - $preStart)
        if ($preChunk -match '\.SYNOPSIS\s') { continue }

        $synopsis = Convert-FuncNameToSynopsis -Name $func.Name

        # Insert just before the 'function' keyword line — line-prefix indent
        $insertOffset = $func.Extent.StartOffset
        $j = $insertOffset - 1
        while ($j -ge 0 -and $text[$j] -ne "`n") { $j-- }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        $indent = $text.Substring($j + 1, $insertOffset - $j - 1) -replace '\S.*', ''

        $help = "<#`r`n$indent.SYNOPSIS`r`n$indent  $synopsis`r`n$indent#>`r`n$indent"

        $edits.Add([pscustomobject]@{
            Start = $insertOffset
            End   = $insertOffset
            New   = $help
        })
    }

    if ($edits.Count -eq 0) { continue }

    # de-dup edits by Start (in case same func appeared twice)
    $edits = $edits | Sort-Object Start -Unique

    $sorted = $edits | Sort-Object Start -Descending
    $newText = $text
    foreach ($e in $sorted) { $newText = $newText.Substring(0, $e.Start) + $e.New + $newText.Substring($e.End) }

    $tokens2 = $errs2 = $null
    [System.Management.Automation.Language.Parser]::ParseInput($newText, [ref]$tokens2, [ref]$errs2) | Out-Null
    if (@($errs2).Count -gt 0) { Write-Host "  POST-FAIL ($(@($errs2).Count)) skip $path"; $totalFails++; continue }

    $enc = New-Object System.Text.UTF8Encoding($hadBom)
    [IO.File]::WriteAllBytes($path, $enc.GetPreamble() + $enc.GetBytes($newText))
    Write-Host ("  Patched " + @($edits).Count + " : " + $path)
    $totalPatched += @($edits).Count
}

Write-Host "`nTotal: $totalPatched (fails: $totalFails)"
$after = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSProvideCommentHelp
Write-Host "Remaining: $(@($after).Count)"

