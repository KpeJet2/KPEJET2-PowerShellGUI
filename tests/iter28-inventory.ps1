# VersionTag: 2606.B5.V51.4
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidUsingPlainTextForPassword,PSAvoidUsingConvertToSecureStringWithPlainText,PSUseUsingScopeModifierInNewRunspaces,PSReservedCmdletChar
$f | Format-Table RuleName, ScriptName, Line, Message -AutoSize



