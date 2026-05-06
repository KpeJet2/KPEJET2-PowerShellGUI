# VersionTag: 2605.B2.V31.7
$ErrorActionPreference = 'Stop'
$RegistryPath = 'C:\PowerShellGUI\sin_registry'
$all = New-Object System.Collections.Generic.List[object]
foreach ($f in Get-ChildItem -Path $RegistryPath -Filter '*.json' -File) {
    try {
        $obj = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { continue }
    try {
        $rec = [pscustomobject]@{
            file     = $f.Name
            id       = if ($obj.PSObject.Properties.Name -contains 'id')         { [string]$obj.id }         else { $f.BaseName }
            title    = if ($obj.PSObject.Properties.Name -contains 'title')      { [string]$obj.title }      else { '' }
            severity = if ($obj.PSObject.Properties.Name -contains 'severity')   { [string]$obj.severity }   else { '' }
            status   = if ($obj.PSObject.Properties.Name -contains 'status')     { [string]$obj.status }     else { '' }
            agent    = if ($obj.PSObject.Properties.Name -contains 'firstAgent') { [string]$obj.firstAgent } elseif ($obj.PSObject.Properties.Name -contains 'agent') { [string]$obj.agent } else { '' }
            category = if ($obj.PSObject.Properties.Name -contains 'category')   { [string]$obj.category }   else { '' }
            kind     = if ($f.Name -like 'SIN-PATTERN-*') { 'PATTERN' } elseif ($f.Name -like 'SEMI-SIN-*') { 'SEMI' } else { 'INSTANCE' }
        }
    } catch {
        Write-Host "FAIL on $($f.Name): $($_.Exception.Message)"
        continue
    }
    $all.Add($rec) | Out-Null
}
"loaded: $($all.Count)"
$json = $all | ConvertTo-Json -Depth 6
"json bytes: $($json.Length)"

