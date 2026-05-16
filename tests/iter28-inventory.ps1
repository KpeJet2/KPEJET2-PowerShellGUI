# VersionTag: 2605.B5.V46.0
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidUsingPlainTextForPassword,PSAvoidUsingConvertToSecureStringWithPlainText,PSUseUsingScopeModifierInNewRunspaces,PSReservedCmdletChar
$f | Format-Table RuleName, ScriptName, Line, Message -AutoSize

