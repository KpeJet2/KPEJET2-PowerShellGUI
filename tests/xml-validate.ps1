# VersionTag: 2605.B2.V31.7
$path = 'C:\PowerShellGUI\~REPORTS\SIN-Scoreboard.xhtml'
$xml = New-Object System.Xml.XmlDocument
try {
    $xml.Load($path)
    'OK'
} catch [System.Xml.XmlException] {
    "XmlException line {0} col {1}: {2}" -f $_.Exception.LineNumber, $_.Exception.LinePosition, $_.Exception.Message
} catch {
    $i = $_.Exception.InnerException
    if ($i) {
        "Inner [{0}] line {1} col {2}: {3}" -f $i.GetType().Name, $i.LineNumber, $i.LinePosition, $i.Message
    } else {
        "Outer: $($_.Exception.Message.Substring(0,[Math]::Min(200,$_.Exception.Message.Length)))"
    }
}

