# VersionTag: 2605.B2.V31.7
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidUsingPlainTextForPassword,PSAvoidUsingConvertToSecureStringWithPlainText,PSUseUsingScopeModifierInNewRunspaces,PSReservedCmdletChar
$f | Format-Table RuleName, ScriptName, Line, Message -AutoSize

