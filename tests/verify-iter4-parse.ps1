# VersionTag: 2605.B2.V31.7
Add-Type -AssemblyName System.Management.Automation
$dbl = Get-ChildItem 'C:\PowerShellGUI\scripts\Build-Agentic*' -ErrorAction SilentlyContinue
$sample = @()
$sample += $dbl
$sample += Get-ChildItem 'C:\PowerShellGUI\scripts' -File -Include *.ps1,*.psm1 -Recurse | Get-Random -Count 20
$sample += Get-ChildItem 'C:\PowerShellGUI\agents' -File -Include *.ps1,*.psm1 -Recurse
$sample += Get-Item 'C:\PowerShellGUI\sovereign-kernel\Initialize-SovereignKernel.ps1' -ErrorAction SilentlyContinue
$sample += Get-Item 'C:\PowerShellGUI\UPM\UserProfile-Manager.ps1' -ErrorAction SilentlyContinue
$bad = @()
foreach ($f in $sample) {
    if ($null -eq $f) { continue }
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count -gt 0) { $bad += [PSCustomObject]@{ Path = $f.FullName; ErrCount = $errs.Count; First = $errs[0].Message } }
}
"Sampled: $($sample.Count); parse failures: $($bad.Count)"
$bad | Format-Table -AutoSize

