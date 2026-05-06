# VersionTag: 2605.B2.V31.7
# iter35: Insert $PSCmdlet.ShouldProcess() guard at start of body for all
# functions PSSA flags with PSShouldProcess (i.e. SupportsShouldProcess
# declared but ShouldProcess never called). Insertion goes immediately
# after the close paren of param() block.
$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSShouldProcess
Write-Host "Hits to fix: $(@($findings).Count)"

$byFile = $findings | Group-Object ScriptPath
$totalPatched = 0
$totalParseFails = 0

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

    $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $hits = @($g.Group)
    $edits = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    foreach ($h in $hits) {
        $f = $funcs | Where-Object {
            $_.Extent.StartLineNumber -le $h.Line -and $_.Extent.EndLineNumber -ge $h.Line
        } | Sort-Object { $_.Extent.EndLineNumber - $_.Extent.StartLineNumber } | Select-Object -First 1
        if (-not $f) { continue }
        if (-not $seen.Add($f.Name + '@' + $f.Extent.StartOffset)) { continue }

        $paramBlock = $f.Body.ParamBlock
        if (-not $paramBlock) { Write-Host "    no param block: $($f.Name)"; continue }

        # Find insertion point: right after the param block's closing token (right paren)
        # ParamBlock extent ends at the ')' of param(...). Insert newline + indent + guard + newline.
        $insertOffset = $paramBlock.Extent.EndOffset
        # Find indent inside body: walk forward looking for next non-blank line
        $i = $insertOffset
        while ($i -lt $text.Length -and ($text[$i] -eq "`r" -or $text[$i] -eq "`n" -or $text[$i] -eq ' ' -or $text[$i] -eq "`t")) { $i++ }
        # Walk back from $i to start of that line to grab indent
        $j = $i - 1
        while ($j -ge 0 -and $text[$j] -ne "`n") { $j-- }
        $indent = ''
        if ($i -lt $text.Length) {
            $indent = $text.Substring($j + 1, $i - $j - 1) -replace '\S.*', ''
        }
        if ([string]::IsNullOrEmpty($indent)) { $indent = '    ' }

        $action = switch -Regex ($f.Name) {
            '^(Set-|Update-|Edit-|Rename-|Move-)' { 'Modify' }
            '^(New-|Add-|Register-|Initialize-)'  { 'Create' }
            '^(Remove-|Unregister-|Clear-|Reset-) ' { 'Delete' }
            '^(Save-|Write-|Export-|Out-)'        { 'Persist' }
            '^(Stop-|Disable-|Suspend-)'          { 'Halt' }
            '^(Start-|Enable-|Resume-|Invoke-)'   { 'Execute' }
            default                               { 'Apply' }
        }
        $guard = "`r`n${indent}if (-not `$PSCmdlet.ShouldProcess('$($f.Name)', '$action')) { return }`r`n"

        $edits.Add([pscustomobject]@{
            Start = $insertOffset
            End   = $insertOffset
            New   = $guard
            Func  = $f.Name
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
$after = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSShouldProcess
Write-Host "Remaining: $(@($after).Count)"
$after | Format-Table ScriptName, Line -AutoSize

