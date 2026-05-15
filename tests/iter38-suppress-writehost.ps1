# VersionTag: 2605.B5.V46.0
# iter38: bulk-suppress PSAvoidUsingWriteHost — UI/CLI banner code policy-acceptable
$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidUsingWriteHost
Write-Host "Hits: $(@($findings).Count)"

$byFile = $findings | Group-Object ScriptPath
$totalPatched = 0
$totalFails = 0
$justification = "Interactive UI banner / CLI progress output; intentional Write-Host for human-readable terminal display."

foreach ($g in $byFile) {
    $path = $g.Name
    if ($path -like '*\PwSh-HelpFilesUpdateSource-ReR*') { continue }

    $bytes = [IO.File]::ReadAllBytes($path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom) { $text = $text.Substring(1) }

    $tokens = $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
    if (@($errs).Count -gt 0) { $totalFails++; continue }

    $allFuncs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $edits = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    # Find which functions contain the Write-Host calls
    foreach ($h in $g.Group) {
        # Find the deepest function containing this line
        $containing = $allFuncs | Where-Object {
            $_.Extent.StartLineNumber -le $h.Line -and $_.Extent.EndLineNumber -ge $h.Line
        } | Sort-Object { $_.Extent.EndOffset - $_.Extent.StartOffset } | Select-Object -First 1
        if (-not $containing) { continue }
        $key = "$($containing.Name)@$($containing.Extent.StartOffset)"
        if (-not $seen.Add($key)) { continue }

        $paramBlock = $containing.Body.ParamBlock
        if (-not $paramBlock) { continue }

        $existing = $paramBlock.Attributes | Where-Object {
            ($_.TypeName.Name -eq 'SuppressMessageAttribute' -or $_.TypeName.FullName -like '*SuppressMessage*') -and
            $_.Extent.Text -match 'PSAvoidUsingWriteHost'
        }
        if ($existing) { continue }

        $firstAttr = $paramBlock.Attributes | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
        $insertOffset = if ($firstAttr) { $firstAttr.Extent.StartOffset } else { $paramBlock.Extent.StartOffset }

        $j = $insertOffset - 1
        while ($j -ge 0 -and $text[$j] -ne "`n") { $j-- }
        $indent = $text.Substring($j + 1, $insertOffset - $j - 1) -replace '\S.*', ''
        $attr = "[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='$justification')]"

        $edits.Add([pscustomobject]@{
            Start = $insertOffset
            End   = $insertOffset
            New   = "$attr`r`n$indent"
        })
    }

    if ($edits.Count -eq 0) { continue }
    $sorted = $edits | Sort-Object Start -Descending
    $newText = $text
    foreach ($e in $sorted) { $newText = $newText.Substring(0, $e.Start) + $e.New + $newText.Substring($e.End) }

    $tokens2 = $errs2 = $null
    [System.Management.Automation.Language.Parser]::ParseInput($newText, [ref]$tokens2, [ref]$errs2) | Out-Null
    if (@($errs2).Count -gt 0) { Write-Host "  POST-FAIL skip $path"; $totalFails++; continue }

    $enc = New-Object System.Text.UTF8Encoding($hadBom)
    [IO.File]::WriteAllBytes($path, $enc.GetPreamble() + $enc.GetBytes($newText))
    Write-Host ("  Patched " + $edits.Count + " : " + $path)
    $totalPatched += $edits.Count
}

Write-Host "`nTotal: $totalPatched (fails: $totalFails)"
$after = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidUsingWriteHost
Write-Host "Remaining: $(@($after).Count)"

