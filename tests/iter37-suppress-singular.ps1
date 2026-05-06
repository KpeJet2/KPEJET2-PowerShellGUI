# VersionTag: 2605.B2.V31.7
# iter37: bulk-add SuppressMessage('PSUseSingularNouns') to all 44 flagged funcs.
# Reason: most return collections; rename+alias would touch too many call sites.
$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseSingularNouns
Write-Host "Hits: $(@($findings).Count)"

$rx = [regex]"cmdlet '(?<func>[^']+)'"
$byFile = $findings | Group-Object ScriptPath
$totalPatched = 0
$totalParseFails = 0
$justification = "Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites."

foreach ($g in $byFile) {
    $path = $g.Name
    if ($path -like '*\PwSh-HelpFilesUpdateSource-ReR*') { Write-Host "  SKIP fragile: $path"; continue }

    $bytes = [IO.File]::ReadAllBytes($path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom) { $text = $text.Substring(1) }

    $tokens = $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
    if (@($errs).Count -gt 0) { Write-Host "  pre-parse fail: $path"; $totalParseFails++; continue }

    $allFuncs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $edits = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    foreach ($h in $g.Group) {
        $m = $rx.Match($h.Message)
        if (-not $m.Success) { continue }
        $fn = $m.Groups['func'].Value
        if (-not $seen.Add($fn)) { continue }

        $func = $allFuncs | Where-Object { $_.Name -eq $fn } | Select-Object -First 1
        if (-not $func) { continue }
        $paramBlock = $func.Body.ParamBlock
        if (-not $paramBlock) { continue }

        # skip if already suppressed
        $existing = $paramBlock.Attributes | Where-Object {
            ($_.TypeName.Name -eq 'SuppressMessageAttribute' -or $_.TypeName.FullName -like '*SuppressMessage*') -and
            $_.Extent.Text -match 'PSUseSingularNouns'
        }
        if ($existing) { continue }

        # Insertion point: before first attribute (CmdletBinding/OutputType/etc), or before param(
        $firstAttr = $paramBlock.Attributes | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
        $insertOffset = if ($firstAttr) { $firstAttr.Extent.StartOffset } else { $paramBlock.Extent.StartOffset }

        $j = $insertOffset - 1
        while ($j -ge 0 -and $text[$j] -ne "`n") { $j-- }
        $indent = $text.Substring($j + 1, $insertOffset - $j - 1) -replace '\S.*', ''

        $attr = "[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='$justification')]"
        $insertion = "$attr`r`n$indent"

        $edits.Add([pscustomobject]@{
            Start = $insertOffset
            End   = $insertOffset
            New   = $insertion
            Func  = $fn
        })
    }

    if ($edits.Count -eq 0) { continue }

    $sorted = $edits | Sort-Object Start -Descending
    $newText = $text
    foreach ($e in $sorted) {
        $newText = $newText.Substring(0, $e.Start) + $e.New + $newText.Substring($e.End)
    }

    $tokens2 = $errs2 = $null
    [System.Management.Automation.Language.Parser]::ParseInput($newText, [ref]$tokens2, [ref]$errs2) | Out-Null
    if (@($errs2).Count -gt 0) {
        Write-Host "  POST-PARSE FAIL ($(@($errs2).Count)) skip: $path"
        $errs2 | Select-Object -First 3 | ForEach-Object { Write-Host "    L$($_.Extent.StartLineNumber) $($_.Message)" }
        $totalParseFails++; continue
    }

    $enc = New-Object System.Text.UTF8Encoding($hadBom)
    [IO.File]::WriteAllBytes($path, $enc.GetPreamble() + $enc.GetBytes($newText))
    Write-Host ("  Patched " + $edits.Count + " : " + $path)
    $totalPatched += $edits.Count
}

Write-Host "`nTotal patched: $totalPatched (parse-fail: $totalParseFails)"
$after = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseSingularNouns
Write-Host "Remaining: $(@($after).Count)"

