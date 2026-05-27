# VersionTag: 2605.B5.V46.0
$mods = @(
    'PwShGUI-LegacyEncoding','PwShGUI-AutoRemediate','PwShGUI-DependencyMap',
    'PwShGUI-BreakingChange','PwShGUI-PSScriptAnalyzerScan'
)
foreach ($m in $mods) {
    $p = "C:\PowerShellGUI\modules\$m.psm1"
    $t=$null;$e=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e)
    "$($m): parse-errors=$($e.Count)"
    try { Import-Module $p -Force -DisableNameChecking; "  import OK" } catch { "  import FAIL: $($_.Exception.Message)" }
}

