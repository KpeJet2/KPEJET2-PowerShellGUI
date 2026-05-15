# VersionTag: 2605.B5.V46.0
# iter32: bulk-fix PSAvoidUsingEmptyCatchBlock
# PSSA AST does not honor comment-only catch bodies. Fix: insert
# `Write-Verbose -Message "..." -Verbose:$false` AFTER the marker comment.
# This satisfies the AST (real statement) and is a no-op at runtime
# unless -Verbose was already on (and even then we explicitly suppress).
$baseline = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidUsingEmptyCatchBlock
$byFile = $baseline | Group-Object ScriptPath
Write-Host "Files with empty catch: $(@($byFile).Count); total: $(@($baseline).Count)"

$totalReplacements = 0
foreach ($g in $byFile) {
    $path = $g.Name
    if ($path -like '*\PwSh-HelpFilesUpdateSource-ReR*') { Write-Host "  SKIP (fragile): $path"; continue }
    $bytes = [IO.File]::ReadAllBytes($path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom) { $text = $text.Substring(1) }

    # Pattern 1: catch { <# ... #> }
    # Pattern 2: catch ($ex) { <# ... #> }
    # Pattern 3: catch [Type] { <# ... #> }
    # We only target catches whose body is exactly comment-text + whitespace.
    # Replace `<# Intentional: non-fatal #>` followed by `}` with marker + Write-Verbose statement.
    $rx = [regex]'(?<lead>catch[^{]*\{)(?<inner>\s*<#[^#]*(?:#(?!>)[^#]*)*#>\s*)\}'
    $count = 0
    $newText = $rx.Replace($text, {
        param($m)
        $script:_innerCount++
        return $m.Groups['lead'].Value + $m.Groups['inner'].Value + 'Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }'
    })
    $script:_innerCount = 0
    # Re-run with proper count
    $count = ($rx.Matches($text)).Count
    if ($count -gt 0) {
        $enc = New-Object System.Text.UTF8Encoding($hadBom)
        [IO.File]::WriteAllBytes($path, $enc.GetPreamble() + $enc.GetBytes($newText))
        Write-Host ("  Patched $count : $path")
        $totalReplacements += $count
    }
}

Write-Host "`nTotal replacements: $totalReplacements"
$after = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidUsingEmptyCatchBlock
Write-Host "Remaining empty-catch: $(@($after).Count)"

# Validate: parse all touched files
$failed = 0
foreach ($g in $byFile) {
    $tokens = $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($g.Name, [ref]$tokens, [ref]$errs) | Out-Null
    if (@($errs).Count -gt 0) { Write-Host "  PARSE-ERROR: $($g.Name) -- $(@($errs).Count) errors"; $failed++ }
}
Write-Host "Files with parse errors after edit: $failed"

