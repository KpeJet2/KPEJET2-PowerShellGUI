[IO.File]::WriteAllBytes(
    "Windguit_Qik-TERMInet0r2-B_TerminalLayoutManager.ps1",
    [Convert]::FromBase64String((Get-Content base64.txt -Raw))
)