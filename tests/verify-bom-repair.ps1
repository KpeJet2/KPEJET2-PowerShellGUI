# VersionTag: 2605.B2.V31.7
$mods = @(
    'AVPN-Tracker', 'CronAiAthon-ErrorLinker', 'CronAiAthon-Pipeline', 'Get-LaunchTelemetry',
    'PKIChainManager', 'PwSh-HelpFilesUpdateSource-ReR', 'PwShGUI-ConvoVault', 'PwShGUI-IntegrityCore',
    'PwShGUI-SchemaTranslator', 'PwShGUI-Theme', 'PwShGUICore', 'SASC-Adapters',
    'SINGovernance', 'UserProfileManager'
)
$root = 'C:\PowerShellGUI\modules'
$fail = 0
foreach ($m in $mods) {
    $p = Join-Path $root ($m + '.psm1')
    try {
        $null = Import-Module $p -Force -ErrorAction Stop -DisableNameChecking -PassThru
        Write-Host "OK   $m"
    } catch {
        Write-Host "FAIL $m :: $($_.Exception.Message.Split([char]10)[0])"
        $fail++
    }
}
"---"
"Failures: $fail"
exit $fail

