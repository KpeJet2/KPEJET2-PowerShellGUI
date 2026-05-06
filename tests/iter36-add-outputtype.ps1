# VersionTag: 2605.B2.V31.7
# iter36: bulk-add [OutputType()] from PSSA findings
# Each finding tells us "cmdlet '<func>' returns an object of type '<type>'"
# We aggregate distinct types per (file, func) and inject one [OutputType(...)] attribute.

$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseOutputTypeCorrectly
Write-Host "Hits: $(@($findings).Count)"

$rx = [regex]"cmdlet '(?<func>[^']+)' returns an object of type '(?<type>[^']+)'"

# Group: (ScriptPath, Func) -> [type list]
$byFile = $findings | Group-Object ScriptPath
$totalPatched = 0
$totalParseFails = 0

foreach ($g in $byFile) {
    $path = $g.Name
    if ($path -like '*\PwSh-HelpFilesUpdateSource-ReR*') { Write-Host "  SKIP fragile: $path"; continue }

    # Build func -> [types] map for this file
    $funcMap = @{}
    foreach ($h in $g.Group) {
        $m = $rx.Match($h.Message)
        if (-not $m.Success) { continue }
        $fn = $m.Groups['func'].Value
        $tp = $m.Groups['type'].Value
        # Skip generics or arrays of object — too vague
        if ($tp -eq 'System.Object') { continue }
        if (-not $funcMap.ContainsKey($fn)) { $funcMap[$fn] = New-Object System.Collections.Generic.HashSet[string] }
        [void]$funcMap[$fn].Add($tp)
    }
    if ($funcMap.Count -eq 0) { continue }

    $bytes = [IO.File]::ReadAllBytes($path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom) { $text = $text.Substring(1) }

    $tokens = $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
    if (@($errs).Count -gt 0) { Write-Host "  pre-parse fail: $path"; $totalParseFails++; continue }

    $allFuncs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $edits = New-Object System.Collections.Generic.List[object]

    foreach ($fnName in $funcMap.Keys) {
        $func = $allFuncs | Where-Object { $_.Name -eq $fnName } | Select-Object -First 1
        if (-not $func) { continue }
        $paramBlock = $func.Body.ParamBlock
        if (-not $paramBlock) { continue }

        # Skip if function already has any [OutputType(...)] attribute
        $existing = $paramBlock.Attributes | Where-Object {
            $_.TypeName.Name -eq 'OutputType' -or $_.TypeName.FullName -eq 'OutputType'
        }
        if ($existing) { continue }

        $types = $funcMap[$fnName] | Sort-Object -Unique
        $typeArgs = ($types | ForEach-Object { "[$_]" }) -join ', '
        $newAttr = "[OutputType($typeArgs)]"

        # Insert location: just before existing [CmdletBinding(...)] if present, else before param block
        $cb = $paramBlock.Attributes | Where-Object {
            $_.TypeName.Name -eq 'CmdletBinding' -or $_.TypeName.FullName -eq 'CmdletBinding'
        } | Select-Object -First 1

        $insertOffset = if ($cb) { $cb.Extent.StartOffset } else { $paramBlock.Extent.StartOffset }

        # Compute indent: walk back to start of line
        $j = $insertOffset - 1
        while ($j -ge 0 -and $text[$j] -ne "`n") { $j-- }
        $indent = $text.Substring($j + 1, $insertOffset - $j - 1) -replace '\S.*', ''
        $insertion = "$newAttr`r`n$indent"

        $edits.Add([pscustomobject]@{
            Start = $insertOffset
            End   = $insertOffset
            New   = $insertion
            Func  = $fnName
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
    Write-Host ("  Patched " + $edits.Count + " funcs : " + $path)
    $totalPatched += $edits.Count
}

Write-Host "`nTotal funcs patched: $totalPatched (parse-fail files: $totalParseFails)"
$after = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseOutputTypeCorrectly
Write-Host "Remaining hits: $(@($after).Count)"

