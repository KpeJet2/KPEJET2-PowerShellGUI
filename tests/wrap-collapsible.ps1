# VersionTag: 2605.B2.V31.7
$path = 'C:\PowerShellGUI\~REPORTS\SIN-Scoreboard.xhtml'
$sections = @(
    @{ id='sec1'; h='1. Agent Scoreboard' },
    @{ id='sec2'; h='2. Full SIN Registry (33 Entries)' },
    @{ id='sec3'; h='3. Controls Matrix &amp; Detection Coverage' },
    @{ id='sec4'; h='4. Coverage Gaps &amp; Recommendations' },
    @{ id='sec5'; h='5. Per-Sin Control Map (All 33 Sins)' },
    @{ id='sec6'; h='6. Sin Timeline' },
    @{ id='sec7'; h='7. Agent Call Telemetry (Session 4)' },
    @{ id='sec8'; h='8. Iteration Delta Summary' },
    @{ id='sec9'; h='9. Missing Tools Assessment' }
)
$lines = [System.IO.File]::ReadAllLines($path)
$out = New-Object System.Collections.Generic.List[string]
$openCount = 0
foreach ($line in $lines) {
    $matched = $false
    foreach ($s in $sections) {
        $needle = "<h2>$($s.h)</h2>"
        if ($line.Contains($needle)) {
            if ($openCount -gt 0) { $out.Add('        </details>'); $openCount-- }
            $indent = ($line -replace '<h2.*$','')
            $out.Add("$indent<details class=`"sin-section`" id=`"$($s.id)`" open=`"open`"><summary>$($s.h)</summary>")
            $openCount++
            $matched = $true
            break
        }
    }
    if (-not $matched) { $out.Add($line) }
}
$final = New-Object System.Collections.Generic.List[string]
foreach ($l in $out) {
    if ($l -match '^\s*</body>' -and $openCount -gt 0) {
        while ($openCount -gt 0) { $final.Add('        </details>'); $openCount-- }
    }
    $final.Add($l)
}
[System.IO.File]::WriteAllLines($path, $final, (New-Object System.Text.UTF8Encoding($true)))
"Lines: $($final.Count)"
try { [xml](Get-Content $path -Raw -Encoding UTF8) | Out-Null; "XHTML-OK" } catch { "XHTML-FAIL: $_" }

