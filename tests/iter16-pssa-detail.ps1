# VersionTag: 2605.B2.V31.7
# Iter16: detailed PSSA findings for high-quality low-count rules
$rules = @(
    'PSPossibleIncorrectComparisonWithNull',
    'PSReservedCmdletChar',
    'PSUseApprovedVerbs',
    'PSUseBOMForUnicodeEncodedFile',
    'PSAvoidUsingPlainTextForPassword',
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    'PSUseDeclaredVarsMoreThanAssignments'
)
$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule $rules
$findings | Select-Object RuleName,@{N='File';E={Split-Path $_.ScriptPath -Leaf}},Line,Message | Format-Table -Wrap
Write-Host ("Total: " + @($findings).Count)

