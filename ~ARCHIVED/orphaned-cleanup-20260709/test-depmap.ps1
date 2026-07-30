# VersionTag: 2606.B5.V51.4
Import-Module C:\PowerShellGUI\modules\PwShGUI-DependencyMap.psm1 -Force
$ErrorActionPreference = 'Continue'
try {
    $m = Get-DependencyMap -WorkspacePath C:\PowerShellGUI -ErrorAction Stop
    "OK Nodes=$($m.NodeCount) Edges=$($m.EdgeCount)"
} catch {
    "FAIL: $_"
    $_.ScriptStackTrace
}



