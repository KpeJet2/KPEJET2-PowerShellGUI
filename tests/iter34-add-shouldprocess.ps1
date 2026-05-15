# VersionTag: 2605.B5.V46.0
# iter34: AST-targeted SupportsShouldProcess injection
# For each PSSA-flagged function: find its [CmdletBinding(...)] attribute and
# add SupportsShouldProcess. If no CmdletBinding present, insert one.
# Backward-compatible: -WhatIf/-Confirm become opt-in; default invocation unchanged.

$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseShouldProcessForStateChangingFunctions
Write-Host "Hits to fix: $(@($findings).Count)"

$byFile = $findings | Group-Object ScriptPath
$totalPatched = 0
$totalParseFails = 0

foreach ($g in $byFile) {
    $path = $g.Name
    if ($path -like '*\PwSh-HelpFilesUpdateSource-ReR*') {
        Write-Host "  SKIP (fragile): $path"; continue
    }

    $bytes = [IO.File]::ReadAllBytes($path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom) { $text = $text.Substring(1) }

    $tokens = $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
    if (@($errs).Count -gt 0) {
        Write-Host "  Pre-parse error: $path"; $totalParseFails++; continue
    }

    # Collect target function names from the findings (each finding's Line is the function's start line)
    $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $hits = @($g.Group)
    $edits = New-Object System.Collections.Generic.List[object]

    foreach ($h in $hits) {
        $f = $funcs | Where-Object {
            $_.Extent.StartLineNumber -le $h.Line -and $_.Extent.EndLineNumber -ge $h.Line
        } | Sort-Object { $_.Extent.EndLineNumber - $_.Extent.StartLineNumber } | Select-Object -First 1
        if (-not $f) { Write-Host "    no func at $($h.Line) in $($g.Name)"; continue }

        # Find CmdletBinding attribute on this function (param block attributes)
        $paramBlock = $f.Body.ParamBlock
        $cb = $null
        if ($paramBlock -and $paramBlock.Attributes) {
            $cb = $paramBlock.Attributes | Where-Object {
                $_.TypeName.FullName -eq 'CmdletBinding' -or $_.TypeName.Name -eq 'CmdletBinding'
            } | Select-Object -First 1
        }

        if ($cb) {
            # Existing CmdletBinding(...) — inject SupportsShouldProcess
            $cbText = $cb.Extent.Text
            if ($cbText -match 'SupportsShouldProcess') { continue }
            if ($cbText -match '^\[CmdletBinding\(\s*\)\]$') {
                $newCb = '[CmdletBinding(SupportsShouldProcess)]'
            } else {
                # has args; inject after first (
                $newCb = $cbText -replace '\[CmdletBinding\(', '[CmdletBinding(SupportsShouldProcess, '
            }
            $edits.Add([pscustomobject]@{
                Start = $cb.Extent.StartOffset
                End   = $cb.Extent.EndOffset
                New   = $newCb
                Func  = $f.Name
            })
        } else {
            # No CmdletBinding — insert before param( or at top of body
            if ($paramBlock) {
                # Insert [CmdletBinding(SupportsShouldProcess)]\n + indent before param block
                $paramStart = $paramBlock.Extent.StartOffset
                # Find indent: walk back from paramStart to previous newline
                $i = $paramStart - 1
                while ($i -ge 0 -and $text[$i] -ne "`n") { $i-- }
                $indent = $text.Substring($i + 1, $paramStart - $i - 1) -replace '\S.*', ''
                $insertion = "[CmdletBinding(SupportsShouldProcess)]`r`n$indent"
                $edits.Add([pscustomobject]@{
                    Start = $paramStart
                    End   = $paramStart
                    New   = $insertion
                    Func  = $f.Name
                })
            } else {
                Write-Host "    no param block in $($f.Name) — skip (would need full body rewrite)"
            }
        }
    }

    if ($edits.Count -eq 0) { continue }

    # Apply edits in reverse order to preserve offsets
    $sorted = $edits | Sort-Object Start -Descending
    $newText = $text
    foreach ($e in $sorted) {
        $newText = $newText.Substring(0, $e.Start) + $e.New + $newText.Substring($e.End)
    }

    # Validate the new text parses
    $tokens2 = $errs2 = $null
    [System.Management.Automation.Language.Parser]::ParseInput($newText, [ref]$tokens2, [ref]$errs2) | Out-Null
    if (@($errs2).Count -gt 0) {
        Write-Host "  POST-PARSE FAIL ($(@($errs2).Count) errors), skipping write: $path"
        $errs2 | Select-Object -First 3 | ForEach-Object { Write-Host "    L$($_.Extent.StartLineNumber): $($_.Message)" }
        $totalParseFails++
        continue
    }

    $enc = New-Object System.Text.UTF8Encoding($hadBom)
    [IO.File]::WriteAllBytes($path, $enc.GetPreamble() + $enc.GetBytes($newText))
    Write-Host ("  Patched " + $edits.Count + " : " + $path)
    $totalPatched += $edits.Count
}

Write-Host "`nTotal patched: $totalPatched (parse-fail files: $totalParseFails)"
$after = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseShouldProcessForStateChangingFunctions
Write-Host "Remaining: $(@($after).Count)"
$after | Format-Table ScriptName, Line -AutoSize

